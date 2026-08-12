"""Contact photo/name sync from the Mac agent.

POST /v1/agent/contacts lets the agent push CNContactStore data (display
name + a small JPEG) for a phone; it lands on the conversations row so the
web console can show real avatars instead of initials.
"""
import base64
import uuid

import pytest

from tests.conftest import _insert_conversation

JPEG_MAGIC = b"\xff\xd8\xff\xe0" + b"\x00" * 64


def _photo_b64() -> str:
    return base64.b64encode(JPEG_MAGIC).decode()


async def test_contact_push_updates_existing_conversation(client, db_conn, test_agent):
    agent, key = test_agent
    phone = "+15005550077"
    await _insert_conversation(db_conn, phone, agent["id"])

    resp = await client.post(
        "/v1/agent/contacts",
        json={"phone": phone, "name": "Vince Tester", "photo_base64": _photo_b64()},
        headers={"Authorization": f"Bearer {key}"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["photo_url"].startswith("/uploads/")

    row = await db_conn.fetchrow(
        "SELECT contact_name, contact_photo_url FROM conversations WHERE phone=$1 AND agent_id=$2",
        phone, agent["id"],
    )
    assert row["contact_name"] == "Vince Tester"
    assert row["contact_photo_url"] == body["photo_url"]


async def test_contact_push_normalizes_phone_and_upserts(client, db_conn, test_agent):
    agent, key = test_agent
    # No conversation exists yet; raw formatted phone should normalize and upsert.
    resp = await client.post(
        "/v1/agent/contacts",
        json={"phone": "(500) 555-0088", "name": "New Person"},
        headers={"Authorization": f"Bearer {key}"},
    )
    assert resp.status_code == 200, resp.text
    row = await db_conn.fetchrow(
        "SELECT contact_name, contact_photo_url FROM conversations WHERE phone=$1 AND agent_id=$2",
        "+15005550088", agent["id"],
    )
    assert row is not None
    assert row["contact_name"] == "New Person"
    assert row["contact_photo_url"] is None  # photo optional


async def test_contact_push_does_not_blank_existing_name(client, db_conn, test_agent):
    agent, key = test_agent
    phone = "+15005550099"
    await db_conn.execute(
        """INSERT INTO conversations (phone, agent_id, contact_name)
           VALUES ($1, $2, 'Kept Name')""",
        phone, agent["id"],
    )
    resp = await client.post(
        "/v1/agent/contacts",
        json={"phone": phone, "photo_base64": _photo_b64()},
        headers={"Authorization": f"Bearer {key}"},
    )
    assert resp.status_code == 200
    row = await db_conn.fetchrow(
        "SELECT contact_name, contact_photo_url FROM conversations WHERE phone=$1 AND agent_id=$2",
        phone, agent["id"],
    )
    assert row["contact_name"] == "Kept Name"
    assert row["contact_photo_url"] is not None


async def test_contact_push_rejects_bad_base64_and_oversize(client, test_agent):
    _, key = test_agent
    resp = await client.post(
        "/v1/agent/contacts",
        json={"phone": "+15005550001", "photo_base64": "!!!not-base64!!!"},
        headers={"Authorization": f"Bearer {key}"},
    )
    assert resp.status_code == 400

    huge = base64.b64encode(b"x" * (600 * 1024)).decode()
    resp = await client.post(
        "/v1/agent/contacts",
        json={"phone": "+15005550001", "photo_base64": huge},
        headers={"Authorization": f"Bearer {key}"},
    )
    assert resp.status_code == 400


async def test_contact_push_requires_agent_auth(client):
    resp = await client.post(
        "/v1/agent/contacts",
        json={"phone": "+15005550001", "name": "Nobody"},
    )
    assert resp.status_code in (401, 403)


async def test_conversations_list_includes_photo_url(client, db_conn, test_agent, admin_user):
    agent, key = test_agent
    phone = "+15005550111"
    await client.post(
        "/v1/agent/contacts",
        json={"phone": phone, "name": "Pic Person", "photo_base64": _photo_b64()},
        headers={"Authorization": f"Bearer {key}"},
    )
    from tests.conftest import make_token

    resp = await client.get(
        "/v1/conversations",
        headers={"Authorization": f"Bearer {make_token(admin_user)}"},
    )
    assert resp.status_code == 200
    convs = [c for c in resp.json() if c["phone"] == phone]
    assert convs and convs[0]["contact_photo_url"].startswith("/uploads/")
