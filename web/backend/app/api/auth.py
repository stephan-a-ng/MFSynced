import logging
from uuid import UUID

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
import asyncpg

from app.api.deps import create_user_token, get_current_user_id, get_db
from app.config import settings
from app.rate_limit import limiter
from app.schemas.auth import GoogleAuthRequest, TokenResponse, UserResponse

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/v1/auth", tags=["auth"])

@router.post("/google", response_model=TokenResponse)
@limiter.limit("10/minute")
async def google_auth(
    request: Request,
    body: GoogleAuthRequest,
    conn: asyncpg.Connection = Depends(get_db),
) -> TokenResponse:
    if not settings.GOOGLE_CLIENT_ID or not settings.GOOGLE_CLIENT_SECRET:
        raise HTTPException(status_code=503, detail="Google OAuth not configured")

    async with httpx.AsyncClient() as client:
        token_resp = await client.post(
            "https://oauth2.googleapis.com/token",
            data={
                "code": body.code,
                "client_id": settings.GOOGLE_CLIENT_ID,
                "client_secret": settings.GOOGLE_CLIENT_SECRET,
                "redirect_uri": body.redirect_uri,
                "grant_type": "authorization_code",
            },
        )
    if token_resp.status_code != 200:
        logger.error("Google token exchange failed: %s %s", token_resp.status_code, token_resp.text)
        raise HTTPException(status_code=401, detail="Failed to exchange auth code")

    tokens = token_resp.json()
    access_token = tokens.get("access_token")

    async with httpx.AsyncClient() as client:
        user_resp = await client.get(
            "https://www.googleapis.com/oauth2/v2/userinfo",
            headers={"Authorization": f"Bearer {access_token}"},
        )
    if user_resp.status_code != 200:
        raise HTTPException(status_code=401, detail="Failed to get user info")

    info = user_resp.json()
    google_id = info["id"]
    email = info["email"]
    name = info.get("name", email)
    picture = info.get("picture")

    domain = email.split("@")[-1]
    if domain != settings.ALLOWED_EMAIL_DOMAIN:
        raise HTTPException(status_code=403, detail=f"Only @{settings.ALLOWED_EMAIL_DOMAIN} emails are allowed")

    role = "admin" if email == settings.ADMIN_EMAIL else "member"

    # Upsert by email — handles first-time real login after a dev-login bootstrap
    # (dev bootstrap inserts a row with email but a fake google_id; real login
    #  must overwrite the google_id so subsequent lookups work correctly)
    user = await conn.fetchrow(
        """INSERT INTO users (google_id, email, name, photo_url, role)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (email) DO UPDATE
           SET google_id = EXCLUDED.google_id,
               name = EXCLUDED.name,
               photo_url = EXCLUDED.photo_url,
               role = EXCLUDED.role
           RETURNING *""",
        google_id, email, name, picture, role,
    )

    jwt_token = create_user_token(user["id"], user["role"])
    return TokenResponse(access_token=jwt_token)

@router.get("/config")
async def auth_config():
    if settings.APP_ENV in ("staging", "development"):
        return {"auth_mode": "dev", "env": settings.APP_ENV}
    return {"auth_mode": "google", "env": settings.APP_ENV}

@router.post("/dev-login", response_model=TokenResponse)
async def dev_login(
    conn: asyncpg.Connection = Depends(get_db),
) -> TokenResponse:
    if settings.APP_ENV not in ("staging", "development"):
        raise HTTPException(status_code=404, detail="Not found")

    email = "leroy@moonfive.tech"
    google_id = "dev-leroy"
    name = "Leroy"
    role = "admin" if email == settings.ADMIN_EMAIL else "member"

    user = await conn.fetchrow("SELECT * FROM users WHERE google_id = $1", google_id)
    if user is None:
        user = await conn.fetchrow(
            """INSERT INTO users (google_id, email, name, role)
               VALUES ($1, $2, $3, $4) RETURNING *""",
            google_id, email, name, role,
        )

    jwt_token = create_user_token(user["id"], user["role"])
    return TokenResponse(access_token=jwt_token)


@router.post("/dev-admin-login", response_model=TokenResponse)
async def dev_admin_login(
    conn: asyncpg.Connection = Depends(get_db),
) -> TokenResponse:
    """Dev-only login as stephan (admin). Creates the admin user if it doesn't exist."""
    if settings.APP_ENV not in ("staging", "development"):
        raise HTTPException(status_code=404, detail="Not found")

    email = settings.ADMIN_EMAIL  # stephan@moonfive.tech
    google_id = "dev-stephan"
    name = "Stephan"
    role = "admin"

    user = await conn.fetchrow("SELECT * FROM users WHERE google_id = $1", google_id)
    if user is None:
        user = await conn.fetchrow(
            """INSERT INTO users (google_id, email, name, role)
               VALUES ($1, $2, $3, $4) RETURNING *""",
            google_id, email, name, role,
        )

    jwt_token = create_user_token(user["id"], user["role"])
    return TokenResponse(access_token=jwt_token)


@router.post("/dev-marco-login", response_model=TokenResponse)
async def dev_marco_login(
    conn: asyncpg.Connection = Depends(get_db),
) -> TokenResponse:
    """Dev-only login as marco@moonfive.tech."""
    if settings.APP_ENV not in ("staging", "development"):
        raise HTTPException(status_code=404, detail="Not found")

    email = "marco@moonfive.tech"
    google_id = "dev-marco"
    name = "Marco"
    role = "member"

    user = await conn.fetchrow("SELECT * FROM users WHERE google_id = $1", google_id)
    if user is None:
        user = await conn.fetchrow(
            """INSERT INTO users (google_id, email, name, role)
               VALUES ($1, $2, $3, $4) RETURNING *""",
            google_id, email, name, role,
        )

    jwt_token = create_user_token(user["id"], user["role"])
    return TokenResponse(access_token=jwt_token)

@router.post("/dev-chase-login", response_model=TokenResponse)
async def dev_chase_login(
    conn: asyncpg.Connection = Depends(get_db),
) -> TokenResponse:
    """Dev-only login as chase@moonfive.tech."""
    if settings.APP_ENV not in ("staging", "development"):
        raise HTTPException(status_code=404, detail="Not found")

    email = "chase@moonfive.tech"
    google_id = "dev-chase"
    name = "Chase"
    role = "member"

    user = await conn.fetchrow("SELECT * FROM users WHERE google_id = $1", google_id)
    if user is None:
        user = await conn.fetchrow(
            """INSERT INTO users (google_id, email, name, role)
               VALUES ($1, $2, $3, $4) RETURNING *""",
            google_id, email, name, role,
        )

    jwt_token = create_user_token(user["id"], user["role"])
    return TokenResponse(access_token=jwt_token)


@router.post("/refresh", response_model=TokenResponse)
async def refresh_token(
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> TokenResponse:
    user = await conn.fetchrow("SELECT * FROM users WHERE id = $1", user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    jwt_token = create_user_token(user["id"], user["role"])
    return TokenResponse(access_token=jwt_token)

@router.get("/me", response_model=UserResponse)
async def get_me(
    user_id: UUID = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
) -> UserResponse:
    user = await conn.fetchrow("SELECT * FROM users WHERE id = $1", user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return UserResponse(id=user["id"], email=user["email"], name=user["name"], picture=user["photo_url"], role=user["role"])
