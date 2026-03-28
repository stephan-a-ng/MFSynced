from uuid import UUID
from datetime import datetime
from pydantic import BaseModel

class InboxThreadResponse(BaseModel):
    id: UUID
    phone: str
    agent_id: UUID
    contact_name: str | None = None
    mode: str  # "fyi" or "action"
    note: str | None = None
    forwarded_by_name: str
    forwarded_by_picture: str | None = None
    has_read: bool = False
    last_message_text: str | None = None
    last_message_at: datetime | None = None
    created_at: datetime

class ThreadDetailResponse(BaseModel):
    thread: InboxThreadResponse
    messages: list['MessageResponse']

class ReplyRequest(BaseModel):
    text: str

# Forward import
from app.schemas.message import MessageResponse
ThreadDetailResponse.model_rebuild()
