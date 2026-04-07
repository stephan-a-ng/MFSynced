#!/usr/bin/env python3
"""
End-to-end test: portal reply → Mac app delivery → sync back.

Mode A (default): Backend-only — simulates Mac app role via API calls.
Mode B (--mac):   Full integration — triggers real Mac app via control API.

Usage:
  python3 scripts/test_e2e_pipeline.py                          # backend-only
  python3 scripts/test_e2e_pipeline.py --mac                    # with Mac app
  python3 scripts/test_e2e_pipeline.py --backend http://localhost:8001
"""
import argparse
import sys
import time
from datetime import datetime, timezone

import httpx

TEST_PHONE = "+15550000001"

passed = 0
failed = 0


def check(label: str, condition: bool, detail: str = ""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  [PASS] {label}")
    else:
        failed += 1
        print(f"  [FAIL] {label}" + (f" — {detail}" if detail else ""))


def main():
    global passed, failed
    parser = argparse.ArgumentParser(description="E2E pipeline test")
    parser.add_argument("--backend", default="http://localhost:8001", help="Backend API URL")
    parser.add_argument("--mac", default="http://127.0.0.1:7891", help="Mac app control API URL")
    parser.add_argument("--use-mac", action="store_true", help="Use real Mac app for send (mode B)")
    args = parser.parse_args()

    api = args.backend + "/v1"
    mac = args.mac
    use_mac = args.use_mac
    client = httpx.Client(timeout=30)

    print(f"\n{'='*60}")
    print(f"  MFSynced E2E Pipeline Test")
    print(f"  Backend: {args.backend}")
    if use_mac:
        print(f"  Mac app: {mac}")
    print(f"  Mode: {'B (Mac app integration)' if use_mac else 'A (backend-only)'}")
    print(f"{'='*60}\n")

    # --- Pre-flight ---
    print("Pre-flight checks:")
    try:
        r = client.get(f"{args.backend}/health")
        check("Backend responding", r.status_code == 200)
    except Exception as e:
        check("Backend responding", False, str(e))
        print("\nBackend not reachable. Is uvicorn running on port 8001?")
        sys.exit(1)

    if use_mac:
        try:
            r = client.get(f"{mac}/health")
            check("Mac app control server responding", r.status_code == 200)
            health = r.json()
            check("Mac app CRM connected", health.get("crm_connected", False))
        except Exception as e:
            check("Mac app control server responding", False, str(e))
            print("\nMac app not reachable. Is it running with the control server?")
            sys.exit(1)

    # --- Auth ---
    print("\nAuthentication:")
    r = client.post(f"{api}/auth/dev-admin-login")
    check("Admin login (Stephan)", r.status_code == 200)
    admin_token = r.json().get("access_token", "")

    r = client.post(f"{api}/auth/dev-chase-login")
    check("Chase login", r.status_code == 200)
    chase_token = r.json().get("access_token", "")

    admin_headers = {"Authorization": f"Bearer {admin_token}"}
    chase_headers = {"Authorization": f"Bearer {chase_token}"}

    # --- Register agent ---
    print("\nAgent setup:")
    r = client.post(f"{api}/agent/register", json={"name": "E2E Test Mac"}, headers=admin_headers)
    check("Agent registered", r.status_code == 200)
    agent_id = r.json().get("agent_id", "")
    api_key = r.json().get("api_key", "")
    agent_headers = {"Authorization": f"Bearer {api_key}"}
    print(f"    agent_id={agent_id}")

    # --- Seed messages ---
    print("\nSeed data:")
    now = datetime.now(timezone.utc)
    messages = [
        {"id": f"e2e-msg-{i}", "phone": TEST_PHONE,
         "text": f"Test message {i}", "timestamp": now.isoformat(),
         "is_from_me": i % 2 == 0, "service": "iMessage",
         "contact_name": "E2E Test Contact"}
        for i in range(3)
    ]
    r = client.post(f"{api}/agent/messages/inbound",
                    json={"agent_id": agent_id, "messages": messages},
                    headers=agent_headers)
    confirmed = r.json().get("confirmed", []) if r.status_code == 200 else []
    check("3 messages synced", r.status_code == 200 and len(confirmed) == 3,
          f"status={r.status_code} body={r.text[:200]}")

    # --- Forward to Chase ---
    r = client.get(f"{api}/agent/users", headers=agent_headers)
    users = r.json()
    chase_id = next((u["id"] for u in users if "chase" in u.get("email", "").lower()), None)
    check("Found Chase user", chase_id is not None, f"users={[u['email'] for u in users]}")

    r = client.post(f"{api}/agent/forward",
                    json={"phone": TEST_PHONE, "mode": "action",
                          "recipient_user_ids": [chase_id]},
                    headers=agent_headers)
    check("Thread forwarded to Chase", r.status_code == 200)
    thread_id = r.json().get("thread_id", "")
    print(f"    thread_id={thread_id}")

    # --- Reply from portal ---
    print("\nReply flow:")
    reply_text = f"E2E test reply {int(time.time())}"
    r = client.post(f"{api}/inbox/{thread_id}/reply",
                    json={"text": reply_text},
                    headers=chase_headers)
    check("Reply sent from portal", r.status_code == 200,
          f"status={r.status_code} body={r.text[:200]}")

    # --- Verify message visible ---
    r = client.get(f"{api}/inbox/{thread_id}", headers=chase_headers)
    msgs = r.json().get("messages", [])
    outbound_msgs = [m for m in msgs if m.get("guid", "").startswith("outbound:")]
    check("Reply visible in thread", len(outbound_msgs) == 1 and outbound_msgs[0]["text"] == reply_text)

    if outbound_msgs:
        check("delivery_status=pending initially",
              outbound_msgs[0].get("delivery_status") == "pending")

    # --- Delivery ---
    print("\nDelivery:")
    if use_mac:
        # Mode B: trigger real Mac app
        r = client.post(f"{mac}/poll", timeout=30)
        check("Mac app poll triggered", r.status_code == 200)
        poll_result = r.json()
        outbound_results = poll_result.get("outbound_results", [])
        if outbound_results:
            check("Mac app sent message", outbound_results[0].get("success", False),
                  outbound_results[0].get("error", ""))
        else:
            check("Mac app sent message", False, "No outbound results — Mac app may use different agent_id")
    else:
        # Mode A: simulate Mac app behavior
        r = client.get(f"{api}/agent/messages/outbound", headers=agent_headers)
        commands = r.json().get("messages", [])
        check("Outbound command fetched", len(commands) >= 1)

        if commands:
            cmd = commands[0]
            check("Command text matches", cmd["text"] == reply_text)
            r = client.post(f"{api}/agent/messages/outbound/{cmd['id']}/ack",
                            json={"status": "delivered"},
                            headers=agent_headers)
            check("Delivery acknowledged", r.status_code == 200)

    # --- Verify final state ---
    print("\nVerification:")
    r = client.get(f"{api}/inbox/{thread_id}", headers=chase_headers)
    msgs = r.json().get("messages", [])
    outbound_msgs = [m for m in msgs if m.get("guid", "").startswith("outbound:")]

    if outbound_msgs:
        status = outbound_msgs[0].get("delivery_status")
        check("delivery_status=delivered", status == "delivered",
              f"got {status}")
    else:
        check("delivery_status=delivered", False, "outbound message not found in thread")

    # Check no duplicates
    reply_copies = [m for m in msgs if m["text"] == reply_text]
    check("No duplicate messages", len(reply_copies) == 1,
          f"found {len(reply_copies)} copies")

    # --- Summary ---
    total = passed + failed
    print(f"\n{'='*60}")
    print(f"  {passed}/{total} passed" + (f", {failed} failed" if failed else "") + ".")
    if failed == 0:
        print("  Pipeline verified end-to-end.")
    print(f"{'='*60}\n")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
