-- Values for lines and stats are scaled integers in tenths (265.5 -> 2655).

-- Sports catalog ------------------------------------------------------------

CREATE TABLE teams (
    id              BIGSERIAL PRIMARY KEY,
    league          TEXT NOT NULL CHECK (league IN ('nfl', 'nba')),
    espn_id         TEXT NOT NULL,
    abbr            TEXT NOT NULL,
    name            TEXT NOT NULL,
    short_name      TEXT NOT NULL,
    location        TEXT NOT NULL DEFAULT '',
    color_primary   TEXT NOT NULL DEFAULT '1F2937',
    color_alt       TEXT NOT NULL DEFAULT 'FFFFFF',
    logo_url        TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (league, espn_id)
);

CREATE TABLE team_colorways (
    league          TEXT NOT NULL,
    abbr            TEXT NOT NULL,
    kind            TEXT NOT NULL DEFAULT 'home' CHECK (kind IN ('home', 'away', 'alt')),
    base            TEXT NOT NULL,
    trim            TEXT NOT NULL,
    accent          TEXT NOT NULL,
    number_fill     TEXT NOT NULL,
    number_outline  TEXT NOT NULL,
    PRIMARY KEY (league, abbr, kind)
);

CREATE TABLE players (
    id              BIGSERIAL PRIMARY KEY,
    league          TEXT NOT NULL CHECK (league IN ('nfl', 'nba')),
    espn_id         TEXT NOT NULL,
    team_id         BIGINT REFERENCES teams(id),
    full_name       TEXT NOT NULL,
    first_name      TEXT NOT NULL DEFAULT '',
    last_name       TEXT NOT NULL DEFAULT '',
    jersey          TEXT,
    position        TEXT,
    headshot_url    TEXT,
    active          BOOLEAN NOT NULL DEFAULT true,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (league, espn_id)
);
CREATE INDEX players_team_idx ON players (team_id) WHERE active;
CREATE INDEX players_name_idx ON players (lower(full_name));

CREATE TABLE games (
    id              BIGSERIAL PRIMARY KEY,
    league          TEXT NOT NULL CHECK (league IN ('nfl', 'nba')),
    espn_id         TEXT NOT NULL,
    season          INT NOT NULL,
    season_type     INT NOT NULL DEFAULT 2,
    week            INT,
    home_team_id    BIGINT NOT NULL REFERENCES teams(id),
    away_team_id    BIGINT NOT NULL REFERENCES teams(id),
    start_at        TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'scheduled'
                    CHECK (status IN ('scheduled', 'in', 'final', 'postponed', 'canceled')),
    status_detail   TEXT NOT NULL DEFAULT '',
    home_score      INT,
    away_score      INT,
    last_synced_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    stats_ingested_at TIMESTAMPTZ,
    UNIQUE (league, espn_id)
);
CREATE INDEX games_start_idx ON games (start_at);

CREATE TABLE stat_definitions (
    key             TEXT PRIMARY KEY,
    league          TEXT NOT NULL,
    label           TEXT NOT NULL,
    short_label     TEXT NOT NULL,
    unit            TEXT NOT NULL,
    espn_category   TEXT,
    espn_key        TEXT NOT NULL
);

CREATE TABLE player_game_stats (
    game_id         BIGINT NOT NULL REFERENCES games(id),
    player_id       BIGINT NOT NULL REFERENCES players(id),
    stat_key        TEXT NOT NULL REFERENCES stat_definitions(key),
    revision        INT NOT NULL DEFAULT 1,
    value_x10       INT NOT NULL,
    source          TEXT NOT NULL CHECK (source IN ('espn', 'admin_demo')),
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id, stat_key, revision)
);
CREATE INDEX pgs_player_stat_idx ON player_game_stats (player_id, stat_key);

-- Playable slate -------------------------------------------------------------

CREATE TABLE markets (
    id              BIGSERIAL PRIMARY KEY,
    game_id         BIGINT NOT NULL REFERENCES games(id),
    player_id       BIGINT NOT NULL REFERENCES players(id),
    stat_key        TEXT NOT NULL REFERENCES stat_definitions(key),
    lock_at         TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'locked', 'settled', 'void')),
    current_version INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (game_id, player_id, stat_key)
);
CREATE INDEX markets_open_idx ON markets (lock_at) WHERE status = 'open';

CREATE TABLE line_versions (
    market_id       BIGINT NOT NULL REFERENCES markets(id),
    version         INT NOT NULL,
    line_x10        INT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (market_id, version)
);

CREATE TABLE market_results (
    market_id       BIGINT NOT NULL REFERENCES markets(id),
    revision        INT NOT NULL,
    value_x10       INT NOT NULL,
    source          TEXT NOT NULL CHECK (source IN ('espn', 'admin_demo', 'dnp')),
    final           BOOLEAN NOT NULL DEFAULT true,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (market_id, revision)
);

CREATE TABLE market_pick_counts (
    market_id       BIGINT PRIMARY KEY REFERENCES markets(id),
    over_count      INT NOT NULL DEFAULT 0,
    under_count     INT NOT NULL DEFAULT 0
);

