import { api } from './client';

export interface SendMessageRequest {
  phone: string;
  text: string;
  agent_id?: string;
  attachment_type?: string;
  attachment_url?: string;
  idempotency_key: string;
}

export interface SendMessageResponse {
  command_id: string;
  agent_id: string;
  phone: string;
  status: string;
  created: string;
}

// status is "pending" | "sent" | "delivered" | "failed: <reason>"
export interface MessageStatus {
  id: string;
  phone: string;
  agent_id: string;
  text: string;
  status: string;
  created_at: string;
  acked_at: string | null;
  agent_last_seen_at: string | null;
}

export const messagesApi = {
  send: (req: SendMessageRequest) => api.post<SendMessageResponse>('/messages/send', req),
  getStatus: (commandId: string) => api.get<MessageStatus>(`/messages/${commandId}`),
};
