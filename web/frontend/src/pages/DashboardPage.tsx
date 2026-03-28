import { useEffect } from 'react';
import { Inbox, Loader2 } from 'lucide-react';
import { useInboxStore } from '../stores/inboxStore';
import { ThreadCard } from '../components/ThreadCard';

export function DashboardPage() {
  const { threads, loading, fetchInbox } = useInboxStore();

  useEffect(() => { fetchInbox(); }, []);

  const actionThreads = threads.filter(t => t.mode === 'action');
  const fyiThreads = threads.filter(t => t.mode === 'fyi');

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={24} className="animate-spin text-muted-foreground" />
      </div>
    );
  }

  return (
    <div className="p-6 max-w-3xl">
      <div className="flex items-center gap-2 mb-6">
        <Inbox size={24} />
        <h1 className="text-xl font-semibold text-foreground">Inbox</h1>
      </div>

      {threads.length === 0 ? (
        <p className="text-muted-foreground">No forwarded threads yet.</p>
      ) : (
        <>
          {actionThreads.length > 0 && (
            <div className="mb-6">
              <h2 className="text-sm font-medium text-muted-foreground mb-2 uppercase tracking-wide">Action Needed</h2>
              <div className="space-y-2">
                {actionThreads.map(t => <ThreadCard key={t.id} thread={t} />)}
              </div>
            </div>
          )}
          {fyiThreads.length > 0 && (
            <div>
              <h2 className="text-sm font-medium text-muted-foreground mb-2 uppercase tracking-wide">FYI</h2>
              <div className="space-y-2">
                {fyiThreads.map(t => <ThreadCard key={t.id} thread={t} />)}
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}
