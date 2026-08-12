"""`mf text agent-register --name NAME` — register a new Mac agent.

``POST /v1/agent/register`` mints a fresh API key for a new Mac agent, bound
to the operator's own account (JWT auth, exchanged the same way as every
other mf-text endpoint — see client.py). The key is returned exactly once
in the response body; the server holds no way to retrieve it again, so it's
printed with a "store it now" warning rather than cached anywhere by this
CLI.
"""

from __future__ import annotations

import click

from ..client import TextError, make_client
from ..render import echo_json


@click.command(
    "agent-register", help="Register a new Mac agent and mint its API key (shown once)."
)
@click.option("--name", required=True, help="A label for this Mac agent (e.g. \"Stephan's MacBook\").")
@click.pass_context
def agent_register_cmd(ctx, name):
    o = ctx.obj
    client = make_client(o["base_url"], o["audience"])
    try:
        result = client.post("/v1/agent/register", json={"name": name})
    except TextError as e:
        raise click.ClickException(str(e))

    if o["json"]:
        echo_json(result)
        return

    click.echo(f"agent_id={result.get('agent_id')}")
    click.echo("")
    click.echo(
        click.style(
            "API key (shown once — store it now, it cannot be retrieved again):",
            fg="yellow",
            bold=True,
        )
    )
    click.echo(result.get("api_key"))
