import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { authApi } from '../api/auth';
import { useAuthStore } from '../stores/authStore';

export function AuthCallbackPage() {
  const navigate = useNavigate();
  const { setAuth } = useAuthStore();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get('code');
    if (!code) { setError('No authorization code received'); return; }

    const redirectUri = `${window.location.origin}/auth/callback`;
    authApi.googleAuth(code, redirectUri)
      .then(async (tokenResp) => {
        localStorage.setItem('token', tokenResp.access_token);
        const user = await authApi.me();
        setAuth(user, tokenResp.access_token);
        navigate('/', { replace: true });
      })
      .catch((err) => setError(err.message || 'Authentication failed'));
  }, []);

  if (error) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <div className="bg-card p-8 rounded-xl shadow-sm border border-border max-w-sm w-full text-center">
          <p className="text-destructive mb-4">{error}</p>
          <a href="/login" className="text-primary hover:underline text-sm">Try again</a>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-background">
      <div className="flex items-center gap-2 text-muted-foreground">
        <Loader2 size={20} className="animate-spin" />
        Signing in...
      </div>
    </div>
  );
}
