"""Verify access tokens issued by user-access (the OIDC (OpenID Connect) IdP (identity provider)).

Fetches and caches the JWKS (JSON Web Key Set) document from user-access, verifies the RS256
signature against the matching key (lookup by `kid` header, resolved by
python-jose against the whole JWK set), and validates `iss` + `exp`.
Audience is checked manually (not via jose's `audience=` kwarg) so we can
accept either this app's own audience or one of the shared "operator"
audiences (e.g. the `mf` CLI's client id) — see
user-access/docs/INTEGRATION.md and inventory's
app/features/auth/user_access.py for the two upstream patterns this
merges.

Raises HTTPException(401) on any failure — bad signature, wrong issuer,
disallowed audience, expired, malformed token, etc.
"""
from __future__ import annotations

import logging
import time
from typing import Any

import httpx
from fastapi import HTTPException
from jose import jwt
from jose.exceptions import JWTError

from app.config import settings

logger = logging.getLogger(__name__)

# JWKS cache. user-access rotates its RS256 signing key, so we can't cache
# the key set forever (that would reject every token minted under the new
# key until this process restarts). Cache with a TTL, and force ONE refetch
# when a token's `kid` isn't in the cached set — so a rotation propagates
# within seconds, no redeploy required.
_JWKS_TTL_SECONDS = 3600  # 1 hour
_jwks_cache: dict[str, Any] = {"keys": None, "fetched_at": 0.0}


async def _fetch_jwks() -> dict:
    """Raw, uncached fetch of the JWKS document. Patched directly in tests."""
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.get(settings.user_access_jwks_url)
        resp.raise_for_status()
        return resp.json()


async def _load_jwks(force: bool = False) -> dict:
    now = time.monotonic()
    fresh = (
        _jwks_cache["keys"] is not None
        and now - _jwks_cache["fetched_at"] < _JWKS_TTL_SECONDS
    )
    if not force and fresh:
        return _jwks_cache["keys"]
    keys = await _fetch_jwks()
    _jwks_cache["keys"] = keys
    _jwks_cache["fetched_at"] = now
    return keys


def clear_jwks_cache() -> None:
    """Drop the cached JWKS document, forcing the next verify to refetch."""
    _jwks_cache["keys"] = None
    _jwks_cache["fetched_at"] = 0.0


async def verify_user_access_token(token: str) -> dict:
    """Verify a user-access RS256 JWT and return its claims.

    Accepts tokens whose `aud` is either `settings.user_access_audience`
    (this app's own client id) or one of the comma-separated
    `settings.user_access_operator_audiences` (shared operator/CLI
    clients). `iss` and `exp` are always enforced.
    """
    try:
        header = jwt.get_unverified_header(token)
    except JWTError as exc:
        raise HTTPException(401, "Malformed token") from exc

    kid = header.get("kid")

    jwks = await _load_jwks()
    known_kids = {k.get("kid") for k in jwks.get("keys", [])}
    if kid and kid not in known_kids:
        # Unknown kid against the cached set => user-access likely rotated.
        # Force one refetch before giving up (bounded: a single refetch,
        # never a loop).
        jwks = await _load_jwks(force=True)

    try:
        # Verify signature + issuer + expiry here; validate the audience
        # ourselves below so we can accept more than one value.
        claims = jwt.decode(
            token,
            jwks,
            algorithms=["RS256"],
            issuer=settings.user_access_issuer,
            options={"verify_aud": False},
        )
    except JWTError as exc:
        logger.warning("user-access JWT rejected: %s", exc)
        raise HTTPException(401, "Invalid token") from exc

    allowed = {settings.user_access_audience}
    allowed |= {a.strip() for a in settings.user_access_operator_audiences.split(",")}
    allowed.discard("")
    raw_aud = claims.get("aud")
    token_auds = {raw_aud} if isinstance(raw_aud, str) else set(raw_aud or ())
    if not (allowed & token_auds):
        logger.warning(
            "user-access JWT rejected: audience %s not in allowed %s",
            sorted(token_auds), sorted(allowed),
        )
        raise HTTPException(401, "Invalid token")

    if not claims.get("sub"):
        raise HTTPException(401, "Token missing sub")

    return claims
