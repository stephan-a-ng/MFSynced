/**
 * Browser-side OIDC (OpenID Connect) flow helpers against user-access.
 *
 * `initiateLogin()` generates a PKCE (Proof Key for Code Exchange) pair + state, stashes the
 * verifier+state in sessionStorage, and redirects the browser to the
 * user-access /authorize endpoint. `completeLogin()` is the inverse:
 * read the verifier from sessionStorage and POST to /token.
 *
 * Ported from deploy/frontend/src/shared/auth/oidc.ts. Deploy reads
 * `client_id` / `user_access_url` from build-time env constants; here they
 * come from the store's cached `/v1/auth/config` response instead, so both
 * entry points await `useAuthStore.getState().loadConfig()` first.
 */
import { ApiError, useAuthStore } from "./store";
import { challengeFromVerifier, generateState, generateVerifier } from "./pkce";

const STORAGE_KEY = "message:oidc-pending";

interface Pending {
  verifier: string;
  state: string;
  returnTo: string;
}

function callbackUrl(): string {
  return `${window.location.origin}/auth/callback`;
}

export async function initiateLogin(returnTo: string = "/"): Promise<void> {
  const config = await useAuthStore.getState().loadConfig();

  const verifier = generateVerifier();
  const state = generateState();
  const challenge = await challengeFromVerifier(verifier);

  const pending: Pending = { verifier, state, returnTo };
  window.sessionStorage.setItem(STORAGE_KEY, JSON.stringify(pending));

  const params = new URLSearchParams({
    response_type: "code",
    client_id: config.client_id,
    redirect_uri: callbackUrl(),
    scope: "openid profile email",
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  window.location.assign(`${config.user_access_url}/authorize?${params.toString()}`);
}

export interface TokenSet {
  accessToken: string;
  refreshToken: string;
  idToken: string;
  expiresIn: number;
}

export async function completeLogin(
  code: string,
  state: string,
): Promise<{ tokens: TokenSet; returnTo: string }> {
  const raw = window.sessionStorage.getItem(STORAGE_KEY);
  if (!raw) {
    throw new ApiError(400, "No pending login (sessionStorage empty)");
  }
  const pending = JSON.parse(raw) as Pending;
  window.sessionStorage.removeItem(STORAGE_KEY);

  if (pending.state !== state) {
    throw new ApiError(400, "state mismatch — possible CSRF");
  }

  const config = await useAuthStore.getState().loadConfig();

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: callbackUrl(),
    code_verifier: pending.verifier,
    client_id: config.client_id,
  });

  const resp = await fetch(`${config.user_access_url}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText);
    throw new ApiError(resp.status, text);
  }
  const data = (await resp.json()) as {
    access_token: string;
    refresh_token: string;
    id_token: string;
    expires_in: number;
  };
  return {
    tokens: {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      idToken: data.id_token,
      expiresIn: data.expires_in,
    },
    returnTo: pending.returnTo,
  };
}
