import { useEffect, useState, useRef } from 'react';
import { useParams, Link } from 'react-router-dom';
import { ArrowLeft, Loader2, Info } from 'lucide-react';
import { inboxApi, type ThreadDetail } from '../api/inbox';
import { MessageBubble } from '../components/MessageBubble';
import { ReplyBox } from '../components/ReplyBox';

export function ThreadViewPage() {
  const { threadId } = useParams<{ threadId: string }>();
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
    if (!threadId) return;
    await inboxApi.reply(threadId, text, attachmentType, attachmentUrl);
    // Refresh messages
    const updated = await inboxApi.get(threadId);
    setData(updated);
  };

  const handleReact = async (messageGuid: string, reactionType: string) => {
    if (!threadId) return;
    await inboxApi.react(threadId, messageGuid, reactionType);
    // Refresh to show updated reactions
    const updated = await inboxApi.get(threadId);
    setData(updated);
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={24} className="animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!data) {
    return <div className="p-6 text-muted-foreground">Thread not found</div>;
  }

  const { thread, messages } = data;

  // Group messages by date
  const groups: { date: string; messages: typeof messages }[] = [];
  let currentDate = '';
  for (const msg of messages) {
    const d = new Date(msg.timestamp).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
    if (d !== currentDate) {
      currentDate = d;
      groups.push({ date: d, messages: [] });
    }
    groups[groups.length - 1].messages.push(msg);
  }

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="border-b border-border p-4 flex items-center gap-3">
        <Link to="/" className="text-muted-foreground hover:text-foreground">
          <ArrowLeft size={20} />
        </Link>
        <div className="flex-1">
          <h2 className="font-semibold text-foreground">{thread.contact_name || thread.phone}</h2>
          <p className="text-xs text-muted-foreground">
            Forwarded by {thread.forwarded_by_name}
            {thread.note && <> &mdash; &ldquo;{thread.note}&rdquo;</>}
          </p>
        </div>
        <span
          className={`text-xs px-2 py-0.5 rounded-full font-medium ${
            thread.mode === 'action'
              ? 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300'
              : 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300'
          }`}
        >
          {thread.mode === 'action' ? 'Action Needed' : 'FYI'}
        </span>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-4 space-y-2">
        {groups.map(g => (
          <div key={g.date}>
            <p className="text-center text-xs text-muted-foreground my-3">{g.date}</p>
            <div className="space-y-1">
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
        <div className="border-t border-border p-3 flex items-center gap-2 text-sm text-muted-foreground">
          <Info size={16} />
          This thread is shared for your information only
        </div>
      )}
    </div>
  );
}
