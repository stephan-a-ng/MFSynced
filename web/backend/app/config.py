import os
from pydantic_settings import BaseSettings

APP_ENV = os.getenv("APP_ENV", "development")
_env_file = f".env.{APP_ENV}" if os.path.exists(f".env.{APP_ENV}") else ".env"

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql://mfsynced:mfsynced@localhost:5432/mfsynced"
    CORS_ORIGINS: str = "http://localhost:5173,http://localhost:3000"
    UPLOAD_DIR: str = "uploads"
    MAX_UPLOAD_MB: int = 50
    APP_ENV: str = "development"

    # user-access OIDC (OpenID Connect). Issuer/JWKS (JSON Web Key Set)/audience per environment — see
    # user-access/docs/INTEGRATION.md §5c. operator_audiences is a
    # comma-separated list of additional accepted audiences (e.g. the
    # shared `mf` CLI client id) beyond this app's own audience.
    user_access_issuer: str = ""
    user_access_jwks_url: str = ""
    user_access_audience: str = ""
    user_access_operator_audiences: str = ""

    model_config = {"env_file": _env_file, "extra": "ignore"}

settings = Settings()
