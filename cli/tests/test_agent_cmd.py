"""Tests for `mftext agent-register --name NAME` / `mf text agent-register`."""

import json

import mf_core.http as mf_http
from click.testing import CliRunner

from mftext.cli import main


def run(args, **kw):
    return CliRunner().invoke(main, args, **kw)


def test_agent_register_posts_name_and_prints_key_once(monkeypatch):
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append((method, path, json, audience))
        return {"agent_id": "agent-123", "api_key": "sk-live-abcxyz"}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["agent-register", "--name", "Stephan's MacBook"])
    assert res.exit_code == 0, res.output
    assert "agent-123" in res.output
    assert "sk-live-abcxyz" in res.output
    assert "store it now" in res.output.lower()

    method, path, body, audience = calls[0]
    assert method == "POST"
    assert path == "/v1/agent/register"
    assert body == {"name": "Stephan's MacBook"}
    assert audience == "message-staging"


def test_agent_register_requires_name():
    res = run(["agent-register"])
    assert res.exit_code != 0


def test_agent_register_json_output(monkeypatch):
    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        return {"agent_id": "agent-1", "api_key": "k"}

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["--json", "agent-register", "--name", "X"])
    assert res.exit_code == 0, res.output
    assert json.loads(res.output) == {"agent_id": "agent-1", "api_key": "k"}


def test_agent_register_api_error_surfaced(monkeypatch):
    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        raise mf_http.APIError(403, "not granted")

    monkeypatch.setattr(mf_http, "request", fake_request)
    res = run(["agent-register", "--name", "X"])
    assert res.exit_code != 0
    assert "403" in res.output
