import { useEffect, useRef, useState } from 'react';
import { BrandLoader } from '../components/brand/BrandLoader';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { completeLogin } from '../shared/auth/oidc';
import { useAuthStore } from '../shared/auth/store';

/**
 * OIDC redirect target — ported from
 * deploy/frontend/src/features/auth/pages/CallbackPage.tsx.
 */
export function AuthCallbackPage() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { loadUser } = useAuthStore();
  const [error, setError] = useState<string | null>(null);
  // completeLogin() consumes the one-shot sessionStorage entry on first run,
  // so we MUST NOT re-enter — StrictMode dev double-invokes, browser bfcache
  // restores, and accidental remounts would all otherwise show a spurious
  // "No pending login" error before the in-flight exchange completes.
  const startedRef = useRef(false);

  useEffect(() => {
    if (startedRef.current) return;
    startedRef.current = true;
    const code = params.get('code');
    const state = params.get('state');
    const oidcError = params.get('error');

    if (oidcError) {
      setError(params.get('error_description') ?? oidcError);
      return;
    }
    if (!code || !state) {
      setError('Missing code or state in callback URL');
      return;
    }

    void (async () => {
      try {
        // completeLogin() persists the token set itself (inside the
        // @moonfive/auth-client instance) — no more setTokens() call here.
        const { returnTo } = await completeLogin(code, state);
        await loadUser();
        navigate(returnTo ?? '/', { replace: true });
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Sign-in failed');
      }
    })();
  }, [params, navigate, loadUser]);

  if (error) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <div className="m5-glass p-8 rounded-xl shadow-sm max-w-sm w-full text-center">
          <p className="text-destructive mb-4">{error}</p>
          <a href="/login" className="text-primary hover:underline text-sm">Try again</a>
        </div>
      </div>
    );
  }

  // Same full-screen brand loader AuthGuard shows during hydration, so the
  // whole login flow reads as ONE continuous loading screen instead of a
  // small card followed by a different full-screen bloom.
  return <BrandLoader label="Signing in…" />;
}
