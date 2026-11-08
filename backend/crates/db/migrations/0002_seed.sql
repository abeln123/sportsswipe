INSERT INTO stat_definitions (key, league, label, short_label, unit, espn_category, espn_key) VALUES
    ('pass_yds', 'nfl', 'Passing yards',   'PASS YDS', 'yards',      'passing',   'passingYards'),
    ('pass_td',  'nfl', 'Passing TDs',     'PASS TD',  'touchdowns', 'passing',   'passingTouchdowns'),
    ('rush_yds', 'nfl', 'Rushing yards',   'RUSH YDS', 'yards',      'rushing',   'rushingYards'),
    ('rec_yds',  'nfl', 'Receiving yards', 'REC YDS',  'yards',      'receiving', 'receivingYards'),
    ('rec',      'nfl', 'Receptions',      'REC',      'receptions', 'receiving', 'receptions'),
    ('pts',      'nba', 'Points',          'POINTS',   'points',     NULL,        'points'),
    ('reb',      'nba', 'Rebounds',        'REBOUNDS', 'rebounds',   NULL,        'rebounds'),
    ('ast',      'nba', 'Assists',         'ASSISTS',  'assists',    NULL,        'assists'),
    ('fg3m',     'nba', '3-pointers',      '3-POINTERS', 'threes',   NULL,        'threePointFieldGoalsMade-threePointFieldGoalsAttempted');

INSERT INTO cosmetic_skus (finish, price, sort) VALUES
    ('bronze', 250, 1),
    ('silver', 1250, 2),
    ('gold', 6250, 3),
    ('diamond', 31250, 4);

-- Hand-tuned home colorways for teams featured in demos. Every other team
-- uses the colorway derived from ESPN's primary and alternate colors.
INSERT INTO team_colorways (league, abbr, base, trim, accent, number_fill, number_outline) VALUES
    ('nba', 'BOS', '007A33', 'FFFFFF', 'BEE8CB', 'FFFFFF', 'FFFFFF'),
    ('nba', 'GS',  '1D428A', 'FFC72C', 'FFC72C', 'FFC72C', 'FFC72C'),
    ('nba', 'MIN', '0C2340', '78BE20', '9CC5E8', '9CC5E8', '78BE20'),
    ('nba', 'LAL', '552583', 'FDB927', 'FDB927', 'FDB927', 'FFFFFF'),
    ('nba', 'DEN', '0E2240', 'FEC524', '8B2131', 'FEC524', 'FEC524'),
    ('nba', 'NY',  '006BB6', 'F58426', 'BEC0C2', 'FFFFFF', 'F58426'),
    ('nba', 'OKC', '007AC1', 'EF3B24', 'FDBB30', 'FFFFFF', 'EF3B24'),
    ('nfl', 'BUF', '00338D', 'C60C30', 'FFFFFF', 'FFFFFF', 'C60C30'),
    ('nfl', 'MIN', '4F2683', 'FFC62F', 'FFFFFF', 'FFFFFF', 'FFC62F'),
    ('nfl', 'KC',  'E31837', 'FFB81C', 'FFFFFF', 'FFFFFF', 'FFB81C'),
    ('nfl', 'DAL', '003594', '869397', 'FFFFFF', 'FFFFFF', '869397'),
    ('nfl', 'PHI', '004C54', 'A5ACAF', 'FFFFFF', 'FFFFFF', 'A5ACAF'),
    ('nfl', 'MIA', '008E97', 'FC4C02', 'FFFFFF', 'FFFFFF', 'FC4C02'),
    ('nfl', 'BAL', '241773', '9E7C0C', 'FFFFFF', 'FFFFFF', '9E7C0C');
