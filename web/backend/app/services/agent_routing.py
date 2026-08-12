"""Resolve which agent (Mac) an outbound send should be routed through.

A user may own multiple registered Mac agents. When sending a new message
we need to pick the right one: prefer an agent that already has a
conversation with this phone number, fall back to the user's single owned
agent, and refuse to guess when it's ambiguous.
"""
from uuid import UUID

import asyncpg


class AgentRoutingError(Exception):
    """Raised when the correct agent for a send cannot be determined.

    Carries an HTTP status code + detail so callers (app/api/messages.py)
    can translate it straight into an HTTPException without re-deriving
    the status code.
    """

    def __init__(self, status_code: int, detail: str):
        self.status_code = status_code
        self.detail = detail
        super().__init__(detail)


async def resolve_agent(
    conn: asyncpg.Connection,
    user_id: UUID,
    phone: str,
    requested_agent_id: UUID | None = None,
) -> UUID:
    """Resolve the agent_id a send to `phone` should be queued against.

    owned = agents owned by user_id.
    conv_agents = distinct owned agents that already have a conversations
    row for `phone`.

    If requested_agent_id is given:
      - must be one of `owned`, else 403.
      - if a conversation with `phone` already exists under a *different*
        owned agent, else 400 (would split history across agents).
      - otherwise the requested agent is returned.

    If no agent is requested:
      - exactly one conv_agent -> that agent.
      - more than one conv_agent -> 400 (ambiguous, caller must specify).
      - no conv_agent and exactly one owned agent -> that agent.
      - no owned agents -> 404 ("no agent registered").
      - more than one owned agent -> 400 ("specify agent_id").
    """
    owned_rows = await conn.fetch(
        "SELECT id FROM agents WHERE user_id = $1", user_id
    )
    owned_ids: set[UUID] = {r["id"] for r in owned_rows}

    conv_rows = await conn.fetch(
        """SELECT DISTINCT c.agent_id
           FROM conversations c
           JOIN agents a ON c.agent_id = a.id
           WHERE a.user_id = $1 AND c.phone = $2""",
        user_id, phone,
    )
    conv_agent_ids: set[UUID] = {r["agent_id"] for r in conv_rows}

    if requested_agent_id is not None:
        if requested_agent_id not in owned_ids:
            raise AgentRoutingError(403, "Not your agent")
        if conv_agent_ids and requested_agent_id not in conv_agent_ids:
            raise AgentRoutingError(
                400,
                "An existing conversation with this phone is under a different agent",
            )
        return requested_agent_id

    if len(conv_agent_ids) == 1:
        return next(iter(conv_agent_ids))
    if len(conv_agent_ids) > 1:
        raise AgentRoutingError(
            400,
            "Multiple agents have conversations with this phone; specify agent_id",
        )

    if len(owned_ids) == 1:
        return next(iter(owned_ids))
    if len(owned_ids) == 0:
        raise AgentRoutingError(404, "No agent registered")
    raise AgentRoutingError(400, "Multiple agents registered; specify agent_id")
