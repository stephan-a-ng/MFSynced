import logging
from datetime import datetime
from uuid import UUID

import asyncpg

logger = logging.getLogger(__name__)

async def store_inbound_messages(
    conn: asyncpg.Connection,
    agent_id: UUID,
    messages: list[dict],
) -> list[str]:
    """Store inbound messages and return list of confirmed guids."""
    confirmed = []
    for msg in messages:
        try:
            # Parse timestamp
            ts = msg.get("timestamp", "")
            try:
                timestamp = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                timestamp = datetime.utcnow()

            phone = msg.get("phone", "")
            guid = msg.get("id", "")

            # Insert message (idempotent via ON CONFLICT)
            await conn.execute(
                """INSERT INTO messages (guid, agent_id, phone, text, timestamp, is_from_me, service,
                                        attachment_type, attachment_url, attachment_mime_type, attachment_filename)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                   ON CONFLICT (guid, agent_id) DO UPDATE SET timestamp = EXCLUDED.timestamp""",
                guid, agent_id, phone,
                msg.get("text", ""),
                timestamp,
                msg.get("is_from_me", False),
                msg.get("service", "iMessage"),
                msg.get("attachment_type"),
                msg.get("attachment_url"),
                msg.get("attachment_mime_type"),
                msg.get("attachment_filename"),
            )

            confirmed.append(guid)

            # Upsert conversation (update contact_name if provided)
            contact_name = msg.get("contact_name")
            if contact_name:
                await conn.execute(
                    """INSERT INTO conversations (phone, agent_id, contact_name, last_message_at, message_count)
                       VALUES ($1, $2, $3, $4, 1)
                       ON CONFLICT (phone, agent_id) DO UPDATE
                       SET last_message_at = GREATEST(conversations.last_message_at, $4),
                           message_count = conversations.message_count + 1,
                           contact_name = COALESCE($3, conversations.contact_name)""",
                    phone, agent_id, contact_name, timestamp,
                )
            else:
                await conn.execute(
                    """INSERT INTO conversations (phone, agent_id, last_message_at, message_count)
                       VALUES ($1, $2, $3, 1)
                       ON CONFLICT (phone, agent_id) DO UPDATE
                       SET last_message_at = GREATEST(conversations.last_message_at, $3),
                           message_count = conversations.message_count + 1""",
                    phone, agent_id, timestamp,
                )
        except Exception as e:
            logger.error("Failed to store message %s: %s", msg.get("id"), e)

    # Unarchive threads for all recipients when a new inbound message arrives
    seen_phones = {(m.get("phone", ""), str(agent_id)) for m in messages if not m.get("is_from_me", False)}
    for phone, _ in seen_phones:
        if phone:
            await conn.execute(
                """UPDATE forwarded_thread_recipients ftr
                   SET is_archived = false
                   FROM forwarded_threads ft
                   WHERE ft.id = ftr.thread_id
                     AND ft.phone = $1
                     AND ft.agent_id = $2
                     AND ftr.is_archived = true""",
                phone, agent_id,
            )

    return confirmed


async def store_inbound_reactions(
    conn: asyncpg.Connection,
    agent_id: UUID,
    reactions: list[dict],
) -> int:
    """Store inbound reactions (upsert). Returns count of processed reactions."""
    count = 0
    for r in reactions:
        try:
            await conn.execute(
                """INSERT INTO reactions (message_guid, agent_id, reaction_type, is_from_me)
                   VALUES ($1, $2, $3, $4)
                   ON CONFLICT (message_guid, agent_id, is_from_me)
                   DO UPDATE SET reaction_type = $3""",
                r["message_guid"], agent_id,
                r["reaction_type"], r.get("is_from_me", False),
            )
            count += 1
        except Exception as e:
            logger.error("Failed to store reaction for %s: %s", r.get("message_guid"), e)
    return count


async def fetch_messages_with_reactions(
    conn: asyncpg.Connection,
    phone: str,
    agent_id: UUID,
    limit: int = 100,
    offset: int = 0,
) -> list[dict]:
    """Fetch messages with their reactions for a conversation."""
    rows = await conn.fetch(
        """SELECT sub.id, sub.guid, sub.phone, sub.text, sub.timestamp, sub.is_from_me, sub.service,
                  sub.attachment_type, sub.attachment_url, sub.attachment_mime_type, sub.attachment_filename
           FROM (
               SELECT id, guid, phone, text, timestamp, is_from_me, service,
                      attachment_type, attachment_url, attachment_mime_type, attachment_filename
               FROM messages
               WHERE phone = $1 AND agent_id = $2
               ORDER BY timestamp DESC
               LIMIT $3 OFFSET $4
           ) sub
           ORDER BY sub.timestamp ASC""",
        phone, agent_id, limit, offset,
    )

    if not rows:
        return []

    guids = [r["guid"] for r in rows]
    reaction_rows = await conn.fetch(
        """SELECT message_guid, reaction_type, is_from_me
           FROM reactions
           WHERE message_guid = ANY($1) AND agent_id = $2""",
        guids, agent_id,
    )

    reactions_by_guid: dict[str, list[dict]] = {}
    for r in reaction_rows:
        reactions_by_guid.setdefault(r["message_guid"], []).append({
            "reaction_type": r["reaction_type"],
            "is_from_me": r["is_from_me"],
        })

    result = []
    for row in rows:
        d = dict(row)
        d["reactions"] = reactions_by_guid.get(row["guid"], [])
        result.append(d)

    return result
