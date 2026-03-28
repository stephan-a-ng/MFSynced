import { Smartphone } from 'lucide-react';

export function ConversationsPage() {
  return (
    <div className="p-6">
      <div className="flex items-center gap-2 mb-6">
        <Smartphone size={24} />
        <h1 className="text-xl font-semibold">My Conversations</h1>
      </div>
      <p className="text-muted-foreground">Connect your Mac app to see synced conversations.</p>
    </div>
  );
}
