from typing import Optional
from uuid import UUID
from datetime import datetime
from pydantic import BaseModel

class ReactionResponse(BaseModel):
    reaction_type: str
    is_from_me: bool

class MessageResponse(BaseModel):
    id: UUID
    guid: str
    phone: str
    text: str
    timestamp: datetime
    is_from_me: bool
    service: str
    attachment_type: Optional[str] = None
    attachment_url: Optional[str] = None
    attachment_mime_type: Optional[str] = None
    attachment_filename: Optional[str] = None
    reactions: list[ReactionResponse] = []

class ConversationResponse(BaseModel):
    phone: str
    agent_id: UUID
    contact_name: Optional[str] = None
    last_message_at: Optional[datetime] = None
    message_count: int = 0
