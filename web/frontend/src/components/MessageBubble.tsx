import type { Message } from '../api/conversations';

export function MessageBubble({ message }: { message: Message }) {
  const time = new Date(message.timestamp).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

  return (
    <div className={`flex ${message.is_from_me ? 'justify-end' : 'justify-start'}`}>
      <div className="max-w-[70%]">
        <div
          className={`px-4 py-2 text-sm leading-relaxed ${
            message.is_from_me
              ? 'bg-primary text-primary-foreground rounded-2xl rounded-br-md'
              : 'bg-muted text-foreground rounded-2xl rounded-bl-md'
          }`}
        >
          {message.text}
        </div>
        <p className={`text-xs text-muted-foreground mt-1 ${message.is_from_me ? 'text-right' : 'text-left'}`}>
          {time}
        </p>
      </div>
    </div>
  );
}
