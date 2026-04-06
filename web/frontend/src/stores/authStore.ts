import { create } from 'zustand';
import type { User } from '../api/auth';
import { authApi } from '../api/auth';
import { ApiError } from '../api/client';

interface AuthState {
  user: User | null;
  token: string | null;
  loading: boolean;
  appEnv: string | null;
  setAuth: (user: User, token: string) => void;
  setAppEnv: (env: string) => void;
  logout: () => void;
  loadUser: () => Promise<void>;
}

function getTokenExpiry(token: string): number | null {
  try {
    const payload = JSON.parse(atob(token.split('.')[1]));
    return payload.exp ?? null;
  } catch {
    return null;
  }
}

export const useAuthStore = create<AuthState>((set, get) => ({
  user: null,
  token: localStorage.getItem('token'),
  loading: true,
  appEnv: null,

  setAppEnv: (env) => set({ appEnv: env }),

  setAuth: (user, token) => {
    localStorage.setItem('token', token);
    set({ user, token, loading: false });
  },

  logout: () => {
    localStorage.removeItem('token');
    set({ user: null, token: null, loading: false });
  },

  loadUser: async () => {
    const token = get().token;
    if (!token) {
      set({ loading: false });
      return;
    }

    const exp = getTokenExpiry(token);
    if (exp && exp * 1000 < Date.now()) {
      localStorage.removeItem('token');
      set({ user: null, token: null, loading: false });
      return;
    }

    try {
      const user = await authApi.me();
      set({ user, loading: false });
    } catch (err) {
      if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
        localStorage.removeItem('token');
        set({ user: null, token: null, loading: false });
      } else {
        set({ loading: false });
      }
    }
  },
}));
