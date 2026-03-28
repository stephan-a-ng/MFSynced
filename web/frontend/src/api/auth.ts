import { api } from './client';

export interface User {
  id: string;
  email: string;
  name: string;
  picture: string | null;
  role: string;
}

interface TokenResponse {
  access_token: string;
}

export const authApi = {
  googleAuth: (code: string, redirectUri: string) =>
    api.post<TokenResponse>('/auth/google', { code, redirect_uri: redirectUri }),
  me: () => api.get<User>('/auth/me'),
  refresh: () => api.post<TokenResponse>('/auth/refresh', {}),
  users: () => api.get<User[]>('/users'),
};
