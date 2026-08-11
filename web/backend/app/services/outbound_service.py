import logging
from uuid import UUID
from datetime import datetime, timezone
from typing import Optional

import asyncpg

logger = logging.getLogger(__name__)


async def queue_outbound_message(
    conn: asyncpg.Connection,
    *,
    agent_id: UUID,
    phone: str,
    text: str,
    created_by_user_id: UUID,
    idempotency_key: Optional[str] = None,
    attachment_type: Optional[str] = None,
    attachment_url: Optional[str] = None,
    forwarded_thread_id: Optional[UUID] = None,
) -> tuple[dict, bool]:
    """Queue an outbound command, deduplicating on (created_by_user_id, idempotency_key).

    Returns (row, created) — created=True only when this call actually
    inserted the row; a replayed idempotency_key returns the original row
    with created=False.
    """
    if idempotency_key is not None:
        existing = await conn.fetchrow(
            """SELECT * FROM outbound_commands
               WHERE created_by_user_id = $1 AND idempotency_key = $2""",
            created_by_user_id, idempotency_key,
        )
        if existing is not None:
            logger.info("queue_outbound_message idempotent replay user_id=%s key=%s cmd_id=%s",
                        created_by_user_id, idempotency_key, existing["id"])
            return dict(existing), False

    row = await conn.fetchrow(
        """INSERT INTO outbound_commands
               (agent_id, phone, text, created_by_user_id, forwarded_thread_id,
                attachment_type, attachment_url, idempotency_key)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (created_by_user_id, idempotency_key) WHERE idempotency_key IS NOT NULL
           DO NOTHING
           RETURNING *""",
        agent_id, phone, text, created_by_user_id, forwarded_thread_id,
        attachment_type, attachment_url, idempotency_key,
    )
    if row is not None:
        logger.info("queue_outbound_message inserted agent_id=%s phone=%s cmd_id=%s",
                    agent_id, phone, row["id"])
        return dict(row), True

    # Lost the insert race against a concurrent request with the same
    # (created_by_user_id, idempotency_key) — re-select the winner's row.
    existing = await conn.fetchrow(
        """SELECT * FROM outbound_commands
           WHERE created_by_user_id = $1 AND idempotency_key = $2""",
        created_by_user_id, idempotency_key,
    )
    if existing is None:
        # Should be unreachable: a DO NOTHING conflict means a matching
        # row exists. Fail loudly rather than return something bogus.
        raise RuntimeError(
            "queue_outbound_message: insert conflicted but no existing row found "
            f"for created_by_user_id={created_by_user_id} idempotency_key={idempotency_key}"
        )
    logger.info("queue_outbound_message lost race, replaying existing user_id=%s key=%s cmd_id=%s",
                created_by_user_id, idempotency_key, existing["id"])
    return dict(existing), False


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
