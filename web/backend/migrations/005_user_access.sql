-- Link local `users` rows to user-access identities (Pattern A migration,
-- see user-access/docs/INTEGRATION.md §7). google_id becomes optional
-- since new users are created from user-access claims, not Google OAuth.

ALTER TABLE users ADD COLUMN IF NOT EXISTS user_access_sub TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_user_access_sub ON users (user_access_sub) WHERE user_access_sub IS NOT NULL;
ALTER TABLE users ALTER COLUMN google_id DROP NOT NULL;
