"""
Tests for the portal reply flow.

Covers: reply creates both outbound_command and messages row, immediate
visibility in thread detail, dedup when Mac app syncs the real message back,
and >500 message scenario.
"""
import pytest
from datetime import datetime, timezone, timedelta
from uuid import UUID

from app.services.message_service import store_inbound_messages
from tests.conftest import make_token, _insert_conversation

PHONE = "+17133039889"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _setup_action_thread(client, db_conn, admin_user, chase_user, test_agent, phone=PHONE):
    """Create a conversation + forwarded action thread and return (thread_id, token, agent, raw_key)."""
    agent, raw_key = test_agent
    await _insert_conversation(db_conn, phone, agent["id"])

    resp = await client.post(
        "/v1/agent/forward",
        json={"phone": phone, "mode": "action", "recipient_user_ids": [str(chase_user["id"])]},
        headers={"Authorization": f"Bearer {raw_key}"},
    )
    assert resp.status_code == 200
    thread_id = resp.json()["thread_id"]
    token = make_token(chase_user)
    return thread_id, token, agent, raw_key


async def _seed_messages(conn, agent_id, phone: str, count: int):
    """Insert `count` messages with sequential timestamps."""
    base = datetime(2024, 1, 1, tzinfo=timezone.utc)
    for i in range(count):
        ts = base + timedelta(hours=i)
        await conn.execute(
            """INSERT INTO messages (guid, agent_id, phone, text, timestamp, is_from_me, service)
               VALUES ($1, $2, $3, $4, $5, false, 'iMessage')""",
            f"msg-{i}", agent_id, phone, f"Message {i}", ts,
        )


# ---------------------------------------------------------------------------
# 1. Reply creates both outbound_command AND messages row
# ---------------------------------------------------------------------------

