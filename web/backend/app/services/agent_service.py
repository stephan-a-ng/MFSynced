import hashlib
import secrets
from uuid import UUID

import asyncpg


def generate_api_key() -> tuple[str, str]:
    """Generate an API key and its SHA-256 hash. Returns (plaintext_key, key_hash)."""
    key = f"mfs_{secrets.token_urlsafe(32)}"
    key_hash = hashlib.sha256(key.encode()).hexdigest()
    return key, key_hash


async def register_agent(
    conn: asyncpg.Connection,
    user_id: UUID,
    name: str = "My Mac",
) -> tuple[dict, str]:
    """Register a new agent. Returns (agent_record, plaintext_api_key)."""
    api_key, key_hash = generate_api_key()
    agent = await conn.fetchrow(
        """INSERT INTO agents (user_id, name, api_key_hash)
           VALUES ($1, $2, $3) RETURNING *""",
        user_id, name, key_hash,
    )
    return dict(agent), api_key
