-- Prevent duplicate forwarded threads for the same conversation
-- Re-forwarding a conversation now updates the existing thread (upsert)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_forwarded_thread_phone_agent'
  ) THEN
    ALTER TABLE forwarded_threads ADD CONSTRAINT uq_forwarded_thread_phone_agent UNIQUE (phone, agent_id);
  END IF;
END $$;
