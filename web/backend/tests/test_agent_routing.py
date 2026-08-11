"""
Tests for agent routing: picking which of a user's agents (Macs) should
handle a send/receive for a given phone number.

Routing precedence:
  - If the caller requests a specific agent_id, it must be one the user
    owns (else 403); if that phone already has a conversation history
    under a *different* owned agent, the explicit request is rejected as
    ambiguous (400) rather than silently splitting history across agents.
  - With no explicit request, an existing conversation for the phone
    settles it -- unless the phone has conversation history spread across
    more than one of the user's owned agents (400, ambiguous).
  - With no conversation history at all, fall back to the user's agent
    count: exactly one -> use it, zero -> 404, more than one -> 400
    (can't guess which Mac should originate the message).
"""
import pytest

from app.services.agent_routing import AgentRoutingError, resolve_agent
from tests.conftest import _insert_agent, _insert_conversation, _insert_user

PHONE = "+15005550001"


# ---------------------------------------------------------------------------
# 1. One owned agent, no conversation history -> that agent
# ---------------------------------------------------------------------------

async def test_single_owned_agent_no_conversation_resolves_to_it(db_conn):
    user = await _insert_user(db_conn, "solo@moonfive.tech", "Solo")
    agent, _ = await _insert_agent(db_conn, user["id"])

    resolved = await resolve_agent(db_conn, user["id"], PHONE)

    assert resolved == agent["id"]


# ---------------------------------------------------------------------------
# 2. Owned agent A has a conversation for the phone; user also owns B ->
#    resolves to A even without an explicit request
# ---------------------------------------------------------------------------

async def test_conversation_history_picks_its_agent_over_other_owned(db_conn):
    user = await _insert_user(db_conn, "two-agents@moonfive.tech", "TwoAgents")
    agent_a, _ = await _insert_agent(db_conn, user["id"], name="Agent A")
    agent_b, _ = await _insert_agent(db_conn, user["id"], name="Agent B")
    await _insert_conversation(db_conn, PHONE, agent_a["id"])

    resolved = await resolve_agent(db_conn, user["id"], PHONE)

    assert resolved == agent_a["id"]
    assert resolved != agent_b["id"]


# ---------------------------------------------------------------------------
# 3. Two owned agents, no conversation, no requested id -> ambiguous (400)
# ---------------------------------------------------------------------------

async def test_multiple_owned_agents_no_conversation_no_request_is_ambiguous(db_conn):
    user = await _insert_user(db_conn, "ambiguous@moonfive.tech", "Ambiguous")
    await _insert_agent(db_conn, user["id"], name="Agent A")
    await _insert_agent(db_conn, user["id"], name="Agent B")

    with pytest.raises(AgentRoutingError) as exc_info:
        await resolve_agent(db_conn, user["id"], PHONE)

    assert exc_info.value.status_code == 400


# ---------------------------------------------------------------------------
# 4. Zero owned agents -> 404
# ---------------------------------------------------------------------------

async def test_no_owned_agents_is_not_found(db_conn):
    user = await _insert_user(db_conn, "noagents@moonfive.tech", "NoAgents")

    with pytest.raises(AgentRoutingError) as exc_info:
        await resolve_agent(db_conn, user["id"], PHONE)

    assert exc_info.value.status_code == 404


# ---------------------------------------------------------------------------
# 5. Requested agent_id not owned by the caller -> 403
# ---------------------------------------------------------------------------

async def test_requested_agent_not_owned_is_forbidden(db_conn):
    user = await _insert_user(db_conn, "requester@moonfive.tech", "Requester")
    other_user = await _insert_user(db_conn, "other@moonfive.tech", "Other")
    other_agent, _ = await _insert_agent(db_conn, other_user["id"])

    with pytest.raises(AgentRoutingError) as exc_info:
        await resolve_agent(
            db_conn, user["id"], PHONE, requested_agent_id=other_agent["id"]
        )

    assert exc_info.value.status_code == 403


# ---------------------------------------------------------------------------
# 6. Requested agent_id is owned, but the phone's conversation lives under
#    a *different* owned agent -> ambiguous (400)
# ---------------------------------------------------------------------------

async def test_requested_agent_owned_but_conversation_elsewhere_is_ambiguous(db_conn):
    user = await _insert_user(db_conn, "conflict@moonfive.tech", "Conflict")
    agent_a, _ = await _insert_agent(db_conn, user["id"], name="Agent A")
    agent_b, _ = await _insert_agent(db_conn, user["id"], name="Agent B")
    await _insert_conversation(db_conn, PHONE, agent_a["id"])

    with pytest.raises(AgentRoutingError) as exc_info:
        await resolve_agent(
            db_conn, user["id"], PHONE, requested_agent_id=agent_b["id"]
        )

    assert exc_info.value.status_code == 400


# ---------------------------------------------------------------------------
# 7. Requested agent_id is owned, no conflicting conversation -> returned
# ---------------------------------------------------------------------------

async def test_requested_agent_owned_no_conflict_is_returned(db_conn):
    user = await _insert_user(db_conn, "clean@moonfive.tech", "Clean")
    agent_a, _ = await _insert_agent(db_conn, user["id"], name="Agent A")
    agent_b, _ = await _insert_agent(db_conn, user["id"], name="Agent B")
    # Conversation exists under the requested agent itself -- not a conflict.
    await _insert_conversation(db_conn, PHONE, agent_a["id"])

    resolved = await resolve_agent(
        db_conn, user["id"], PHONE, requested_agent_id=agent_a["id"]
    )

    assert resolved == agent_a["id"]
    assert resolved != agent_b["id"]
