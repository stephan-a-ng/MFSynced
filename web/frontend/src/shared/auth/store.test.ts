// Environment: happy-dom (vitest.config.ts default) — needs real
// window.localStorage/sessionStorage and crypto.subtle for the
// @moonfive/auth-client instance's PKCE (Proof Key for Code Exchange) work.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createAuthClient, TokenResponseError, type AuthClient } from "@moonfive/auth-client";
import {
  authFetch,
  buildClientConfig,
  REFRESH_LOCK_NAME,
  STORAGE_KEY,
  useAuthStore,
  type AuthConfig,
} from "./store";

const AUTH_CONFIG: AuthConfig = {
  auth_mode: "oidc",
  user_access_url: "https://user-access-api-staging-537479330777.us-central1.run.app",
  client_id: "message-staging",
};

function tokenResponse(access: string, refresh: string): Response {
  return new Response(
    JSON.stringify({ access_token: access, refresh_token: refresh, expires_in: 900 }),
    { status: 200 },
  );
}

/** Routes a stubbed global fetch by URL suffix: /v1/auth/config vs. the IdP (identity provider)'s /token. */
function routedFetch(tokenHandler: () => Response): typeof fetch {
  return vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    if (url.endsWith("/v1/auth/config")) {
      return new Response(JSON.stringify(AUTH_CONFIG), { status: 200 });
    }
    if (url.endsWith("/token")) {
      return tokenHandler();
    }
    throw new Error(`unexpected fetch in test: ${url}`);
  }) as unknown as typeof fetch;
}

function resetStore(): void {
  useAuthStore.getState().client?.stop();
  useAuthStore.setState({
    client: null,
    accessToken: null,
    user: null,
    loading: false,
    authConfig: null,
  });
}

beforeEach(() => {
  resetStore();
  window.localStorage.clear();
  window.sessionStorage.clear();
});

afterEach(() => {
  resetStore();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("buildClientConfig", () => {
  it("maps /v1/auth/config's response into the auth-client's config, namespaced to this app", () => {
    const cfg = buildClientConfig(AUTH_CONFIG);
    expect(cfg.issuer).toBe(AUTH_CONFIG.user_access_url);
    expect(cfg.clientId).toBe(AUTH_CONFIG.client_id);
    expect(cfg.redirectUri).toBe(`${window.location.origin}/auth/callback`);
    expect(cfg.storageKey).toBe(STORAGE_KEY);
    expect(cfg.storageKey).toBe("message:tokens");
    expect(cfg.lockName).toBe(REFRESH_LOCK_NAME);
    expect(cfg.lockName).toBe("message:token-refresh");
  });

  it("lets a caller override individual fields (e.g. injecting fetch/navigate for tests)", () => {
    const navigate = () => {};
    const cfg = buildClientConfig(AUTH_CONFIG, { navigate });
    expect(cfg.navigate).toBe(navigate);
    expect(cfg.issuer).toBe(AUTH_CONFIG.user_access_url);
  });
});

describe("loadConfig", () => {
  it("fetches /v1/auth/config once, constructs exactly one client, and hydrates authConfig", async () => {
    const configFetch = vi.fn(async () => new Response(JSON.stringify(AUTH_CONFIG), { status: 200 }));
    vi.stubGlobal("fetch", configFetch);

    const first = await useAuthStore.getState().loadConfig();
    const client = useAuthStore.getState().client;
    expect(first).toEqual(AUTH_CONFIG);
    expect(client).not.toBeNull();

    // A redundant call (StrictMode double-invoke, a second consumer calling
    // loadConfig independently) must not re-fetch or construct a second
    // client, which would arm its own duplicate proactive-refresh timer and
    // cross-tab listeners.
    const second = await useAuthStore.getState().loadConfig();
    expect(second).toBe(first);
    expect(useAuthStore.getState().client).toBe(client);
    expect(configFetch).toHaveBeenCalledTimes(1);
  });

  it("throws and leaves no client constructed when /v1/auth/config responds non-2xx", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 500 })));
    await expect(useAuthStore.getState().loadConfig()).rejects.toThrow();
    expect(useAuthStore.getState().client).toBeNull();
  });
});

describe("sign-in reflects through the store", () => {
  it("completeLogin's token set flows into accessToken via the client's subscription", async () => {
    vi.stubGlobal("fetch", routedFetch(() => tokenResponse("access-1", "refresh-1")));

    await useAuthStore.getState().loadConfig();
    const client = useAuthStore.getState().client as AuthClient;

    const loginUrl = await client.buildLoginUrl("/inbox");
    const state = new URL(loginUrl).searchParams.get("state") as string;
    const { returnTo } = await client.completeLogin("code-1", state);

    expect(returnTo).toBe("/inbox");
    expect(useAuthStore.getState().accessToken).toBe("access-1");
    const persisted = JSON.parse(window.localStorage.getItem(STORAGE_KEY) as string) as {
      refreshToken: string;
    };
    expect(persisted.refreshToken).toBe("refresh-1");
  });
});

describe("logout", () => {
  it("clears the store and storage through the client", async () => {
    vi.stubGlobal("fetch", routedFetch(() => tokenResponse("a", "r")));
    await useAuthStore.getState().loadConfig();
    const client = useAuthStore.getState().client as AuthClient;
    client.setTokens({ accessToken: "a", refreshToken: "r", expiresAt: Date.now() + 900_000 });
    useAuthStore.setState({ user: { id: "1", email: "x@moonfive.tech", name: "X", picture: null, role: "member" } });
    expect(useAuthStore.getState().accessToken).toBe("a");

    useAuthStore.getState().logout();

    expect(useAuthStore.getState().accessToken).toBeNull();
    expect(useAuthStore.getState().user).toBeNull();
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull();
  });
});

describe("reload survival", () => {
  it("a fresh client instance (a new tab / a reload) reads the previously persisted tokens", () => {
    window.localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ accessToken: "a1", refreshToken: "r1", expiresAt: Date.now() + 900_000 }),
    );

    const client = createAuthClient(buildClientConfig(AUTH_CONFIG));
    expect(client.getState().isAuthenticated).toBe(true);
    expect(client.getState().accessToken).toBe("a1");
    client.stop();
  });
});

describe("authFetch", () => {
  it("rejects clearly when called before a client has been initialized", async () => {
    await expect(authFetch("/v1/inbox")).rejects.toThrow(/before the auth client was initialized/);
  });
});

describe("an unreadable 2xx from /token is terminal, never retried", () => {
  // The bug the in-house copy had: a 2xx from /token means the IdP (identity provider) consumed
  // the one-time-use refresh token, even if the body can't be parsed. Keeping
  // that token around (or leaving it in storage) is a guaranteed
  // reuse-detection trip on the next attempt — this proves the swap fixes it.
  it("refresh() rejects with TokenResponseError and the store reflects the resulting logout", async () => {
    window.localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ accessToken: "stale-access", refreshToken: "R1", expiresAt: Date.now() + 900_000 }),
    );
    vi.stubGlobal(
      "fetch",
      routedFetch(() => new Response("<html>gateway timeout</html>", { status: 200 })),
    );

    await useAuthStore.getState().loadConfig();
    expect(useAuthStore.getState().accessToken).toBe("stale-access");

    await expect(useAuthStore.getState().refresh()).rejects.toBeInstanceOf(TokenResponseError);

    expect(useAuthStore.getState().accessToken).toBeNull();
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull();
  });
});
