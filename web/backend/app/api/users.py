from uuid import UUID
from fastapi import APIRouter, Depends
import asyncpg
from app.api.deps import get_current_user_id, get_db
from app.schemas.auth import UserResponse

router = APIRouter(prefix="/v1/users", tags=["users"])

@router.get("", response_model=list[UserResponse])
async def list_users(
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> list[UserResponse]:
    rows = await conn.fetch("SELECT * FROM users ORDER BY name")
    return [
        UserResponse(id=r["id"], email=r["email"], name=r["name"], picture=r["photo_url"], role=r["role"])
        for r in rows
    ]
