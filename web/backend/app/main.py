import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.config import settings
from app.db import init_pool, close_pool
from app.rate_limit import limiter
from app.api import auth, health, users, agent, conversations, forward, inbox, upload

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool(settings.DATABASE_URL)
    logger.info("Database pool initialized")
    # Ensure upload directory exists
    Path(settings.UPLOAD_DIR).mkdir(parents=True, exist_ok=True)
    yield
    await close_pool()
    logger.info("Database pool closed")

app = FastAPI(title="MFSynced", version="0.1.0", lifespan=lifespan)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.CORS_ORIGINS.split(",") if o.strip()],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def request_logging_middleware(request: Request, call_next):
    import time
    if request.url.path in ("/health", "/openapi.json") or request.url.path.startswith("/uploads/"):
        return await call_next(request)
    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = (time.perf_counter() - start) * 1000
    caller = "anon"
    auth = request.headers.get("authorization", "")
    if auth.startswith("Bearer "):
        try:
            from jose import jwt as _jwt
            payload = _jwt.decode(auth[7:], settings.JWT_SECRET, algorithms=[settings.JWT_ALGORITHM])
            caller = f"user:{payload.get('sub', '?')}"
        except Exception:
            caller = "agent-key"
    logger.info("HTTP %s %s -> %s (%.0fms) caller=%s",
                request.method, request.url.path, response.status_code, duration_ms, caller)
    return response

@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    return response

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.exception("Unhandled error: %s", exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})

# Register routers
app.include_router(health.router)
app.include_router(auth.router)
app.include_router(users.router)
app.include_router(agent.router)
app.include_router(conversations.router)
app.include_router(forward.router)
app.include_router(inbox.router)
app.include_router(upload.router)

# Serve uploaded files
app.mount("/uploads", StaticFiles(directory=settings.UPLOAD_DIR), name="uploads")
