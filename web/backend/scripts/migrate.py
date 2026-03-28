#!/usr/bin/env python3
"""Run SQL migrations against the database."""
import asyncio
import sys
from pathlib import Path
import asyncpg

async def run_migrations(dsn: str):
    conn = await asyncpg.connect(dsn)
    migrations_dir = Path(__file__).parent.parent / "migrations"
    for sql_file in sorted(migrations_dir.glob("*.sql")):
        print(f"Running {sql_file.name}...")
        sql = sql_file.read_text()
        await conn.execute(sql)
        print(f"  Done.")
    await conn.close()
    print("All migrations complete.")

if __name__ == "__main__":
    dsn = sys.argv[1] if len(sys.argv) > 1 else "postgresql://mfsynced:mfsynced@localhost:5432/mfsynced"
    asyncio.run(run_migrations(dsn))
