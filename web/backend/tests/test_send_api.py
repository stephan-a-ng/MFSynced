"""
Tests for the send API (POST /v1/messages/send, GET /v1/messages/{command_id}).

TDD RED: app/api/send.py (or equivalent) does not exist yet. These tests
define the spec:
  - user-JWT-authenticated send endpoint that normalizes phone numbers,
    routes to an agent (explicit agent_id or auto-resolved for a
    single-agent user), and is idempotent per (user, idempotency_key).
  - a status-lookup endpoint scoped to the caller's own agents.

Covers: happy path, idempotent replay, per-user idempotency scoping,
missing idempotency_key validation, auto-routing to a lone owned agent,
403 on an unowned explicit agent_id, full status lifecycle
(pending -> sent -> delivered) driven through the existing agent
endpoints, 404 isolation across users/unknown ids, and unauthenticated
access.
"""
from uuid import UUID, uuid4

from tests.conftest import make_token, _insert_user, _insert_agent


# ---------------------------------------------------------------------------
# 1. Send happy path
# ---------------------------------------------------------------------------

async def test_send_happy_path(client, db_conn, admin_user, test_agent):
    agent, _ = test_agent
    token = make_token(admin_user)

    resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "555-123-4567",
            "text": "Hello there",
            "agent_id": str(agent["id"]),
            "idempotency_key": "key-happy-path",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "pending"
    assert body["created"] is True
    assert body["agent_id"] == str(agent["id"])
    assert body["phone"] == "+15551234567"

    cmd_id = UUID(body["command_id"])
    cmd = await db_conn.fetchrow(
        "SELECT * FROM outbound_commands WHERE id = $1", cmd_id,
    )
    assert cmd is not None
    assert cmd["phone"] == "+15551234567"
    assert cmd["agent_id"] == agent["id"]
    assert cmd["created_by_user_id"] == admin_user["id"]
    assert cmd["status"] == "pending"
    assert cmd["text"] == "Hello there"

    convo = await db_conn.fetchrow(
        "SELECT * FROM conversations WHERE phone = $1 AND agent_id = $2",
        "+15551234567", agent["id"],
    )
    assert convo is not None


# ---------------------------------------------------------------------------
# 2. Idempotent replay: same key + same user, different text -> same row
# ---------------------------------------------------------------------------

async def test_send_idempotent_replay_same_user(client, db_conn, admin_user, test_agent):
    agent, _ = test_agent
    token = make_token(admin_user)
    headers = {"Authorization": f"Bearer {token}"}

    resp1 = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551234567",
            "text": "Original text",
            "agent_id": str(agent["id"]),
            "idempotency_key": "replay-key-1",
        },
        headers=headers,
    )
    assert resp1.status_code == 200
    body1 = resp1.json()
    assert body1["created"] is True
    command_id = body1["command_id"]

    resp2 = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551234567",
            "text": "Different text, should be ignored",
            "agent_id": str(agent["id"]),
            "idempotency_key": "replay-key-1",
        },
        headers=headers,
    )
    assert resp2.status_code == 200
    body2 = resp2.json()
    assert body2["created"] is False
    assert body2["command_id"] == command_id

    rows = await db_conn.fetch(
        "SELECT * FROM outbound_commands WHERE created_by_user_id = $1", admin_user["id"],
    )
    assert len(rows) == 1
    assert rows[0]["text"] == "Original text"


# ---------------------------------------------------------------------------
# 3. Idempotency key is scoped per-user: two users, same key -> two rows
# ---------------------------------------------------------------------------

async def test_send_idempotency_scoped_per_user(client, db_conn, admin_user, test_agent):
    agent, _ = test_agent
    other_user = await _insert_user(db_conn, "other@moonfive.tech", "Other")
    other_agent, _ = await _insert_agent(db_conn, other_user["id"], "Other Mac")

    shared_key = "shared-idempotency-key"

    resp1 = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551234567",
            "text": "From admin",
            "agent_id": str(agent["id"]),
            "idempotency_key": shared_key,
        },
        headers={"Authorization": f"Bearer {make_token(admin_user)}"},
    )
    assert resp1.status_code == 200

    resp2 = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5559876543",
            "text": "From other",
            "agent_id": str(other_agent["id"]),
            "idempotency_key": shared_key,
        },
        headers={"Authorization": f"Bearer {make_token(other_user)}"},
    )
    assert resp2.status_code == 200

    assert resp1.json()["command_id"] != resp2.json()["command_id"]

    rows = await db_conn.fetch("SELECT * FROM outbound_commands")
    assert len(rows) == 2


# ---------------------------------------------------------------------------
# 4. Missing idempotency_key -> 422
# ---------------------------------------------------------------------------

async def test_send_missing_idempotency_key_rejected(client, admin_user, test_agent):
    agent, _ = test_agent
    resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551234567",
            "text": "No idem key",
            "agent_id": str(agent["id"]),
        },
        headers={"Authorization": f"Bearer {make_token(admin_user)}"},
    )
    assert resp.status_code == 422


