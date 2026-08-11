"""
Tests for the OIDC user-upsert path.

After the user-access OIDC migration, logins no longer come from Google
directly — they arrive as OIDC claims (sub / email / name / picture /
app_role) resolved by `app.services.user_service.upsert_user_from_claims`.

Resolution order:
  1. users.user_access_sub == sub          -> return that row (refresh name/photo)
  2. else users.email == claims.email      -> link it (set user_access_sub)
  3. else                                  -> INSERT a new user

users.role always mirrors the incoming app_role claim, so a role change in
user-access propagates on next login.

This is a pure RED file: `app.services.user_service` does not exist yet, and
migration 005_user_access.sql (which adds users.user_access_sub and makes
users.google_id nullable) has not been written. Every test here is expected
to fail until both land.
"""
import uuid

import pytest


def _claims(sub=None, email="new.user@moonfive.tech", name="New User", picture=None, app_role="member"):
    return {
        "sub": sub or str(uuid.uuid4()),
        "email": email,
        "name": name,
        "picture": picture,
        "app_role": app_role,
    }


# ---------------------------------------------------------------------------
# 1. New sub + new email -> creates a user
# ---------------------------------------------------------------------------

async def test_new_claims_create_user(db_conn):
    from app.services.user_service import upsert_user_from_claims

    claims = _claims(email="fresh@moonfive.tech", name="Fresh Person", app_role="member")
    user = await upsert_user_from_claims(db_conn, claims)

    assert user["email"] == "fresh@moonfive.tech"
    assert user["name"] == "Fresh Person"
    assert user["role"] == "member"
    assert user["google_id"] is None
    assert str(user["user_access_sub"]) == claims["sub"]

    row = await db_conn.fetchrow("SELECT * FROM users WHERE email = $1", "fresh@moonfive.tech")
    assert row is not None
    assert row["id"] == user["id"]


# ---------------------------------------------------------------------------
# 2. Same sub called twice -> one row; second call updates changed name
# ---------------------------------------------------------------------------

async def test_repeat_login_same_sub_updates_in_place(db_conn):
    from app.services.user_service import upsert_user_from_claims

    sub = str(uuid.uuid4())
    first = await upsert_user_from_claims(
        db_conn, _claims(sub=sub, email="repeat@moonfive.tech", name="Old Name")
    )

    second = await upsert_user_from_claims(
        db_conn, _claims(sub=sub, email="repeat@moonfive.tech", name="New Name")
    )

    assert second["id"] == first["id"]
    assert second["name"] == "New Name"

    count = await db_conn.fetchval("SELECT count(*) FROM users WHERE user_access_sub = $1", sub)
    assert count == 1


# ---------------------------------------------------------------------------
# 3. Legacy (pre-migration) user linked by email on first OIDC login
# ---------------------------------------------------------------------------

async def test_legacy_user_linked_by_email(db_conn):
    from app.services.user_service import upsert_user_from_claims

    legacy = await db_conn.fetchrow(
        """INSERT INTO users (google_id, email, name, role)
           VALUES ($1, $2, $3, $4) RETURNING *""",
        "legacy-google-id", "legacy@moonfive.tech", "Legacy Person", "member",
    )

    sub = str(uuid.uuid4())
    linked = await upsert_user_from_claims(
        db_conn, _claims(sub=sub, email="legacy@moonfive.tech", name="Legacy Person")
    )

    assert linked["id"] == legacy["id"]
    assert str(linked["user_access_sub"]) == sub
    assert linked["google_id"] == "legacy-google-id"  # untouched

    row = await db_conn.fetchrow("SELECT * FROM users WHERE id = $1", legacy["id"])
    assert str(row["user_access_sub"]) == sub
    assert row["google_id"] == "legacy-google-id"


# ---------------------------------------------------------------------------
# 4. app_role propagates on every login (admin <-> member)
# ---------------------------------------------------------------------------

async def test_role_mirrors_app_role_claim_each_login(db_conn):
    from app.services.user_service import upsert_user_from_claims

    sub = str(uuid.uuid4())
    admin_login = await upsert_user_from_claims(
        db_conn, _claims(sub=sub, email="roleflip@moonfive.tech", app_role="admin")
    )
    assert admin_login["role"] == "admin"

    member_login = await upsert_user_from_claims(
        db_conn, _claims(sub=sub, email="roleflip@moonfive.tech", app_role="member")
    )
    assert member_login["role"] == "member"
    assert member_login["id"] == admin_login["id"]

    row = await db_conn.fetchrow("SELECT role FROM users WHERE id = $1", admin_login["id"])
    assert row["role"] == "member"


# ---------------------------------------------------------------------------
# 5. Second sub can't steal an email already linked to a different sub
# ---------------------------------------------------------------------------

async def test_conflicting_sub_for_already_linked_email_raises(db_conn):
    from app.services.user_service import upsert_user_from_claims

    first_sub = str(uuid.uuid4())
    await upsert_user_from_claims(
        db_conn, _claims(sub=first_sub, email="shared@moonfive.tech", name="Original Owner")
    )

    second_sub = str(uuid.uuid4())
    with pytest.raises(ValueError):
        await upsert_user_from_claims(
            db_conn, _claims(sub=second_sub, email="shared@moonfive.tech", name="Impostor")
        )

    # The original row must be untouched — no silent relink to the new sub.
    row = await db_conn.fetchrow("SELECT * FROM users WHERE email = $1", "shared@moonfive.tech")
    assert str(row["user_access_sub"]) == first_sub

    stolen = await db_conn.fetchrow("SELECT * FROM users WHERE user_access_sub = $1", second_sub)
    assert stolen is None


# ---------------------------------------------------------------------------
# 6. Schema assertions: migration 005 shape
# ---------------------------------------------------------------------------

async def test_user_access_sub_column_is_unique(db_conn):
    row = await db_conn.fetchrow(
        """SELECT column_name, is_nullable
           FROM information_schema.columns
           WHERE table_name = 'users' AND column_name = 'user_access_sub'"""
    )
    assert row is not None, "users.user_access_sub column is missing (migration 005 not applied?)"
    assert row["is_nullable"] == "YES"

    # Uniqueness may be enforced by a UNIQUE constraint or a (partial) unique
    # index — pg_indexes covers both forms.
    unique_index = await db_conn.fetchrow(
        """SELECT indexname FROM pg_indexes
           WHERE tablename = 'users'
             AND indexdef ILIKE '%UNIQUE%'
             AND indexdef ILIKE '%user_access_sub%'"""
    )
    assert unique_index is not None, "users.user_access_sub has no unique index/constraint"


async def test_google_id_is_nullable(db_conn):
    row = await db_conn.fetchrow(
        """SELECT is_nullable FROM information_schema.columns
           WHERE table_name = 'users' AND column_name = 'google_id'"""
    )
    assert row is not None
    assert row["is_nullable"] == "YES"

    inserted = await db_conn.fetchrow(
        """INSERT INTO users (google_id, email, name, role)
           VALUES (NULL, $1, $2, $3) RETURNING *""",
        "nullgoogle@moonfive.tech", "Null Google", "member",
    )
    assert inserted["google_id"] is None
