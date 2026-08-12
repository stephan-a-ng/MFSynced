import { useState } from 'react';
import { useLocation } from 'react-router-dom';
import { ThemeToggle } from '../components/ThemeToggle';
import { initiateLogin } from '../shared/auth/oidc';

export function LoginPage() {
  const location = useLocation();
  const returnTo = (location.state as { from?: string } | null)?.from ?? '/';
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleLogin = async () => {
    setStarting(true);
    setError(null);
    try {
      await initiateLogin(returnTo);
      // On success, initiateLogin() navigates the browser away — this
      // component unmounts before `starting` matters again.
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to start sign-in');
      setStarting(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-background relative">
      <div className="absolute top-4 right-4">
        <ThemeToggle />
      </div>
      <div className="bg-card border border-border rounded-xl shadow-sm p-8 max-w-sm w-full text-center animate-fade-in">
        <h1 className="font-brand text-3xl font-extrabold text-foreground mb-2">MFSynced</h1>
        <p className="text-muted-foreground text-sm mb-1">Team iMessage Hub</p>
        <p className="text-muted-foreground text-xs mb-6">Sign in with your @moonfive.tech email</p>
        {error && <p className="text-destructive text-sm mb-4">{error}</p>}
        <button
          onClick={handleLogin}
          disabled={starting}
          className="w-full py-2.5 px-4 rounded-md font-medium text-sm transition-colors cursor-pointer disabled:opacity-50"
          style={{ backgroundColor: '#ffd028', color: '#000' }}
          onMouseEnter={e => (e.currentTarget.style.backgroundColor = '#e6bb24')}
          onMouseLeave={e => (e.currentTarget.style.backgroundColor = '#ffd028')}
        >
          {starting ? 'Signing in...' : 'Sign in with Moon Five'}
        </button>
      </div>
    </div>
  );
}
