"""The `text` command group — an HTTP client for the mf-text (iMessage
relay) service API.

Mirrors the `deploy` / `access` / `data` CLI conventions: a Click group,
subcommands under commands/, --json output.

Authenticates like every other `mf` plugin: the stored `mf login` session is
silently exchanged (RFC 8693 (Token Exchange)) for a `message-<env>`
audience token via mf_core.http — see client.py. There is no `--token`
bypass (unlike deploy/cli); `$MESSAGE_API_URL` only overrides the base URL,
never the auth path. The `mf` front door already owns env selection
(`mf --env ... text ...` / `mf use`); this standalone `mftext` entry point
shares the same mf_core session state, so there's no separate --env flag
here.
"""

from __future__ import annotations

import click

from . import __version__
from .commands.agent_cmd import agent_register_cmd
from .commands.list_cmd import list_cmd
from .commands.read_cmd import read_cmd
from .commands.send_cmd import send_cmd
from .config import audience, base_url


@click.group(
    "text",
    help="Moon Five text (iMessage relay) CLI. Authenticates via `mf login` "
    "(silent token exchange, audience message-<env>).",
)
@click.version_option(__version__, prog_name="mftext")
@click.option("--json", "as_json", is_flag=True, help="Raw JSON output.")
@click.pass_context
def main(ctx, as_json):
    ctx.obj = {"base_url": base_url(), "audience": audience(), "json": as_json}


main.add_command(list_cmd)
main.add_command(read_cmd)
main.add_command(send_cmd)
main.add_command(agent_register_cmd)


if __name__ == "__main__":
    main()
