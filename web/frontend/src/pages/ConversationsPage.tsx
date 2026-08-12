import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Smartphone, Forward, Loader2, Plus } from 'lucide-react';
import { useConversationStore } from '../stores/conversationStore';
import { ForwardDialog } from '../components/ForwardDialog';
import { ComposeDialog } from '../components/ComposeDialog';
import type { Conversation } from '../api/conversations';

export function ConversationsPage() {
  const { conversations, loading, fetchConversations } = useConversationStore();
  const [forwardTarget, setForwardTarget] = useState<Conversation | null>(null);
  const [composeOpen, setComposeOpen] = useState(false);

  useEffect(() => { fetchConversations(); }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={24} className="animate-spin text-muted-foreground" />
      </div>
    );
  }

  return (
    <div className="p-6 max-w-3xl">
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-2">
          <Smartphone size={24} />
          <h1 className="text-xl font-semibold text-foreground">My Conversations</h1>
        </div>
        <button
          onClick={() => setComposeOpen(true)}
          className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-md bg-primary text-primary-foreground hover:opacity-90 transition-opacity"
        >
          <Plus size={14} />
          New Message
        </button>
      </div>

      {conversations.length === 0 ? (
        <p className="text-muted-foreground">No synced conversations yet. Connect your Mac app.</p>
      ) : (
        <div className="space-y-1">
          {conversations.map(c => (
            <Link
              key={`${c.phone}-${c.agent_id}`}
              to={`/conversations/${encodeURIComponent(c.phone)}?agent_id=${encodeURIComponent(c.agent_id)}`}
              className="flex items-center p-3 rounded-lg border border-border hover:bg-muted/50 transition-colors"
            >
              <div className="flex-1 min-w-0">
                <p className="font-medium text-sm text-foreground">{c.contact_name || c.phone}</p>
                {c.contact_name && <p className="text-xs text-muted-foreground">{c.phone}</p>}
                <p className="text-xs text-muted-foreground">{c.message_count} messages</p>
              </div>
              {c.last_message_at && (
                <span className="text-xs text-muted-foreground mr-3">
                  {new Date(c.last_message_at).toLocaleDateString([], { month: 'short', day: 'numeric' })}
                </span>
              )}
              <button
                onClick={(e) => { e.preventDefault(); e.stopPropagation(); setForwardTarget(c); }}
                className="flex items-center gap-1 px-3 py-1.5 text-xs font-medium rounded-md bg-primary/10 text-primary hover:bg-primary/20 transition-colors"
              >
                <Forward size={14} />
                Forward
              </button>
            </Link>
          ))}
        </div>
      )}

      {forwardTarget && (
        <ForwardDialog
          phone={forwardTarget.phone}
          agentId={forwardTarget.agent_id}
          contactName={forwardTarget.contact_name}
          onClose={() => setForwardTarget(null)}
          onForwarded={() => { setForwardTarget(null); alert('Thread forwarded!'); }}
        />
      )}

      {composeOpen && (
        <ComposeDialog conversations={conversations} onClose={() => setComposeOpen(false)} />
      )}
    </div>
  );
}
