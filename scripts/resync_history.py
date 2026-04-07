#!/usr/bin/env python3
"""
Re-sync message history for a chat to the backend with correct timestamps.
Reads directly from ~/Library/Messages/chat.db and pushes to the API.
"""
import sqlite3
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

CHAT_IDENTIFIER = "34913"
AGENT_ID = "65851a62-6083-4b42-85a8-ba2a8fffa5ea"

# Staging backend (mirror)
API_ENDPOINT = "https://mfsynced-api-staging-iztclq7eza-uc.a.run.app/v1/agent"
API_KEY = "mfs_gnGPp46mF4blhmIbCto5VYFbdjnqwJJM5aT1toH-jDU"

CHAT_DB = Path.home() / "Library/Messages/chat.db"
APPLE_EPOCH_OFFSET = 978307200  # seconds between 1970-01-01 and 2001-01-01
NS_PER_SECOND = 1_000_000_000


def apple_ns_to_iso8601(apple_ns: int):
    if apple_ns <= 0:
        return None
    unix_ts = apple_ns / NS_PER_SECOND + APPLE_EPOCH_OFFSET
    return datetime.fromtimestamp(unix_ts, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def fetch_messages(chat_id: str) -> list[dict]:
    conn = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("""
        SELECT
            m.ROWID AS message_id,
            m.guid,
            m.text,
            m.is_from_me,
            m.date AS message_date,
            m.service,
            h.id AS sender_id
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        LEFT JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE c.chat_identifier = ?
        ORDER BY m.ROWID ASC
    """, (chat_id,))
    rows = cur.fetchall()
    conn.close()

    messages = []
    skipped = 0
    for row in rows:
        ts = apple_ns_to_iso8601(row["message_date"])
        if ts is None:
            skipped += 1
            continue
        messages.append({
            "id": row["guid"],
            "phone": row["sender_id"] or chat_id,
            "text": row["text"] or "",
            "timestamp": ts,
            "is_from_me": bool(row["is_from_me"]),
            "service": row["service"] or "SMS",
            "contact_name": "34913",
        })

    print(f"Fetched {len(messages)} messages ({skipped} skipped — zero/null date)")
    if messages:
        print(f"  First: {messages[0]['timestamp']}")
        print(f"  Last:  {messages[-1]['timestamp']}")
    return messages


def push_history(messages: list[dict]) -> None:
    url = f"{API_ENDPOINT}/sync/{CHAT_IDENTIFIER}/history"
    batch_size = 100
    total = 0

    for i in range(0, len(messages), batch_size):
        batch = messages[i:i + batch_size]
        body = json.dumps({"agent_id": AGENT_ID, "messages": batch}).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.loads(resp.read())
                total += len(batch)
                print(f"  Batch {i // batch_size + 1}: pushed {len(batch)} → {result}")
        except urllib.error.HTTPError as e:
            print(f"  Batch {i // batch_size + 1}: HTTP {e.code} — {e.read().decode()}")
            raise

    print(f"Done — pushed {total} messages total")


if __name__ == "__main__":
    print(f"Reading from: {CHAT_DB}")
    print(f"Chat: {CHAT_IDENTIFIER}")
    print(f"Endpoint: {API_ENDPOINT}")
    print()

    messages = fetch_messages(CHAT_IDENTIFIER)
    if not messages:
        print("No messages found — check that chat.db has Full Disk Access.")
    else:
        push_history(messages)
