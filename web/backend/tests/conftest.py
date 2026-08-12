"""
Test fixtures for MFSynced backend.

Uses a real PostgreSQL test database (mfsynced_test) so SQL logic is
validated end-to-end — no mocks. A single connection is shared across all
tests; each test wraps its work in a SAVEPOINT that is rolled back on
teardown so tests don't interfere with each other.

Pre-requisites (one-time setup by a superuser):
  createdb -U stephanng mfsynced_test
  psql -U stephanng -d mfsynced_test -c "GRANT ALL PRIVILEGES ON DATABASE mfsynced_test TO mfsynced;"
  psql -U stephanng -d mfsynced_test -c "GRANT ALL ON SCHEMA public TO mfsynced;"
"""
import hashlib
import secrets
import time
from pathlib import Path
from unittest.mock import patch

import asyncpg
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from httpx import ASGITransport, AsyncClient
from jose import jwt as jose_jwt

from app.main import app

# ---------------------------------------------------------------------------
# user-access OIDC test doubles: session RSA keypair + fake JWKS.
# The app verifies tokens against app.shared.auth's JWKS fetch; we patch that
# fetch for the whole session and mint RS256 tokens with the test key.
# ---------------------------------------------------------------------------

TEST_ISSUER = "https://user-access-test.invalid"
TEST_AUDIENCE = "message-test"
TEST_KID = "conftest-key-1"

_private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
TEST_PRIVATE_PEM = _private_key.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    serialization.NoEncryption(),
).decode()


def _b64url_uint(n: int) -> str:
    import base64

    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


_pub = _private_key.public_key().public_numbers()
TEST_JWKS = {
    "keys": [
        {
            "kty": "RSA",
            "kid": TEST_KID,
            "use": "sig",
            "alg": "RS256",
            "n": _b64url_uint(_pub.n),
            "e": _b64url_uint(_pub.e),
        }
    ]
}


@pytest.fixture(scope="session", autouse=True)
def _uploads_tmp_dir(tmp_path_factory):
    """Point UPLOAD_DIR at a session tmp dir - endpoint tests write real
    files, which must never land in the repo's working tree."""
    from app.config import settings

    settings.UPLOAD_DIR = str(tmp_path_factory.mktemp("uploads"))
    yield


@pytest.fixture(scope="session", autouse=True)
def _user_access_test_idp():
    """Point the app's verifier at the test issuer/JWKS for the whole session."""
    from app.config import settings
    import app.shared.auth as ua_auth

    settings.user_access_issuer = TEST_ISSUER
    settings.user_access_jwks_url = f"{TEST_ISSUER}/.well-known/jwks.json"
    settings.user_access_audience = TEST_AUDIENCE
    settings.user_access_operator_audiences = ""

    async def _fake_fetch_jwks():
        return TEST_JWKS

    ua_auth.clear_jwks_cache()
    with patch.object(ua_auth, "_fetch_jwks", _fake_fetch_jwks):
        yield
    ua_auth.clear_jwks_cache()

MIGRATIONS_DIR = Path(__file__).parent.parent / "migrations"
TEST_DB_URL = "postgresql://mfsynced:mfsynced@localhost:5432/mfsynced_test"

# ---------------------------------------------------------------------------
# Session-scoped infrastructure: pool + schema + one shared connection
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
async def _db_pool():
    pool = await asyncpg.create_pool(TEST_DB_URL, min_size=1, max_size=5)

    # Wipe and rebuild schema from migrations once per session
    async with pool.acquire() as conn:
        await conn.execute("""
            DROP TABLE IF EXISTS reactions CASCADE;
            DROP TABLE IF EXISTS outbound_commands CASCADE;
            DROP TABLE IF EXISTS forwarded_thread_recipients CASCADE;
            DROP TABLE IF EXISTS forwarded_threads CASCADE;
            DROP TABLE IF EXISTS messages CASCADE;
            DROP TABLE IF EXISTS conversations CASCADE;
            DROP TABLE IF EXISTS agents CASCADE;
            DROP TABLE IF EXISTS users CASCADE;
        """)
        for sql_file in sorted(MIGRATIONS_DIR.glob("*.sql")):
            await conn.execute(sql_file.read_text())

    yield pool
    await pool.close()


