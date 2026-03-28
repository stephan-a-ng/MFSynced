from uuid import UUID
from datetime import datetime, timezone

import asyncpg


async def fetch_pending_commands(
    conn: asyncpg.Connection,
    agent_id: UUID,
) -> list[dict]:
    """Fetch pending outbound commands for an agent and mark them as sent."""
    rows = await conn.fetch(
        """UPDATE outbound_commands
           SET status = 'sent'
           WHERE agent_id = $1 AND status = 'pending'
           RETURNING id, phone, text""",
        agent_id,
    )
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
    return result != "UPDATE 0"
