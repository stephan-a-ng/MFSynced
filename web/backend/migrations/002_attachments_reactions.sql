-- Attachment support for messages
ALTER TABLE messages ADD COLUMN attachment_type TEXT;       -- 'image', 'video', 'audio'
ALTER TABLE messages ADD COLUMN attachment_url TEXT;
ALTER TABLE messages ADD COLUMN attachment_mime_type TEXT;
ALTER TABLE messages ADD COLUMN attachment_filename TEXT;

-- Attachment support for outbound commands
ALTER TABLE outbound_commands ADD COLUMN attachment_type TEXT;
ALTER TABLE outbound_commands ADD COLUMN attachment_url TEXT;

-- Reactions table (iMessage tapbacks)
CREATE TABLE reactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_guid TEXT NOT NULL,
    agent_id UUID NOT NULL REFERENCES agents(id),
    reaction_type TEXT NOT NULL CHECK (reaction_type IN ('love', 'like', 'dislike', 'laugh', 'emphasize', 'question')),
    is_from_me BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(message_guid, agent_id, is_from_me)
);
CREATE INDEX idx_reactions_message ON reactions(message_guid, agent_id);
