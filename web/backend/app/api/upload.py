from uuid import UUID

from fastapi import APIRouter, Depends, UploadFile

from app.api.deps import get_current_user_id
from app.api.agent import _save_upload

router = APIRouter(prefix="/v1", tags=["upload"])


@router.post("/upload")
async def upload_file(
    file: UploadFile,
    user_id: UUID = Depends(get_current_user_id),
):
    """Upload an attachment file (JWT auth for web users)."""
    return await _save_upload(file)
