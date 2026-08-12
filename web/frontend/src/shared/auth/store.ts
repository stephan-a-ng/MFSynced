import { create } from "zustand";

/**
 * Cross-tab hardened auth store — ported from
 * deploy/frontend/src/shared/auth/store.ts, adapted for MFSynced:
 *
 *  - Storage keys renamed `deploy:` -> `message:` (this app's OIDC client is
 *    "message", not "deploy").
 *  - Deploy reads its user-access URL / client_id from build-time env
 *    constants (`@/env`). MFSynced's backend doesn't bake those in at build
 *    time, so instead we fetch `GET /v1/auth/config` once at runtime and
 *    cache the result here (`authConfig` + `loadConfig()`), and every place
 *    that needs `user_access_url` / `client_id` awaits `loadConfig()` first.
 *  - `loadUser()` hits THIS APP'S OWN `/v1/auth/me` (not user-access
 *    directly) — unlike deploy. This app's backend validates the
 *    user-access-issued JWT itself (JWKS, see app/shared/auth.py) and
 *    upserts/returns its own local user row (id/email/name/picture/role),
 *    which is the shape other MFSynced UI (ForwardDialog's `User`, the
 *    sidebar) already expects. Only the OIDC handshake itself
 *    (/authorize, /token — see oidc.ts and refresh() below) talks to
 *    user-access directly.
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

export interface TokenSet {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

export interface AuthConfig {
  auth_mode: string;
  user_access_url: string;
  client_id: string;
}

interface AuthState {
  accessToken: string | null;
  refreshToken: string | null;
  expiresAt: number | null;
  user: MeResponse | null;
  loading: boolean;
  authConfig: AuthConfig | null;
  setTokens: (tokens: TokenSet) => void;
  setUser: (user: MeResponse | null) => void;
  loadConfig: () => Promise<AuthConfig>;
  loadUser: () => Promise<void>;
  refresh: () => Promise<void>;
  logout: () => void;
  bearerHeader: () => Record<string, string>;
  /**
   * Adopt a token set (or a clear) reported by ANOTHER browser tab via the
   * `storage` event, WITHOUT re-persisting to localStorage — that tab already
   * wrote (or removed) the key; echoing it back here would be a redundant
   * same-value write. Only updates in-memory state. See scheduler.ts's
   * `storage` listener, wired in `startProactiveRefresh`.
   */
  adoptTokens: (tokens: TokenSet | null) => void;
}

export const STORAGE_KEY = "message:tokens";

// Cross-tab mutual-exclusion lock name. user-access refresh tokens are
// STRICTLY one-time-use, so the SINGLE most important invariant is "only one
// tab redeems a given refresh token." The in-tab single-flight guard below
// only de-dupes within ONE tab; this Web Lock name serializes the whole
// refresh operation ACROSS tabs of the same origin. Kept as a distinctive,
// greppable literal so the shipped bundle can be verified by grep.
export const REFRESH_LOCK_NAME = "message:token-refresh";

const API_BASE = import.meta.env.VITE_API_URL || "";

/**
 * Run `fn` while holding the cross-tab `message:token-refresh` Web Lock, so
 * no two tabs redeem a one-time-use refresh token concurrently (the
 * thundering herd that trips reuse detection and revokes the whole family).
 *
 * Graceful fallback: when `navigator.locks` is unavailable (older browsers,
 * insecure contexts, non-DOM test envs) we run `fn` directly — cross-tab
 * serialization is lost, but the in-tab single-flight guard plus the
 * lost-race discrimination in refresh() still prevent a lost race from
 * logging everyone out.
 */
function withRefreshLock<T>(fn: () => Promise<T>): Promise<T> {
  const locks =
    typeof navigator !== "undefined"
      ? (navigator as Navigator & { locks?: LockManager }).locks
      : undefined;
  if (!locks || typeof locks.request !== "function") {
    return fn();
  }
  return locks.request(REFRESH_LOCK_NAME, () => fn()) as Promise<T>;
}

