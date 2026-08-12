#!/usr/bin/env python3
"""Run SQL migrations against the database, tracked in schema_migrations.

Full replacement for the original scripts/migrate.py, which had no tracking
table and re-ran every migrations/*.sql on every invocation (harmless only
by luck — every file so far happened to be idempotent DDL). This version
applies each file at most once.

Usage:
    python3 scripts/migrate.py [dsn]              # apply pending migrations
    python3 scripts/migrate.py [dsn] --dry-run     # list pending, change nothing
    python3 scripts/migrate.py [dsn] --baseline    # record existing migrations
                                                    # as already-applied, WITHOUT
                                                    # running their SQL

--baseline exists for the live staging/production DBs, where
001_initial.sql .. 004_archive.sql already ran (by hand, via the old
untracked script) before this tracking table existed. Run it ONCE per live
DB before the first tracked deploy:

    python3 scripts/migrate.py "$DATABASE_URL" --baseline

That records 001-004 as applied without re-executing them (re-running e.g.
a CREATE TABLE would error; a CREATE TABLE IF NOT EXISTS would silently
no-op but still gives no guarantee the file is a true no-op today). Any
migration added AFTER the baseline runs normally through the apply path
the next time this script is invoked without --baseline.

Each pending migration runs inside its own transaction; the filename is
recorded in schema_migrations only after that transaction's statements
succeed. A failing migration aborts the run immediately — later migrations
are not attempted, since they may assume the failed one landed. Re-running
after a fix skips everything already recorded and resumes at the failed
file.
"""
import argparse
import asyncio
import os
import sys
from pathlib import Path

import asyncpg

DEFAULT_DSN = "postgresql://mfsynced:mfsynced@localhost:5432/mfsynced"
MIGRATIONS_DIR = Path(__file__).parent.parent / "migrations"

CREATE_TRACKING_TABLE = """
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


async def _tracking_table_exists(conn: asyncpg.Connection) -> bool:
    row = await conn.fetchrow(
        "SELECT to_regclass('public.schema_migrations') IS NOT NULL AS exists"
    )
    return bool(row["exists"])


async def _applied_filenames(conn: asyncpg.Connection) -> set:
    # Read-only: does NOT create the table. Callers that need to guarantee
    # the table exists first (apply/baseline) create it themselves before
    # calling this.
    if not await _tracking_table_exists(conn):
        return set()
    rows = await conn.fetch("SELECT filename FROM schema_migrations")
    return {r["filename"] for r in rows}


def _all_migration_files() -> list:
    return sorted(MIGRATIONS_DIR.glob("*.sql"))


async def cmd_dry_run(conn: asyncpg.Connection) -> int:
    """Report pending migrations. Makes NO database changes (does not even
    create schema_migrations if it's missing)."""
    applied = await _applied_filenames(conn)
    pending = [f for f in _all_migration_files() if f.name not in applied]
    if not pending:
        print("No pending migrations.")
        return 0
    print(f"{len(pending)} pending migration(s):")
    for f in pending:
        print(f"  {f.name}")
    if not applied:
        print(
            "\nNote: schema_migrations does not exist yet (or is empty). If this "
            "database already has some/all of the files above applied by hand "
            "(e.g. a live DB where earlier migrations predate this tracking "
            "table), run --baseline instead of applying — otherwise the next "
            "non-dry-run invocation will try to re-run them."
        )
    return 0


async def cmd_baseline(conn: asyncpg.Connection, through: str | None = None) -> int:
    """Record not-yet-tracked migrations/*.sql as applied, WITHOUT executing
    their SQL. Idempotent: safe to re-run, only fills gaps.

    `through` limits the baseline to files sorted <= that filename — for a
    live DB that has historically applied only a prefix of the migrations
    (e.g. 001-004), so newer files still run through the apply path.
    """
    await conn.execute(CREATE_TRACKING_TABLE)
    applied = await _applied_filenames(conn)
    candidates = _all_migration_files()
    if through is not None:
        names = [f.name for f in candidates]
        if through not in names:
            print(f"ABORT: --baseline-through {through!r} does not match any "
                  f"migrations/*.sql file.", file=sys.stderr)
            return 1
        candidates = [f for f in candidates if f.name <= through]
    to_record = [f for f in candidates if f.name not in applied]
    if not to_record:
        print("Nothing to baseline — schema_migrations already covers all migrations/*.sql.")
        return 0
    async with conn.transaction():
        for f in to_record:
            await conn.execute(
                "INSERT INTO schema_migrations (filename) VALUES ($1) "
                "ON CONFLICT (filename) DO NOTHING",
                f.name,
            )
            print(f"Baselined {f.name} (recorded, NOT executed).")
    print(f"Baseline complete: {len(to_record)} file(s) recorded.")
    return 0


async def cmd_apply(conn: asyncpg.Connection) -> int:
    """Apply every pending migrations/*.sql, in sorted order, each in its
    own transaction, recording the filename only on success."""
    await conn.execute(CREATE_TRACKING_TABLE)
    applied = await _applied_filenames(conn)
    pending = [f for f in _all_migration_files() if f.name not in applied]
    if not pending:
        print("No pending migrations. Database is up to date.")
        return 0
    for f in pending:
        print(f"Running {f.name}...")
        sql = f.read_text()
        try:
            async with conn.transaction():
                await conn.execute(sql)
                await conn.execute(
                    "INSERT INTO schema_migrations (filename) VALUES ($1)",
                    f.name,
                )
        except Exception as exc:
            print(f"ABORT: {f.name} failed: {exc}", file=sys.stderr)
            print(
                f"Stopped after {f.name} — later migrations were NOT attempted "
                "(they may assume this one already landed). Fix the SQL and "
                "re-run; already-applied migrations are skipped automatically.",
                file=sys.stderr,
            )
            return 1
        print(f"  Done: {f.name}")
    print(f"All migrations complete. {len(pending)} applied.")
    return 0


async def main_async(args: argparse.Namespace) -> int:
    if not MIGRATIONS_DIR.is_dir():
        print(f"ABORT: migrations dir not found: {MIGRATIONS_DIR}", file=sys.stderr)
        return 1

    conn = await asyncpg.connect(args.dsn)
    try:
        if args.dry_run:
            return await cmd_dry_run(conn)
        if args.baseline or args.baseline_through:
            return await cmd_baseline(conn, through=args.baseline_through)
        return await cmd_apply(conn)
    finally:
        await conn.close()


def parse_args(argv: list) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply migrations/*.sql against DSN, tracked in schema_migrations."
    )
    parser.add_argument(
        "dsn",
        nargs="?",
        default=os.environ.get("DATABASE_URL", DEFAULT_DSN),
        help="Postgres DSN (default: $DATABASE_URL, else the local-dev default).",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="Print pending migrations and exit. Makes no DB changes.",
    )
    mode.add_argument(
        "--baseline",
        action="store_true",
        help=(
            "Record every migrations/*.sql not already tracked as applied, "
            "WITHOUT executing its SQL. Use once on a live DB where migrations "
            "already ran before schema_migrations existed."
        ),
    )
    mode.add_argument(
        "--baseline-through",
        metavar="FILENAME",
        help=(
            "Like --baseline, but only records files sorted <= FILENAME "
            "(e.g. 004_archive.sql) — for a live DB that has applied only a "
            "prefix of the migrations; newer files still run via normal apply."
        ),
    )
    return parser.parse_args(argv)


if __name__ == "__main__":
    parsed = parse_args(sys.argv[1:])
    sys.exit(asyncio.run(main_async(parsed)))
