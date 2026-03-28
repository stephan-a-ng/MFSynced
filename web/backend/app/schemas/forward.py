from uuid import UUID
from pydantic import BaseModel

class ForwardRequest(BaseModel):
    phone: str
    agent_id: UUID
    recipient_user_ids: list[UUID]
    mode: str = "fyi"  # "fyi" or "action"
    note: str | None = None

class ForwardResponse(BaseModel):
    thread_id: UUID
