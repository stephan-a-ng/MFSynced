"""Presentation: JSON passthrough or an aligned table of selected columns.

Mirrors deploycli/render.py — kept as its own tiny module (not shared)
because the two CLIs are separately-installed packages.
"""

from __future__ import annotations

import json as _json

import click


def echo_json(data) -> None:
    click.echo(_json.dumps(data, indent=2, default=str))


def _cell(value) -> str:
    if value is None:
        return "-"
    return str(value)


def render_rows(rows: list[dict], columns: list[str]) -> None:
    if not rows:
        click.echo("(none)")
        return
    widths = {c: len(c) for c in columns}
    for row in rows:
        for c in columns:
            widths[c] = max(widths[c], len(_cell(row.get(c))))
    header = "  ".join(c.ljust(widths[c]) for c in columns)
    click.echo(header)
    click.echo("  ".join("-" * widths[c] for c in columns))
    for row in rows:
        click.echo("  ".join(_cell(row.get(c)).ljust(widths[c]) for c in columns))


def render_one(obj: dict, columns: list[str]) -> None:
    render_rows([obj], columns)
