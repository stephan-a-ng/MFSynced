"""Resolve a local `users` row from verified user-access JWT claims.

Mirrors Pattern A of user-access/docs/INTEGRATION.md §7 — the local
`users` table keeps its own PK and FK-referencing tables are left alone;
we just add a `user_access_sub` link column.

Resolution order on every authenticated request:
  1. Direct link — `users.user_access_sub == claims["sub"]`. Fast path
     for every request after the first.
  2. Fallback by email — for rows that pre-date the migration (still
     have a `google_id`, no `user_access_sub` yet). Backfills the link
     so the next request hits branch 1.
  3. Brand-new user — insert a fresh row with `google_id` left NULL.

If an email already resolves to a DIFFERENT `user_access_sub` than the
one presented, we refuse to silently reassign it (that would let one
account annex another's history) — callers should surface this as a
5xx, not swallow it.
"""
from __future__ import annotations

from typing import Any

import asyncpg


def _role_from_claims(claims: dict) -> str:
    return "admin" if claims.get("app_role") == "admin" else "member"


async def upsert_user_from_claims(conn: asyncpg.Connection, claims: dict) -> dict[str, Any]:
    sub = claims.get("sub")
    email = (claims.get("email") or "").lower()
    if not sub or not email:
        # Operator-audience tokens (e.g. a widened ua-cli audience) may lack an
        # email claim; map to a clean auth failure instead of a KeyError 500.
        raise ValueError("token missing sub or email claim")
    if claims.get("email_verified") is False:
        # user-access asserts Google-verified emails today; guard the
        # email-linking path in case a future IdP flow mints unverified ones.
        raise ValueError("token email is not verified")
    name = claims.get("name") or email
    photo_url = claims.get("picture")
    role = _role_from_claims(claims)

    # 1. Direct link first — fastest, set after first sign-in.
    user = await conn.fetchrow(
        "SELECT * FROM users WHERE user_access_sub = $1", sub,
    )
    if user is not None:
        # Mirror role/name/photo from the token on every call so admin
        # grants/revokes in user-access take effect without a re-insert.
        user = await conn.fetchrow(
            """UPDATE users SET name = $1, photo_url = $2, role = $3
               WHERE id = $4
               RETURNING *""",
            name, photo_url, role, user["id"],
        )
        return dict(user)

    # 2. Fall back to email — for existing rows that pre-date the migration.
    existing = await conn.fetchrow(
        "SELECT * FROM users WHERE lower(email) = $1", email,
    )
    if existing is not None:
        if existing["user_access_sub"] is not None and existing["user_access_sub"] != sub:
            # Email matches a row already linked to a different sub — do
            # NOT silently steal it.
            raise ValueError(
                f"email {email!r} is already linked to a different user-access sub"
            )
        user = await conn.fetchrow(
            """UPDATE users
               SET user_access_sub = $1, name = $2, photo_url = $3, role = $4
               WHERE id = $5
               RETURNING *""",
            sub, name, photo_url, role, existing["id"],
        )
        return dict(user)

    # 3. Brand-new user — insert with the user-access sub as the link.
    user = await conn.fetchrow(
        """INSERT INTO users (email, name, photo_url, role, user_access_sub, google_id)
           VALUES ($1, $2, $3, $4, $5, NULL)
           RETURNING *""",
        email, name, photo_url, role, sub,
    )
    return dict(user)
