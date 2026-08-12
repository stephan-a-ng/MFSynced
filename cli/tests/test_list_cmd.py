"""Tests for `mftext list` / `mf text list`."""

import json

import mf_core.http as mf_http
from click.testing import CliRunner

from mftext.cli import main


def run(args, **kw):
    return CliRunner().invoke(main, args, **kw)


def _stub(monkeypatch, rows):
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append(
            {"method": method, "path": path, "base": base, "params": params, "audience": audience}
        )
        return rows

    monkeypatch.setattr(mf_http, "request", fake_request)
    return calls


def test_list_renders_table_with_short_agent_id(monkeypatch):
    rows = [
        {
            "phone": "+15551234567",
            "agent_id": "abcdef12-3456-7890-abcd-ef1234567890",
            "contact_name": "Alice",
            "last_message_at": "2026-08-01T00:00:00Z",
            "message_count": 12,
        }
    ]
    calls = _stub(monkeypatch, rows)

    res = run(["list"])
    assert res.exit_code == 0, res.output
    assert "Alice" in res.output
    assert "abcdef12" in res.output
    assert "abcdef12-3456-7890-abcd-ef1234567890" not in res.output  # full uuid not printed

    assert calls[0]["method"] == "GET"
    assert calls[0]["path"] == "/v1/conversations"
    assert calls[0]["audience"] == "message-staging"


def test_list_json_passthrough(monkeypatch):
    rows = [
        {
            "phone": "+1",
            "agent_id": "x",
            "contact_name": None,
            "last_message_at": None,
            "message_count": 0,
        }
    ]
    _stub(monkeypatch, rows)
    res = run(["--json", "list"])
    assert res.exit_code == 0, res.output
    assert json.loads(res.output) == rows


def test_list_empty(monkeypatch):
    _stub(monkeypatch, [])
    res = run(["list"])
    assert res.exit_code == 0
    assert "(none)" in res.output


def test_list_api_error_surfaced(monkeypatch):
    def fake_request(*_a, **_k):
        raise mf_http.APIError(401, "no stored tokens")

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["list"])
    assert res.exit_code != 0
    assert "401" in res.output
