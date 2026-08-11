"""Thin HTTP client for the mf-text (Mac-relayed iMessage) API.

Every network call goes through ``mf_core.http.request`` — the same
silently-authenticated transport (RFC 8693 (Token Exchange) token exchange,
with the m2m (machine-to-machine) credential path inherited for headless
agents) every other `mf` plugin uses — scoped to the ``message-<env>``
audience (see config.py). There is no explicit-token / bypass path here
(unlike deploy/cli's ``--token``/``$DEPLOY_TOKEN`` break-glass): `mf text`
always authenticates via the operator's `mf login` session.

``mf_core`` is imported lazily inside ``_request`` so tests monkeypatch
``mf_core.http.request`` directly (the module-level attribute), which takes
effect regardless of this lazy import.
"""

from __future__ import annotations

from typing import Any


class TextError(Exception):
    """Wraps an mf_core APIError, preserving its status + message verbatim."""

    def __init__(self, message: str, status: int | None = None):
        self.status = status
        super().__init__(message)


class TextClient:
    def __init__(self, base_url: str, audience: str):
        self.base_url = base_url.rstrip("/")
        self.audience = audience

    def _request(
        self, method: str, path: str, *, json: dict | None = None, params: dict | None = None
    ) -> Any:
        from mf_core import http as mf_http

        try:
            return mf_http.request(
                method,
                path,
                base=self.base_url,
                json=json,
                params=params,
                audience=self.audience,
            )
        except mf_http.APIError as e:
            # str(e) already embeds "status: detail" (e.g. "user-access API
            # error 403: ..."); preserve it verbatim rather than re-wrapping.
            raise TextError(str(e), status=getattr(e, "status", None)) from e

    def get(self, path: str, params: dict | None = None) -> Any:
        return self._request("GET", path, params=params)

    def post(self, path: str, json: dict | None = None) -> Any:
        return self._request("POST", path, json=json)


def make_client(base_url: str, audience: str) -> TextClient:
    return TextClient(base_url, audience)
