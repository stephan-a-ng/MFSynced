from uuid import UUID
from pydantic import BaseModel

class GoogleAuthRequest(BaseModel):
    code: str
    redirect_uri: str

class TokenResponse(BaseModel):
    access_token: str

class UserResponse(BaseModel):
    id: UUID
    email: str
    name: str
    picture: str | None = None
    role: str
