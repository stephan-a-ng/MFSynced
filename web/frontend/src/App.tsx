import { useEffect } from 'react';
import { BrowserRouter, Routes, Route, Navigate, NavLink, useNavigate } from 'react-router-dom';
import { Inbox, Smartphone, LogOut, Loader2 } from 'lucide-react';
import { useAuthStore } from './stores/authStore';
import { authApi } from './api/auth';
import { ThemeToggle } from './components/ThemeToggle';
import { LoginPage } from './pages/LoginPage';
import { AuthCallbackPage } from './pages/AuthCallbackPage';
import { DashboardPage } from './pages/DashboardPage';
import { ConversationsPage } from './pages/ConversationsPage';
import { ThreadViewPage } from './pages/ThreadViewPage';

function AuthGuard({ children }: { children: React.ReactNode }) {
  const { user, token, loading, loadUser, setAppEnv } = useAuthStore();

  useEffect(() => {
    loadUser();
    authApi.config().then((cfg) => setAppEnv(cfg.env)).catch(() => {});
  }, []);

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Loader2 size={24} className="animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!token || !user) return <Navigate to="/login" replace />;
  return <>{children}</>;
}

function Layout({ children }: { children: React.ReactNode }) {
  const { user, logout, appEnv } = useAuthStore();
  const navigate = useNavigate();

  const handleLogout = () => {
    logout();
    navigate('/login');
  };

  const navItems = [
    { to: '/', icon: Inbox, label: 'Inbox' },
    { to: '/conversations', icon: Smartphone, label: 'Conversations' },
  ];

  return (
    <div className="flex h-screen bg-background">
      {/* Sidebar */}
      <div className="w-56 border-r border-border flex flex-col bg-card">
        <div className="p-4 border-b border-border">
          <div className="flex items-center gap-2">
            <h1 className="font-bold text-lg text-foreground">MFSynced</h1>
            {appEnv === 'staging' && (
              <span className="px-1.5 py-0.5 text-[10px] font-semibold uppercase rounded bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">
                Staging
              </span>
            )}
          </div>
          <p className="text-xs text-muted-foreground">Team iMessage Hub</p>
        </div>

        <nav className="flex-1 p-2 space-y-1">
          {navItems.map(({ to, icon: Icon, label }) => (
            <NavLink
              key={to}
              to={to}
              end={to === '/'}
              className={({ isActive }) =>
                `flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-colors ${
                  isActive
                    ? 'bg-primary/10 text-primary font-medium'
                    : 'text-muted-foreground hover:bg-muted hover:text-foreground'
                }`
              }
            >
              <Icon size={18} />
              {label}
            </NavLink>
          ))}
        </nav>

        <div className="p-3 border-t border-border space-y-2">
          <div className="flex items-center gap-2">
            {user?.picture && (
              <img src={user.picture} alt="" className="w-7 h-7 rounded-full" />
            )}
            <div className="flex-1 min-w-0">
              <p className="text-xs font-medium text-foreground truncate">{user?.name}</p>
              <p className="text-xs text-muted-foreground truncate">{user?.email}</p>
            </div>
          </div>
          <div className="flex items-center gap-1">
            <ThemeToggle />
            <button
              onClick={handleLogout}
              className="w-9 h-9 rounded-lg flex items-center justify-center transition-colors hover:bg-slate-100 dark:hover:bg-slate-700"
              aria-label="Sign out"
            >
              <LogOut size={18} className="text-muted-foreground" />
            </button>
          </div>
        </div>
      </div>

      {/* Main content */}
      <div className="flex-1 overflow-auto">
        {children}
      </div>
    </div>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route path="/auth/callback" element={<AuthCallbackPage />} />
        <Route
          path="/*"
          element={
            <AuthGuard>
              <Layout>
                <Routes>
                  <Route path="/" element={<DashboardPage />} />
                  <Route path="/conversations" element={<ConversationsPage />} />
                  <Route path="/inbox/:threadId" element={<ThreadViewPage />} />
                </Routes>
              </Layout>
            </AuthGuard>
          }
        />
      </Routes>
    </BrowserRouter>
  );
}