@pytest.fixture(scope="session")
async def _db_conn(_db_pool):
    """One connection shared for all tests in the session."""
    conn = await _db_pool.acquire()
    yield conn
    await _db_pool.release(conn)


@pytest.fixture(scope="session")
async def _client(_db_conn):
    """One httpx client with get_db wired to the shared connection."""
    from app.db import get_db

    async def _override_get_db():
        yield _db_conn

    app.dependency_overrides[get_db] = _override_get_db
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.pop(get_db, None)


# ---------------------------------------------------------------------------
# Function-scoped: SAVEPOINT isolation so each test starts clean
# ---------------------------------------------------------------------------

@pytest.fixture
async def db_conn(_db_conn):
    """Per-test isolation via table truncation before each test."""
    await _db_conn.execute("""
        TRUNCATE reactions, outbound_commands, forwarded_thread_recipients,
                 forwarded_threads, messages, conversations, agents, users
        RESTART IDENTITY CASCADE
    """)
    yield _db_conn


@pytest.fixture
def client(_client):
    """Tests receive the session-level client; isolation is via db_conn savepoints."""
    return _client


# ---------------------------------------------------------------------------
# Seed helpers
# ---------------------------------------------------------------------------

async def _insert_user(conn, email: str, name: str, role: str = "member") -> dict:
    return dict(await conn.fetchrow(
        """INSERT INTO users (google_id, email, name, role)
           VALUES ($1, $2, $3, $4) RETURNING *""",
        f"test-{email}", email, name, role,
    ))


async def _insert_agent(conn, user_id, name: str = "Test Mac") -> tuple[dict, str]:
    """Returns (agent_record, raw_api_key)."""
    raw_key = secrets.token_hex(32)
    key_hash = hashlib.sha256(raw_key.encode()).hexdigest()
    agent = dict(await conn.fetchrow(
        """INSERT INTO agents (user_id, name, api_key_hash)
           VALUES ($1, $2, $3) RETURNING *""",
        user_id, name, key_hash,
    ))
    return agent, raw_key


async def _insert_conversation(conn, phone: str, agent_id) -> None:
    await conn.execute(
        "INSERT INTO conversations (phone, agent_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        phone, agent_id,
    )


# ---------------------------------------------------------------------------
# Per-test seed fixtures (all depend on db_conn so they're rolled back)
# ---------------------------------------------------------------------------

@pytest.fixture
async def admin_user(db_conn) -> dict:
    return await _insert_user(db_conn, "stephan@moonfive.tech", "Stephan", role="admin")


@pytest.fixture
async def chase_user(db_conn) -> dict:
    return await _insert_user(db_conn, "chase@moonfive.tech", "Chase")


@pytest.fixture
async def marco_user(db_conn) -> dict:
    return await _insert_user(db_conn, "marco@moonfive.tech", "Marco")


@pytest.fixture
async def test_agent(db_conn, admin_user) -> tuple[dict, str]:
    """Returns (agent, raw_api_key)."""
    return await _insert_agent(db_conn, admin_user["id"])


@pytest.fixture
async def test_conversation(db_conn, test_agent) -> str:
    agent, _ = test_agent
    phone = "+15005550001"
    await _insert_conversation(db_conn, phone, agent["id"])
    return phone


def make_token(user: dict) -> str:
    """Mint a user-access-style RS256 token for a seeded user row.

    The email claim links the token to the row via the upsert-by-email path,
    so tests keep working with users inserted directly by fixtures.
    """
    now = int(time.time())
    claims = {
        "iss": TEST_ISSUER,
        "aud": TEST_AUDIENCE,
        "sub": user.get("user_access_sub") or f"test-sub-{user['email']}",
        "email": user["email"],
        "email_verified": True,
        "name": user.get("name") or user["email"],
        "app_role": user.get("role", "member"),
        "iat": now,
        "exp": now + 900,
    }
    return jose_jwt.encode(
        claims, TEST_PRIVATE_PEM, algorithm="RS256", headers={"kid": TEST_KID}
    )
