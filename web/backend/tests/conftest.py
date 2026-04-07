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
from pathlib import Path

import asyncpg
import pytest
from httpx import ASGITransport, AsyncClient

from app.api.deps import create_user_token
from app.main import app

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
    return create_user_token(user["id"], user["role"])
