import { authFetch } from '../shared/auth/store';

const BASE_URL = `${import.meta.env.VITE_API_URL || ''}/v1`;

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/**
 * Every request below is routed through the store's `authFetch` (a thin
 * wrapper over the @moonfive/auth-client instance's `authFetch`), which
 * attaches the bearer and, on a 401, performs exactly one single-flight
 * refresh and one retry before giving up — never a loop. A 401 reaching the
 * error branches here means that retry also failed and the client has
 * already logged out; there is nothing left to clear.
 */
async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string> || {}),
  };

  const res = await authFetch(`${BASE_URL}${path}`, { ...options, headers });

  if (!res.ok) {
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

    const res = await authFetch(`${BASE_URL}/upload`, {
      method: 'POST',
      body: formData,
    });

    if (!res.ok) {
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
