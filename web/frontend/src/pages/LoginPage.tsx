import { ThemeToggle } from '../components/ThemeToggle';

const GOOGLE_CLIENT_ID = import.meta.env.VITE_GOOGLE_CLIENT_ID || '';
const SCOPES = 'openid email profile';

export function LoginPage() {
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

  return (
    <div className="min-h-screen flex items-center justify-center bg-background relative">
      <div className="absolute top-4 right-4">
        <ThemeToggle />
      </div>
      <div className="bg-card border border-border rounded-xl shadow-sm p-8 max-w-sm w-full text-center animate-fade-in">
        <div className="flex items-center justify-center gap-3 mb-2">
          <h1 className="text-2xl font-bold text-foreground">MFSynced</h1>
        </div>
        <p className="text-muted-foreground text-sm mb-1">Team iMessage Hub</p>
        <p className="text-muted-foreground text-xs mb-6">Sign in with your @moonfive.tech email</p>
        <button
          onClick={handleLogin}
          className="w-full py-2.5 px-4 rounded-md font-medium text-sm transition-colors cursor-pointer"
          style={{ backgroundColor: '#ffd028', color: '#000' }}
          onMouseEnter={e => (e.currentTarget.style.backgroundColor = '#e6bb24')}
          onMouseLeave={e => (e.currentTarget.style.backgroundColor = '#ffd028')}
        >
          Sign in with Google
        </button>
      </div>
    </div>
  );
}
