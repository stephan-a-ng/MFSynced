import { Inbox } from 'lucide-react';

export function DashboardPage() {
  return (
    <div className="p-6">
      <div className="flex items-center gap-2 mb-6">
        <Inbox size={24} />
        <h1 className="text-xl font-semibold">Inbox</h1>
      </div>
      <p className="text-muted-foreground">No forwarded threads yet. Forward a conversation from My Conversations.</p>
    </div>
  );
}
