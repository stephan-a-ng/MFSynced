import { Link } from 'react-router-dom';
import type { InboxThread } from '../api/inbox';

export function ThreadCard({ thread }: { thread: InboxThread }) {
  const time = thread.last_message_at
    ? new Date(thread.last_message_at).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
    : '';

  return (
    <Link
      to={`/inbox/${thread.id}`}
      className="block p-4 border border-border rounded-lg hover:bg-muted/50 transition-colors"
    >
      <div className="flex items-start justify-between gap-2">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            {!thread.has_read && <div className="w-2 h-2 rounded-full bg-primary flex-shrink-0" />}
            <h3 className="font-medium text-sm text-foreground truncate">
              {thread.contact_name || thread.phone}
            </h3>
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
          {thread.last_message_text && (
            <p className="text-xs text-muted-foreground mt-1 truncate">{thread.last_message_text}</p>
          )}
          <p className="text-xs text-muted-foreground mt-1">
            Forwarded by {thread.forwarded_by_name}
          </p>
        </div>
        <span className="text-xs text-muted-foreground flex-shrink-0">{time}</span>
      </div>
    </Link>
  );
}
