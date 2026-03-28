from datetime import datetime, timedelta, timezone
from typing import NamedTuple
from uuid import UUID
import hashlib

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
import asyncpg

from app.config import settings
from app.db import get_db

bearer_scheme = HTTPBearer(auto_error=False)

class TokenPayload(NamedTuple):
    user_id: UUID
    role: str

def create_user_token(user_id: UUID, role: str = "member") -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "role": role,
        "iat": now,
        "exp": now + timedelta(hours=settings.JWT_EXPIRE_HOURS),
    }
    return jwt.encode(payload, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)

async def get_current_user_id(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> UUID:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    try:
        payload = jwt.decode(credentials.credentials, settings.JWT_SECRET, algorithms=[settings.JWT_ALGORITHM])
        user_id = payload.get("sub")
        if user_id is None:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
        return UUID(user_id)
    except (JWTError, ValueError) as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token") from exc

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
