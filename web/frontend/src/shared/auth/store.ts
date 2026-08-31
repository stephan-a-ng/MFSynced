import { create } from "zustand";
import { createAuthClient, type AuthClient, type AuthClientConfig } from "@moonfive/auth-client";

/**
 * Thin Zustand adapter over `@moonfive/auth-client` (user-access PR #82) —
 * the single source of truth for the cross-tab refresh single-flight /
 * proactive renew / 401-retry-once contract, replacing this app's in-house
 * copy of deploy's OIDC (OpenID Connect) recipe.
 *
 * MFSynced's backend doesn't bake `user_access_url` / `client_id` in at
 * build time — it fetches `GET /v1/auth/config` once at runtime instead
 * (`loadConfig()` below), same as before this swap. The auth-client instance
 * is therefore constructed lazily, the first time config resolves, and
 * memoized here for the app's lifetime — never a second client, never a
 * second set of proactive-refresh timers or cross-tab listeners.
 */

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/** Shape of the caller-info payload from this app's own `/v1/auth/me`. */
export interface MeResponse {
  id: string;
  email: string;
  name: string;
  picture: string | null;
  role: string;
}

export interface AuthConfig {
  auth_mode: string;
  user_access_url: string;
  client_id: string;
}

/** localStorage key for the persisted token set — UNCHANGED from the
 * in-house store, so already-signed-in users are carried across this swap
 * rather than bounced to the login screen. */
export const STORAGE_KEY = "message:tokens";

/** navigator.locks name serializing refresh across tabs of this origin —
 * UNCHANGED from the in-house store. */
export const REFRESH_LOCK_NAME = "message:token-refresh";

const API_BASE = import.meta.env.VITE_API_URL || "";

/**
 * Pure mapping from `/v1/auth/config`'s response to the auth-client's
 * config. Exported so tests can build the exact same real client the app
 * does, swapping only `navigate`/`fetch`/`storage`/`locks` for fakes instead
 * of re-deriving these values by hand and risking drift.
 */
export function buildClientConfig(
  config: AuthConfig,
  overrides: Partial<AuthClientConfig> = {},
): AuthClientConfig {
  return {
    issuer: config.user_access_url,
    clientId: config.client_id,
    redirectUri: `${window.location.origin}/auth/callback`,
    storageKey: STORAGE_KEY,
    lockName: REFRESH_LOCK_NAME,
    ...overrides,
  };
}

interface AuthState {
  /** The underlying @moonfive/auth-client instance, once `authConfig` resolves. */
  client: AuthClient | null;
  accessToken: string | null;
  user: MeResponse | null;
  loading: boolean;
  authConfig: AuthConfig | null;

  setUser: (user: MeResponse | null) => void;
  loadConfig: () => Promise<AuthConfig>;
  loadUser: () => Promise<void>;
  refresh: () => Promise<void>;
  logout: () => void;
}

// Single-flight + cache for the `/v1/auth/config` fetch. Kept as module-level
// state (not in the store) so `loadConfig()` can be called from many places
// (AuthGuard via loadUser, LoginPage, oidc.ts) without racing duplicate
// requests.
let configInFlight: Promise<AuthConfig> | null = null;

export const useAuthStore = create<AuthState>((set, get) => ({
  client: null,
  // Read directly off localStorage (not off the client, which does not exist
  // yet) so a reload with a persisted session renders authenticated UI
  // immediately, before /v1/auth/config has even resolved.
  accessToken: readPersistedAccessToken(),
  user: null,
  loading: false,
  authConfig: null,

  setUser: (user) => set({ user }),

  loadConfig: async () => {
    const cached = get().authConfig;
    if (cached) return cached;
    if (configInFlight) return configInFlight;

    configInFlight = (async () => {
      const resp = await fetch(`${API_BASE}/v1/auth/config`);
      if (!resp.ok) {
        throw new ApiError(resp.status, "Failed to load auth config");
      }
      const data = (await resp.json()) as AuthConfig;

      if (!get().client) {
        const client = createAuthClient(buildClientConfig(data));
        client.subscribe((s) => {
          set({
            accessToken: s.accessToken,
            // Mirror a client-observed logout (local or cross-tab) into the
            // app-level user record too — it is not part of AuthState.
            ...(s.isAuthenticated ? {} : { user: null }),
          });
        });
        client.start();
        set({ client, accessToken: client.getState().accessToken });
      }
      set({ authConfig: data });
      return data;
    })();

    try {
      return await configInFlight;
    } finally {
      configInFlight = null;
    }
  },

  loadUser: async () => {
    const { accessToken, loading } = get();
    if (!accessToken) return;
    // Single-flight: AuthGuard and CallbackPage can both call this, so
    // without a guard the OIDC callback path issues /v1/auth/me twice.
    if (loading) return;
    set({ loading: true });
    try {
      await get().loadConfig();
      const client = get().client;
      if (!client) throw new ApiError(500, "auth client not initialized");
      const resp = await client.authFetch(`${API_BASE}/v1/auth/me`);
      if (!resp.ok) {
        throw new ApiError(resp.status, await resp.text().catch(() => resp.statusText));
      }
      set({ user: (await resp.json()) as MeResponse });
    } finally {
      set({ loading: false });
    }
  },

  refresh: async () => {
    await get().loadConfig();
    const client = get().client;
    if (!client) throw new ApiError(500, "auth client not initialized");
    return client.refresh();
  },

  logout: () => {
    // logout() is async on the client (it may best-effort POST
    // {issuer}/logout), but every caller here treats it as fire-and-forget —
    // the store's own state (accessToken/user) updates synchronously via the
    // client's setState -> subscribe callback above.
    void get().client?.logout();
    set({ user: null });
  },
}));

function readPersistedAccessToken(): string | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { accessToken?: string };
    return parsed.accessToken ?? null;
  } catch {
    return null;
  }
}

/**
 * Authenticated fetch for the API layer (api/client.ts): attaches the
 * bearer, and on a 401 performs exactly one single-flight refresh and one
 * retry before giving up — never a loop. Route every /v1/* call through this
 * rather than reading `accessToken` off the store directly, which can hold a
 * token seconds from expiry.
 */
export function authFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const client = useAuthStore.getState().client;
  if (!client) {
    return Promise.reject(
      new ApiError(500, "authFetch called before the auth client was initialized"),
    );
  }
  return client.authFetch(input, init);
}
