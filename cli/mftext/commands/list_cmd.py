"""`mf text list` — list conversations across all your registered Mac agents.

``GET /v1/conversations`` returns rows keyed by (phone, agent_id) — the API
has no agent-name join, so each row carries an ``agent_id`` UUID but no
human-readable agent name. Rather than print the full UUID (unreadable in a
table), we display a short id (its first 8 hex chars) under the ``agent``
column.
"""

from __future__ import annotations

import click

from ..client import TextError, make_client
from ..render import echo_json, render_rows

_COLUMNS = ["phone", "contact_name", "last_message_at", "message_count", "agent"]


def _short_id(agent_id) -> str:
    return str(agent_id)[:8] if agent_id is not None else "-"


@click.command("list", help="List conversations across all your registered Mac agents.")
@click.pass_context
def list_cmd(ctx):
    o = ctx.obj
    client = make_client(o["base_url"], o["audience"])
    try:
        rows = client.get("/v1/conversations")
    except TextError as e:
        raise click.ClickException(str(e))

    if o["json"]:
        echo_json(rows)
        return

    table_rows = [{**r, "agent": _short_id(r.get("agent_id"))} for r in rows]
    render_rows(table_rows, _COLUMNS)
