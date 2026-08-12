import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
import asyncpg

from app.api.deps import get_current_user_id, get_db
from app.schemas.messages_api import SendMessageRequest, SendMessageResponse, CommandStatusResponse
from app.services.phone import normalize_phone
from app.services.agent_routing import resolve_agent, AgentRoutingError
from app.services.outbound_service import queue_outbound_message

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/v1/messages", tags=["messages"])


@router.post("/send", response_model=SendMessageResponse)
async def send_message(
    body: SendMessageRequest,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> SendMessageResponse:
    """Queue an outbound message for delivery by the resolved Mac agent."""
    try:
        phone = normalize_phone(body.phone)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    try:
        agent_id = await resolve_agent(conn, user_id, phone, body.agent_id)
    except AgentRoutingError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc

    row, created = await queue_outbound_message(
        conn,
        agent_id=agent_id,
        phone=phone,
        text=body.text,
        created_by_user_id=user_id,
        idempotency_key=body.idempotency_key,
        attachment_type=body.attachment_type,
        attachment_url=body.attachment_url,
    )

    # Ensure the conversation row exists so it shows up in list_conversations
    # and satisfies the FK (foreign key) the forwarding path relies on.
    await conn.execute(
        """INSERT INTO conversations (phone, agent_id)
           VALUES ($1, $2)
           ON CONFLICT (phone, agent_id) DO NOTHING""",
        phone, agent_id,
    )

    logger.info("send_message user_id=%s agent_id=%s phone=%s cmd_id=%s created=%s",
                user_id, agent_id, phone, row["id"], created)

    return SendMessageResponse(
        command_id=row["id"],
        agent_id=row["agent_id"],
        phone=row["phone"],
        status=row["status"],
        created=created,
    )


@router.get("/{command_id}", response_model=CommandStatusResponse)
async def get_command_status(
    command_id: UUID,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> CommandStatusResponse:
    """Look up delivery status for a previously-queued outbound command.

    Visible to the agent's owner and to the command's creator (a forwarded-
    thread reply is authored by the recipient, not the agent owner).
    """
    row = await conn.fetchrow(
        """SELECT oc.*, a.last_seen_at, a.user_id
           FROM outbound_commands oc
           JOIN agents a ON oc.agent_id = a.id
           WHERE oc.id = $1""",
        command_id,
    )
    if row is None or (row["user_id"] != user_id and row["created_by_user_id"] != user_id):
        raise HTTPException(status_code=404, detail="Command not found")

    return CommandStatusResponse(
        id=row["id"],
        phone=row["phone"],
        agent_id=row["agent_id"],
        text=row["text"],
        status=row["status"],
        created_at=row["created_at"],
        acked_at=row["acked_at"],
        agent_last_seen_at=row["last_seen_at"],
    )
