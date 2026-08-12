from uuid import UUID
import hashlib

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
import asyncpg

from app.db import get_db
from app.shared.auth import verify_user_access_token
from app.services.user_service import upsert_user_from_claims

bearer_scheme = HTTPBearer(auto_error=False)

async def get_current_user_id(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    conn: asyncpg.Connection = Depends(get_db),
) -> UUID:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")

    claims = await verify_user_access_token(credentials.credentials)

    # Machine tokens (mf CLI service accounts, etc.) don't get to hit
    # human-facing endpoints through this dependency — that's what
    # require_agent_auth / the m2m path is for.
    if claims.get("principal_type") == "service_account":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Service account tokens are not accepted here")

    try:
        user = await upsert_user_from_claims(conn, claims)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc

    return UUID(str(user["id"]))

async def require_agent_auth(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    conn: asyncpg.Connection = Depends(get_db),
) -> dict:
    """Validate agent API key. Returns agent record as dict."""
    if credentials is None:
        raise HTTPException(status_code=401, detail="Not authenticated")
    api_key = credentials.credentials
    key_hash = hashlib.sha256(api_key.encode()).hexdigest()
    agent = await conn.fetchrow("SELECT * FROM agents WHERE api_key_hash = $1", key_hash)
    if agent is None:
        raise HTTPException(status_code=401, detail="Invalid API key")
    await conn.execute("UPDATE agents SET last_seen_at = now() WHERE id = $1", agent["id"])
    return dict(agent)
