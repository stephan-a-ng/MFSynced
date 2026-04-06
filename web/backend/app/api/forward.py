from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException
import asyncpg

from app.api.deps import get_current_user_id, get_db
from app.schemas.forward import ForwardRequest, ForwardResponse

router = APIRouter(prefix="/v1/forward", tags=["forward"])

@router.post("", response_model=ForwardResponse)
async def forward_thread(
    body: ForwardRequest,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> ForwardResponse:
    """Forward a conversation thread to team members."""
    # Verify user owns the agent
    agent = await conn.fetchrow("SELECT * FROM agents WHERE id = $1 AND user_id = $2", body.agent_id, user_id)
    if agent is None:
        raise HTTPException(status_code=403, detail="Not your agent")

    # Verify conversation exists
    conv = await conn.fetchrow(
        "SELECT * FROM conversations WHERE phone = $1 AND agent_id = $2",
        body.phone, body.agent_id,
    )
    if conv is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    # Validate mode
    if body.mode not in ("fyi", "action"):
        raise HTTPException(status_code=400, detail="Mode must be 'fyi' or 'action'")

    # Upsert forwarded thread — re-forwarding same conversation updates existing record
    thread = await conn.fetchrow(
        """INSERT INTO forwarded_threads (phone, agent_id, forwarded_by_user_id, mode, note)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (phone, agent_id)
           DO UPDATE SET mode = $4, note = $5, forwarded_by_user_id = $3,
                         created_at = now()
           RETURNING id""",
        body.phone, body.agent_id, user_id, body.mode, body.note,
    )

    # Add recipients
    for recipient_id in body.recipient_user_ids:
        await conn.execute(
            """INSERT INTO forwarded_thread_recipients (thread_id, user_id)
               VALUES ($1, $2) ON CONFLICT DO NOTHING""",
            thread["id"], recipient_id,
        )

    return ForwardResponse(thread_id=thread["id"])
