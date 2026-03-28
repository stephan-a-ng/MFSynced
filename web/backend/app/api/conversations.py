from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException, Query
import asyncpg

from app.api.deps import get_current_user_id, get_db
from app.schemas.message import ConversationResponse, MessageResponse

router = APIRouter(prefix="/v1/conversations", tags=["conversations"])

@router.get("", response_model=list[ConversationResponse])
async def list_conversations(
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> list[ConversationResponse]:
    """List all conversations for agents owned by the current user."""
    rows = await conn.fetch(
        """SELECT c.phone, c.agent_id, c.contact_name, c.last_message_at, c.message_count
           FROM conversations c
           JOIN agents a ON c.agent_id = a.id
           WHERE a.user_id = $1
           ORDER BY c.last_message_at DESC NULLS LAST""",
        user_id,
    )
    return [ConversationResponse(**dict(r)) for r in rows]

@router.get("/{phone}/messages", response_model=list[MessageResponse])
async def get_conversation_messages(
    phone: str,
    agent_id: UUID = Query(...),
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
    limit: int = Query(100, le=500),
    offset: int = Query(0),
) -> list[MessageResponse]:
    """Get messages for a specific conversation."""
    # Verify user owns this agent
    agent = await conn.fetchrow("SELECT * FROM agents WHERE id = $1 AND user_id = $2", agent_id, user_id)
    if agent is None:
        raise HTTPException(status_code=403, detail="Not your agent")

    rows = await conn.fetch(
        """SELECT id, guid, phone, text, timestamp, is_from_me, service
           FROM messages
           WHERE phone = $1 AND agent_id = $2
           ORDER BY timestamp ASC
           LIMIT $3 OFFSET $4""",
        phone, agent_id, limit, offset,
    )
    return [MessageResponse(**dict(r)) for r in rows]
