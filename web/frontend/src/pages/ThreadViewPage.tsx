import { useEffect, useState, useRef } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { Loader2, Info, Archive } from 'lucide-react';
import { inboxApi, type ThreadDetail } from '../api/inbox';
import { useInboxStore } from '../stores/inboxStore';
import { MessageBubble } from '../components/MessageBubble';
import { ReplyBox } from '../components/ReplyBox';

// Deterministic avatar color (same palette as InboxLayout)
const COLORS = [
  ['#5B8AF5', '#fff'],
  ['#34C759', '#fff'],
  ['#FF9500', '#fff'],
  ['#FF3B30', '#fff'],
  ['#AF52DE', '#fff'],
  ['#FF2D55', '#fff'],
  ['#5AC8FA', '#fff'],
  ['#FFCC00', '#000'],
];
function avatarColor(name: string) {
  const hash = name.split('').reduce((a, c) => a + c.charCodeAt(0), 0);
  return COLORS[hash % COLORS.length];
}
function initials(name: string) {
  return name.split(' ').filter(Boolean).slice(0, 2).map(w => w[0].toUpperCase()).join('') || '?';
}

function formatGroupTime(iso: string) {
  const d = new Date(iso);
  const now = new Date();
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (d.toDateString() === now.toDateString()) return `Today ${time}`;
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return `Yesterday ${time}`;
  const isThisYear = d.getFullYear() === now.getFullYear();
  const dateStr = d.toLocaleDateString([], {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    ...(isThisYear ? {} : { year: 'numeric' }),
  });
  return `${dateStr} at ${time}`;
}

// Group messages by calendar day (matching Mac app behavior)
function groupMessages(messages: ThreadDetail['messages']) {
  const groups: { label: string; messages: typeof messages }[] = [];
  let lastDay = '';
  for (const msg of messages) {
    const d = new Date(msg.timestamp);
    const day = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
    if (day !== lastDay) {
      groups.push({ label: formatGroupTime(msg.timestamp), messages: [] });
      lastDay = day;
    }
    groups[groups.length - 1].messages.push(msg);
  }
  return groups;
}

export function ThreadViewPage() {
  const { threadId } = useParams<{ threadId: string }>();
  const navigate = useNavigate();
  const { archiveThread } = useInboxStore();
  const [data, setData] = useState<ThreadDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!threadId) return;
    setLoading(true);
    inboxApi.get(threadId).then(d => {
      setData(d);
      setLoading(false);
      inboxApi.markRead(threadId);
    }).catch(() => setLoading(false));
  }, [threadId]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView();
  }, [data?.messages.length]);

  const handleReply = async (text: string, attachmentType?: string, attachmentUrl?: string) => {
    if (!threadId || !data) return;

    // Show the sent message immediately before the backend round-trip
    const optimisticGuid = `pending-${crypto.randomUUID()}`;
    const optimisticMsg = {
      id: crypto.randomUUID(),
      guid: optimisticGuid,
      phone: data.thread.phone,
      text,
      timestamp: new Date().toISOString(),
      is_from_me: true,
      service: 'iMessage',
      attachment_type: attachmentType ?? null,
      attachment_url: attachmentUrl ?? null,
      attachment_mime_type: null,
      attachment_filename: null,
      reactions: [],
    };
    setData(prev => prev ? { ...prev, messages: [...prev.messages, optimisticMsg] } : prev);

    await inboxApi.reply(threadId, text, attachmentType, attachmentUrl);

    // Refetch and preserve any optimistic messages not yet in the DB
    const updated = await inboxApi.get(threadId);
    setData(prev => {
      if (!prev) return updated;
      const realGuids = new Set(updated.messages.map(m => m.guid));
      const pending = prev.messages.filter(m => m.guid.startsWith('pending-') && !realGuids.has(m.guid));
      return { ...updated, messages: [...updated.messages, ...pending] };
    });
  };

  const handleArchive = async () => {
    if (!threadId) return;
    await archiveThread(threadId);
    navigate('/inbox');
  };

  const handleReact = async (messageGuid: string, reactionType: string) => {
    if (!threadId) return;
    await inboxApi.react(threadId, messageGuid, reactionType);
    const updated = await inboxApi.get(threadId);
    setData(updated);
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader2 size={24} className="animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!data) {
    return <div className="p-6 text-muted-foreground text-sm">Thread not found</div>;
  }

  const { thread, messages } = data;
  const name = thread.contact_name || thread.phone;
  const [bg, fg] = avatarColor(name);
  const groups = groupMessages(messages);

  return (
    <div className="flex flex-col h-full">
      {/* Header — centered avatar + name like Mac app */}
      <div className="border-b border-border px-4 py-3 flex flex-col items-center gap-1 flex-shrink-0 relative">
        <button
          onClick={handleArchive}
          className="absolute right-3 top-3 p-1.5 rounded-md text-muted-foreground hover:text-foreground hover:bg-muted transition-colors"
          title="Archive"
        >
          <Archive size={15} />
        </button>
        <div
          style={{ width: 48, height: 48, background: bg, color: fg, fontSize: 18 }}
          className="rounded-full flex items-center justify-center font-semibold select-none"
        >
          {initials(name)}
        </div>
        <div className="text-center">
          <h2 className="text-[14px] font-semibold text-foreground leading-snug">{name}</h2>
          {thread.contact_name && (
            <p className="text-[11px] text-muted-foreground">{thread.phone}</p>
          )}
        </div>
        <div className="flex items-center gap-2 mt-0.5">
          <span
            className={`text-[11px] px-2 py-0.5 rounded-full font-medium ${
              thread.mode === 'action'
                ? 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300'
                : 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300'
            }`}
          >
            {thread.mode === 'action' ? 'Action Needed' : 'FYI'}
          </span>
          <span className="text-[11px] text-muted-foreground">
            from {thread.forwarded_by_name}
          </span>
          {thread.note && (
            <span className="text-[11px] text-muted-foreground italic">&ldquo;{thread.note}&rdquo;</span>
          )}
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-1">
        {groups.length === 0 && (
          <p className="text-center text-xs text-muted-foreground pt-8">No messages yet</p>
        )}
        {groups.map((g, gi) => (
          <div key={gi}>
            <p className="text-center text-[11px] text-muted-foreground my-3 select-none">{g.label}</p>
            <div className="space-y-0.5">
              {g.messages.map(m => (
                <MessageBubble key={m.id} message={m} onReact={handleReact} />
              ))}
            </div>
          </div>
        ))}
        <div ref={bottomRef} />
      </div>

      {/* Reply or FYI banner */}
      {thread.mode === 'action' ? (
        <ReplyBox onSend={handleReply} />
      ) : (
        <div className="border-t border-border p-3 flex items-center gap-2 text-xs text-muted-foreground flex-shrink-0">
          <Info size={14} />
          This thread is shared for your information only
        </div>
      )}
    </div>
  );
}
