"""
Tests for forwarding recipient isolation.

The core invariant: teammates only see threads that were explicitly forwarded
to them. Re-forwarding a thread with a new recipient list must replace (not
append) the previous list.

Regression coverage for: recipients not being removed on re-forward, allowing
stale recipients to see threads indefinitely.
"""
import pytest

from tests.conftest import make_token

PHONE = "+15005550001"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _forward_via_agent(client, raw_api_key, agent_id, phone, recipient_ids):
    """Call the Mac app forward endpoint."""
    resp = await client.post(
        "/v1/agent/forward",
        json={
            "phone": phone,
            "mode": "fyi",
            "recipient_user_ids": [str(uid) for uid in recipient_ids],
        },
        headers={"Authorization": f"Bearer {raw_api_key}"},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["thread_id"]


async def _forward_via_web(client, admin_user, agent_id, phone, recipient_ids):
    """Call the web frontend forward endpoint."""
    token = make_token(admin_user)
    resp = await client.post(
        "/v1/forward",
        json={
            "phone": phone,
            "agent_id": str(agent_id),
            "mode": "fyi",
            "recipient_user_ids": [str(uid) for uid in recipient_ids],
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["thread_id"]


# ---------------------------------------------------------------------------
# 1. Basic: initial forward sets recipients correctly
# ---------------------------------------------------------------------------

async def test_initial_forward_sets_recipients(
    client, db_conn, admin_user, chase_user, test_agent, test_conversation
):
    agent, raw_key = test_agent
    thread_id = await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation, [chase_user["id"]]
    )

    rows = await db_conn.fetch(
        "SELECT user_id FROM forwarded_thread_recipients WHERE thread_id = $1",
        thread_id,
    )
    user_ids = {str(r["user_id"]) for r in rows}
    assert str(chase_user["id"]) in user_ids
    assert len(user_ids) == 1


# ---------------------------------------------------------------------------
# 2. Regression: re-forwarding via Mac app replaces (not appends) recipients
# ---------------------------------------------------------------------------

async def test_agent_reforward_replaces_recipients(
    client, db_conn, admin_user, chase_user, marco_user, test_agent, test_conversation
):
    """
    Regression test for the root bug: stale recipients persisted after re-forward.

    Flow:
      1. Forward to [Chase, Marco]
      2. Re-forward to [Marco only]
      3. Chase must NOT be in forwarded_thread_recipients any more
    """
    agent, raw_key = test_agent

    # Step 1: forward to both
    await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation,
        [chase_user["id"], marco_user["id"]],
    )

    # Step 2: re-forward to Marco only
    thread_id = await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation, [marco_user["id"]]
    )

    rows = await db_conn.fetch(
        "SELECT user_id FROM forwarded_thread_recipients WHERE thread_id = $1",
        thread_id,
    )
    user_ids = {str(r["user_id"]) for r in rows}

    assert str(marco_user["id"]) in user_ids, "Marco should still be a recipient"
    assert str(chase_user["id"]) not in user_ids, "Chase must be removed after re-forward"


# ---------------------------------------------------------------------------
# 3. Regression: re-forwarding via web frontend replaces recipients
# ---------------------------------------------------------------------------

async def test_web_reforward_replaces_recipients(
    client, db_conn, admin_user, chase_user, marco_user, test_agent, test_conversation
):
    agent, _ = test_agent

    # Forward to both
    await _forward_via_web(
        client, admin_user, agent["id"], test_conversation,
        [chase_user["id"], marco_user["id"]],
    )

    # Re-forward to Marco only
    thread_id = await _forward_via_web(
        client, admin_user, agent["id"], test_conversation, [marco_user["id"]]
    )

    rows = await db_conn.fetch(
        "SELECT user_id FROM forwarded_thread_recipients WHERE thread_id = $1",
        thread_id,
    )
    user_ids = {str(r["user_id"]) for r in rows}

    assert str(marco_user["id"]) in user_ids
    assert str(chase_user["id"]) not in user_ids


# ---------------------------------------------------------------------------
# 4. Inbox: non-recipient sees empty inbox
# ---------------------------------------------------------------------------

async def test_inbox_empty_for_non_recipient(
    client, admin_user, chase_user, marco_user, test_agent, test_conversation
):
    agent, raw_key = test_agent

    # Forward to Marco only
    await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation, [marco_user["id"]]
    )

    # Chase checks his inbox — should be empty
    resp = await client.get(
        "/v1/inbox",
        headers={"Authorization": f"Bearer {make_token(chase_user)}"},
    )
    assert resp.status_code == 200
    assert resp.json() == []


# ---------------------------------------------------------------------------
# 5. Inbox: recipient sees their thread
# ---------------------------------------------------------------------------

async def test_inbox_shows_thread_for_recipient(
    client, admin_user, marco_user, test_agent, test_conversation
):
    agent, raw_key = test_agent

    await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation, [marco_user["id"]]
    )

    resp = await client.get(
        "/v1/inbox",
        headers={"Authorization": f"Bearer {make_token(marco_user)}"},
    )
    assert resp.status_code == 200
    threads = resp.json()
    assert len(threads) == 1
    assert threads[0]["phone"] == test_conversation


# ---------------------------------------------------------------------------
# 6. Thread detail: non-recipient gets 403
# ---------------------------------------------------------------------------

async def test_non_recipient_cannot_get_thread(
    client, admin_user, chase_user, marco_user, test_agent, test_conversation
):
    agent, raw_key = test_agent

    thread_id = await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation, [marco_user["id"]]
    )

    resp = await client.get(
        f"/v1/inbox/{thread_id}",
        headers={"Authorization": f"Bearer {make_token(chase_user)}"},
    )
    assert resp.status_code == 403


# ---------------------------------------------------------------------------
# 7. Thread detail: recipient gets 200
# ---------------------------------------------------------------------------

async def test_recipient_can_get_thread(
    client, admin_user, marco_user, test_agent, test_conversation
):
    agent, raw_key = test_agent

    thread_id = await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation, [marco_user["id"]]
    )

    resp = await client.get(
        f"/v1/inbox/{thread_id}",
        headers={"Authorization": f"Bearer {make_token(marco_user)}"},
    )
    assert resp.status_code == 200
    assert resp.json()["thread"]["phone"] == test_conversation


# ---------------------------------------------------------------------------
# 8. Archive: non-recipient gets 403
# ---------------------------------------------------------------------------

async def test_archive_requires_recipient(
    client, admin_user, chase_user, marco_user, test_agent, test_conversation
):
    agent, raw_key = test_agent

    thread_id = await _forward_via_agent(
        client, raw_key, agent["id"], test_conversation, [marco_user["id"]]
    )

    # Chase tries to archive a thread he was never forwarded
    resp = await client.patch(
        f"/v1/inbox/{thread_id}/archive",
        headers={"Authorization": f"Bearer {make_token(chase_user)}"},
    )
    assert resp.status_code == 403
