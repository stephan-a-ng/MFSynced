import { useEffect, useState } from 'react';
import { Outlet, NavLink, useParams, useNavigate } from 'react-router-dom';
import { Loader2, Archive } from 'lucide-react';
import { useInboxStore } from '../stores/inboxStore';
import type { InboxThread } from '../api/inbox';

// Deterministic color from a string
const COLORS = [
  ['#5B8AF5', '#fff'], // blue
  ['#34C759', '#fff'], // green
  ['#FF9500', '#fff'], // orange
  ['#FF3B30', '#fff'], // red
  ['#AF52DE', '#fff'], // purple
  ['#FF2D55', '#fff'], // pink
  ['#5AC8FA', '#fff'], // light blue
  ['#FFCC00', '#000'], // yellow
];
function avatarColor(name: string) {
  const hash = name.split('').reduce((a, c) => a + c.charCodeAt(0), 0);
  return COLORS[hash % COLORS.length];
}
function initials(name: string) {
  return name.split(' ').filter(Boolean).slice(0, 2).map(w => w[0].toUpperCase()).join('') || '?';
}

function Avatar({ name, size = 36 }: { name: string; size?: number }) {
  const [bg, fg] = avatarColor(name);
  return (
    <div style={{ width: size, height: size, background: bg, color: fg, fontSize: size * 0.38, flexShrink: 0 }}
      className="rounded-full flex items-center justify-center font-semibold select-none">
      {initials(name)}
    </div>
  );
}

function formatTime(iso: string) {
  const d = new Date(iso);
  const now = new Date();
  const isToday = d.toDateString() === now.toDateString();
  if (isToday) return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const diff = (now.getTime() - d.getTime()) / 86400000;
  if (diff < 7) return d.toLocaleDateString([], { weekday: 'short' });
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

function ThreadRow({ thread, selected }: { thread: InboxThread; selected: boolean }) {
  const name = thread.contact_name || thread.phone;
  const { archiveThread } = useInboxStore();
  const navigate = useNavigate();
  const [hovered, setHovered] = useState(false);

  const handleArchive = async (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    await archiveThread(thread.id);
    if (selected) navigate('/inbox');
  };

  return (
    <NavLink to={`/inbox/${thread.id}`}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      className={`flex items-center gap-2.5 px-2.5 py-2 mx-1 rounded-lg cursor-pointer transition-colors ${selected ? 'bg-primary/15' : 'hover:bg-muted/70'}`}>
      <div className="relative">
        <Avatar name={name} size={36} />
        {!thread.has_read && (
          <div className="absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full bg-primary border-2 border-card" />
        )}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-baseline justify-between gap-1">
          <span className={`text-[13px] truncate ${!thread.has_read ? 'font-semibold text-foreground' : 'font-medium text-foreground'}`}>
            {name}
          </span>
          {hovered ? (
            <button
              onClick={handleArchive}
              className="flex-shrink-0 p-0.5 rounded hover:text-foreground text-muted-foreground transition-colors"
              title="Archive"
            >
              <Archive size={13} />
            </button>
          ) : thread.last_message_at ? (
            <span className="text-[11px] text-muted-foreground flex-shrink-0">{formatTime(thread.last_message_at)}</span>
          ) : null}
        </div>
        {thread.last_message_text && (
          <p className="text-[12px] text-muted-foreground truncate leading-snug">{thread.last_message_text}</p>
        )}
      </div>
    </NavLink>
  );
}

export function InboxLayout() {
  const { threads, loading, fetchInbox } = useInboxStore();
  const { threadId } = useParams<{ threadId?: string }>();

  useEffect(() => { fetchInbox(); }, []);

  return (
    <div className="flex h-full overflow-hidden">
      {/* Left: thread list */}
      <div className="w-[280px] flex-shrink-0 border-r border-border flex flex-col bg-background overflow-hidden">
        <div className="px-3 pt-4 pb-2 flex-shrink-0">
          <h1 className="text-[15px] font-bold text-foreground">Inbox</h1>
        </div>

        <div className="flex-1 overflow-y-auto py-1">
          {loading ? (
            <div className="flex justify-center pt-8"><Loader2 size={20} className="animate-spin text-muted-foreground" /></div>
          ) : threads.length === 0 ? (
            <p className="text-xs text-muted-foreground text-center pt-8 px-4">No forwarded threads yet.</p>
          ) : (
            threads.map(t => <ThreadRow key={t.id} thread={t} selected={t.id === threadId} />)
          )}
        </div>
      </div>

      {/* Right: thread detail */}
      <div className="flex-1 overflow-hidden flex flex-col">
        {threadId
          ? <Outlet />
          : (
            <div className="flex flex-col items-center justify-center h-full text-muted-foreground gap-2">
              <div className="text-4xl">💬</div>
              <p className="text-sm">Select a conversation</p>
            </div>
          )}
      </div>
    </div>
  );
}