-- Identity -------------------------------------------------------------------

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    is_admin        BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email_idx ON users (lower(email));

CREATE TABLE sessions (
    token_hash      TEXT PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL
);

CREATE TABLE profiles (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    display_name    TEXT NOT NULL,
    handle          TEXT NOT NULL,
    tag             TEXT NOT NULL,
    bio             TEXT NOT NULL DEFAULT '',
    favorite_team_id BIGINT REFERENCES teams(id),
    visibility      TEXT NOT NULL DEFAULT 'friends' CHECK (visibility IN ('public', 'friends', 'private'))
);
CREATE UNIQUE INDEX profiles_handle_tag_idx ON profiles (upper(handle), tag);
CREATE INDEX profiles_handle_prefix_idx ON profiles (upper(handle) text_pattern_ops);

CREATE TABLE blocks (
    blocker         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker, blocked)
);

-- Game records ---------------------------------------------------------------

CREATE TABLE commands (
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    command_id      UUID NOT NULL,
    kind            TEXT NOT NULL,
    payload_hash    TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('accepted', 'rejected')),
    http_status     INT NOT NULL,
    result          JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, command_id)
);

CREATE TABLE entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind            TEXT NOT NULL CHECK (kind IN ('single', 'parlay')),
    command_id      UUID NOT NULL,
    stake           BIGINT NOT NULL CHECK (stake >= 0),
    rule_version    INT NOT NULL,
    potential_return BIGINT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'won', 'lost', 'void')),
    credited        BIGINT NOT NULL DEFAULT 0,
    single_market_id BIGINT REFERENCES markets(id),
    accepted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    settled_at      TIMESTAMPTZ,
    revealed_at     TIMESTAMPTZ
);
CREATE UNIQUE INDEX entries_one_single_per_market ON entries (user_id, single_market_id) WHERE single_market_id IS NOT NULL;
CREATE INDEX entries_user_history_idx ON entries (user_id, accepted_at DESC, id DESC);

CREATE TABLE entry_legs (
    id              BIGSERIAL PRIMARY KEY,
    entry_id        UUID NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    leg_no          INT NOT NULL,
    market_id       BIGINT NOT NULL REFERENCES markets(id),
    line_version    INT NOT NULL,
    line_x10        INT NOT NULL,
    side            TEXT NOT NULL CHECK (side IN ('over', 'under')),
    result          TEXT CHECK (result IN ('win', 'loss', 'push', 'void')),
    result_revision INT,
    UNIQUE (entry_id, leg_no)
);
CREATE INDEX entry_legs_market_idx ON entry_legs (market_id);

CREATE TABLE grade_events (
    entry_id        UUID NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    revision_key    TEXT NOT NULL,
    status          TEXT NOT NULL,
    credit          BIGINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (entry_id, revision_key)
);

-- Coin economy ---------------------------------------------------------------

CREATE TABLE coin_accounts (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    balance         BIGINT NOT NULL DEFAULT 0,
    version         BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE coin_ledger (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    delta           BIGINT NOT NULL,
    reason          TEXT NOT NULL,
    source_key      TEXT NOT NULL UNIQUE,
    entry_id        UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX coin_ledger_user_idx ON coin_ledger (user_id, id);

-- Collection -----------------------------------------------------------------

CREATE TABLE card_series (
    player_id       BIGINT PRIMARY KEY REFERENCES players(id),
    series          TEXT NOT NULL DEFAULT 'debut',
    card_no         SERIAL UNIQUE
);

CREATE TABLE mastery_events (
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    player_id       BIGINT NOT NULL REFERENCES players(id),
    market_id       BIGINT NOT NULL REFERENCES markets(id),
    entry_id        UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, player_id, market_id)
);

CREATE TABLE mastery_totals (
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    player_id       BIGINT NOT NULL REFERENCES players(id),
    correct_count   BIGINT NOT NULL DEFAULT 0,
    first_earned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, player_id)
);

CREATE TABLE cosmetic_skus (
    finish          TEXT PRIMARY KEY CHECK (finish IN ('bronze', 'silver', 'gold', 'diamond')),
    price           BIGINT NOT NULL,
    sort            INT NOT NULL
);

CREATE TABLE cosmetic_purchases (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    command_id      UUID NOT NULL,
    finish          TEXT NOT NULL REFERENCES cosmetic_skus(finish),
    price           BIGINT NOT NULL,
    player_id       BIGINT REFERENCES players(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, command_id)
);

CREATE TABLE equipped_finishes (
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    player_id       BIGINT NOT NULL REFERENCES players(id),
    finish          TEXT NOT NULL,
    purchase_id     UUID NOT NULL REFERENCES cosmetic_purchases(id),
    PRIMARY KEY (user_id, player_id)
);

-- Contests (practice, no cash) ----------------------------------------------

