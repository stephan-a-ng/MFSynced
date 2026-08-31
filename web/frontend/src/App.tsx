import { useEffect, useState } from 'react';
import { BrowserRouter, Routes, Route, Navigate, NavLink, useLocation, useNavigate } from 'react-router-dom';
import { LogOut } from 'lucide-react';
import { useAuthStore } from './shared/auth/store';
import { ThemeToggle } from './components/ThemeToggle';
import { FlowerMark } from './components/brand/FlowerMark';
import { BrandLoader } from './components/brand/BrandLoader';
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
    // loadUser() resolves /v1/auth/config first (loadConfig()), which
    // constructs and starts the @moonfive/auth-client instance — arming its
    // proactive-refresh timer and cross-tab storage/focus listeners. There is
    // no separate startProactiveRefresh() call anymore.
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
    return <BrandLoader />;
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
    { to: '/', label: 'Inbox' },
    { to: '/conversations', label: 'Conversations' },
  ];

  return (
    <div className="min-h-screen h-screen flex flex-col bg-background text-foreground">
      {/* Deploy's shell: a pinned, opaque top bar — mark + wordmark, inline
          text nav, user/actions on the right. Opaque on purpose: nothing may
          read through the nav as content scrolls beneath it. */}
      <header className="sticky top-0 z-30 border-b border-border bg-background">
        <div className="w-full px-6 sm:px-11 flex flex-wrap items-center gap-x-6 gap-y-2 py-3 sm:gap-x-8">
          <NavLink to="/" className="flex items-center gap-2.5 font-semibold text-foreground">
            <FlowerMark
              size="26px"
              fill="currentColor"
              autoplay
              className="h-[26px] w-[26px] flex-none"
            />
            <span className="font-brand">Message</span>
          </NavLink>
          <nav className="flex flex-wrap items-center gap-4 text-sm">
            {navItems.map(({ to, label }) => (
              <NavLink
                key={to}
                to={to}
                end={to === '/'}
                className={({ isActive }) =>
                  isActive
                    ? 'text-foreground font-medium'
                    : 'text-muted-foreground hover:text-foreground'
                }
              >
                {label}
              </NavLink>
            ))}
          </nav>
          <div className="ml-auto min-w-0 flex items-center gap-2 text-sm sm:gap-4">
            {user?.email && (
              <span className="hidden max-w-48 truncate text-muted-foreground sm:block">
                {user.email}
              </span>
            )}
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
      </header>

      {/* Main content */}
      <main className="flex-1 min-h-0 overflow-auto">
        {children}
      </main>
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
