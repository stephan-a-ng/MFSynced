"""Tests for `mftext read <phone>` / `mf text read`."""

import json

import click
import mf_core.http as mf_http
import pytest
from click.testing import CliRunner

from mftext.cli import main
from mftext.commands.read_cmd import resolve_conversation

_CONVERSATIONS = [
    {
        "phone": "+15551234567",
        "agent_id": "agent-1",
        "contact_name": "Alice",
        "last_message_at": None,
        "message_count": 2,
    },
    {
        "phone": "+15559998888",
        "agent_id": "agent-2",
        "contact_name": "Bob",
        "last_message_at": None,
        "message_count": 1,
    },
]

_MESSAGES = [
    {
        "id": "m1",
        "guid": "g1",
        "phone": "+15551234567",
        "text": "hi",
        "timestamp": "2026-08-01T00:00:00Z",
        "is_from_me": False,
        "service": "iMessage",
    },
    {
        "id": "m2",
        "guid": "g2",
        "phone": "+15551234567",
        "text": "hey back",
        "timestamp": "2026-08-01T00:01:00Z",
        "is_from_me": True,
        "service": "iMessage",
    },
]


def run(args, **kw):
    return CliRunner().invoke(main, args, **kw)


def _stub(monkeypatch, conversations=None, messages=None):
    conversations = _CONVERSATIONS if conversations is None else conversations
    messages = _MESSAGES if messages is None else messages
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append({"method": method, "path": path, "params": params, "audience": audience})
        if path == "/v1/conversations":
            return conversations
        if path.endswith("/messages"):
            return messages
        raise AssertionError(f"unexpected path {path}")

    monkeypatch.setattr(mf_http, "request", fake_request)
    return calls


# ---------------------------------------------------------------------------
# resolve_conversation() — the phone -> conversation normalizer, unit-tested
# directly (no HTTP involved).
# ---------------------------------------------------------------------------


def test_resolve_exact_digits_match():
    conv = resolve_conversation(_CONVERSATIONS, "+15551234567")
    assert conv["agent_id"] == "agent-1"


def test_resolve_trailing_10_digit_fallback():
    # Caller typed no country code; stored phone has "+1" — only the
    # trailing-10-digit fallback matches.
    conv = resolve_conversation(_CONVERSATIONS, "5551234567")
    assert conv["agent_id"] == "agent-1"


def test_resolve_ignores_formatting_punctuation():
    conv = resolve_conversation(_CONVERSATIONS, "+1 (555) 123-4567")
    assert conv["agent_id"] == "agent-1"


def test_resolve_no_match_raises():
    with pytest.raises(click.ClickException):
        resolve_conversation(_CONVERSATIONS, "+19998887777")


def test_resolve_ambiguous_exact_raises():
    dup = _CONVERSATIONS + [{"phone": "+15551234567", "agent_id": "agent-3"}]
    with pytest.raises(click.ClickException):
        resolve_conversation(dup, "+15551234567")


# ---------------------------------------------------------------------------
# `read` CLI end-to-end (conversations lookup -> messages fetch -> print).
# ---------------------------------------------------------------------------


def test_read_resolves_agent_and_prints_messages(monkeypatch):
    calls = _stub(monkeypatch)
    res = run(["read", "+15551234567"])
    assert res.exit_code == 0, res.output
    assert "them: 2026-08-01T00:00:00Z hi" in res.output
    assert "me: 2026-08-01T00:01:00Z hey back" in res.output

    msg_call = calls[1]
    assert msg_call["path"] == "/v1/conversations/+15551234567/messages"
    assert msg_call["params"] == {"agent_id": "agent-1", "limit": 30}
    assert msg_call["audience"] == "message-staging"


def test_read_limit_flag_passed_through(monkeypatch):
    calls = _stub(monkeypatch)
    res = run(["read", "+15551234567", "--limit", "5"])
    assert res.exit_code == 0, res.output
    assert calls[1]["params"]["limit"] == 5


def test_read_trailing_10_digit_normalizer_through_cli(monkeypatch):
    calls = _stub(monkeypatch)
    res = run(["read", "5551234567"])  # no country code; matches +15551234567
    assert res.exit_code == 0, res.output
    assert calls[1]["params"]["agent_id"] == "agent-1"
    # The resolved conversation's stored phone is used in the messages path,
    # not the operator's raw (differently-formatted) input.
    assert calls[1]["path"] == "/v1/conversations/+15551234567/messages"


def test_read_no_conversation_found(monkeypatch):
    _stub(monkeypatch)
    res = run(["read", "+19998887777"])
    assert res.exit_code != 0
    assert "no conversation" in res.output.lower()


def test_read_empty_messages(monkeypatch):
    _stub(monkeypatch, messages=[])
    res = run(["read", "+15551234567"])
    assert res.exit_code == 0
    assert "(no messages)" in res.output


def test_read_json_passthrough(monkeypatch):
    _stub(monkeypatch)
    res = run(["--json", "read", "+15551234567"])
    assert res.exit_code == 0, res.output
    assert json.loads(res.output) == _MESSAGES


def test_read_api_error_surfaced(monkeypatch):
    def fake_request(*_a, **_k):
        raise mf_http.APIError(403, "not your agent")

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["read", "+15551234567"])
    assert res.exit_code != 0
    assert "403" in res.output
