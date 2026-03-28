import { useState } from 'react';
import { Send } from 'lucide-react';

interface Props {
  onSend: (text: string) => Promise<void>;
}

export function ReplyBox({ onSend }: Props) {
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);

  const handleSend = async () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setSending(true);
    try {
      await onSend(trimmed);
      setText('');
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="border-t border-border p-3 flex gap-2">
      <input
        type="text"
        value={text}
        onChange={e => setText(e.target.value)}
        onKeyDown={e => e.key === 'Enter' && !e.shiftKey && handleSend()}
        placeholder="Type a reply..."
        className="flex-1 px-4 py-2 text-sm rounded-full border border-border bg-background text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
        disabled={sending}
      />
      <button
        onClick={handleSend}
        disabled={!text.trim() || sending}
        className="w-9 h-9 rounded-full bg-primary text-primary-foreground flex items-center justify-center disabled:opacity-50 transition-opacity"
      >
        <Send size={16} />
      </button>
    </div>
  );
}
