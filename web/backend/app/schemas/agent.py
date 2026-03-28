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

class InboundBatch(BaseModel):
    agent_id: str  # UUID as string (Mac app sends this)
    messages: list[InboundMessage]

class InboundResponse(BaseModel):
    confirmed: list[str]  # list of confirmed message guids

class OutboundCommand(BaseModel):
    id: UUID
    phone: str
    text: str

class OutboundResponse(BaseModel):
    messages: list[OutboundCommand]

class AckRequest(BaseModel):
    status: str  # "delivered" or "failed: reason"

class HistoryBatch(BaseModel):
    agent_id: str
    messages: list[InboundMessage]
