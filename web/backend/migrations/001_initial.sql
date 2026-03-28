CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    google_id TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    photo_url TEXT,
    role TEXT NOT NULL DEFAULT 'member',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE agents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    name TEXT NOT NULL DEFAULT 'My Mac',
    api_key_hash TEXT NOT NULL,
    last_seen_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_agents_user_id ON agents(user_id);

CREATE TABLE conversations (
    phone TEXT NOT NULL,
    agent_id UUID NOT NULL REFERENCES agents(id),
    contact_name TEXT,
    last_message_at TIMESTAMPTZ,
    message_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (phone, agent_id)
);

CREATE TABLE messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guid TEXT NOT NULL,
    agent_id UUID NOT NULL REFERENCES agents(id),
    phone TEXT NOT NULL,
    text TEXT NOT NULL DEFAULT '',
    timestamp TIMESTAMPTZ NOT NULL,
    is_from_me BOOLEAN NOT NULL DEFAULT false,
    service TEXT NOT NULL DEFAULT 'iMessage',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(guid, agent_id)
);
CREATE INDEX idx_messages_phone_agent ON messages(phone, agent_id, timestamp DESC);
CREATE INDEX idx_messages_agent_id ON messages(agent_id);

CREATE TABLE forwarded_threads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone TEXT NOT NULL,
    agent_id UUID NOT NULL,
    forwarded_by_user_id UUID NOT NULL REFERENCES users(id),
    mode TEXT NOT NULL CHECK (mode IN ('fyi', 'action')),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (phone, agent_id) REFERENCES conversations(phone, agent_id)
);
CREATE INDEX idx_forwarded_threads_phone_agent ON forwarded_threads(phone, agent_id);

CREATE TABLE forwarded_thread_recipients (
    thread_id UUID NOT NULL REFERENCES forwarded_threads(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    has_read BOOLEAN NOT NULL DEFAULT false,
    read_at TIMESTAMPTZ,
    PRIMARY KEY (thread_id, user_id)
);
CREATE INDEX idx_ftr_user_id ON forwarded_thread_recipients(user_id);

CREATE TABLE outbound_commands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id UUID NOT NULL REFERENCES agents(id),
    phone TEXT NOT NULL,
    text TEXT NOT NULL,
    created_by_user_id UUID NOT NULL REFERENCES users(id),
    forwarded_thread_id UUID REFERENCES forwarded_threads(id),
    status TEXT NOT NULL DEFAULT 'pending',
    acked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_outbound_agent_status ON outbound_commands(agent_id, status);
