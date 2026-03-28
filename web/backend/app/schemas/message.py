from uuid import UUID
from datetime import datetime
from pydantic import BaseModel

class MessageResponse(BaseModel):
    id: UUID
    guid: str
    phone: str
    text: str
    timestamp: datetime
    is_from_me: bool
    service: str

class ConversationResponse(BaseModel):
    phone: str
    agent_id: UUID
    contact_name: str | None = None
    last_message_at: datetime | None = None
    message_count: int = 0