async def test_reply_creates_command_and_message(
    client, db_conn, admin_user, chase_user, test_agent,
):
    thread_id, token, agent, _ = await _setup_action_thread(
        client, db_conn, admin_user, chase_user, test_agent,
    )

    resp = await client.post(
        f"/v1/inbox/{thread_id}/reply",
        json={"text": "Hello from portal"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200

    # outbound_command exists
    cmd = await db_conn.fetchrow(
        "SELECT * FROM outbound_commands WHERE phone = $1 AND agent_id = $2",
        PHONE, agent["id"],
    )
    assert cmd is not None
    assert cmd["text"] == "Hello from portal"
    assert cmd["status"] == "pending"

    # messages row exists with outbound: guid
    msg = await db_conn.fetchrow(
        "SELECT * FROM messages WHERE guid LIKE 'outbound:%' AND phone = $1 AND agent_id = $2",
        PHONE, agent["id"],
    )
    assert msg is not None
    assert msg["text"] == "Hello from portal"
    assert msg["is_from_me"] is True
    assert msg["guid"] == f"outbound:{cmd['id']}"


# ---------------------------------------------------------------------------
# 2. GET thread after reply includes the sent message
# ---------------------------------------------------------------------------

async def test_thread_includes_reply_immediately(
    client, db_conn, admin_user, chase_user, test_agent,
):
    thread_id, token, agent, _ = await _setup_action_thread(
        client, db_conn, admin_user, chase_user, test_agent,
    )

    await client.post(
        f"/v1/inbox/{thread_id}/reply",
        json={"text": "Visible immediately"},
        headers={"Authorization": f"Bearer {token}"},
    )

    resp = await client.get(
        f"/v1/inbox/{thread_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    messages = resp.json()["messages"]
    texts = [m["text"] for m in messages]
    assert "Visible immediately" in texts
    # Should be the last message (most recent)
    assert messages[-1]["text"] == "Visible immediately"
    assert messages[-1]["is_from_me"] is True


# ---------------------------------------------------------------------------
# 3. >500 messages: reply still visible
# ---------------------------------------------------------------------------

async def test_reply_visible_with_500_plus_messages(
    client, db_conn, admin_user, chase_user, test_agent,
):
    thread_id, token, agent, _ = await _setup_action_thread(
        client, db_conn, admin_user, chase_user, test_agent,
    )

    # Seed 600 old messages
    await _seed_messages(db_conn, agent["id"], PHONE, 600)

    # Reply from portal
    await client.post(
        f"/v1/inbox/{thread_id}/reply",
        json={"text": "Reply after 600 msgs"},
        headers={"Authorization": f"Bearer {token}"},
    )

    resp = await client.get(
        f"/v1/inbox/{thread_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    messages = resp.json()["messages"]
    assert len(messages) == 500  # limit

    # The reply should be the last message (newest)
    assert messages[-1]["text"] == "Reply after 600 msgs"
    assert messages[-1]["is_from_me"] is True

    # Oldest messages should be cut off (msg-0 through msg-100 gone)
    guids = [m["guid"] for m in messages]
    assert "msg-0" not in guids


# ---------------------------------------------------------------------------
# 4. Inbound sync removes outbound placeholder (dedup)
# ---------------------------------------------------------------------------

async def test_inbound_sync_removes_placeholder(db_conn, test_agent):
    agent, _ = test_agent
    text = "Hello from portal"

    # Insert outbound placeholder
    await db_conn.execute(
        """INSERT INTO messages (guid, agent_id, phone, text, timestamp, is_from_me, service)
           VALUES ($1, $2, $3, $4, now(), true, 'iMessage')""",
        "outbound:fake-cmd-id", agent["id"], PHONE, text,
    )

    # Verify placeholder exists
    row = await db_conn.fetchrow(
        "SELECT * FROM messages WHERE guid = 'outbound:fake-cmd-id' AND agent_id = $1",
        agent["id"],
    )
    assert row is not None

    # Simulate Mac app syncing the real message back
    await store_inbound_messages(db_conn, agent["id"], [{
        "id": "iMessage;-;real-guid-123",
        "phone": PHONE,
        "text": text,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "is_from_me": True,
        "service": "iMessage",
    }])

    # Placeholder should be gone
    placeholder = await db_conn.fetchrow(
        "SELECT * FROM messages WHERE guid = 'outbound:fake-cmd-id' AND agent_id = $1",
        agent["id"],
    )
    assert placeholder is None

    # Real message should exist
    real = await db_conn.fetchrow(
        "SELECT * FROM messages WHERE guid = 'iMessage;-;real-guid-123' AND agent_id = $1",
        agent["id"],
    )
    assert real is not None
    assert real["text"] == text
    assert real["is_from_me"] is True


# ---------------------------------------------------------------------------
# 5. Full flow: reply → refetch → inbound sync → no duplicates
# ---------------------------------------------------------------------------

async def test_full_reply_then_sync_no_duplicates(
    client, db_conn, admin_user, chase_user, test_agent,
):
    thread_id, token, agent, _ = await _setup_action_thread(
        client, db_conn, admin_user, chase_user, test_agent,
    )
    text = "Full flow test"

    # Step 1: Reply via web
    await client.post(
        f"/v1/inbox/{thread_id}/reply",
        json={"text": text},
        headers={"Authorization": f"Bearer {token}"},
    )

    # Step 2: GET thread — should have outbound: message
    resp = await client.get(
        f"/v1/inbox/{thread_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    messages_before = resp.json()["messages"]
    assert any(m["guid"].startswith("outbound:") for m in messages_before)
    assert sum(1 for m in messages_before if m["text"] == text) == 1

    # Step 3: Simulate Mac app syncing the real message back
    await store_inbound_messages(db_conn, agent["id"], [{
        "id": "iMessage;-;synced-back-guid",
        "phone": PHONE,
        "text": text,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "is_from_me": True,
        "service": "iMessage",
    }])

    # Step 4: GET thread again — only real message, no placeholder
    resp = await client.get(
        f"/v1/inbox/{thread_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    messages_after = resp.json()["messages"]
    guids = [m["guid"] for m in messages_after]
    assert "iMessage;-;synced-back-guid" in guids
    assert not any(g.startswith("outbound:") for g in guids)
    # Exactly one copy
    assert sum(1 for m in messages_after if m["text"] == text) == 1
