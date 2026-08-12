"""
Tests for app.shared.auth — user-access OIDC JWT verification.

Spec: `verify_user_access_token(token)` validates an RS256 JWT issued by the
bespoke user-access OIDC provider — signature via JWKS, issuer match,
audience match (primary OR one of the comma-separated operator audiences),
exp enforcement, and in-process JWKS caching with a one-shot re-fetch on an
unknown `kid` (key-rotation tolerance). Any failure -> HTTPException(401).
`clear_jwks_cache()` is a test hook that resets the module-level cache.

TDD RED: `app/shared/auth.py` does not exist yet. This whole file is
expected to fail at collection with ImportError/ModuleNotFoundError until
that module (and the new `user_access_*` fields on `app.config.Settings`)
are implemented. That is expected — this file is the spec.

Self-contained: generates its own RSA keypairs and JWKS fixtures, and stubs
the network fetch — no conftest fixtures, no DB.
"""
import base64
from datetime import datetime, timedelta, timezone

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import HTTPException
from jose import jwt

from app.config import settings

# The module under test does not exist yet (TDD RED). Importing at module
# scope means pytest collection itself fails loudly with ImportError, which
# is the expected starting state for every test below.
import app.shared.auth as auth_module
from app.shared.auth import clear_jwks_cache, verify_user_access_token

# ---------------------------------------------------------------------------
# Fixed test settings
# ---------------------------------------------------------------------------

TEST_ISSUER = "https://user-access.moonfive.tech/"
TEST_JWKS_URL = "https://user-access.moonfive.tech/.well-known/jwks.json"
TEST_AUDIENCE = "mfsynced-web"
TEST_OPERATOR_AUDIENCES = "ua-cli,ua-mobile"
TEST_KID = "test-key-1"
ROTATED_KID = "test-key-2"

# ---------------------------------------------------------------------------
# RSA keypairs + JWKS fixture data (module scope — generated once)
# ---------------------------------------------------------------------------

_PRIVATE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_PUBLIC_KEY = _PRIVATE_KEY.public_key()

PRIVATE_PEM = _PRIVATE_KEY.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
).decode("utf-8")

# A second, unrelated keypair — simulates a token forged with the wrong key
# (e.g. an attacker's key) while still claiming the trusted `kid`.
_OTHER_PRIVATE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_PRIVATE_PEM = _OTHER_PRIVATE_KEY.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
).decode("utf-8")

# A third keypair, published only under ROTATED_KID — simulates a rotated
# signing key that shows up on JWKS re-fetch but not the initial fetch.
_ROTATED_PRIVATE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ROTATED_PRIVATE_PEM = _ROTATED_PRIVATE_KEY.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
).decode("utf-8")


def _b64url_uint(value: int) -> str:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _jwk_for(public_key, kid: str) -> dict:
    numbers = public_key.public_numbers()
    return {
        "kty": "RSA",
        "kid": kid,
        "use": "sig",
        "alg": "RS256",
        "n": _b64url_uint(numbers.n),
        "e": _b64url_uint(numbers.e),
    }


JWKS_WITH_TEST_KEY = {"keys": [_jwk_for(_PUBLIC_KEY, TEST_KID)]}
JWKS_WITH_ROTATED_KEY = {
    "keys": [
        _jwk_for(_PUBLIC_KEY, TEST_KID),
        _jwk_for(_ROTATED_PRIVATE_KEY.public_key(), ROTATED_KID),
    ]
}

# A non-PEM-looking secret derived from the published modulus — used for the
# HS256 alg-confusion attempt. (python-jose refuses to use a PEM-formatted
# key as an HMAC secret outright, so a "use the public key as the HMAC
# secret" attack has to use its raw material instead; either way, RS256-only
# enforcement must reject it regardless of what secret was used to sign.)
_HS256_ATTACK_SECRET = JWKS_WITH_TEST_KEY["keys"][0]["n"]


def make_token(
    claims_overrides: dict | None = None,
    *,
    kid: str | None = TEST_KID,
    key: str = PRIVATE_PEM,
    algorithm: str = "RS256",
) -> str:
    """Sign a test JWT. Defaults match TEST_ISSUER/TEST_AUDIENCE with a 1h exp."""
    now = datetime.now(timezone.utc)
    claims = {
        "iss": TEST_ISSUER,
        "aud": TEST_AUDIENCE,
        "sub": "user-abc123",
        "email": "stephan@moonfive.tech",
        "iat": now,
        "exp": now + timedelta(hours=1),
    }
    if claims_overrides:
        claims.update(claims_overrides)
    headers = {"kid": kid} if kid is not None else {}
    return jwt.encode(claims, key, algorithm=algorithm, headers=headers)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _reset_auth_state(monkeypatch):
    """Point settings at the test IdP and reset the module-level JWKS cache
    before and after every test, so nothing leaks between tests."""
    monkeypatch.setattr(settings, "user_access_issuer", TEST_ISSUER)
    monkeypatch.setattr(settings, "user_access_jwks_url", TEST_JWKS_URL)
    monkeypatch.setattr(settings, "user_access_audience", TEST_AUDIENCE)
    monkeypatch.setattr(settings, "user_access_operator_audiences", TEST_OPERATOR_AUDIENCES)
    clear_jwks_cache()
    yield
    clear_jwks_cache()


