"""Tests for mftext.config: base URL resolution + audience."""

import click
import mf_core.session as mf_session
import pytest

from mftext import config


def test_base_url_staging_default(monkeypatch):
    monkeypatch.setattr(mf_session, "current_env", lambda: "staging")
    monkeypatch.delenv("MESSAGE_API_URL", raising=False)
    assert config.base_url() == "https://mfsynced-api-staging-iztclq7eza-uc.a.run.app"


def test_base_url_production_default(monkeypatch):
    monkeypatch.setattr(mf_session, "current_env", lambda: "production")
    monkeypatch.delenv("MESSAGE_API_URL", raising=False)
    assert config.base_url() == "https://mfsynced-api-production-iztclq7eza-uc.a.run.app"


def test_message_api_url_override_wins(monkeypatch):
    monkeypatch.setattr(mf_session, "current_env", lambda: "production")
    monkeypatch.setenv("MESSAGE_API_URL", "https://custom.example.com/")
    assert config.base_url() == "https://custom.example.com"


def test_unknown_env_raises_click_exception(monkeypatch):
    monkeypatch.setattr(mf_session, "current_env", lambda: "sandbox")
    monkeypatch.delenv("MESSAGE_API_URL", raising=False)
    with pytest.raises(click.ClickException) as exc_info:
        config.base_url()
    msg = str(exc_info.value)
    assert "sandbox" in msg
    assert "staging" in msg and "production" in msg


def test_audience_defaults_to_current_env(monkeypatch):
    monkeypatch.setattr(mf_session, "current_env", lambda: "staging")
    assert config.audience() == "message-staging"


def test_audience_explicit_env_overrides_current(monkeypatch):
    monkeypatch.setattr(mf_session, "current_env", lambda: "staging")
    assert config.audience("production") == "message-production"


def test_audience_unknown_env_does_not_raise():
    # audience() never consults _URLS — even an unknown env just formats the
    # string; only base_url() validates against the known env set.
    assert config.audience("sandbox") == "message-sandbox"
