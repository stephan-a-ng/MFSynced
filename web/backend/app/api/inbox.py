from uuid import UUID
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException
import asyncpg

from app.api.deps import get_current_user_id, get_db
from app.schemas.inbox import InboxThreadResponse, ThreadDetailResponse, ReplyRequest, ReactRequest
from app.schemas.message import MessageResponse, ReactionResponse
from app.services.message_service import fetch_messages_with_reactions

router = APIRouter(prefix="/v1/inbox", tags=["inbox"])

VALID_REACTIONS = {"love", "like", "dislike", "laugh", "emphasize", "question"}

@router.get("", response_model=list[InboxThreadResponse])
async def list_inbox(
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> list[InboxThreadResponse]:
    """List all forwarded threads for the current user."""
    rows = await conn.fetch(
        """SELECT
               ft.id, ft.phone, ft.agent_id, ft.mode, ft.note, ft.created_at,
               c.contact_name,
               u.name AS forwarded_by_name, u.photo_url AS forwarded_by_picture,
               ftr.has_read,
               (SELECT m.text FROM messages m
                WHERE m.phone = ft.phone AND m.agent_id = ft.agent_id
                ORDER BY m.timestamp DESC LIMIT 1) AS last_message_text,
               (SELECT m.timestamp FROM messages m
                WHERE m.phone = ft.phone AND m.agent_id = ft.agent_id
                ORDER BY m.timestamp DESC LIMIT 1) AS last_message_at
           FROM forwarded_threads ft
           JOIN forwarded_thread_recipients ftr ON ft.id = ftr.thread_id
           JOIN users u ON ft.forwarded_by_user_id = u.id
           LEFT JOIN conversations c ON ft.phone = c.phone AND ft.agent_id = c.agent_id
           WHERE ftr.user_id = $1
           ORDER BY last_message_at DESC NULLS LAST""",
        user_id,
    )
    return [InboxThreadResponse(**dict(r)) for r in rows]

@router.get("/{thread_id}", response_model=ThreadDetailResponse)
async def get_thread(
    thread_id: UUID,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> ThreadDetailResponse:
    """Get a forwarded thread with all messages."""
    # Verify user is a recipient
    recipient = await conn.fetchrow(
        "SELECT * FROM forwarded_thread_recipients WHERE thread_id = $1 AND user_id = $2",
        thread_id, user_id,
    )
    if recipient is None:
        raise HTTPException(status_code=403, detail="Not a recipient of this thread")

    # Get thread info
    row = await conn.fetchrow(
        """SELECT ft.id, ft.phone, ft.agent_id, ft.mode, ft.note, ft.created_at,
                  c.contact_name,
                  u.name AS forwarded_by_name, u.photo_url AS forwarded_by_picture
           FROM forwarded_threads ft
           JOIN users u ON ft.forwarded_by_user_id = u.id
           LEFT JOIN conversations c ON ft.phone = c.phone AND ft.agent_id = c.agent_id
           WHERE ft.id = $1""",
        thread_id,
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Thread not found")

    thread = InboxThreadResponse(
        **dict(row),
        has_read=recipient["has_read"],
        last_message_text=None,
        last_message_at=None,
    )

    # Get messages with reactions
    messages = await fetch_messages_with_reactions(conn, row["phone"], row["agent_id"])

    return ThreadDetailResponse(
        thread=thread,
        messages=[
            MessageResponse(
                **{k: m[k] for k in ("id", "guid", "phone", "text", "timestamp", "is_from_me", "service",
                                      "attachment_type", "attachment_url", "attachment_mime_type", "attachment_filename")},
                reactions=[ReactionResponse(**r) for r in m["reactions"]],
            )
            for m in messages
        ],
    )

@router.post("/{thread_id}/reply")
async def reply_to_thread(
    thread_id: UUID,
    body: ReplyRequest,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Reply to an action thread (creates outbound command for Mac app)."""
    # Verify recipient
    recipient = await conn.fetchrow(
        "SELECT * FROM forwarded_thread_recipients WHERE thread_id = $1 AND user_id = $2",
        thread_id, user_id,
    )
    if recipient is None:
        raise HTTPException(status_code=403, detail="Not a recipient")

    # Get thread and verify mode
    thread = await conn.fetchrow("SELECT * FROM forwarded_threads WHERE id = $1", thread_id)
    if thread is None:
        raise HTTPException(status_code=404, detail="Thread not found")
    if thread["mode"] != "action":
        raise HTTPException(status_code=400, detail="This thread is read-only (FYI mode)")

    # Create outbound command
    await conn.execute(
        """INSERT INTO outbound_commands (agent_id, phone, text, created_by_user_id, forwarded_thread_id,
                                          attachment_type, attachment_url)
           VALUES ($1, $2, $3, $4, $5, $6, $7)""",
        thread["agent_id"], thread["phone"], body.text or "", user_id, thread_id,
        body.attachment_type, body.attachment_url,
    )

    return {"status": "queued"}

@router.post("/{thread_id}/react")
async def react_to_message(
    thread_id: UUID,
    body: ReactRequest,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Add or toggle a reaction on a message in a thread."""
    if body.reaction_type not in VALID_REACTIONS:
        raise HTTPException(status_code=400, detail=f"Invalid reaction type. Must be one of: {', '.join(VALID_REACTIONS)}")

    # Verify recipient
    recipient = await conn.fetchrow(
        "SELECT * FROM forwarded_thread_recipients WHERE thread_id = $1 AND user_id = $2",
        thread_id, user_id,
    )
    if recipient is None:
        raise HTTPException(status_code=403, detail="Not a recipient")

    thread = await conn.fetchrow("SELECT * FROM forwarded_threads WHERE id = $1", thread_id)
    if thread is None:
        raise HTTPException(status_code=404, detail="Thread not found")

    # Check if same reaction already exists (toggle off)
    existing = await conn.fetchrow(
        """SELECT id, reaction_type FROM reactions
           WHERE message_guid = $1 AND agent_id = $2 AND is_from_me = true""",
        body.message_guid, thread["agent_id"],
    )

    if existing and existing["reaction_type"] == body.reaction_type:
        # Remove reaction (toggle off)
        await conn.execute("DELETE FROM reactions WHERE id = $1", existing["id"])
        return {"status": "removed"}
    else:
        # Upsert reaction
        await conn.execute(
            """INSERT INTO reactions (message_guid, agent_id, reaction_type, is_from_me)
               VALUES ($1, $2, $3, true)
               ON CONFLICT (message_guid, agent_id, is_from_me)
               DO UPDATE SET reaction_type = $3""",
            body.message_guid, thread["agent_id"], body.reaction_type,
        )
        return {"status": "added"}

@router.patch("/{thread_id}/read")
async def mark_read(
    thread_id: UUID,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Mark a forwarded thread as read."""
    await conn.execute(
        """UPDATE forwarded_thread_recipients
           SET has_read = true, read_at = $1
           WHERE thread_id = $2 AND user_id = $3""",
        datetime.now(timezone.utc), thread_id, user_id,
    )
    return {"status": "ok"}
