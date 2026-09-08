import os

import asyncpg

pool: asyncpg.Pool | None = None


# This service shares Cloud SQL connection capacity with other Moon Five
# backends. See moonfive-crm/docs/postmortem/2026-06-03-gmail-pubsub-retry-storm.md.
def pool_settings() -> dict[str, int]:
    def read_size(name: str, default: int) -> int:
        value = os.getenv(name, str(default))
        try:
            return int(value)
        except ValueError as exc:
            raise ValueError(f"{name} must be an integer; got {value!r}") from exc

    min_size = read_size("DB_POOL_MIN_SIZE", 0)
    max_size = read_size("DB_POOL_MAX_SIZE", 3)
    if min_size > max_size:
        raise ValueError(
            "DB_POOL_MIN_SIZE must be less than or equal to DB_POOL_MAX_SIZE"
        )
    return {"min_size": min_size, "max_size": max_size}


async def init_pool(dsn: str):
    global pool
    pool = await asyncpg.create_pool(dsn, **pool_settings())

async def close_pool():
    global pool
    if pool:
        await pool.close()
        pool = None

async def get_db():
    async with pool.acquire() as conn:
        yield conn
