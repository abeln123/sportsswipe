CREATE TABLE presentation_cards (
 position INT PRIMARY KEY CHECK(position BETWEEN 1 AND 5), player_id BIGINT UNIQUE NOT NULL REFERENCES players(id)
);
CREATE TABLE presentation_entitlements (
 user_id UUID NOT NULL REFERENCES users(id), player_id BIGINT NOT NULL REFERENCES players(id),
 season INT NOT NULL, calls INT NOT NULL DEFAULT 400 CHECK(calls=400), created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,player_id)
);
ALTER TABLE diamond_collectibles ADD COLUMN qualification_source TEXT NOT NULL DEFAULT 'earned'
 CHECK(qualification_source IN ('earned','admin_presentation'));
CREATE TABLE head_to_heads (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), creator_id UUID NOT NULL REFERENCES users(id),
 opponent_id UUID REFERENCES users(id), token_hash TEXT NOT NULL UNIQUE, token TEXT NOT NULL,
 lock_at TIMESTAMPTZ NOT NULL, tie_game_id BIGINT NOT NULL REFERENCES games(id),
 shared_market_id BIGINT NOT NULL REFERENCES markets(id), thread_id UUID REFERENCES threads(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), accepted_at TIMESTAMPTZ,
 CHECK(opponent_id IS NULL OR opponent_id<>creator_id)
);
CREATE TABLE head_to_head_questions (
 challenge_id UUID NOT NULL REFERENCES head_to_heads(id), position INT NOT NULL CHECK(position BETWEEN 1 AND 10),
 market_id BIGINT NOT NULL REFERENCES markets(id), line_version INT NOT NULL, line_x10 INT NOT NULL,
 PRIMARY KEY(challenge_id,position),UNIQUE(challenge_id,market_id)
);
CREATE TABLE head_to_head_entries (
 challenge_id UUID NOT NULL REFERENCES head_to_heads(id),user_id UUID NOT NULL REFERENCES users(id),
 answers JSONB NOT NULL, tiebreak INT NOT NULL CHECK(tiebreak BETWEEN 0 AND 2000),
 submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),PRIMARY KEY(challenge_id,user_id)
);
ALTER TABLE shared_items DROP CONSTRAINT shared_items_kind_check;
ALTER TABLE shared_items ADD CHECK(kind IN ('research','card','pick','head_to_head'));
CREATE INDEX head_to_heads_creator ON head_to_heads(creator_id,created_at DESC);
CREATE INDEX head_to_heads_opponent ON head_to_heads(opponent_id,created_at DESC);
ALTER TABLE head_to_heads ADD COLUMN command_id UUID NOT NULL;
ALTER TABLE head_to_heads ADD UNIQUE(creator_id,command_id);
