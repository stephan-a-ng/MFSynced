"""Tests for database pool configuration."""

import pytest

from app.db import pool_settings


def test_pool_settings_defaults_when_environment_is_unset(monkeypatch):
    monkeypatch.delenv("DB_POOL_MIN_SIZE", raising=False)
    monkeypatch.delenv("DB_POOL_MAX_SIZE", raising=False)

    assert pool_settings() == {"min_size": 0, "max_size": 3}


def test_pool_settings_uses_environment_overrides(monkeypatch):
    monkeypatch.setenv("DB_POOL_MIN_SIZE", "1")
    monkeypatch.setenv("DB_POOL_MAX_SIZE", "4")

    assert pool_settings() == {"min_size": 1, "max_size": 4}


def test_pool_settings_rejects_invalid_environment_values(monkeypatch):
    monkeypatch.setenv("DB_POOL_MIN_SIZE", "not-an-integer")

    with pytest.raises(ValueError, match="DB_POOL_MIN_SIZE must be an integer"):
        pool_settings()


def test_pool_settings_rejects_minimum_greater_than_maximum(monkeypatch):
    monkeypatch.setenv("DB_POOL_MIN_SIZE", "4")
    monkeypatch.setenv("DB_POOL_MAX_SIZE", "3")

    with pytest.raises(ValueError, match="DB_POOL_MIN_SIZE must be less than or equal to DB_POOL_MAX_SIZE"):
        pool_settings()
