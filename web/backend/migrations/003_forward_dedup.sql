-- Prevent duplicate forwarded threads for the same conversation
-- Re-forwarding a conversation now updates the existing thread (upsert)
ALTER TABLE forwarded_threads ADD CONSTRAINT uq_forwarded_thread_phone_agent UNIQUE (phone, agent_id);
