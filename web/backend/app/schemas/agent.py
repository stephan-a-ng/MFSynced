from typing import Optional
from uuid import UUID
from pydantic import BaseModel

class RegisterRequest(BaseModel):
    name: str = "My Mac"

class RegisterResponse(BaseModel):
    agent_id: UUID
    api_key: str  # Only returned once at registration

class InboundMessage(BaseModel):
    id: str  # message guid
    phone: str
    text: str = ""
    timestamp: str  # ISO8601
    is_from_me: bool = False
    service: str = "iMessage"
    contact_name: Optional[str] = None         # resolved from Contacts on Mac
    attachment_type: Optional[str] = None      # 'image', 'video', 'audio'
    attachment_url: Optional[str] = None
    attachment_mime_type: Optional[str] = None
    attachment_filename: Optional[str] = None

class InboundBatch(BaseModel):
    agent_id: str  # UUID as string (Mac app sends this)
    messages: list[InboundMessage]

class InboundResponse(BaseModel):
    confirmed: list[str]  # list of confirmed message guids

class InboundReaction(BaseModel):
    message_guid: str
    reaction_type: str  # love, like, dislike, laugh, emphasize, question
    is_from_me: bool = False

class InboundReactionBatch(BaseModel):
    agent_id: str
    reactions: list[InboundReaction]

class OutboundCommand(BaseModel):
    id: UUID
    phone: str
    text: str
    attachment_type: Optional[str] = None
    attachment_url: Optional[str] = None

class OutboundResponse(BaseModel):
    messages: list[OutboundCommand]

class AckRequest(BaseModel):
    status: str  # "delivered" or "failed: reason"

class HistoryBatch(BaseModel):
    agent_id: str
    messages: list[InboundMessage]

class AgentForwardRequest(BaseModel):
    phone: str
    mode: str = "action"  # "fyi" or "action"
    note: Optional[str] = None
    recipient_user_ids: list[str]  # UUID strings