CREATE TABLE contests (
    id              BIGSERIAL PRIMARY KEY,
    week_start      DATE NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    zone            TEXT NOT NULL DEFAULT 'America/New_York',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE contest_days (
    id              BIGSERIAL PRIMARY KEY,
    contest_id      BIGINT NOT NULL REFERENCES contests(id),
    day_index       INT NOT NULL CHECK (day_index BETWEEN 0 AND 6),
    game_date       DATE NOT NULL,
    lock_at         TIMESTAMPTZ,
    slate_version   INT NOT NULL DEFAULT 0,
    tiebreak_label  TEXT,
    tiebreak_market_ids BIGINT[] NOT NULL DEFAULT '{}',
    tiebreak_actual_x10 INT,
    graded_at       TIMESTAMPTZ,
    UNIQUE (contest_id, day_index)
);

CREATE TABLE contest_questions (
    id              BIGSERIAL PRIMARY KEY,
    contest_day_id  BIGINT NOT NULL REFERENCES contest_days(id),
    q_no            INT NOT NULL,
    market_id       BIGINT NOT NULL REFERENCES markets(id),
    line_x10        INT NOT NULL,
    result          TEXT CHECK (result IN ('over', 'under', 'void')),
    UNIQUE (contest_day_id, q_no)
);

CREATE TABLE contest_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contest_day_id  BIGINT NOT NULL REFERENCES contest_days(id),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    command_id      UUID NOT NULL,
    slate_version   INT NOT NULL,
    tiebreak_x10    INT NOT NULL,
    submitted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    points          INT,
    tiebreak_error_x10 INT,
    UNIQUE (contest_day_id, user_id)
);

CREATE TABLE contest_answers (
    entry_id        UUID NOT NULL REFERENCES contest_entries(id) ON DELETE CASCADE,
    question_id     BIGINT NOT NULL REFERENCES contest_questions(id),
    side            TEXT NOT NULL CHECK (side IN ('over', 'under')),
    PRIMARY KEY (entry_id, question_id)
);

CREATE TABLE standings (
    contest_id      BIGINT NOT NULL REFERENCES contests(id),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    points          INT NOT NULL,
    days_counted    INT NOT NULL,
    tiebreak_error_x10 BIGINT NOT NULL,
    rank            INT NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (contest_id, user_id)
);

-- Social ---------------------------------------------------------------------

CREATE TABLE friend_requests (
    id              BIGSERIAL PRIMARY KEY,
    from_user       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (from_user, to_user)
);

CREATE TABLE friendships (
    user_a          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_b          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_a, user_b),
    CHECK (user_a < user_b)
);

CREATE TABLE threads (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            TEXT NOT NULL CHECK (kind IN ('dm', 'league')),
    dm_a            UUID REFERENCES users(id) ON DELETE CASCADE,
    dm_b            UUID REFERENCES users(id) ON DELETE CASCADE,
    last_seq        BIGINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (dm_a, dm_b)
);

CREATE TABLE leagues (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    owner_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    join_code       TEXT NOT NULL UNIQUE,
    capacity        INT NOT NULL DEFAULT 50,
    thread_id       UUID NOT NULL REFERENCES threads(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE league_members (
    league_id       UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (league_id, user_id)
);
CREATE INDEX league_members_user_idx ON league_members (user_id);

CREATE TABLE invites (
    id              BIGSERIAL PRIMARY KEY,
    token_hash      TEXT NOT NULL UNIQUE,
    league_id       UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
    creator_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    max_uses        INT NOT NULL DEFAULT 25,
    uses            INT NOT NULL DEFAULT 0,
    expires_at      TIMESTAMPTZ NOT NULL,
    revoked         BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE messages (
    thread_id       UUID NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    seq             BIGINT NOT NULL,
    sender_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_msg_id   UUID NOT NULL,
    body            TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (thread_id, seq),
    UNIQUE (sender_id, client_msg_id)
);

CREATE TABLE thread_reads (
    thread_id       UUID NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_read_seq   BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (thread_id, user_id)
);

-- Infrastructure ---------------------------------------------------------------

CREATE TABLE outbox (
    id              BIGSERIAL PRIMARY KEY,
    topic           TEXT NOT NULL,
    payload         JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at    TIMESTAMPTZ
);
CREATE INDEX outbox_pending_idx ON outbox (id) WHERE processed_at IS NULL;

CREATE TABLE jobs (
    id              BIGSERIAL PRIMARY KEY,
    kind            TEXT NOT NULL,
    dedupe_key      TEXT,
    payload         JSONB NOT NULL DEFAULT '{}',
    run_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempts        INT NOT NULL DEFAULT 0,
    locked_until    TIMESTAMPTZ,
    last_error      TEXT,
    done_at         TIMESTAMPTZ
);
CREATE INDEX jobs_ready_idx ON jobs (run_at) WHERE done_at IS NULL;
CREATE UNIQUE INDEX jobs_dedupe_idx ON jobs (dedupe_key) WHERE done_at IS NULL;

CREATE TABLE ingest_registry (
    provider        TEXT NOT NULL,
    resource        TEXT NOT NULL,
    checksum        TEXT NOT NULL,
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, resource)
);
