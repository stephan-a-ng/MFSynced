import { api } from './client';
import type { Message } from './conversations';

export interface InboxThread {
  id: string;
  phone: string;
  agent_id: string;
  contact_name: string | null;
  mode: 'fyi' | 'action';
  note: string | null;
  forwarded_by_name: string;
  forwarded_by_picture: string | null;
  has_read: boolean;
  last_message_text: string | null;
  last_message_at: string | null;
  created_at: string;
}

export interface ThreadDetail {
  thread: InboxThread;
  messages: Message[];
}

export const inboxApi = {
  list: () => api.get<InboxThread[]>('/inbox'),
  get: (threadId: string) => api.get<ThreadDetail>(`/inbox/${threadId}`),
  reply: (threadId: string, text: string, attachmentType?: string, attachmentUrl?: string) =>
    api.post(`/inbox/${threadId}/reply`, { text, attachment_type: attachmentType, attachment_url: attachmentUrl }),
  react: (threadId: string, messageGuid: string, reactionType: string) =>
    api.post<{ status: string }>(`/inbox/${threadId}/react`, { message_guid: messageGuid, reaction_type: reactionType }),
  markRead: (threadId: string) => api.patch(`/inbox/${threadId}/read`, {}),
};
