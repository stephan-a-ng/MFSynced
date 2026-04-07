from typing import Optional
from uuid import UUID
from datetime import datetime
from pydantic import BaseModel

class InboxThreadResponse(BaseModel):
    id: UUID
    phone: str
    agent_id: UUID
    contact_name: Optional[str] = None
    mode: str  # "fyi" or "action"
    note: Optional[str] = None
    forwarded_by_name: str
    forwarded_by_picture: Optional[str] = None
    has_read: bool = False
    is_archived: bool = False
    last_message_text: Optional[str] = None
    last_message_at: Optional[datetime] = None
    created_at: datetime

class ThreadDetailResponse(BaseModel):
    thread: InboxThreadResponse
    messages: list['MessageResponse']

class ReplyRequest(BaseModel):
    text: str = ""
    attachment_type: Optional[str] = None
    attachment_url: Optional[str] = None

class ReactRequest(BaseModel):
    message_guid: str
    reaction_type: str  # love, like, dislike, laugh, emphasize, question

# Forward import
from app.schemas.message import MessageResponse
ThreadDetailResponse.model_rebuild()
