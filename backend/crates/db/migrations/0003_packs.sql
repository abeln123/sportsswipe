-- Game markets. Values are from the home team's side: moneyline and spread
-- grade the final margin (home minus away), total grades combined points.
-- They are attached to a stand-in "team" player row (position 'TEAM').
INSERT INTO stat_definitions (key, league, label, short_label, unit, espn_category, espn_key) VALUES
    ('moneyline', 'game', 'Moneyline',    'MONEYLINE', 'margin', NULL, '-'),
    ('spread',    'game', 'Spread',       'SPREAD',    'margin', NULL, '-'),
    ('total',     'game', 'Total points', 'TOTAL PTS', 'points', NULL, '-');

-- Card packs -------------------------------------------------------------------

CREATE TABLE pack_types (
    key             TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    tagline         TEXT NOT NULL,
    price           BIGINT NOT NULL CHECK (price >= 0),
    size            INT NOT NULL CHECK (size BETWEEN 1 AND 10),
    league          TEXT CHECK (league IN ('nfl', 'nba')),
    -- mixed: any line; game: moneyline/spread/total; position: players at
    -- `positions`; allstar: the top lines of each stat.
    kind            TEXT NOT NULL CHECK (kind IN ('mixed', 'game', 'position', 'allstar')),
    positions       TEXT[],
    -- Challenge packs pay `multiplier` x price when at least `target_pct`
    -- of the pack's picks are right.
    target_pct      INT CHECK (target_pct BETWEEN 1 AND 100),
    multiplier      INT CHECK (multiplier > 0),
    foil            TEXT NOT NULL,
    sort            INT NOT NULL,
    active          BOOLEAN NOT NULL DEFAULT true
);

INSERT INTO pack_types (key, name, tagline, price, size, league, kind, positions, target_pct, multiplier, foil, sort) VALUES
    ('starter', 'Starter Pack',  'Five lines from across tonight''s slate',         10, 5, NULL,  'mixed',    NULL,                      NULL, NULL, '2FA968,0F5132', 1),
    ('gameday', 'Game Day Pack', 'Moneylines, spreads and totals',                  10, 5, NULL,  'game',     NULL,                      NULL, NULL, 'E0B04A,7A4E0E', 2),
    ('allstar', 'All-Star Pack', 'The biggest lines from the league''s top players', 10, 5, NULL,  'allstar',  NULL,                      NULL, NULL, 'C9D6FF,5B4BC4', 3),
    ('qb',      'QB Pack',       'Quarterbacks only',                               10, 5, 'nfl', 'position', ARRAY['QB'],               NULL, NULL, '6FA8FF,1D3E8A', 4),
    ('rb',      'RB Pack',       'Running backs only',                              10, 5, 'nfl', 'position', ARRAY['RB','FB'],          NULL, NULL, 'FF8E6E,8A2A12', 5),
    ('wr',      'WR / TE Pack',  'Receivers and tight ends',                        10, 5, 'nfl', 'position', ARRAY['WR','TE'],          NULL, NULL, '7FE0D2,0E5A52', 6),
    ('guards',  'Guards Pack',   'Point and shooting guards',                       10, 5, 'nba', 'position', ARRAY['PG','SG','G'],      NULL, NULL, 'FFB86B,8A4A0E', 7),
    ('bigs',    'Bigs Pack',     'Forwards and centers',                            10, 5, 'nba', 'position', ARRAY['SF','PF','F','C'],  NULL, NULL, 'D7A6FF,5A1F8A', 8),
    ('triple',  '3x Pack',       'Hit 80% of the pack to win 3x the price',        100, 5, NULL,  'mixed',    NULL,                      80,   3,    'FFE8A3,B8862B', 9);

CREATE TABLE pack_purchases (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pack_key        TEXT NOT NULL REFERENCES pack_types(key),
    command_id      UUID NOT NULL,
    sport           TEXT NOT NULL DEFAULT 'all',
    price           BIGINT NOT NULL,
    size            INT NOT NULL,
    target_pct      INT,
    payout          BIGINT NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'won', 'lost', 'void')),
    credited        BIGINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    settled_at      TIMESTAMPTZ,
    UNIQUE (user_id, command_id)
);
CREATE INDEX pack_purchases_user_idx ON pack_purchases (user_id, created_at DESC);

CREATE TABLE pack_cards (
    purchase_id     UUID NOT NULL REFERENCES pack_purchases(id) ON DELETE CASCADE,
    position        INT NOT NULL,
    market_id       BIGINT NOT NULL REFERENCES markets(id),
    entry_id        UUID REFERENCES entries(id) ON DELETE SET NULL,
    picked_at       TIMESTAMPTZ,
    PRIMARY KEY (purchase_id, position),
    UNIQUE (purchase_id, market_id)
);
CREATE INDEX pack_cards_entry_idx ON pack_cards (entry_id);
CREATE INDEX pack_cards_market_idx ON pack_cards (market_id) WHERE entry_id IS NULL;
