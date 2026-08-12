import base64
import binascii
import hashlib
import logging
import uuid as _uuid
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from pydantic import BaseModel, Field
import asyncpg

from app.api.deps import get_current_user_id, require_agent_auth, get_db
from app.config import settings
from app.schemas.agent import (
    RegisterRequest, RegisterResponse,
    InboundBatch, InboundResponse,
    InboundReactionBatch,
    OutboundResponse, OutboundCommand,
    AckRequest,
    HistoryBatch,
    AgentForwardRequest,
)
from app.services.agent_service import register_agent
from app.services.phone import normalize_phone
from app.services.message_service import store_inbound_messages, store_inbound_reactions
from app.services.outbound_service import fetch_pending_commands, acknowledge_command

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/v1/agent", tags=["agent"])


@router.post("/register", response_model=RegisterResponse)
async def register(
    body: RegisterRequest,
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> RegisterResponse:
    """Register a new Mac agent. Requires JWT auth (user must log in to web app first)."""
    agent, api_key = await register_agent(conn, user_id, body.name)
    return RegisterResponse(agent_id=agent["id"], api_key=api_key)


@router.post("/messages/inbound", response_model=InboundResponse)
async def inbound_messages(
    body: InboundBatch,
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
) -> InboundResponse:
    """Receive a batch of messages from the Mac app."""
    confirmed = await store_inbound_messages(
        conn, agent["id"],
        [m.model_dump() for m in body.messages],
    )
    logger.info("inbound_messages agent_id=%s batch_size=%d confirmed=%d",
                agent["id"], len(body.messages), len(confirmed))
    return InboundResponse(confirmed=confirmed)


@router.post("/reactions/inbound")
async def inbound_reactions(
    body: InboundReactionBatch,
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Receive a batch of reactions from the Mac app."""
    count = await store_inbound_reactions(
        conn, agent["id"],
        [r.model_dump() for r in body.reactions],
    )
    return {"confirmed": count}


@router.post("/upload")
async def agent_upload(
    file: UploadFile,
    agent: dict = Depends(require_agent_auth),
):
    """Upload an attachment file (agent API key auth)."""
    return await _save_upload(file)


@router.get("/messages/outbound", response_model=OutboundResponse)
async def outbound_messages(
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
) -> OutboundResponse:
    """Return pending outbound commands for the Mac app to send."""
    commands = await fetch_pending_commands(conn, agent["id"])
    logger.info("outbound_messages agent_id=%s command_count=%d", agent["id"], len(commands))
    return OutboundResponse(
        messages=[OutboundCommand(**{k: c[k] for k in ("id", "phone", "text", "attachment_type", "attachment_url")}) for c in commands]
    )


@router.post("/messages/outbound/{command_id}/ack")
async def ack_outbound(
    command_id: UUID,
    body: AckRequest,
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Acknowledge delivery of an outbound command."""
    found = await acknowledge_command(conn, command_id, agent["id"], body.status)
    logger.info("ack_outbound command_id=%s agent_id=%s status=%s found=%s",
                command_id, agent["id"], body.status, found)
    if not found:
        raise HTTPException(status_code=404, detail="Command not found")
    return {"status": "ok"}


@router.post("/sync/{phone}/history")
async def sync_history(
    phone: str,
    body: HistoryBatch,
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Receive full conversation history for a phone number."""
    await store_inbound_messages(
        conn, agent["id"],
        [m.model_dump() for m in body.messages],
    )
    return {"status": "ok"}


@router.get("/users")
async def list_users_for_agent(
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
):
    """List all team members. Used by Mac app forward picker."""
    rows = await conn.fetch("SELECT id, email, name, photo_url FROM users ORDER BY name")
    return [{"id": str(r["id"]), "name": r["name"], "email": r["email"], "picture": r["photo_url"]} for r in rows]


@router.post("/forward")
async def forward_thread_from_agent(
    body: AgentForwardRequest,
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
):
    """Forward a conversation thread to team members. Used by Mac app."""
    if body.mode not in ("fyi", "action"):
        raise HTTPException(status_code=400, detail="Mode must be 'fyi' or 'action'")

    # Ensure conversation row exists to satisfy the FK constraint.
    # Messages may not have synced yet when the user first taps Forward.
    await conn.execute(
        """INSERT INTO conversations (phone, agent_id)
           VALUES ($1, $2)
           ON CONFLICT (phone, agent_id) DO NOTHING""",
        body.phone, agent["id"],
    )

    thread = await conn.fetchrow(
        """INSERT INTO forwarded_threads (phone, agent_id, forwarded_by_user_id, mode, note)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (phone, agent_id)
           DO UPDATE SET mode = $4, note = $5, forwarded_by_user_id = $3, created_at = now()
           RETURNING id""",
        body.phone, agent["id"], agent["user_id"], body.mode, body.note,
    )

    # Replace recipients — delete stale entries so only the current list is active
    await conn.execute(
        "DELETE FROM forwarded_thread_recipients WHERE thread_id = $1",
        thread["id"],
    )
    for recipient_id in body.recipient_user_ids:
        await conn.execute(
            """INSERT INTO forwarded_thread_recipients (thread_id, user_id)
               VALUES ($1, $2) ON CONFLICT DO NOTHING""",
            thread["id"], UUID(recipient_id),
        )

    return {"thread_id": str(thread["id"])}


class ContactPush(BaseModel):
    phone: str
    name: str | None = None
    photo_base64: str | None = Field(default=None, max_length=1_500_000)


MAX_CONTACT_PHOTO_BYTES = 512 * 1024


@router.post("/contacts")
async def push_contact(
    body: ContactPush,
    agent: dict = Depends(require_agent_auth),
    conn: asyncpg.Connection = Depends(get_db),
) -> dict:
    """Store a contact's display name and photo on its conversation row.

    The Mac app pushes CNContactStore data here so the web console can show
    real avatars. Photo storage shares the uploads dir (same accepted
    ephemerality as attachments; the app re-pushes on every launch).
    """
    try:
        phone = normalize_phone(body.phone)
    except ValueError:
        raise HTTPException(status_code=400, detail="Unparseable phone")

    photo_url: str | None = None
    if body.photo_base64:
        try:
            photo = base64.b64decode(body.photo_base64, validate=True)
        except (binascii.Error, ValueError):
            raise HTTPException(status_code=400, detail="Invalid photo_base64")
        if len(photo) > MAX_CONTACT_PHOTO_BYTES:
            raise HTTPException(status_code=400, detail="Photo too large (max 512KB)")
        upload_dir = Path(settings.UPLOAD_DIR)
        upload_dir.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(photo).hexdigest()[:16]
        filename = f"contact_{agent['id']}_{digest}.jpg"
        (upload_dir / filename).write_bytes(photo)
        photo_url = f"/uploads/{filename}"

    await conn.execute(
        """INSERT INTO conversations (phone, agent_id, contact_name, contact_photo_url)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (phone, agent_id) DO UPDATE SET
             contact_name = COALESCE(EXCLUDED.contact_name, conversations.contact_name),
             contact_photo_url = COALESCE(EXCLUDED.contact_photo_url, conversations.contact_photo_url)""",
        phone, agent["id"], body.name, photo_url,
    )
    return {"phone": phone, "photo_url": photo_url}


async def _save_upload(file: UploadFile) -> dict:
    """Save uploaded file and return its URL."""
    max_bytes = settings.MAX_UPLOAD_MB * 1024 * 1024
    content = await file.read()
    if len(content) > max_bytes:
        raise HTTPException(status_code=413, detail=f"File too large (max {settings.MAX_UPLOAD_MB}MB)")

    upload_dir = Path(settings.UPLOAD_DIR)
    upload_dir.mkdir(parents=True, exist_ok=True)

    ext = Path(file.filename or "").suffix or ""
    filename = f"{_uuid.uuid4()}{ext}"
    filepath = upload_dir / filename

    with open(filepath, "wb") as f:
        f.write(content)

    return {"url": f"/uploads/{filename}"}
