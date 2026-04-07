import { create } from 'zustand';
import type { InboxThread } from '../api/inbox';
import { inboxApi } from '../api/inbox';

interface InboxState {
  threads: InboxThread[];
  loading: boolean;
  fetchInbox: () => Promise<void>;
  archiveThread: (threadId: string) => Promise<void>;
}

export const useInboxStore = create<InboxState>((set, get) => ({
  threads: [],
  loading: true,
  fetchInbox: async () => {
    set({ loading: true });
    try {
      const threads = await inboxApi.list();
      set({ threads, loading: false });
    } catch {
      set({ loading: false });
    }
  },
  archiveThread: async (threadId: string) => {
    await inboxApi.archive(threadId);
    // Optimistically remove from list
    set({ threads: get().threads.filter(t => t.id !== threadId) });
  },
}));