// Single-flight guard: user-access refresh tokens are one-time-use with
// rotation — replaying an already-consumed refresh token trips reuse
// detection and revokes the WHOLE token family (including the child that
// was just issued). Several queries can independently hit a 401 at once
// (e.g. paused polls all resuming together after the tab was idle past the
// access-token lifetime), so every concurrent refresh() call must share the
// SAME in-flight network request rather than each racing to redeem the same
// refresh token.
let refreshInFlight: Promise<void> | null = null;

// AbortController for the in-flight /token fetch, so a logout() or a cross-tab
// logout (adoptTokens(null)) landing mid-refresh can cancel the network call
// (in addition to the epoch backstop that stops a late 200 from resurrecting
// the session).
let refreshAbort: AbortController | null = null;

// Bumped by logout() so a refresh() that was already in flight when logout()
// ran can detect, once its /token response lands, that the session it was
// refreshing no longer exists — and abort instead of calling setTokens and
// silently resurrecting a session the user just signed out of.
let logoutEpoch = 0;

/** Distinct rejection thrown when an in-flight refresh() is superseded by a logout(). */
export class RefreshAbortedError extends Error {
  constructor() {
    super("refresh aborted: logged out while the request was in flight");
    this.name = "RefreshAbortedError";
  }
}

function readPersisted(): TokenSet | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as TokenSet;
    if (!parsed.accessToken || !parsed.refreshToken) return null;
    return parsed;
  } catch {
    return null;
  }
}

function writePersisted(tokens: TokenSet | null): void {
  if (typeof window === "undefined") return;
  if (tokens === null) {
    window.localStorage.removeItem(STORAGE_KEY);
  } else {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(tokens));
  }
}

const initial = readPersisted();

// Single-flight + cache for the `/v1/auth/config` fetch. Kept as module-level
// state (not in the store) so `loadConfig()` can be called from many places
// (AuthGuard, LoginPage, oidc.ts) without racing duplicate requests.
let configInFlight: Promise<AuthConfig> | null = null;

