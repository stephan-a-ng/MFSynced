import { assetUrl } from '../api/client';
import { FlowerSpinner } from '../components/brand/BrandLoader';
import { useEffect, useRef, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { conversationsApi, type Message } from '../api/conversations';
import { messagesApi } from '../api/messages';
import { MessageBubble } from '../components/MessageBubble';
import { ReplyBox } from '../components/ReplyBox';

const POLL_STATUS_MS = 2_000;
const POLL_MESSAGES_MS = 10_000;
const STATUS_TIMEOUT_MS = 60_000;
const AGENT_STALE_MS = 10 * 60 * 1000;

// Deterministic avatar color (same palette as ThreadViewPage/InboxLayout)
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

function timeAgo(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diffMs / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

// Group messages by calendar day (matching Mac app behavior)
function groupMessages(messages: Message[]) {
  const groups: { label: string; messages: Message[] }[] = [];
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

interface PendingSend {
  idempotencyKey: string;
  commandId: string | null;
  text: string;
  attachmentType?: string;
  attachmentUrl?: string;
  createdAt: number; // ms epoch of most recent (re)send attempt
  status: string; // 'pending' | 'sent' | 'delivered' | 'failed: <reason>' | 'failed: timeout'
  agentLastSeenAt: string | null;
}

function isTerminal(status: string) {
  return status === 'delivered' || status.startsWith('failed');
}

function pendingToMessage(p: PendingSend, phone: string): Message {
  return {
    id: p.idempotencyKey,
    guid: `pending-${p.idempotencyKey}`,
    phone,
    text: p.text,
    timestamp: new Date(p.createdAt).toISOString(),
    is_from_me: true,
    service: 'iMessage',
    attachment_type: p.attachmentType ?? null,
    attachment_url: p.attachmentUrl ?? null,
    attachment_mime_type: null,
    attachment_filename: null,
    reactions: [],
    delivery_status: p.status,
  };
}

// Reconcile pending optimistic sends against a freshly-fetched real message
// list: once a real message with the same text (sent by us, at or after the
// pending item's send time) shows up, drop the optimistic bubble in favor of
// the real one. Matches oldest-pending-first so duplicate-text sends don't
// steal each other's match.
function reconcilePending(realMessages: Message[], pendingList: PendingSend[]): PendingSend[] {
  const claimed = new Set<string>();
  const candidates = realMessages.filter(m => m.is_from_me);
  const sorted = [...pendingList].sort((a, b) => a.createdAt - b.createdAt);
  const stillPending = new Set(sorted.map(p => p.idempotencyKey));
  for (const p of sorted) {
    const match = candidates.find(
      m => !claimed.has(m.guid) && m.text === p.text && new Date(m.timestamp).getTime() >= p.createdAt - 5_000
    );
    if (match) {
      claimed.add(match.guid);
      stillPending.delete(p.idempotencyKey);
    }
  }
  return pendingList.filter(p => stillPending.has(p.idempotencyKey));
}

export function ConversationThreadPage() {
  const { phone } = useParams<{ phone: string }>();
  const [searchParams] = useSearchParams();
  const agentId = searchParams.get('agent_id');

  const [messages, setMessages] = useState<Message[]>([]);
  const [contactName, setContactName] = useState<string | null>(null);
  const [contactPhoto, setContactPhoto] = useState<string | null>(null);
  const [pending, setPending] = useState<PendingSend[]>([]);
  const [loading, setLoading] = useState(true);
  const bottomRef = useRef<HTMLDivElement>(null);
  const pendingRef = useRef<PendingSend[]>([]);

  useEffect(() => {
    pendingRef.current = pending;
  }, [pending]);

  // Load contact name from the conversations list (best-effort, non-blocking).
  useEffect(() => {
    if (!phone) return;
    conversationsApi
      .list()
      .then(list => {
        const match = list.find(c => c.phone === phone && (!agentId || c.agent_id === agentId));
        setContactName(match?.contact_name ?? null);
        setContactPhoto(match?.contact_photo_url ?? null);
      })
      .catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phone]);

  // Fetch + poll the real message list every 10s (mirrors ThreadViewPage).
  useEffect(() => {
    if (!phone || !agentId) {
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    conversationsApi
      .messages(phone, agentId)
      .then(msgs => {
        if (cancelled) return;
        setMessages(msgs);
        setLoading(false);
      })
      .catch(() => {
        if (!cancelled) setLoading(false);
      });

    const interval = setInterval(() => {
      conversationsApi
        .messages(phone, agentId)
        .then(msgs => {
          if (cancelled) return;
          setMessages(msgs);
          setPending(prev => reconcilePending(msgs, prev));
        })
        .catch(() => {});
    }, POLL_MESSAGES_MS);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [phone, agentId]);

  // Poll command status for every non-terminal pending send every 2s, up to
  // a 60s cap per send attempt (after which it's marked as a local timeout).
  useEffect(() => {
    const interval = setInterval(() => {
      const now = Date.now();
      for (const p of pendingRef.current) {
        if (!p.commandId || isTerminal(p.status)) continue;
        if (now - p.createdAt >= STATUS_TIMEOUT_MS) {
          setPending(prev =>
            prev.map(x => (x.idempotencyKey === p.idempotencyKey && !isTerminal(x.status) ? { ...x, status: 'failed: timeout' } : x))
          );
          continue;
        }
        messagesApi
          .getStatus(p.commandId)
          .then(res => {
            setPending(prev =>
              prev.map(x =>
                x.idempotencyKey === p.idempotencyKey ? { ...x, status: res.status, agentLastSeenAt: res.agent_last_seen_at } : x
              )
            );
          })
          .catch(() => {});
      }
    }, POLL_STATUS_MS);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    bottomRef.current?.scrollIntoView();
  }, [messages.length, pending.length]);

  const doSend = async (p: PendingSend) => {
    if (!phone) return;
    try {
      const res = await messagesApi.send({
        phone,
        text: p.text,
        agent_id: agentId || undefined,
        attachment_type: p.attachmentType,
        attachment_url: p.attachmentUrl,
        idempotency_key: p.idempotencyKey,
      });
      setPending(prev =>
        prev.map(x => (x.idempotencyKey === p.idempotencyKey ? { ...x, commandId: res.command_id, status: res.status } : x))
      );
    } catch (err) {
      setPending(prev =>
        prev.map(x =>
          x.idempotencyKey === p.idempotencyKey ? { ...x, status: `failed: ${(err as Error).message || 'send failed'}` } : x
        )
      );
    }
  };

  const handleSend = async (text: string, attachmentType?: string, attachmentUrl?: string) => {
    if (!phone || !text.trim()) return;
    const newPending: PendingSend = {
      idempotencyKey: crypto.randomUUID(),
      commandId: null,
      text: text.trim(),
      attachmentType,
      attachmentUrl,
      createdAt: Date.now(),
      status: 'pending',
      agentLastSeenAt: null,
    };
    setPending(prev => [...prev, newPending]);
    await doSend(newPending);
  };

  // MessageBubble's retry callback only hands back the message text, so we
  // resolve it to the most recent terminal (failed/timed-out) pending item
  // with that text and resend it, reusing its idempotency key.
  const handleRetry = (text: string) => {
    const target = [...pendingRef.current].reverse().find(p => p.text === text && isTerminal(p.status));
    if (!target) return;
    const retried: PendingSend = { ...target, status: 'pending', createdAt: Date.now(), commandId: null, agentLastSeenAt: null };
    setPending(prev => prev.map(x => (x.idempotencyKey === target.idempotencyKey ? retried : x)));
    doSend(retried);
  };

  if (!phone) {
    return <div className="p-6 text-sm text-muted-foreground">Conversation not found</div>;
  }

  if (!agentId) {
    return <div className="p-6 text-sm text-muted-foreground">Missing agent — open this conversation from the Conversations list.</div>;
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <FlowerSpinner />
      </div>
    );
  }

  const name = contactName || phone;
  const [bg, fg] = avatarColor(name);
  const allMessages = [...messages, ...pending.map(p => pendingToMessage(p, phone))];
  const groups = groupMessages(allMessages);

  const queuedNotes = new Map<string, string>();
  for (const p of pending) {
    if (p.status === 'pending' && p.agentLastSeenAt) {
      const age = Date.now() - new Date(p.agentLastSeenAt).getTime();
      if (age > AGENT_STALE_MS) {
        queuedNotes.set(p.idempotencyKey, `queued — Mac last seen ${timeAgo(p.agentLastSeenAt)}`);
      }
    }
  }

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="border-b border-border px-4 py-3 flex flex-col items-center gap-1 flex-shrink-0">
        {contactPhoto ? (
          <img
            src={assetUrl(contactPhoto)}
            alt=""
            style={{ width: 48, height: 48 }}
            className="rounded-full object-cover select-none"
          />
        ) : (
          <div
            style={{ width: 48, height: 48, background: bg, color: fg, fontSize: 18 }}
            className="rounded-full flex items-center justify-center font-semibold select-none"
          >
            {initials(name)}
          </div>
        )}
        <div className="text-center">
          <h2 className="text-[14px] font-semibold text-foreground leading-snug">{name}</h2>
          {contactName && <p className="text-[11px] text-muted-foreground">{phone}</p>}
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-1">
        {groups.length === 0 && <p className="text-center text-xs text-muted-foreground pt-8">No messages yet</p>}
        {groups.map((g, gi) => (
          <div key={gi}>
            <p className="text-center text-[11px] text-muted-foreground my-3 select-none">{g.label}</p>
            <div className="space-y-0.5">
              {g.messages.map(m => (
                <div key={m.id}>
                  <MessageBubble message={m} onRetry={handleRetry} />
                  {queuedNotes.has(m.id) && (
                    <p className="text-[11px] text-muted-foreground text-right pr-1 mt-0.5">{queuedNotes.get(m.id)}</p>
                  )}
                </div>
              ))}
            </div>
          </div>
        ))}
        <div ref={bottomRef} />
      </div>

      <ReplyBox onSend={handleSend} />
    </div>
  );
}
