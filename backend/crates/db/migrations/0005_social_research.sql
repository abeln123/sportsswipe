ALTER TABLE invites ALTER COLUMN league_id DROP NOT NULL;
CREATE TABLE shared_items (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK (kind IN ('research','card','pick')),
 payload JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE messages ADD COLUMN share_id UUID REFERENCES shared_items(id) ON DELETE SET NULL;
