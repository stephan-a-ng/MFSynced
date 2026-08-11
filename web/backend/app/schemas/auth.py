from uuid import UUID
from pydantic import BaseModel

class UserResponse(BaseModel):
    id: UUID
    email: str
    name: str
    picture: str | None = None
    role: str
