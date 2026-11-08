-- Rehearsal resets are real reverse transactions; original sales stay verifiable.
CREATE TABLE presentation_sale_resets (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 sale_id UUID NOT NULL UNIQUE REFERENCES collectible_sales(id),
 transaction_bytes TEXT NOT NULL,
 block_height BIGINT NOT NULL,
 signature TEXT UNIQUE,
 status TEXT NOT NULL CHECK(status IN ('signing','submitted','confirmed','expired')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 confirmed_at TIMESTAMPTZ
);
