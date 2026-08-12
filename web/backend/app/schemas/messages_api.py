from typing import Optional
from uuid import UUID
from datetime import datetime

from pydantic import BaseModel, Field, model_validator


class SendMessageRequest(BaseModel):
    phone: str
    text: str = ""
    agent_id: Optional[UUID] = None
    attachment_type: Optional[str] = None
    attachment_url: Optional[str] = None
    # Client-generated, unique per (user, logical send) so retries/double-taps
    # never queue the message twice. See migrations/006_send_idempotency.sql.
    idempotency_key: str = Field(..., min_length=8)

    @model_validator(mode="after")
    def _text_or_attachment(self) -> "SendMessageRequest":
        if not self.text and not self.attachment_url:
            raise ValueError("text may only be empty when attachment_url is set")
        return self


class SendMessageResponse(BaseModel):
    command_id: UUID
    agent_id: UUID
    phone: str
    status: str
    created: bool  # False when this call replayed an existing idempotency_key


class CommandStatusResponse(BaseModel):
    id: UUID
    phone: str
    agent_id: UUID
    text: str
    status: str
    created_at: datetime
    acked_at: Optional[datetime] = None
    agent_last_seen_at: Optional[datetime] = None
