/**
 * Browser-side PKCE (Proof Key for Code Exchange, RFC 7636) — generate a code_verifier + S256 code_challenge.
 *
 * The verifier is a random 43-128 char URL-safe string; the challenge
 * is BASE64URL(SHA256(verifier)) with no padding.
 *
 * Ported verbatim from deploy/frontend/src/shared/auth/pkce.ts.
 */

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function generateVerifier(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

export async function challengeFromVerifier(verifier: string): Promise<string> {
  const data = new TextEncoder().encode(verifier);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return base64UrlEncode(new Uint8Array(digest));
}

export function generateState(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}
