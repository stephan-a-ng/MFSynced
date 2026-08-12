import { api } from './client';

// `User` here is the app-level user record (used e.g. by ForwardDialog's
// recipient picker), distinct from the OIDC session identity
// (`MeResponse` in `shared/auth/store.ts`).
export interface User {
  id: string;
  email: string;
  name: string;
  picture: string | null;
  role: string;
}

export const authApi = {
  users: () => api.get<User[]>('/users'),
};
