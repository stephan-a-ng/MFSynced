import { useState, useEffect } from 'react';
import { X } from 'lucide-react';
import { authApi, type User } from '../api/auth';
import { forwardApi } from '../api/forward';

interface Props {
  phone: string;
  agentId: string;
  contactName: string | null;
  onClose: () => void;
  onForwarded: () => void;
}

export function ForwardDialog({ phone, agentId, contactName, onClose, onForwarded }: Props) {
  const [users, setUsers] = useState<User[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<'fyi' | 'action'>('fyi');
  const [note, setNote] = useState('');
  const [sending, setSending] = useState(false);

  useEffect(() => {
    authApi.users().then(setUsers);
  }, []);

  const toggle = (id: string) => {
    const next = new Set(selected);
    next.has(id) ? next.delete(id) : next.add(id);
    setSelected(next);
  };

  const handleForward = async () => {
    if (selected.size === 0) return;
    setSending(true);
    try {
      await forwardApi.forward({
        phone,
        agent_id: agentId,
        recipient_user_ids: Array.from(selected),
        mode,
        note: note.trim() || undefined,
      });
      onForwarded();
    } catch (err) {
      alert('Failed to forward: ' + (err as Error).message);
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={onClose}>
      <div className="bg-card border border-border rounded-xl shadow-lg w-full max-w-md p-6" onClick={e => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h2 className="font-semibold text-foreground">Forward Thread</h2>
          <button onClick={onClose} className="text-muted-foreground hover:text-foreground">
            <X size={18} />
          </button>
        </div>

        <p className="text-sm text-muted-foreground mb-4">
          Forward <strong>{contactName || phone}</strong> to team members
        </p>

        {/* Mode selector */}
        <div className="flex gap-2 mb-4">
          {(['fyi', 'action'] as const).map(m => (
            <button
              key={m}
              onClick={() => setMode(m)}
              className={`flex-1 py-2 text-sm rounded-md border transition-colors ${
                mode === m
                  ? 'border-primary bg-primary/10 text-primary font-medium'
                  : 'border-border text-muted-foreground hover:bg-muted'
              }`}
            >
              {m === 'fyi' ? 'FYI (Read-only)' : 'Action Needed'}
            </button>
          ))}
        </div>

        {/* Recipients */}
        <div className="space-y-1 mb-4 max-h-48 overflow-y-auto">
          {users.map(u => (
            <label key={u.id} className="flex items-center gap-2 p-2 rounded-md hover:bg-muted cursor-pointer">
              <input
                type="checkbox"
                checked={selected.has(u.id)}
                onChange={() => toggle(u.id)}
                className="rounded"
              />
              <span className="text-sm text-foreground">{u.name}</span>
              <span className="text-xs text-muted-foreground">{u.email}</span>
            </label>
          ))}
        </div>

        {/* Note */}
        <textarea
          placeholder="Add a note (optional)"
          value={note}
          onChange={e => setNote(e.target.value)}
          className="w-full p-2 text-sm border border-border rounded-md bg-background text-foreground resize-none mb-4"
          rows={2}
        />

        <button
          onClick={handleForward}
          disabled={selected.size === 0 || sending}
          className="w-full py-2 rounded-md text-sm font-medium bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-50 transition-opacity"
        >
          {sending ? 'Forwarding...' : `Forward to ${selected.size} recipient${selected.size !== 1 ? 's' : ''}`}
        </button>
      </div>
    </div>
  );
}
