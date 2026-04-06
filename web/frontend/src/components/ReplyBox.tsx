import { useState, useRef } from 'react';
import { Send, Paperclip, Mic, X, Image, Film } from 'lucide-react';
import { api } from '../api/client';

interface Props {
  onSend: (text: string, attachmentType?: string, attachmentUrl?: string) => Promise<void>;
}

type AttachmentType = 'image' | 'video' | 'audio';

interface PendingAttachment {
  type: AttachmentType;
  url: string;
  filename: string;
  previewUrl?: string;
}

export function ReplyBox({ onSend }: Props) {
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const [attachment, setAttachment] = useState<PendingAttachment | null>(null);
  const [uploading, setUploading] = useState(false);
  const [recording, setRecording] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);

  const handleSend = async () => {
    const trimmed = text.trim();
    if (!trimmed && !attachment) return;
    setSending(true);
    try {
      await onSend(trimmed, attachment?.type, attachment?.url);
      setText('');
      setAttachment(null);
    } finally {
      setSending(false);
    }
  };

  const handleFileSelect = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    let type: AttachmentType;
    if (file.type.startsWith('image/')) type = 'image';
    else if (file.type.startsWith('video/')) type = 'video';
    else if (file.type.startsWith('audio/')) type = 'audio';
    else return; // unsupported type

    setUploading(true);
    try {
      const { url } = await api.upload(file);
      const previewUrl = type === 'image' ? URL.createObjectURL(file) : undefined;
      setAttachment({ type, url, filename: file.name, previewUrl });
    } catch (err) {
      console.error('Upload failed:', err);
    } finally {
      setUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  const startRecording = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream);
      chunksRef.current = [];

      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      recorder.onstop = async () => {
        stream.getTracks().forEach(t => t.stop());
        const blob = new Blob(chunksRef.current, { type: recorder.mimeType });
        const ext = recorder.mimeType.includes('webm') ? '.webm' : '.m4a';
        const file = new File([blob], `voice${ext}`, { type: recorder.mimeType });

        setUploading(true);
        try {
          const { url } = await api.upload(file);
          setAttachment({ type: 'audio', url, filename: file.name });
        } catch (err) {
          console.error('Upload failed:', err);
        } finally {
          setUploading(false);
        }
      };

      recorder.start();
      mediaRecorderRef.current = recorder;
      setRecording(true);
    } catch (err) {
      console.error('Microphone access denied:', err);
    }
  };

  const stopRecording = () => {
    mediaRecorderRef.current?.stop();
    mediaRecorderRef.current = null;
    setRecording(false);
  };

  const removeAttachment = () => {
    if (attachment?.previewUrl) URL.revokeObjectURL(attachment.previewUrl);
    setAttachment(null);
  };

  const canSend = (text.trim() || attachment) && !uploading && !recording;

  return (
    <div className="border-t border-border">
      {/* Attachment preview */}
      {attachment && (
        <div className="px-3 pt-3 flex items-center gap-2">
          <div className="flex items-center gap-2 px-3 py-1.5 bg-muted rounded-lg text-sm">
            {attachment.type === 'image' && attachment.previewUrl ? (
              <img src={attachment.previewUrl} alt="preview" className="w-10 h-10 object-cover rounded" />
            ) : attachment.type === 'image' ? (
              <Image size={16} className="text-muted-foreground" />
            ) : attachment.type === 'video' ? (
              <Film size={16} className="text-muted-foreground" />
            ) : (
              <Mic size={16} className="text-muted-foreground" />
            )}
            <span className="text-muted-foreground truncate max-w-[200px]">{attachment.filename}</span>
            <button onClick={removeAttachment} className="text-muted-foreground hover:text-foreground">
              <X size={14} />
            </button>
          </div>
        </div>
      )}

      {/* Upload progress */}
      {uploading && (
        <div className="px-3 pt-2">
          <div className="h-1 bg-muted rounded-full overflow-hidden">
            <div className="h-full bg-primary rounded-full animate-pulse w-2/3" />
          </div>
        </div>
      )}

      {/* Input row */}
      <div className="p-3 flex items-center gap-2">
        {/* File picker */}
        <input
          ref={fileInputRef}
          type="file"
          accept="image/*,video/*,audio/*"
          onChange={handleFileSelect}
          className="hidden"
        />
        <button
          onClick={() => fileInputRef.current?.click()}
          disabled={uploading || recording}
          className="w-9 h-9 rounded-full flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-muted disabled:opacity-50 transition-colors"
          title="Attach file"
        >
          <Paperclip size={18} />
        </button>

        {/* Voice recording */}
        <button
          onClick={recording ? stopRecording : startRecording}
          disabled={uploading}
          className={`w-9 h-9 rounded-full flex items-center justify-center transition-colors ${
            recording
              ? 'bg-red-500 text-white animate-pulse'
              : 'text-muted-foreground hover:text-foreground hover:bg-muted disabled:opacity-50'
          }`}
          title={recording ? 'Stop recording' : 'Record voice message'}
        >
          <Mic size={18} />
        </button>

        {/* Text input */}
        <input
          type="text"
          value={text}
          onChange={e => setText(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && !e.shiftKey && canSend && handleSend()}
          placeholder={recording ? 'Recording...' : 'Type a reply...'}
          className="flex-1 px-4 py-2 text-sm rounded-full border border-border bg-background text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
          disabled={sending || recording}
        />

        {/* Send button */}
        <button
          onClick={handleSend}
          disabled={!canSend || sending}
          className="w-9 h-9 rounded-full bg-primary text-primary-foreground flex items-center justify-center disabled:opacity-50 transition-opacity"
        >
          <Send size={16} />
        </button>
      </div>
    </div>
  );
}
