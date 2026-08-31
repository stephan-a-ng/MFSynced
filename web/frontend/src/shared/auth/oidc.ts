/**
 * Thin wrappers over the `@moonfive/auth-client` instance for the two
 * OIDC (OpenID Connect) entry points this app's pages call directly:
 * `initiateLogin()` (LoginPage) and `completeLogin()` (AuthCallbackPage).
 *
 * The PKCE (Proof Key for Code Exchange) handshake, state/nonce generation,
 * and token persistence all now live inside the package — this file only
 * resolves `/v1/auth/config` (via the store's `loadConfig()`, which also
 * constructs and starts the client) and delegates.
 */
import { ApiError, useAuthStore } from "./store";

export async function initiateLogin(returnTo: string = "/"): Promise<void> {
  await useAuthStore.getState().loadConfig();
  const client = useAuthStore.getState().client;
  if (!client) throw new ApiError(500, "auth client not initialized");
  // Returned (not awaited-then-discarded): client.login() deliberately never
  // resolves on success — it navigates the browser away and a `finally` that
  // fired mid-navigation would be a debugging trap — so this function must
  // inherit that same "only settles on failure" contract rather than
  // resolving early once the redirect is dispatched.
  return client.login(returnTo);
}

export async function completeLogin(
  code: string,
  state: string,
): Promise<{ returnTo?: string }> {
  await useAuthStore.getState().loadConfig();
  const client = useAuthStore.getState().client;
  if (!client) throw new ApiError(500, "auth client not initialized");
  // Persists the token set itself — the caller no longer needs to call
  // setTokens().
  return client.completeLogin(code, state);
}
