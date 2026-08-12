"""Tests for mftext.client.TextClient — the mf_core.http.request passthrough."""

import mf_core.http as mf_http
import pytest

from mftext.client import TextError, make_client


def test_get_passes_method_path_base_audience_params(monkeypatch):
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append((method, path, base, json, params, audience))
        return {"ok": True}

    monkeypatch.setattr(mf_http, "request", fake_request)

    client = make_client("https://mfsynced-api-staging-iztclq7eza-uc.a.run.app", "message-staging")
    result = client.get("/v1/conversations", params={"a": "b"})

    assert result == {"ok": True}
    assert calls == [
        (
            "GET",
            "/v1/conversations",
            "https://mfsynced-api-staging-iztclq7eza-uc.a.run.app",
            None,
            {"a": "b"},
            "message-staging",
        )
    ]


def test_post_passes_json_body(monkeypatch):
    calls = []

    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        calls.append((method, path, json))
        return {"id": "1"}

    monkeypatch.setattr(mf_http, "request", fake_request)

    client = make_client("https://x", "message-production")
    result = client.post("/v1/messages/send", json={"phone": "+1555", "text": "hi"})
    assert result == {"id": "1"}
    assert calls == [("POST", "/v1/messages/send", {"phone": "+1555", "text": "hi"})]


def test_base_url_trailing_slash_stripped():
    client = make_client("https://x/", "message-production")
    assert client.base_url == "https://x"


def test_api_error_wrapped_as_text_error_preserving_message(monkeypatch):
    def fake_request(method, path, *, base=None, json=None, params=None, audience=None):
        raise mf_http.APIError(403, "not granted")

    monkeypatch.setattr(mf_http, "request", fake_request)

    client = make_client("https://x", "message-production")
    with pytest.raises(TextError) as exc_info:
        client.get("/v1/conversations")
    msg = str(exc_info.value)
    assert "403" in msg
    assert "not granted" in msg
    assert exc_info.value.status == 403
