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
            result = await conn.execute(
                """INSERT INTO messages (guid, agent_id, phone, text, timestamp, is_from_me, service)
                   VALUES ($1, $2, $3, $4, $5, $6, $7)
                   ON CONFLICT (guid, agent_id) DO NOTHING""",
                guid, agent_id, phone,
                msg.get("text", ""),
                timestamp,
                msg.get("is_from_me", False),
                msg.get("service", "iMessage"),
            )

            confirmed.append(guid)

            # Upsert conversation
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

    return confirmed
