import logging
from uuid import UUID
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException
import asyncpg

from app.api.deps import get_current_user_id, get_db
from app.schemas.inbox import InboxThreadResponse, ThreadDetailResponse, ReplyRequest, ReactRequest
from app.schemas.message import MessageResponse, ReactionResponse
from app.services.message_service import fetch_messages_with_reactions

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/v1/inbox", tags=["inbox"])

VALID_REACTIONS = {"love", "like", "dislike", "laugh", "emphasize", "question"}

@router.get("", response_model=list[InboxThreadResponse])
async def list_inbox(
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
    archived: bool = False,
) -> list[InboxThreadResponse]:
    """List forwarded threads for the current user. archived=true returns archived threads.

    One thread per phone number is returned — if the same contact was forwarded from
    multiple agents (e.g. primary + mirror backend), the thread with the most recent
    message wins and duplicates are suppressed.
    """
    rows = await conn.fetch(
        """SELECT * FROM (
               SELECT DISTINCT ON (ft.phone)
                   ft.id, ft.phone, ft.agent_id, ft.mode, ft.note, ft.created_at,
                   c.contact_name,
                   u.name AS forwarded_by_name, u.photo_url AS forwarded_by_picture,
                   ftr.has_read, ftr.is_archived,
                   last_msg.text AS last_message_text,
                   last_msg.timestamp AS last_message_at
               FROM forwarded_threads ft
               JOIN forwarded_thread_recipients ftr ON ft.id = ftr.thread_id
               JOIN users u ON ft.forwarded_by_user_id = u.id
               LEFT JOIN conversations c ON ft.phone = c.phone AND ft.agent_id = c.agent_id
               LEFT JOIN LATERAL (
                   SELECT text, timestamp FROM messages
                   WHERE phone = ft.phone AND agent_id = ft.agent_id
                   ORDER BY timestamp DESC LIMIT 1
               ) last_msg ON true
               WHERE ftr.user_id = $1 AND ftr.is_archived = $2
               ORDER BY ft.phone, last_msg.timestamp DESC NULLS LAST
           ) deduped
           ORDER BY last_message_at DESC NULLS LAST""",
        user_id, archived,
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
        is_archived=recipient["is_archived"],
        last_message_text=None,
        last_message_at=None,
    )

    # Get messages with reactions (fetch up to 500 so full conversation context is visible)
    messages = await fetch_messages_with_reactions(conn, row["phone"], row["agent_id"], limit=500)
    logger.info("get_thread thread_id=%s phone=%s agent_id=%s message_count=%d",
                thread_id, row["phone"], row["agent_id"], len(messages))

    # Look up delivery statuses for portal-sent messages (outbound:* guids)
    outbound_cmd_ids = []
    for m in messages:
        if m["guid"].startswith("outbound:"):
            try:
                outbound_cmd_ids.append(UUID(m["guid"].split(":", 1)[1]))
            except (ValueError, IndexError):
                pass

    delivery_statuses: dict[str, str] = {}
    if outbound_cmd_ids:
        status_rows = await conn.fetch(
            "SELECT id, status FROM outbound_commands WHERE id = ANY($1)",
            outbound_cmd_ids,
        )
        for sr in status_rows:
            delivery_statuses[f"outbound:{sr['id']}"] = sr["status"]

    return ThreadDetailResponse(
        thread=thread,
        messages=[
            MessageResponse(
                **{k: m[k] for k in ("id", "guid", "phone", "text", "timestamp", "is_from_me", "service",
                                      "attachment_type", "attachment_url", "attachment_mime_type", "attachment_filename")},
                reactions=[ReactionResponse(**r) for r in m["reactions"]],
                delivery_status=delivery_statuses.get(m["guid"]),
            )
            for m in messages
        ],
    )

@router.patch("/{thread_id}/archive")
async def archive_thread(
    thread_id: UUID,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Archive a thread for the current user."""
    recipient = await conn.fetchrow(
        "SELECT 1 FROM forwarded_thread_recipients WHERE thread_id = $1 AND user_id = $2",
        thread_id, user_id,
    )
    if recipient is None:
        raise HTTPException(status_code=403, detail="Not a recipient")
    await conn.execute(
        """UPDATE forwarded_thread_recipients
           SET is_archived = true
           WHERE thread_id = $1 AND user_id = $2""",
        thread_id, user_id,
    )
    return {"status": "archived"}


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
    cmd = await conn.fetchrow(
        """INSERT INTO outbound_commands (agent_id, phone, text, created_by_user_id, forwarded_thread_id,
                                          attachment_type, attachment_url)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           RETURNING id""",
        thread["agent_id"], thread["phone"], body.text or "", user_id, thread_id,
        body.attachment_type, body.attachment_url,
    )
    command_id = cmd["id"]

    # Insert into messages immediately so the reply is visible in thread view
    await conn.execute(
        """INSERT INTO messages (guid, agent_id, phone, text, timestamp, is_from_me, service,
                                attachment_type, attachment_url)
           VALUES ($1, $2, $3, $4, $5, true, 'iMessage', $6, $7)""",
        f"outbound:{command_id}", thread["agent_id"], thread["phone"],
        body.text or "", datetime.now(timezone.utc),
        body.attachment_type, body.attachment_url,
    )

    logger.info("reply_to_thread thread_id=%s phone=%s text_len=%d cmd_id=%s user_id=%s",
                thread_id, thread["phone"], len(body.text or ""), command_id, user_id)

    # Unarchive for all recipients when a message is sent
    await conn.execute(
        """UPDATE forwarded_thread_recipients
           SET is_archived = false
           WHERE thread_id = $1 AND is_archived = true""",
        thread_id,
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
