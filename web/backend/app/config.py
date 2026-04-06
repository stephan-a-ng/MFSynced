import os
from pydantic_settings import BaseSettings

APP_ENV = os.getenv("APP_ENV", "development")
_env_file = f".env.{APP_ENV}" if os.path.exists(f".env.{APP_ENV}") else ".env"

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql://mfsynced:mfsynced@localhost:5432/mfsynced"
    JWT_SECRET: str = "dev-secret-change-in-production"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_HOURS: int = 24 * 30
    GOOGLE_CLIENT_ID: str = ""
    GOOGLE_CLIENT_SECRET: str = ""
    ALLOWED_EMAIL_DOMAIN: str = "moonfive.tech"
    ADMIN_EMAIL: str = "stephan@moonfive.tech"
    CORS_ORIGINS: str = "http://localhost:5173,http://localhost:3000"
    UPLOAD_DIR: str = "uploads"
    MAX_UPLOAD_MB: int = 50
    APP_ENV: str = "development"

    model_config = {"env_file": _env_file, "extra": "ignore"}

settings = Settings()
