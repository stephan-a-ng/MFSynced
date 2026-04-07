import logging
from uuid import UUID
from datetime import datetime, timezone

import asyncpg

logger = logging.getLogger(__name__)


async def fetch_pending_commands(
    conn: asyncpg.Connection,
    agent_id: UUID,
) -> list[dict]:
    """Fetch pending outbound commands for an agent and mark them as sent."""
    rows = await conn.fetch(
        """UPDATE outbound_commands
           SET status = 'sent'
           WHERE agent_id = $1 AND status = 'pending'
           RETURNING id, phone, text, attachment_type, attachment_url""",
        agent_id,
    )
    logger.info("fetch_pending_commands agent_id=%s count=%d", agent_id, len(rows))
    return [dict(r) for r in rows]


async def acknowledge_command(
    conn: asyncpg.Connection,
    command_id: UUID,
    agent_id: UUID,
    status: str,
) -> bool:
    """Acknowledge an outbound command. Returns True if found and updated."""
    result = await conn.execute(
        """UPDATE outbound_commands
           SET status = $1, acked_at = $2
           WHERE id = $3 AND agent_id = $4""",
        status, datetime.now(timezone.utc), command_id, agent_id,
    )
    found = result != "UPDATE 0"
    logger.info("acknowledge_command command_id=%s agent_id=%s status=%s found=%s",
                command_id, agent_id, status, found)
    return found
