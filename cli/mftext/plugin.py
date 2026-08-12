"""mftext as the `mf text` plugin.

Exposes ``register(group)`` (the ``mf.plugins`` contract) which mounts the
standalone `text` command group under the `mf` front door, so `text …` is
also available as `mf text …` (alongside `mf deploy` / `mf data` /
`mf access`). The text group is self-contained — its own ``ctx.obj`` built
from config.py — so it needs nothing from the mf context.
"""

from __future__ import annotations

import click


def register(group: click.Group) -> None:
    from mftext.cli import main as text_group

    group.add_command(text_group, name="text")