export const useAuthStore = create<AuthState>((set, get) => ({
  accessToken: initial?.accessToken ?? null,
  refreshToken: initial?.refreshToken ?? null,
  expiresAt: initial?.expiresAt ?? null,
  user: null,
  loading: false,
  authConfig: null,

  setTokens: (tokens) => {
    // Always overwrite the persisted set — replaying a stale refresh token
    // trips user-access reuse detection and revokes the whole family.
    writePersisted(tokens);
    set({
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: tokens.expiresAt,
    });
  },

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
    const { accessToken } = get();
    if (!accessToken) return;
    // Single-flight: boot, AuthGuard and CallbackPage all call this, so
    // without a guard the OIDC callback path issues /v1/me twice.
    if (get().loading) return;
    set({ loading: true });
    try {
      const resp = await fetch(`${API_BASE}/v1/auth/me`, {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (!resp.ok) {
        if (resp.status === 401) {
          // Try a refresh, then retry once. refresh() talks to user-access
          // directly (it owns the refresh token); this app's own /v1/auth/me
          // just needs the freshly rotated access token on retry.
          await get().refresh();
          const retry = await fetch(`${API_BASE}/v1/auth/me`, {
            headers: { Authorization: `Bearer ${get().accessToken}` },
          });
          if (!retry.ok) {
            get().logout();
            return;
          }
          set({ user: (await retry.json()) as MeResponse });
          return;
        }
        throw new ApiError(resp.status, await resp.text().catch(() => resp.statusText));
      }
      set({ user: (await resp.json()) as MeResponse });
    } finally {
      set({ loading: false });
    }
  },

  refresh: async (): Promise<void> => {
    // Share the in-flight refresh across all concurrent callers instead of
    // letting each redeem the (single-use) refresh token independently.
    if (refreshInFlight) return refreshInFlight;

    const { refreshToken } = get();
    if (!refreshToken) {
      get().logout();
      throw new ApiError(401, "no refresh token");
    }

    const config = await get().loadConfig();

    // Snapshot the logout epoch at the moment this refresh attempt starts —
    // if logout() runs before the /token response lands, the epoch will have
    // moved on and run() below aborts rather than resurrecting the session.
    const epochAtStart = logoutEpoch;

    // `run` executes INSIDE the cross-tab Web Lock (or directly, on fallback).
    // Only ONE tab is ever inside here at a time for a given origin.
    const run = async (): Promise<void> => {
      // Double-checked locking: now that we (may) hold the lock, re-read the
      // persisted token — another tab could have rotated it while we waited.
      const persisted = readPersisted();

      if (!persisted) {
        // Another tab logged out while we waited for the lock. Follow it and
        // do NOT hit the network with an orphaned refresh token.
        if (epochAtStart === logoutEpoch) get().adoptTokens(null);
        throw new RefreshAbortedError();
      }

      if (persisted.refreshToken !== refreshToken) {
        // Another tab already won the race and rotated the pair. Adopt its
        // fresh tokens instead of replaying our now-consumed refresh token
        // (which would trip reuse detection). No network call at all.
        if (epochAtStart === logoutEpoch) get().adoptTokens(persisted);
        return;
      }

      const controller = new AbortController();
      refreshAbort = controller;
      const body = new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: refreshToken,
        client_id: config.client_id,
      });
      const resp = await fetch(`${config.user_access_url}/token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
        signal: controller.signal,
      });

      if (epochAtStart !== logoutEpoch) {
        // logout() (or a cross-tab logout) ran while this request was in
        // flight. The session this refresh was for no longer exists — do not
        // call setTokens and resurrect it.
        throw new RefreshAbortedError();
      }

      if (!resp.ok) {
        // Lost-race discrimination: re-read the persisted token. If it now
        // differs from the one we just sent, ANOTHER tab rotated successfully
        // in parallel (this only happens on the Web-Locks fallback path) — our
        // 401 is just "your token was already consumed," NOT a real
        // revocation. Adopt the winner's tokens and stay signed in rather than
        // logging everyone out.
        const latest = readPersisted();
        if (latest && latest.refreshToken !== refreshToken) {
          get().adoptTokens(latest);
          return;
        }
        // A genuine expiry/revocation — full logout.
        get().logout();
        throw new ApiError(resp.status, await resp.text().catch(() => resp.statusText));
      }
      const tokens = (await resp.json()) as {
        access_token: string;
        refresh_token: string;
        expires_in: number;
      };
      get().setTokens({
        accessToken: tokens.access_token,
        refreshToken: tokens.refresh_token,
        expiresAt: Date.now() + tokens.expires_in * 1000,
      });
    };

    refreshInFlight = withRefreshLock(run).finally(() => {
      refreshInFlight = null;
      refreshAbort = null;
    });
    return refreshInFlight;
  },

  logout: () => {
    // Bump the epoch FIRST and drop any in-flight refresh reference so:
    //  (1) an already-in-flight run() aborts instead of resurrecting the
    //      session once its response lands (see epoch check in run() above);
    //  (2) a refresh() call made right after logout() (but before the
    //      aborted attempt settles) starts a fresh request instead of
    //      joining the doomed one.
    logoutEpoch += 1;
    refreshInFlight = null;
    if (refreshAbort) {
      refreshAbort.abort();
      refreshAbort = null;
    }
    writePersisted(null);
    set({ accessToken: null, refreshToken: null, expiresAt: null, user: null });
  },

  bearerHeader: (): Record<string, string> => {
    const { accessToken } = get();
    return accessToken ? { Authorization: `Bearer ${accessToken}` } : {};
  },

  adoptTokens: (tokens) => {
    if (tokens === null) {
      // Another tab logged out (its `writePersisted(null)` fired our storage
      // listener). Mirror logout()'s teardown so an in-flight refresh in THIS
      // tab that lands 200 afterward cannot resurrect the just-ended session:
      // bump the epoch (the run() epoch check then throws), drop the
      // single-flight ref, and abort the in-flight /token fetch.
      logoutEpoch += 1;
      refreshInFlight = null;
      if (refreshAbort) {
        refreshAbort.abort();
        refreshAbort = null;
      }
      set({ accessToken: null, refreshToken: null, expiresAt: null, user: null });
      return;
    }
    set({
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: tokens.expiresAt,
    });
  },
}));