async def test_send_empty_text_no_attachment_rejected(client, admin_user, test_agent):
    agent, _ = test_agent
    resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551234567",
            "text": "",
            "agent_id": str(agent["id"]),
            "idempotency_key": "empty-text-key",
        },
        headers={"Authorization": f"Bearer {make_token(admin_user)}"},
    )
    assert resp.status_code in (400, 422)


# ---------------------------------------------------------------------------
# 5. Brand-new phone, no agent_id given, single owned agent -> auto-routes
# ---------------------------------------------------------------------------

async def test_send_auto_routes_to_sole_owned_agent(client, db_conn, admin_user, test_agent):
    agent, _ = test_agent
    resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551110000",
            "text": "Auto routed",
            "idempotency_key": "auto-route-key",
        },
        headers={"Authorization": f"Bearer {make_token(admin_user)}"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["agent_id"] == str(agent["id"])
    assert body["phone"] == "+15551110000"


# ---------------------------------------------------------------------------
# 6. Explicit agent_id not owned by caller -> 403
# ---------------------------------------------------------------------------

async def test_send_explicit_agent_not_owned_forbidden(client, db_conn, admin_user):
    other_user = await _insert_user(db_conn, "notmine@moonfive.tech", "NotMine")
    other_agent, _ = await _insert_agent(db_conn, other_user["id"], "Not Mine Mac")

    resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551234567",
            "text": "Should be forbidden",
            "agent_id": str(other_agent["id"]),
            "idempotency_key": "forbidden-key",
        },
        headers={"Authorization": f"Bearer {make_token(admin_user)}"},
    )
    assert resp.status_code == 403


# ---------------------------------------------------------------------------
# 7. GET status lifecycle: pending -> sent -> delivered, via existing
#    agent endpoints (simulating the Mac app).
# ---------------------------------------------------------------------------

async def test_get_status_lifecycle_via_agent_endpoints(client, db_conn, admin_user, test_agent):
    agent, raw_key = test_agent
    token = make_token(admin_user)

    send_resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5552223333",
            "text": "Track my status",
            "agent_id": str(agent["id"]),
            "idempotency_key": "status-lifecycle-key",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert send_resp.status_code == 200
    command_id = send_resp.json()["command_id"]

    # Initial status: pending
    get_resp = await client.get(
        f"/v1/messages/{command_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert get_resp.status_code == 200
    body = get_resp.json()
    assert body["status"] == "pending"
    assert body["phone"] == "+15552223333"
    assert body["agent_id"] == str(agent["id"])
    assert "agent_last_seen_at" in body  # may be null

    # Mac app fetches outbound commands -> flips pending to sent
    fetch_resp = await client.get(
        "/v1/agent/messages/outbound",
        headers={"Authorization": f"Bearer {raw_key}"},
    )
    assert fetch_resp.status_code == 200
    fetched_ids = [m["id"] for m in fetch_resp.json()["messages"]]
    assert str(command_id) in [str(i) for i in fetched_ids]

    get_resp = await client.get(
        f"/v1/messages/{command_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert get_resp.json()["status"] == "sent"

    # Mac app acks delivery
    ack_resp = await client.post(
        f"/v1/agent/messages/outbound/{command_id}/ack",
        json={"status": "delivered"},
        headers={"Authorization": f"Bearer {raw_key}"},
    )
    assert ack_resp.status_code == 200

    get_resp = await client.get(
        f"/v1/messages/{command_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    body = get_resp.json()
    assert body["status"] == "delivered"
    assert body["acked_at"] is not None


# ---------------------------------------------------------------------------
# 8. GET isolation: another user's command -> 404; unknown uuid -> 404
# ---------------------------------------------------------------------------

async def test_get_status_other_users_command_404(client, db_conn, admin_user, test_agent):
    agent, _ = test_agent
    token_owner = make_token(admin_user)

    send_resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5554445555",
            "text": "Owner's message",
            "agent_id": str(agent["id"]),
            "idempotency_key": "isolation-key",
        },
        headers={"Authorization": f"Bearer {token_owner}"},
    )
    assert send_resp.status_code == 200
    command_id = send_resp.json()["command_id"]

    other_user = await _insert_user(db_conn, "intruder@moonfive.tech", "Intruder")
    resp = await client.get(
        f"/v1/messages/{command_id}",
        headers={"Authorization": f"Bearer {make_token(other_user)}"},
    )
    assert resp.status_code == 404


async def test_get_status_unknown_id_404(client, admin_user):
    resp = await client.get(
        f"/v1/messages/{uuid4()}",
        headers={"Authorization": f"Bearer {make_token(admin_user)}"},
    )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# 9. Unauthenticated send -> 401
# ---------------------------------------------------------------------------

async def test_send_unauthenticated_401(client):
    resp = await client.post(
        "/v1/messages/send",
        json={
            "phone": "5551234567",
            "text": "No auth",
            "idempotency_key": "no-auth-key",
        },
    )
    assert resp.status_code == 401
