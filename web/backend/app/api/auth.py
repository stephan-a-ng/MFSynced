import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
import asyncpg

from app.api.deps import get_current_user_id, get_db
from app.config import settings
from app.schemas.auth import UserResponse

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/v1/auth", tags=["auth"])

@router.get("/config")
async def auth_config():
    return {
        "auth_mode": "oidc",
        "user_access_url": settings.user_access_issuer,
        "client_id": settings.user_access_audience,
    }

@router.get("/me", response_model=UserResponse)
async def get_me(
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> UserResponse:
    user = await conn.fetchrow("SELECT * FROM users WHERE id = $1", user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return UserResponse(id=user["id"], email=user["email"], name=user["name"], picture=user["photo_url"], role=user["role"])
