import { api } from './client';

interface ForwardRequest {
  phone: string;
  agent_id: string;
  recipient_user_ids: string[];
  mode: 'fyi' | 'action';
  note?: string;
}

export const forwardApi = {
  forward: (req: ForwardRequest) => api.post<{ thread_id: string }>('/forward', req),
};
