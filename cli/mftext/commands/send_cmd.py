"""`mf text send <phone> <text>` — enqueue an outbound text via a Mac agent.

``POST /v1/messages/send`` enqueues the message for a Mac agent to actually
send over iMessage; ``--agent-id`` targets a specific one, otherwise the API
picks. Every invocation mints a fresh ``idempotency_key`` (uuid4) — a single
CLI invocation sends exactly one message under that key; it never changes
across a ``--wait`` poll loop (the key protects the *send*, not the reads).

``--wait`` polls ``GET /v1/messages/{command_id}`` — a *module-level*
``time`` import (mirrors deploy/cli's ``ota confirm`` pattern) so tests can
monkeypatch ``time.sleep`` — every 2s until the command reaches a terminal
status: ``"delivered"`` exits 0; ``"failed: <reason>"`` or a timeout exit
non-zero, printing the reason.
"""

from __future__ import annotations

import time
import uuid

import click

from ..client import TextError, make_client
from ..render import echo_json

_POLL_INTERVAL_S = 2.0


def _is_terminal(status: str) -> bool:
    return status == "delivered" or status.startswith("failed")


@click.command(
    "send", help="Send a text via a registered Mac agent. e.g. mf text send +15551234567 'hi'"
)
@click.argument("phone")
@click.argument("text")
@click.option(
    "--agent-id", default=None, help="Target a specific agent (default: the API picks one)."
)
@click.option("--wait", is_flag=True, help="Poll until the message reaches a terminal status.")
@click.option(
    "--timeout",
    type=float,
    default=60.0,
    show_default=True,
    help="Max seconds to wait with --wait.",
)
@click.pass_context
def send_cmd(ctx, phone, text, agent_id, wait, timeout):
    o = ctx.obj
    client = make_client(o["base_url"], o["audience"])
    idempotency_key = str(uuid.uuid4())

    payload = {"phone": phone, "text": text, "idempotency_key": idempotency_key}
    if agent_id is not None:
        payload["agent_id"] = agent_id

    try:
        result = client.post("/v1/messages/send", json=payload)
    except TextError as e:
        raise click.ClickException(str(e))

    command_id = result.get("command_id")

    if not wait:
        if o["json"]:
            echo_json(result)
        else:
            click.echo(f"command_id={command_id} status={result.get('status')}")
        # Contract says /send returns "pending", but if the backend ever
        # reports a synchronous failure, reflect it in the exit code.
        if str(result.get("status", "")).startswith("failed"):
            raise SystemExit(1)
        return

    if not o["json"]:
        click.echo(f"command_id={command_id} status={result.get('status')} — waiting…")

    final = _await_terminal(client, command_id, timeout, quiet=o["json"])

    if o["json"]:
        echo_json(final)

    final_status = (final or {}).get("status") or ""
    if final_status == "delivered":
        if not o["json"]:
            click.echo(click.style(f"delivered (command_id={command_id})", fg="green"))
        return
    if final_status.startswith("failed"):
        if not o["json"]:
            click.echo(click.style(f"FAILED: {final_status}", fg="red"))
        raise SystemExit(1)
    if not o["json"]:
        click.echo(
            click.style(
                f"TIMEOUT after {timeout:.0f}s (last status={final_status or '?'})", fg="red"
            )
        )
    raise SystemExit(1)


def _await_terminal(client, command_id: str, timeout_s: float, quiet: bool = False) -> dict | None:
    """Poll GET /v1/messages/{command_id} until its status is terminal or the
    timeout elapses; returns the last-seen row (possibly None if every poll
    errored)."""
    deadline = time.monotonic() + max(0.0, timeout_s)
    last: dict | None = None
    while True:
        try:
            last = client.get(f"/v1/messages/{command_id}")
        except TextError as e:
            if not quiet:
                click.echo(click.style(f"  poll error (will retry): {e}", fg="yellow"))
        status = (last or {}).get("status") or ""
        if not quiet:
            click.echo(f"  status={status or '?'}")
        if _is_terminal(status):
            return last
        if time.monotonic() >= deadline:
            return last
        time.sleep(max(0.0, min(_POLL_INTERVAL_S, deadline - time.monotonic())))
