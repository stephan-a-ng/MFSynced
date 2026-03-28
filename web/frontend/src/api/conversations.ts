import { api } from './client';

export interface Conversation {
  phone: string;
  agent_id: string;
  contact_name: string | null;
  last_message_at: string | null;
  message_count: number;
}

export interface Message {
  id: string;
  guid: string;
  phone: string;
  text: string;
  timestamp: string;
  is_from_me: boolean;
  service: string;
}

export const conversationsApi = {
  list: () => api.get<Conversation[]>('/conversations'),
  messages: (phone: string, agentId: string, limit = 100) =>
    api.get<Message[]>(`/conversations/${encodeURIComponent(phone)}/messages?agent_id=${agentId}&limit=${limit}`),
};
