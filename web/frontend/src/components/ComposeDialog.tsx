import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { X } from 'lucide-react';
import { messagesApi } from '../api/messages';
import type { Conversation } from '../api/conversations';

interface Props {
  conversations: Conversation[];
  onClose: () => void;
}

const PHONE_CHARS_RE = /^[\d+()\-\s]+$/;

function isValidPhone(v: string) {
  if (!v.trim() || !PHONE_CHARS_RE.test(v)) return false;
  return v.replace(/\D/g, '').length >= 7;
}

function agentLabel(agentId: string) {
  return `Mac ${agentId.slice(0, 6)}`;
}

export function ComposeDialog({ conversations, onClose }: Props) {
  const navigate = useNavigate();
  const distinctAgentIds = useMemo(() => Array.from(new Set(conversations.map(c => c.agent_id))), [conversations]);
  const showAgentPicker = distinctAgentIds.length > 1;

  const [phone, setPhone] = useState('');
  const [message, setMessage] = useState('');
  const [agentId, setAgentId] = useState(distinctAgentIds.length === 1 ? distinctAgentIds[0] : '');
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per dialog lifetime: a retry click after a timed-out-but-committed
  // send must replay the same key so the backend dedupes instead of re-sending.
  const [idempotencyKey] = useState(() => crypto.randomUUID());

  const phoneValid = isValidPhone(phone);
  const canSend = phoneValid && message.trim().length > 0 && !sending;

  const handleSubmit = async () => {
    if (!canSend) return;
    setSending(true);
    setError(null);
    try {
      const trimmedPhone = phone.trim();
      await messagesApi.send({
        phone: trimmedPhone,
        text: message.trim(),
        agent_id: agentId || undefined,
        idempotency_key: idempotencyKey,
      });
      const qs = agentId ? `?agent_id=${encodeURIComponent(agentId)}` : '';
      navigate(`/conversations/${encodeURIComponent(trimmedPhone)}${qs}`);
      onClose();
    } catch (err) {
      setError((err as Error).message || 'Failed to send message');
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={onClose}>
      <div className="bg-card border border-border rounded-xl shadow-lg w-full max-w-md p-6" onClick={e => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h2 className="font-semibold text-foreground">New Message</h2>
          <button onClick={onClose} className="text-muted-foreground hover:text-foreground">
            <X size={18} />
          </button>
        </div>

        <label className="block text-xs font-medium text-muted-foreground mb-1">Phone number</label>
        <input
          type="text"
          value={phone}
          onChange={e => setPhone(e.target.value)}
          placeholder="+1 (555) 123-4567"
          className="w-full p-2 text-sm border border-border rounded-md bg-background text-foreground mb-1"
        />
        {phone.length > 0 && !phoneValid && <p className="text-xs text-red-500 mb-3">Enter a valid phone number</p>}
        {(phone.length === 0 || phoneValid) && <div className="mb-3" />}

        {showAgentPicker && (
          <>
            <label className="block text-xs font-medium text-muted-foreground mb-1">Send from</label>
            <select
              value={agentId}
              onChange={e => setAgentId(e.target.value)}
              className="w-full p-2 text-sm border border-border rounded-md bg-background text-foreground mb-3"
            >
              <option value="">Select a Mac…</option>
              {distinctAgentIds.map(id => (
                <option key={id} value={id}>
                  {agentLabel(id)}
                </option>
              ))}
            </select>
          </>
        )}

        <label className="block text-xs font-medium text-muted-foreground mb-1">Message</label>
        <textarea
          value={message}
          onChange={e => setMessage(e.target.value)}
          placeholder="Type a message…"
          rows={3}
          className="w-full p-2 text-sm border border-border rounded-md bg-background text-foreground resize-none mb-4"
        />

        {error && <p className="text-xs text-red-500 mb-3">{error}</p>}

        <button
          onClick={handleSubmit}
          disabled={!canSend || (showAgentPicker && !agentId)}
          className="w-full py-2 rounded-md text-sm font-medium bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-50 transition-opacity"
        >
          {sending ? 'Sending…' : 'Send'}
        </button>
      </div>
    </div>
  );
}
