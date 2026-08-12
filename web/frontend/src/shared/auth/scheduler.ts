import { STORAGE_KEY, useAuthStore, type TokenSet } from "./store";

/**
 * Proactive refresh scheduling — so we ideally never NEED the reactive
 * single-flight 401 path at all: refresh the access token shortly before it
 * expires, before any query has a chance to 401.
 *
 * Ported verbatim from deploy/frontend/src/shared/auth/scheduler.ts (only
 * the import path changed).
 *
 * `refreshDelayMs` is a pure helper (no clock/timer access) so it's trivial
 * to unit test: given an expiry timestamp and "now", how long until we
 * should proactively refresh. Floors at 5s so a clock skew / stale
 * `expiresAt` can never produce a near-zero delay that busy-loops
 * setTimeout(0) refresh attempts.
 */
export function refreshDelayMs(
  expiresAt: number | null,
  nowMs: number,
  earlyMs = 60_000,
): number | null {
  if (expiresAt === null) return null;
  const naive = expiresAt - nowMs - earlyMs;
  return Math.max(naive, 5_000);
}

const FOCUS_REFRESH_WINDOW_MS = 60_000;

let armed = false;
let timer: ReturnType<typeof setTimeout> | null = null;

function clearArmedTimer(): void {
  if (timer !== null) {
    clearTimeout(timer);
    timer = null;
  }
}

/**
 * Max anti-herd jitter (ms) added to the proactive-refresh delay. Defense in
 * depth on top of the cross-tab Web Lock: N tabs that hydrated the SAME
 * `expiresAt` would otherwise arm identical timers and fire at the same
 * instant. A small random spread means the first tab to wake acquires the lock
 * and rotates the token; the rest then wake to find it already rotated (their
 * double-checked locking adopts it, no network call). Bounded well under the
 * 60s early-refresh margin so a jittered timer still fires before expiry.
 */
const REFRESH_JITTER_MS = 3_000;

/** (Re)arm the proactive-refresh timer against the store's current tokens. */
function armTimer(): void {
  clearArmedTimer();
  const { refreshToken, expiresAt } = useAuthStore.getState();
  if (!refreshToken || expiresAt === null) return;

  const base = refreshDelayMs(expiresAt, Date.now());
  if (base === null) return;
  const delay = base + Math.floor(Math.random() * REFRESH_JITTER_MS);

  timer = setTimeout(() => {
    void useAuthStore.getState().refresh().catch(() => {
      // refresh() already logs out on failure; nothing further to do here.
    });
  }, delay);
}

/** Refresh immediately if we're within the early-refresh window (e.g. the tab was backgrounded past expiry and just regained focus). */
function refreshIfDue(): void {
  const { refreshToken, expiresAt } = useAuthStore.getState();
  if (!refreshToken) return;
  if (expiresAt !== null && Date.now() >= expiresAt - FOCUS_REFRESH_WINDOW_MS) {
    void useAuthStore.getState().refresh().catch(() => {});
  }
}

/**
 * Cross-tab token adoption: user-access refresh tokens are single-use with
 * rotation, so if tab A refreshes and rotates the token pair, tab B must NOT
 * later replay the refresh token it still has in memory — that trips reuse
 * detection and revokes the whole family (logging BOTH tabs out). The
 * `storage` event only fires in OTHER tabs (never the tab that made the
 * write), so on receiving it we adopt the new pair (or a logout) into this
 * tab's in-memory store WITHOUT writing back to localStorage — the writing
 * tab already did that; a same-value echo would be redundant, and this
 * listener should never itself be a source of localStorage writes.
 */
function handleStorageEvent(event: StorageEvent): void {
  if (event.key !== STORAGE_KEY) return;

  if (event.newValue === null) {
    // Another tab logged out — follow it.
    useAuthStore.getState().adoptTokens(null);
    return;
  }

  try {
    const parsed = JSON.parse(event.newValue) as Partial<TokenSet>;
    if (!parsed.accessToken || !parsed.refreshToken || typeof parsed.expiresAt !== "number") {
      return;
    }
    useAuthStore.getState().adoptTokens(parsed as TokenSet);
  } catch {
    // Malformed payload from another tab — ignore rather than adopt garbage.
  }
}

/**
 * Arms the proactive-refresh timer and wires visibility/focus/storage
 * listeners.
 *
 * Idempotent PER MODULE INSTANCE — calling it more than once against the
 * SAME loaded instance of this module is a safe no-op (a logged-out store
 * simply no-ops the timer arm; no refreshToken to schedule against). This
 * guarantee does NOT extend across a Vite HMR reload of this module: HMR
 * replaces the module and resets the `armed` flag to false, but the
 * `document`/`window` listeners registered by the PREVIOUS module instance
 * are never torn down (nothing calls `removeEventListener` on unload), so a
 * dev-mode HMR update of this file can accumulate duplicate listeners.
 * Production is a single module boot with no HMR, so this doesn't affect it.
 */
export function startProactiveRefresh(): void {
  if (armed) return;
  armed = true;

  armTimer();
  useAuthStore.subscribe((state, prevState) => {
    if (state.expiresAt !== prevState.expiresAt || state.refreshToken !== prevState.refreshToken) {
      armTimer();
    }
  });

  if (typeof document !== "undefined") {
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") refreshIfDue();
    });
  }
  if (typeof window !== "undefined") {
    window.addEventListener("focus", refreshIfDue);
    window.addEventListener("storage", handleStorageEvent);
  }
}
