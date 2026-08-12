"""`mf text read <phone>` — print a conversation's message history.

``GET /v1/conversations/{phone}/messages`` requires ``agent_id`` as a query
param, but operators only know the phone number. We resolve the target
conversation by matching against ``GET /v1/conversations``:

  1. exact match on digits-only phone (strips "+", spaces, dashes, parens);
  2. falling back to a trailing-10-digit match, so "+15551234567",
     "15551234567", and "5551234567" all resolve to the same conversation
     regardless of how the caller typed the number or how it's stored.

Zero or multiple (ambiguous) matches at either stage raise loudly rather
than guessing. The messages endpoint returns oldest-first (a page, per
``limit``/``offset``); we print it as-is, so output reads newest-last.
"""

from __future__ import annotations

import click

from ..client import TextError, make_client
from ..render import echo_json


def _digits(phone: str) -> str:
    return "".join(c for c in phone if c.isdigit())


def _last10(phone: str) -> str:
    d = _digits(phone)
    return d[-10:] if len(d) >= 10 else d


def resolve_conversation(conversations: list[dict], phone: str) -> dict:
    """Return the single conversation row matching ``phone``.

    Exact digits-only match wins outright. If none, fall back to a
    trailing-10-digit match (handles +1 country-code / formatting
    mismatches between what the operator typed and what's stored). Raises
    click.ClickException on zero or ambiguous (>1) matches at either stage.
    """
    target = _digits(phone)
    exact = [c for c in conversations if _digits(c.get("phone", "")) == target]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        raise click.ClickException(
            f"Ambiguous phone {phone!r} — matches {len(exact)} conversations "
            f"(across agents); disambiguate with the exact stored number."
        )

    target10 = _last10(phone)
    fallback = [c for c in conversations if _last10(c.get("phone", "")) == target10]
    if len(fallback) == 1:
        return fallback[0]
    if len(fallback) > 1:
        raise click.ClickException(
            f"Ambiguous phone {phone!r} — matches {len(fallback)} conversations "
            f"(across agents) by trailing-10-digit fallback; disambiguate with "
            f"the exact stored number."
        )

    raise click.ClickException(f"No conversation found for phone {phone!r}.")


@click.command(
    "read", help="Print message history for a conversation. e.g. mf text read +15551234567"
)
@click.argument("phone")
@click.option("--limit", type=int, default=30, show_default=True, help="Max messages to fetch.")
@click.pass_context
def read_cmd(ctx, phone, limit):
    o = ctx.obj
    client = make_client(o["base_url"], o["audience"])
    try:
        conversations = client.get("/v1/conversations")
        conv = resolve_conversation(conversations, phone)
        messages = client.get(
            f"/v1/conversations/{conv['phone']}/messages",
            params={"agent_id": str(conv["agent_id"]), "limit": limit},
        )
    except TextError as e:
        raise click.ClickException(str(e))

    if o["json"]:
        echo_json(messages)
        return

    if not messages:
        click.echo("(no messages)")
        return

    # Oldest-first as returned by the API -> print as-is (newest-last).
    for m in messages:
        who = "me" if m.get("is_from_me") else "them"
        click.echo(f"{who}: {m.get('timestamp')} {m.get('text')}")
