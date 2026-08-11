"""The text plugin mounts a `text` group (list/read/send/agent-register)
under `mf`."""

import click

from mftext.plugin import register


def test_register_mounts_text_with_subcommands():
    g = click.Group("mf")
    register(g)
    assert "text" in g.commands
    text = g.commands["text"]
    for sub in ("list", "read", "send", "agent-register"):
        assert sub in text.commands, f"missing mf text {sub}"
