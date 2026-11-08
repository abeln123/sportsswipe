-- Mastery remains the achievement. These rows describe a separate devnet asset.
ALTER TABLE players ADD COLUMN collectible_demo BOOLEAN NOT NULL DEFAULT false;
CREATE TABLE collectible_wallets (
 user_id UUID PRIMARY KEY REFERENCES users(id), address TEXT NOT NULL UNIQUE,
 challenge TEXT, challenge_expires TIMESTAMPTZ, verified BOOLEAN NOT NULL DEFAULT false
);
CREATE TABLE collectible_sessions (
 token_hash TEXT PRIMARY KEY, user_id UUID NOT NULL REFERENCES users(id),
 purpose TEXT NOT NULL CHECK(purpose IN ('handoff','session')), expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE diamond_collectibles (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), edition BIGSERIAL UNIQUE,
 earner_id UUID NOT NULL REFERENCES users(id), player_id BIGINT NOT NULL REFERENCES players(id),
 earner_name TEXT NOT NULL, athlete_name TEXT NOT NULL, season INT NOT NULL,
 earned_calls INT NOT NULL CHECK(earned_calls>=400), asset_address TEXT UNIQUE,
 mint_transaction TEXT, mint_signature TEXT UNIQUE, mint_block_height BIGINT,
 minted_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(earner_id,player_id)
);
CREATE TABLE collectible_sales (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), collectible_id UUID NOT NULL REFERENCES diamond_collectibles(id),
 seller_id UUID NOT NULL REFERENCES users(id), buyer_id UUID REFERENCES users(id),
 seller_wallet TEXT NOT NULL, buyer_wallet TEXT, lamports BIGINT NOT NULL CHECK(lamports BETWEEN 1 AND 10000000000),
 transaction_bytes TEXT, block_height BIGINT, signature TEXT UNIQUE,
 status TEXT NOT NULL CHECK(status IN ('listed','signing','submitted','confirmed','cancelled','expired')) DEFAULT 'listed',
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), confirmed_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX collectible_one_live_sale ON collectible_sales(collectible_id) WHERE status IN ('listed','signing','submitted');
