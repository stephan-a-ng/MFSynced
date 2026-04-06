import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { ThemeToggle } from '../components/ThemeToggle';
import { authApi } from '../api/auth';
import type { AuthConfig } from '../api/auth';
import { useAuthStore } from '../stores/authStore';

const GOOGLE_CLIENT_ID = import.meta.env.VITE_GOOGLE_CLIENT_ID || '';
const SCOPES = 'openid email profile';

export function LoginPage() {
  const navigate = useNavigate();
  const { setAuth, setAppEnv } = useAuthStore();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [config, setConfig] = useState<AuthConfig | null>(null);

  useEffect(() => {
    authApi.config().then((cfg) => {
      setConfig(cfg);
      setAppEnv(cfg.env);
    }).catch(() => setConfig({ auth_mode: 'google', env: 'production' }));
  }, []);

  const handleLogin = () => {
    const redirectUri = `${window.location.origin}/auth/callback`;
    const params = new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      redirect_uri: redirectUri,
      response_type: 'code',
      scope: SCOPES,
      access_type: 'offline',
      prompt: 'consent',
    });
    window.location.href = `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
  };

  const handleDevLogin = async () => {
    setLoading(true);
    setError(null);
    try {
      const tokenResp = await authApi.devLogin();
      localStorage.setItem('token', tokenResp.access_token);
      const user = await authApi.me();
      setAuth(user, tokenResp.access_token);
      navigate('/', { replace: true });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Dev login failed');
    } finally {
      setLoading(false);
    }
  };

  const handleDevAdminLogin = async () => {
    setLoading(true);
    setError(null);
    try {
      const tokenResp = await authApi.devAdminLogin();
      localStorage.setItem('token', tokenResp.access_token);
      const user = await authApi.me();
      setAuth(user, tokenResp.access_token);
      navigate('/', { replace: true });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Dev admin login failed');
    } finally {
      setLoading(false);
    }
  };

  const handleDevMarcoLogin = async () => {
    setLoading(true);
    setError(null);
    try {
      const tokenResp = await authApi.devMarcoLogin();
      localStorage.setItem('token', tokenResp.access_token);
      const user = await authApi.me();
      setAuth(user, tokenResp.access_token);
      navigate('/', { replace: true });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Dev marco login failed');
    } finally {
      setLoading(false);
    }
  };

  if (!config) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Loader2 size={24} className="animate-spin text-muted-foreground" />
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-background relative">
      <div className="absolute top-4 right-4">
        <ThemeToggle />
      </div>
      <div className="bg-card border border-border rounded-xl shadow-sm p-8 max-w-sm w-full text-center animate-fade-in">
        <div className="flex items-center justify-center gap-3 mb-2">
          <h1 className="text-2xl font-bold text-foreground">MFSynced</h1>
          {config.env === 'staging' && (
            <span className="px-1.5 py-0.5 text-[10px] font-semibold uppercase rounded bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">
              Staging
            </span>
          )}
        </div>
        <p className="text-muted-foreground text-sm mb-1">Team iMessage Hub</p>
        <p className="text-muted-foreground text-xs mb-6">Sign in with your @moonfive.tech email</p>
        {error && <p className="text-destructive text-sm mb-4">{error}</p>}
        {config.auth_mode === 'dev' ? (
          <div className="space-y-2">
            <button
              onClick={handleDevLogin}
              disabled={loading}
              className="w-full py-2.5 px-4 rounded-md font-medium text-sm transition-colors cursor-pointer disabled:opacity-50"
              style={{ backgroundColor: '#ffd028', color: '#000' }}
              onMouseEnter={e => (e.currentTarget.style.backgroundColor = '#e6bb24')}
              onMouseLeave={e => (e.currentTarget.style.backgroundColor = '#ffd028')}
            >
              {loading ? 'Signing in...' : 'Sign in as leroy@moonfive.tech'}
            </button>
            <button
              onClick={handleDevAdminLogin}
              disabled={loading}
              className="w-full py-2.5 px-4 rounded-md font-medium text-sm transition-colors cursor-pointer disabled:opacity-50"
              style={{ backgroundColor: '#1a1a2e', color: '#ffd028' }}
              onMouseEnter={e => (e.currentTarget.style.backgroundColor = '#0f0f1a')}
              onMouseLeave={e => (e.currentTarget.style.backgroundColor = '#1a1a2e')}
            >
              {loading ? 'Signing in...' : 'Sign in as stephan@moonfive.tech (admin)'}
            </button>
            <button
              onClick={handleDevMarcoLogin}
              disabled={loading}
              className="w-full py-2.5 px-4 rounded-md font-medium text-sm transition-colors cursor-pointer disabled:opacity-50"
              style={{ backgroundColor: '#0d3b2e', color: '#4ade80' }}
              onMouseEnter={e => (e.currentTarget.style.backgroundColor = '#092b21')}
              onMouseLeave={e => (e.currentTarget.style.backgroundColor = '#0d3b2e')}
            >
              {loading ? 'Signing in...' : 'Sign in as marco@moonfive.tech'}
            </button>
          </div>
        ) : (
          <button
            onClick={handleLogin}
            className="w-full py-2.5 px-4 rounded-md font-medium text-sm transition-colors cursor-pointer"
            style={{ backgroundColor: '#ffd028', color: '#000' }}
            onMouseEnter={e => (e.currentTarget.style.backgroundColor = '#e6bb24')}
            onMouseLeave={e => (e.currentTarget.style.backgroundColor = '#ffd028')}
          >
            Sign in with Google
          </button>
        )}
      </div>
    </div>
  );
}
