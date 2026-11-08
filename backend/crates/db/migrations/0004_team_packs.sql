-- Team packs stay in sync with the imported team catalog.
ALTER TABLE pack_types ADD COLUMN team_id BIGINT REFERENCES teams(id);
CREATE UNIQUE INDEX pack_types_team_idx ON pack_types(team_id) WHERE team_id IS NOT NULL;
CREATE INDEX pack_cards_all_market_idx ON pack_cards(market_id);

CREATE FUNCTION sync_team_pack() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pack_types (key, name, tagline, price, size, league, kind, foil, sort, team_id)
  VALUES ('team-' || NEW.id, NEW.short_name || ' Pack',
          NEW.name || ' · All positions + game lines', 50, 5, NEW.league, 'mixed',
          NEW.color_primary || ',' || NEW.color_alt, 100, NEW.id)
  ON CONFLICT (key) DO UPDATE SET name = EXCLUDED.name, tagline = EXCLUDED.tagline,
    league = EXCLUDED.league, foil = EXCLUDED.foil;
  RETURN NEW;
END;
$$;
CREATE TRIGGER teams_sync_pack AFTER INSERT OR UPDATE ON teams
FOR EACH ROW EXECUTE FUNCTION sync_team_pack();
INSERT INTO pack_types (key, name, tagline, price, size, league, kind, foil, sort, team_id)
SELECT 'team-' || id, short_name || ' Pack', name || ' · All positions + game lines',
       50, 5, league, 'mixed', color_primary || ',' || color_alt, 100, id FROM teams;
