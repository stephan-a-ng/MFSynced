import asyncpg

pool: asyncpg.Pool | None = None

async def init_pool(dsn: str, min_size: int = 2, max_size: int = 10):
    global pool
    pool = await asyncpg.create_pool(dsn, min_size=min_size, max_size=max_size)

async def close_pool():
    global pool
    if pool:
        await pool.close()
        pool = None

async def get_db():
    async with pool.acquire() as conn:
        yield conn
