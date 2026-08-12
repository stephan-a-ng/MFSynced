import { useAuthStore } from '../shared/auth/store';

const BASE_URL = `${import.meta.env.VITE_API_URL || ''}/v1`;

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function authHeader(): Record<string, string> {
  const { accessToken } = useAuthStore.getState();
  return accessToken ? { Authorization: `Bearer ${accessToken}` } : {};
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string> || {}),
  };

  let res = await fetch(`${BASE_URL}${path}`, { ...options, headers: { ...headers, ...authHeader() } });

  if (res.status === 401) {
    // Single retry: refresh the access token once, then replay the request.
    // If the refresh itself fails (no/expired refresh token, revoked family),
    // refresh() already calls logout() — the store's accessToken/user go
    // null, and AuthGuard reacts to that by redirecting to /login.
    try {
      await useAuthStore.getState().refresh();
      res = await fetch(`${BASE_URL}${path}`, { ...options, headers: { ...headers, ...authHeader() } });
    } catch {
      useAuthStore.getState().logout();
    }
  }

  if (!res.ok) {
    if (res.status === 401) {
      useAuthStore.getState().logout();
    }
    const text = await res.text();
    throw new ApiError(res.status, `${res.status}: ${text}`);
  }
  if (res.status === 204) return undefined as T;
  return res.json();
}

export const api = {
  get: <T>(path: string) => request<T>(path),
  post: <T>(path: string, body: unknown) => request<T>(path, { method: 'POST', body: JSON.stringify(body) }),
  patch: <T>(path: string, body: unknown) => request<T>(path, { method: 'PATCH', body: JSON.stringify(body) }),
  put: <T>(path: string, body: unknown) => request<T>(path, { method: 'PUT', body: JSON.stringify(body) }),
  delete: (path: string) => request<void>(path, { method: 'DELETE' }),
  upload: async (file: File): Promise<{ url: string }> => {
    const formData = new FormData();
    formData.append('file', file);

    const doUpload = () =>
      fetch(`${BASE_URL}/upload`, {
        method: 'POST',
        headers: authHeader(),
        body: formData,
      });

    let res = await doUpload();
    if (res.status === 401) {
      try {
        await useAuthStore.getState().refresh();
        res = await doUpload();
      } catch {
        useAuthStore.getState().logout();
      }
    }

    if (!res.ok) {
      if (res.status === 401) {
        useAuthStore.getState().logout();
      }
      const text = await res.text();
      throw new ApiError(res.status, `${res.status}: ${text}`);
    }
    return res.json();
  },
};

/** Prefix a backend-relative asset path (e.g. /uploads/...) with the API
 * origin. nginx only proxies /v1 and /ws, so relative asset URLs 404 (or
 * worse, return index.html) on the deployed frontend origin. */
export function assetUrl(path: string): string {
  if (/^https?:\/\//.test(path)) return path;
  return `${import.meta.env.VITE_API_URL || ''}${path}`;
}
