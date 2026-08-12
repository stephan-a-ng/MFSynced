"""Shared test fixtures for the mf text CLI.

Every mftext network call routes through ``mf_core.http.request`` — there is
no explicit-token bypass (see client.py) — so a bare ``CliRunner`` invocation
with nothing stubbed would otherwise fall through to the REAL mf_core
session cache on this machine and could reach out to a live staging/
production API using the operator's real `mf login` credentials. This
autouse fixture defaults that path to a deterministic offline 401 and a
fixed ``current_env`` ("staging"); individual tests override either with
their own monkeypatch as needed.
"""

from __future__ import annotations

import mf_core.http as mf_http
import mf_core.session as mf_session
import pytest


@pytest.fixture(autouse=True)
def _mf_core_no_network(monkeypatch):
    def _no_session(*_args, **_kwargs):
        raise mf_http.APIError(
            401, "test isolation: mf_core.http.request not stubbed by this test"
        )

    monkeypatch.setattr(mf_http, "request", _no_session)
    monkeypatch.setattr(mf_session, "current_env", lambda: "staging")
    monkeypatch.delenv("MESSAGE_API_URL", raising=False)
