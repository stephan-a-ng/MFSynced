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

export interface AuthConfig {
  auth_mode: 'dev' | 'google';
  env: string;
}

export const authApi = {
  config: () => api.get<AuthConfig>('/auth/config'),
  googleAuth: (code: string, redirectUri: string) =>
    api.post<TokenResponse>('/auth/google', { code, redirect_uri: redirectUri }),
  devLogin: () => api.post<TokenResponse>('/auth/dev-login', {}),
  devAdminLogin: () => api.post<TokenResponse>('/auth/dev-admin-login', {}),
  devMarcoLogin: () => api.post<TokenResponse>('/auth/dev-marco-login', {}),
  me: () => api.get<User>('/auth/me'),
  refresh: () => api.post<TokenResponse>('/auth/refresh', {}),
  users: () => api.get<User[]>('/users'),
};
