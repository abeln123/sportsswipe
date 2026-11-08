-- Historical research is isolated from markets, grading, and account data.
CREATE TABLE analyst_source_cache (
    resource TEXT PRIMARY KEY,
    body JSONB NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE analyst_request_limits (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    minute TIMESTAMPTZ NOT NULL,
    requests INT NOT NULL DEFAULT 1,
    PRIMARY KEY(user_id, minute)
);
CREATE INDEX analyst_source_cache_age ON analyst_source_cache(fetched_at);
-- These can be ingested and researched without becoming playable markets.
INSERT INTO stat_definitions(key,league,label,short_label,unit,espn_category,espn_key) VALUES
('pass_int','nfl','Passing interceptions','INT','interceptions','passing','interceptions'),
('rush_td','nfl','Rushing touchdowns','RUSH TD','touchdowns','rushing','rushingTouchdowns'),
('rec_td','nfl','Receiving touchdowns','REC TD','touchdowns','receiving','receivingTouchdowns'),
('stl','nba','Steals','STL','steals',NULL,'steals'),
('blk','nba','Blocks','BLK','blocks',NULL,'blocks'),
('tov','nba','Turnovers','TO','turnovers',NULL,'turnovers')
ON CONFLICT(key) DO NOTHING;
