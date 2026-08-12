-- Idempotency support for the send API: same (user, key) never double-queues.
ALTER TABLE outbound_commands ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_outbound_idempotency ON outbound_commands (created_by_user_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