def _patch_fetch(monkeypatch, *responses: dict):
    """Patch app.shared.auth._fetch_jwks with an async stub that returns
    `responses` in sequence (the last response repeats for any extra calls).
    Returns a dict with a live "count" of how many times it was called, so
    tests can assert on re-fetch behavior.
    """
    calls = {"count": 0}

    async def _fake_fetch_jwks():
        idx = min(calls["count"], len(responses) - 1)
        calls["count"] += 1
        return responses[idx]

    monkeypatch.setattr(auth_module, "_fetch_jwks", _fake_fetch_jwks)
    return calls


# ---------------------------------------------------------------------------
# 1. Valid token -> returns claims
# ---------------------------------------------------------------------------

async def test_valid_token_returns_claims(monkeypatch):
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)
    token = make_token({"sub": "user-42", "email": "chase@moonfive.tech"})

    claims = await verify_user_access_token(token)

    assert claims["sub"] == "user-42"
    assert claims["email"] == "chase@moonfive.tech"


# ---------------------------------------------------------------------------
# 2. Wrong audience -> 401
# ---------------------------------------------------------------------------

async def test_wrong_audience_rejected(monkeypatch):
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)
    token = make_token({"aud": "some-other-app"})

    with pytest.raises(HTTPException) as exc_info:
        await verify_user_access_token(token)
    assert exc_info.value.status_code == 401


# ---------------------------------------------------------------------------
# 3. Audience in operator_audiences -> accepted
# ---------------------------------------------------------------------------

async def test_operator_audience_accepted(monkeypatch):
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)
    token = make_token({"aud": "ua-cli"})  # in TEST_OPERATOR_AUDIENCES, not the primary aud

    claims = await verify_user_access_token(token)

    assert claims["aud"] == "ua-cli"


# ---------------------------------------------------------------------------
# 4. Wrong issuer -> 401
# ---------------------------------------------------------------------------

async def test_wrong_issuer_rejected(monkeypatch):
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)
    token = make_token({"iss": "https://not-user-access.example.com/"})

    with pytest.raises(HTTPException) as exc_info:
        await verify_user_access_token(token)
    assert exc_info.value.status_code == 401


# ---------------------------------------------------------------------------
# 5. Expired -> 401
# ---------------------------------------------------------------------------

async def test_expired_token_rejected(monkeypatch):
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)
    now = datetime.now(timezone.utc)
    token = make_token({"iat": now - timedelta(hours=2), "exp": now - timedelta(hours=1)})

    with pytest.raises(HTTPException) as exc_info:
        await verify_user_access_token(token)
    assert exc_info.value.status_code == 401


# ---------------------------------------------------------------------------
# 6. Token signed by a DIFFERENT RSA key (same kid) -> 401
# ---------------------------------------------------------------------------

async def test_wrong_signing_key_same_kid_rejected(monkeypatch):
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)
    # kid=TEST_KID (default), but signed with a key never published under it.
    token = make_token(key=OTHER_PRIVATE_PEM)

    with pytest.raises(HTTPException) as exc_info:
        await verify_user_access_token(token)
    assert exc_info.value.status_code == 401


# ---------------------------------------------------------------------------
# 7. Unknown kid, refetch finds it -> accepted (rotation tolerance)
# ---------------------------------------------------------------------------

async def test_unknown_kid_triggers_refetch_and_succeeds(monkeypatch):
    calls = _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY, JWKS_WITH_ROTATED_KEY)
    token = make_token(kid=ROTATED_KID, key=ROTATED_PRIVATE_PEM)

    claims = await verify_user_access_token(token)

    assert claims["sub"] == "user-abc123"
    assert calls["count"] == 2  # initial fetch (miss) + one forced re-fetch


# ---------------------------------------------------------------------------
# 8. Unknown kid, refetch still lacks it -> 401
# ---------------------------------------------------------------------------

async def test_unknown_kid_still_missing_after_refetch_rejected(monkeypatch):
    calls = _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY, JWKS_WITH_TEST_KEY)
    token = make_token(kid="never-published-kid", key=OTHER_PRIVATE_PEM)

    with pytest.raises(HTTPException) as exc_info:
        await verify_user_access_token(token)
    assert exc_info.value.status_code == 401
    assert calls["count"] == 2  # still only one forced re-fetch, not a retry loop


# ---------------------------------------------------------------------------
# 9. HS256 alg confusion -> 401
# ---------------------------------------------------------------------------

async def test_hs256_alg_confusion_rejected(monkeypatch):
    """RS256-only enforcement: a token signed HS256 (e.g. an attacker trying
    to use published key material as an HMAC secret) must be rejected
    outright, not silently accepted because a key for `kid` was found."""
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)
    token = make_token(key=_HS256_ATTACK_SECRET, algorithm="HS256")

    with pytest.raises(HTTPException) as exc_info:
        await verify_user_access_token(token)
    assert exc_info.value.status_code == 401


# ---------------------------------------------------------------------------
# 10. Garbage string -> 401
# ---------------------------------------------------------------------------

async def test_garbage_token_rejected(monkeypatch):
    _patch_fetch(monkeypatch, JWKS_WITH_TEST_KEY)

    with pytest.raises(HTTPException) as exc_info:
        await verify_user_access_token("not-a-real-jwt")
    assert exc_info.value.status_code == 401
