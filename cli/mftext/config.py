"""Config: base URL + audience resolution for the `mf text` CLI.

Base URL resolution order: ``$MESSAGE_API_URL`` env var override > the
per-env default below, keyed off the active `mf` environment
(``mf_core.session.current_env()``). ``mf_core`` is imported lazily inside
``_current_env`` so tests can monkeypatch ``mf_core.session.current_env``
without needing mf_core importable at module load time.

Unlike deploy/cli, mftext has no explicit-token / bypass transport — every
call authenticates via ``mf_core.http.request`` (see client.py), so there is
no ``resolve(api_url, token)`` here, just the base URL and audience.
"""

from __future__ import annotations

import os

import click

# Per-env message (mfsynced) API base URL. TODO: swap for
# api.message.moonfive.tech once the custom domain is mapped (mirrors
# deploy's api.deploy.moonfive.tech / user-access's users-api.moonfive.tech).
_URLS = {
    "staging": "https://mfsynced-api-staging-iztclq7eza-uc.a.run.app",
    "production": "https://mfsynced-api-production-iztclq7eza-uc.a.run.app",
}
DEFAULT_ENV = "production"


def _current_env() -> str:
    """The active `mf` environment. Imported lazily so pure ``$MESSAGE_API_URL``
    usage keeps working even without mf_core installed, and so tests can
    monkeypatch ``mf_core.session.current_env``."""
    from mf_core import session

    return session.current_env()


def base_url(env: str | None = None) -> str:
    """Resolve the message API base URL: ``$MESSAGE_API_URL`` always wins;
    otherwise the per-env default for the active (or given) `mf` environment.
    An unknown environment (no override present) is a loud error — never a
    silent fallback to production."""
    override = os.environ.get("MESSAGE_API_URL")
    if override:
        return override.rstrip("/")
    e = env or _current_env()
    if e not in _URLS:
        raise click.ClickException(
            f"unknown mf environment {e!r} — no message API URL for it "
            f"(known: {', '.join(sorted(_URLS))}); set $MESSAGE_API_URL to override"
        )
    return _URLS[e]


def audience(env: str | None = None) -> str:
    """``message-<env>`` for the active (or given) `mf` environment — the
    OIDC (OpenID Connect) `aud` the mfsynced backend validates."""
    return f"message-{env or _current_env()}"
