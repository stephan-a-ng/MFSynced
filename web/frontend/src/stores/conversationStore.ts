import { create } from 'zustand';
import type { Conversation } from '../api/conversations';
import { conversationsApi } from '../api/conversations';

interface ConversationState {
  conversations: Conversation[];
  loading: boolean;
  fetchConversations: () => Promise<void>;
}

export const useConversationStore = create<ConversationState>((set) => ({
  conversations: [],
  loading: true,
  fetchConversations: async () => {
    set({ loading: true });
    try {
      const conversations = await conversationsApi.list();
      set({ conversations, loading: false });
    } catch {
      set({ loading: false });
    }
  },
}));
