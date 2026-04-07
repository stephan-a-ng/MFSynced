"""
Tests for message fetch ordering.

Verifies that fetch_messages_with_reactions returns the LATEST N messages
(not oldest N), so recent messages are always visible in the portal thread view.
"""
import pytest
from datetime import datetime, timezone, timedelta

from app.services.message_service import fetch_messages_with_reactions
from tests.conftest import make_token

PHONE = "+17133039889"


async def _seed_messages(conn, agent_id, phone: str, count: int):
    """Insert `count` messages with sequential timestamps, oldest first."""
    base = datetime(2024, 1, 1, tzinfo=timezone.utc)
    for i in range(count):
        ts = base + timedelta(hours=i)
        await conn.execute(
            """INSERT INTO messages (guid, agent_id, phone, text, timestamp, is_from_me, service)
               VALUES ($1, $2, $3, $4, $5, false, 'iMessage')""",
            f"msg-{i}", agent_id, phone, f"Message {i}", ts,
        )


# ---------------------------------------------------------------------------
# 1. With >500 messages, fetch returns the LATEST 500, not the oldest 500
# ---------------------------------------------------------------------------

async def test_fetch_returns_latest_messages(db_conn, test_agent):
    """When there are 600 messages, the 500 returned should be the newest ones."""
    agent, _ = test_agent
    await _seed_messages(db_conn, agent["id"], PHONE, 600)

    msgs = await fetch_messages_with_reactions(db_conn, PHONE, agent["id"], limit=500)

    assert len(msgs) == 500
    # Returned messages should be in chronological order (ASC)
    timestamps = [m["timestamp"] for m in msgs]
    assert timestamps == sorted(timestamps)
    # The last returned message should be msg-599 (the newest)
    assert msgs[-1]["guid"] == "msg-599"
    # The first returned message should be msg-100 (600-500=100)
    assert msgs[0]["guid"] == "msg-100"


# ---------------------------------------------------------------------------
# 2. With ≤500 messages, all messages are returned in chronological order
# ---------------------------------------------------------------------------

async def test_fetch_all_messages_when_under_limit(db_conn, test_agent):
    agent, _ = test_agent
    await _seed_messages(db_conn, agent["id"], PHONE, 10)

    msgs = await fetch_messages_with_reactions(db_conn, PHONE, agent["id"], limit=500)

    assert len(msgs) == 10
    assert msgs[0]["guid"] == "msg-0"
    assert msgs[-1]["guid"] == "msg-9"


# ---------------------------------------------------------------------------
# 3. Thread detail API returns newest messages (end-to-end via HTTP)
# ---------------------------------------------------------------------------

async def test_thread_detail_shows_newest_messages(
    client, db_conn, admin_user, marco_user, test_agent
):
    """GET /inbox/{thread_id} should include the newest message, not just the oldest 500."""
    import secrets, hashlib
    agent, raw_key = test_agent

    # Ensure conversation row exists
    await db_conn.execute(
        "INSERT INTO conversations (phone, agent_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        PHONE, agent["id"],
    )

    # Seed 600 messages (oldest msg-0, newest msg-599)
    await _seed_messages(db_conn, agent["id"], PHONE, 600)

    # Forward to marco
    resp = await client.post(
        "/v1/agent/forward",
        json={"phone": PHONE, "mode": "fyi", "recipient_user_ids": [str(marco_user["id"])]},
        headers={"Authorization": f"Bearer {raw_key}"},
    )
    assert resp.status_code == 200
    thread_id = resp.json()["thread_id"]

    # Fetch thread detail
    resp = await client.get(
        f"/v1/inbox/{thread_id}",
        headers={"Authorization": f"Bearer {make_token(marco_user)}"},
    )
    assert resp.status_code == 200
    messages = resp.json()["messages"]

    assert len(messages) == 500
    guids = [m["guid"] for m in messages]
    # Newest message (msg-599) must be visible
    assert "msg-599" in guids, "Most recent message must appear in the thread detail"
    # Oldest message (msg-0) must NOT be visible since we have 600 total
    assert "msg-0" not in guids, "Oldest message should be cut off when over the limit"
