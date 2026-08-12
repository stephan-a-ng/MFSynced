"""Tests for `mftext send <phone> <text>` / `mf text send` — POST /v1/messages/send
plus the --wait polling loop against GET /v1/messages/{id}.
"""

import json
import uuid

import mf_core.http as mf_http
import pytest
from click.testing import CliRunner

import mftext.commands.send_cmd as send_mod
from mftext.cli import main


def run(args, **kw):
    return CliRunner().invoke(main, args, **kw)


@pytest.fixture(autouse=True)
def _no_sleep(monkeypatch):
    """Never actually sleep in tests (module-level `time` import in
    send_cmd.py mirrors deploy/cli's ota-confirm pattern for exactly this)."""
    monkeypatch.setattr(send_mod.time, "sleep", lambda *_a, **_k: None)


# ---------------------------------------------------------------------------
# Plain send (no --wait): posts once with a fresh idempotency_key.
# ---------------------------------------------------------------------------


def test_send_posts_with_fresh_idempotency_key(monkeypatch):
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append((method, path, json, audience))
        return {
            "command_id": "cmd-1",
            "agent_id": "a1",
            "phone": "+1555",
            "status": "pending",
            "created": "now",
        }

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["send", "+1555", "hello"])
    assert res.exit_code == 0, res.output
    assert "command_id=cmd-1" in res.output

    method, path, body, audience = calls[0]
    assert method == "POST"
    assert path == "/v1/messages/send"
    assert body["phone"] == "+1555"
    assert body["text"] == "hello"
    assert audience == "message-staging"
    uuid.UUID(body["idempotency_key"])  # a real uuid4, present


def test_send_agent_id_flag_included(monkeypatch):
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append(json)
        return {"command_id": "cmd-1", "status": "pending"}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["send", "+1555", "hello", "--agent-id", "agent-9"])
    assert res.exit_code == 0, res.output
    assert calls[0]["agent_id"] == "agent-9"


def test_send_agent_id_omitted_when_not_given(monkeypatch):
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append(json)
        return {"command_id": "cmd-1", "status": "pending"}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["send", "+1555", "hello"])
    assert res.exit_code == 0, res.output
    assert "agent_id" not in calls[0]


def test_send_json_output_no_wait(monkeypatch):
    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        return {
            "command_id": "cmd-1",
            "agent_id": "a1",
            "phone": "+1555",
            "status": "pending",
            "created": "now",
        }

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["--json", "send", "+1555", "hello"])
    assert res.exit_code == 0, res.output
    assert json.loads(res.output)["command_id"] == "cmd-1"


# ---------------------------------------------------------------------------
# --wait: polls GET /v1/messages/{id} every 2s (patched sleep) until terminal.
# ---------------------------------------------------------------------------


def test_send_wait_delivered_exits_zero(monkeypatch):
    statuses = ["pending", "sent", "delivered"]
    polls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        if method == "POST":
            return {"command_id": "cmd-1", "status": "pending"}
        polls.append(path)
        status = statuses.pop(0) if statuses else "delivered"
        return {"id": "cmd-1", "status": status}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["send", "+1555", "hello", "--wait", "--timeout", "10"])
    assert res.exit_code == 0, res.output
    assert "delivered" in res.output.lower()
    assert polls and all(p == "/v1/messages/cmd-1" for p in polls)


def test_send_wait_idempotency_key_stable_across_polls(monkeypatch):
    """The idempotency key is generated exactly once (at POST time) and never
    regenerated across the --wait poll loop — only GETs happen there."""
    seen_keys = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        if method == "POST":
            seen_keys.append(json["idempotency_key"])
            return {"command_id": "cmd-1", "status": "pending"}
        return {"id": "cmd-1", "status": "delivered"}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["send", "+1555", "hello", "--wait"])
    assert res.exit_code == 0, res.output
    assert len(seen_keys) == 1


def test_send_wait_failed_exits_nonzero_and_prints_reason(monkeypatch):
    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        if method == "POST":
            return {"command_id": "cmd-1", "status": "pending"}
        return {"id": "cmd-1", "status": "failed: agent unreachable"}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["send", "+1555", "hello", "--wait"])
    assert res.exit_code != 0
    assert "failed: agent unreachable" in res.output


def test_send_wait_timeout_exits_nonzero(monkeypatch):
    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        if method == "POST":
            return {"command_id": "cmd-1", "status": "pending"}
        return {"id": "cmd-1", "status": "sent"}  # never reaches a terminal status

    monkeypatch.setattr(mf_http, "request", fake_request)
    # --timeout 0: the deadline is already elapsed after the first poll, so
    # this terminates immediately (with patched sleep) instead of looping
    # for a real 60s.
    res = run(["send", "+1555", "hello", "--wait", "--timeout", "0"])
    assert res.exit_code != 0
    assert "timeout" in res.output.lower()


def test_send_wait_json_output_includes_final_status(monkeypatch):
    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        if method == "POST":
            return {"command_id": "cmd-1", "status": "pending"}
        return {"id": "cmd-1", "status": "delivered"}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["--json", "send", "+1555", "hello", "--wait"])
    assert res.exit_code == 0, res.output
    assert json.loads(res.output)["status"] == "delivered"
