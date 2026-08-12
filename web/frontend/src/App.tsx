import { useEffect, useState } from 'react';
import { BrowserRouter, Routes, Route, Navigate, NavLink, useLocation, useNavigate } from 'react-router-dom';
import { Inbox, Smartphone, LogOut, Loader2 } from 'lucide-react';
import { useAuthStore } from './shared/auth/store';
import { startProactiveRefresh } from './shared/auth/scheduler';
import { ThemeToggle } from './components/ThemeToggle';
import { LoginPage } from './pages/LoginPage';
import { AuthCallbackPage } from './pages/AuthCallbackPage';
import { DashboardPage } from './pages/DashboardPage';
import { ConversationsPage } from './pages/ConversationsPage';
import { ConversationThreadPage } from './pages/ConversationThreadPage';
import { ThreadViewPage } from './pages/ThreadViewPage';

function AuthGuard({ children }: { children: React.ReactNode }) {
  const { user, accessToken, loadUser } = useAuthStore();
  const location = useLocation();
  // Local "have we tried to hydrate the session yet" flag — distinct from
  // the store's `loading`, which is just loadUser()'s single-flight mutex
  // (false by default, not "true until the first load resolves").
  const [hydrating, setHydrating] = useState(true);

  useEffect(() => {
    startProactiveRefresh();
    if (accessToken) {
      loadUser()
        .catch(() => {})
        .finally(() => setHydrating(false));
    } else {
      setHydrating(false);
    }
    // Only ever run once on mount — loadUser/accessToken changes afterward
    // (e.g. a token refresh) must not re-trigger hydration.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (hydrating) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Loader2 size={24} className="animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!accessToken || !user) {
    return <Navigate to="/login" state={{ from: location.pathname }} replace />;
  }
  return <>{children}</>;
}

function Layout({ children }: { children: React.ReactNode }) {
  const { user, logout } = useAuthStore();
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
        <nav className="flex-1 p-2 pt-3 space-y-1">
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
              className="w-9 h-9 rounded-lg flex items-center justify-center transition-colors hover:bg-muted"
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
                  <Route path="/conversations/:phone" element={<ConversationThreadPage />} />
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
