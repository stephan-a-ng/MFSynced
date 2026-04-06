import { useState, useRef, useEffect } from 'react';
import { Play, Pause } from 'lucide-react';
import type { Message } from '../api/conversations';

const REACTION_EMOJI: Record<string, string> = {
  love: '\u2764\uFE0F',
  like: '\uD83D\uDC4D',
  dislike: '\uD83D\uDC4E',
  laugh: '\uD83D\uDE02',
  emphasize: '\u203C\uFE0F',
  question: '\u2753',
};

const REACTION_TYPES = ['love', 'like', 'dislike', 'laugh', 'emphasize', 'question'] as const;

interface Props {
  message: Message;
  onReact?: (messageGuid: string, reactionType: string) => void;
}

export function MessageBubble({ message, onReact }: Props) {
  const time = new Date(message.timestamp).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const [showReactionPicker, setShowReactionPicker] = useState(false);
  const pickerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!showReactionPicker) return;
    const handleClick = (e: MouseEvent) => {
      if (pickerRef.current && !pickerRef.current.contains(e.target as Node)) {
        setShowReactionPicker(false);
      }
    };
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, [showReactionPicker]);

  const handleReact = (type: string) => {
    onReact?.(message.guid, type);
    setShowReactionPicker(false);
  };

  const fromMe = message.is_from_me;
  const hasAttachment = !!message.attachment_type;
  const hasText = !!message.text;
  const hasReactions = message.reactions.length > 0;

  return (
    <div className={`flex ${fromMe ? 'justify-end' : 'justify-start'} group`}>
      <div className="max-w-[70%] relative">
        {/* Reaction picker */}
        {showReactionPicker && (
          <div
            ref={pickerRef}
            className={`absolute bottom-full mb-1 z-10 flex gap-0.5 bg-background border border-border rounded-full px-1.5 py-1 shadow-lg ${
              fromMe ? 'right-0' : 'left-0'
            }`}
          >
            {REACTION_TYPES.map(type => (
              <button
                key={type}
                onClick={() => handleReact(type)}
                className="w-8 h-8 flex items-center justify-center rounded-full hover:bg-muted text-base transition-colors"
              >
                {REACTION_EMOJI[type]}
              </button>
            ))}
          </div>
        )}

        {/* Message bubble */}
        <div
          onClick={() => onReact && setShowReactionPicker(p => !p)}
          className={`overflow-hidden cursor-pointer ${
            fromMe
              ? hasAttachment && !hasText
                ? 'rounded-2xl rounded-br-md'
                : 'bg-primary text-primary-foreground rounded-2xl rounded-br-md'
              : hasAttachment && !hasText
                ? 'rounded-2xl rounded-bl-md'
                : 'bg-muted text-foreground rounded-2xl rounded-bl-md'
          }`}
        >
          {/* Attachment content */}
          {hasAttachment && <AttachmentContent message={message} />}

          {/* Text content */}
          {hasText && (
            <p className={`px-4 py-2 text-sm leading-relaxed ${hasAttachment ? (fromMe ? 'bg-primary text-primary-foreground' : 'bg-muted text-foreground') : ''}`}>
              {message.text}
            </p>
          )}

          {/* Attachment-only (no text) needs background */}
          {hasAttachment && !hasText && !['image', 'video'].includes(message.attachment_type!) && (
            <span />
          )}
        </div>

        {/* Reactions */}
        {hasReactions && (
          <div className={`flex gap-0.5 mt-0.5 ${fromMe ? 'justify-end' : 'justify-start'}`}>
            {message.reactions.map((r, i) => (
              <span
                key={i}
                className="inline-flex items-center justify-center w-6 h-6 rounded-full bg-muted border border-border text-xs"
                title={`${r.is_from_me ? 'You' : 'Them'}: ${r.reaction_type}`}
              >
                {REACTION_EMOJI[r.reaction_type] || r.reaction_type}
              </span>
            ))}
          </div>
        )}

        {/* Timestamp */}
        <p className={`text-xs text-muted-foreground mt-1 ${fromMe ? 'text-right' : 'text-left'}`}>
          {time}
        </p>
      </div>
    </div>
  );
}

function AttachmentContent({ message }: { message: Message }) {
  const apiBase = import.meta.env.VITE_API_URL || '';
  const url = message.attachment_url?.startsWith('http')
    ? message.attachment_url
    : `${apiBase}${message.attachment_url}`;

  switch (message.attachment_type) {
    case 'image':
      return (
        <img
          src={url}
          alt={message.attachment_filename || 'Image'}
          className="max-w-full max-h-80 object-contain"
          loading="lazy"
        />
      );
    case 'video':
      return (
        <video
          src={url}
          controls
          preload="metadata"
          className="max-w-full max-h-80"
        >
          <track kind="captions" />
        </video>
      );
    case 'audio':
      return <VoiceMessage url={url} />;
    default:
      return (
        <a
          href={url}
          target="_blank"
          rel="noopener noreferrer"
          className="px-4 py-2 text-sm underline block"
        >
          {message.attachment_filename || 'Attachment'}
        </a>
      );
  }
}

function VoiceMessage({ url }: { url: string }) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const [playing, setPlaying] = useState(false);
  const [progress, setProgress] = useState(0);
  const [duration, setDuration] = useState(0);

  const toggle = (e: React.MouseEvent) => {
    e.stopPropagation();
    const audio = audioRef.current;
    if (!audio) return;
    if (playing) {
      audio.pause();
    } else {
      audio.play();
    }
  };

  const formatTime = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, '0')}`;
  };

  return (
    <div className="flex items-center gap-3 px-4 py-3 min-w-[200px] bg-muted rounded-2xl">
      <audio
        ref={audioRef}
        src={url}
        preload="metadata"
        onLoadedMetadata={() => setDuration(audioRef.current?.duration || 0)}
        onTimeUpdate={() => {
          const a = audioRef.current;
          if (a && a.duration) setProgress(a.currentTime / a.duration);
        }}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => { setPlaying(false); setProgress(0); }}
      />
      <button
        onClick={toggle}
        className="w-8 h-8 rounded-full bg-primary text-primary-foreground flex items-center justify-center flex-shrink-0"
      >
        {playing ? <Pause size={14} /> : <Play size={14} className="ml-0.5" />}
      </button>
      <div className="flex-1 min-w-0">
        {/* Progress bar */}
        <div className="h-1.5 bg-border rounded-full overflow-hidden">
          <div
            className="h-full bg-primary rounded-full transition-all duration-100"
            style={{ width: `${progress * 100}%` }}
          />
        </div>
        <p className="text-xs text-muted-foreground mt-1">
          {duration > 0 ? formatTime(playing ? (audioRef.current?.currentTime || 0) : duration) : '0:00'}
        </p>
      </div>
    </div>
  );
}
