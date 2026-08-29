import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, useAuthStore } from "./store";
import { completeLogin, initiateLogin } from "./oidc";

const AUTH_CONFIG = {
  auth_mode: "oidc",
  user_access_url: "https://user-access-api-staging-537479330777.us-central1.run.app",
  client_id: "message-staging",
};

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

describe("initiateLogin", () => {
  it("resolves config, then redirects to the IdP (identity provider)'s /authorize with this app's client_id", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify(AUTH_CONFIG), { status: 200 })),
    );
    const assign = vi.fn();
    vi.stubGlobal("location", { ...window.location, assign });

    // initiateLogin() -> client.login() deliberately never resolves on
    // success (it navigates the browser away) — fire it and wait on the
    // `assign` spy instead of awaiting the call itself, or this test would
    // hang forever.
    void initiateLogin("/inbox");
    await vi.waitFor(() => expect(assign).toHaveBeenCalledTimes(1));

    const url = new URL(assign.mock.calls[0][0] as string);
    expect(`${url.origin}${url.pathname}`).toBe(`${AUTH_CONFIG.user_access_url}/authorize`);
    expect(url.searchParams.get("client_id")).toBe(AUTH_CONFIG.client_id);
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
  });

  it("propagates a config-load failure rather than silently no-oping", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 500 })));
    await expect(initiateLogin()).rejects.toBeInstanceOf(ApiError);
  });
});

describe("completeLogin", () => {
  it("delegates to the client and returns its returnTo, without the caller persisting tokens itself", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.endsWith("/v1/auth/config")) {
          return new Response(JSON.stringify(AUTH_CONFIG), { status: 200 });
        }
        return new Response(
          JSON.stringify({ access_token: "a", refresh_token: "r", expires_in: 900 }),
          { status: 200 },
        );
      }),
    );

    await useAuthStore.getState().loadConfig();
    const client = useAuthStore.getState().client!;
    const loginUrl = await client.buildLoginUrl("/threads/42");
    const state = new URL(loginUrl).searchParams.get("state") as string;

    const result = await completeLogin("code-1", state);

    expect(result.returnTo).toBe("/threads/42");
    expect(useAuthStore.getState().accessToken).toBe("a");
  });
});
