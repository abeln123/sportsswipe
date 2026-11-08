//! Teams, players, games and box scores normalized from ESPN.

use anyhow::Result;
use sqlx::{PgPool, Postgres, Transaction};
use ss_espn::{BoxScore, League, RosterPlayer, ScoreboardGame, Team};
use std::collections::{HashMap, HashSet};

pub async fn upsert_team(pool: &PgPool, league: League, t: &Team) -> Result<i64> {
    let id: i64 = sqlx::query_scalar(
        r#"INSERT INTO teams (league, espn_id, abbr, name, short_name, location, color_primary, color_alt, logo_url, updated_at)
           VALUES ($1,$2,$3,$4,$5,$6,upper($7),upper($8),$9, now())
           ON CONFLICT (league, espn_id) DO UPDATE SET
             abbr = EXCLUDED.abbr, name = EXCLUDED.name, short_name = EXCLUDED.short_name,
             location = EXCLUDED.location, color_primary = EXCLUDED.color_primary,
             color_alt = EXCLUDED.color_alt, logo_url = EXCLUDED.logo_url, updated_at = now()
           RETURNING id"#,
    )
    .bind(league.as_str())
    .bind(&t.espn_id)
    .bind(&t.abbr)
    .bind(&t.name)
    .bind(&t.short_name)
    .bind(&t.location)
    .bind(&t.color)
    .bind(&t.alternate_color)
    .bind(&t.logo_url)
    .fetch_one(pool)
    .await?;
    Ok(id)
}

pub async fn team_ids(pool: &PgPool, league: League) -> Result<Vec<(i64, String)>> {
    Ok(
        sqlx::query_as("SELECT id, espn_id FROM teams WHERE league = $1 ORDER BY id")
            .bind(league.as_str())
            .fetch_all(pool)
            .await?,
    )
}

/// Replaces a team's active roster. Players missing from the feed become
/// inactive but keep their history.
pub async fn sync_roster(
    pool: &PgPool,
    league: League,
    team_id: i64,
    players: &[RosterPlayer],
) -> Result<usize> {
    let mut tx = pool.begin().await?;
    let mut seen = Vec::with_capacity(players.len());
    for p in players {
        sqlx::query(
            r#"INSERT INTO players (league, espn_id, team_id, full_name, first_name, last_name, jersey, position, headshot_url, active, updated_at)
               VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,true,now())
               ON CONFLICT (league, espn_id) DO UPDATE SET
                 team_id = EXCLUDED.team_id, full_name = EXCLUDED.full_name, first_name = EXCLUDED.first_name,
                 last_name = EXCLUDED.last_name, jersey = EXCLUDED.jersey, position = EXCLUDED.position,
                 headshot_url = EXCLUDED.headshot_url, active = true, updated_at = now()"#,
        )
        .bind(league.as_str())
        .bind(&p.espn_id)
        .bind(team_id)
        .bind(&p.full_name)
        .bind(&p.first_name)
        .bind(&p.last_name)
        .bind(&p.jersey)
        .bind(&p.position)
        .bind(&p.headshot_url)
        .execute(&mut *tx)
        .await?;
        seen.push(p.espn_id.clone());
    }
    sqlx::query(
        "UPDATE players SET active = false WHERE team_id = $1 AND league = $2 AND NOT (espn_id = ANY($3)) AND position IS DISTINCT FROM 'TEAM'",
    )
        .bind(team_id)
        .bind(league.as_str())
        .bind(&seen)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(seen.len())
}

pub struct GameUpsert {
    pub id: i64,
    pub status: String,
    pub stats_ingested: bool,
}

pub async fn upsert_game(
    pool: &PgPool,
    league: League,
    g: &ScoreboardGame,
) -> Result<Option<GameUpsert>> {
    let row: Option<(i64, String, bool)> = sqlx::query_as(
        r#"WITH h AS (SELECT id FROM teams WHERE league = $1 AND espn_id = $2),
                a AS (SELECT id FROM teams WHERE league = $1 AND espn_id = $3)
           INSERT INTO games (league, espn_id, season, season_type, week, home_team_id, away_team_id, start_at, status, status_detail, home_score, away_score, last_synced_at)
           SELECT $1, $4, $5, $6, $7, h.id, a.id, $8, $9, $10, $11, $12, now() FROM h, a
           ON CONFLICT (league, espn_id) DO UPDATE SET
             season = EXCLUDED.season, season_type = EXCLUDED.season_type, week = EXCLUDED.week,
             start_at = EXCLUDED.start_at, status = EXCLUDED.status, status_detail = EXCLUDED.status_detail,
             home_score = EXCLUDED.home_score, away_score = EXCLUDED.away_score, last_synced_at = now()
           RETURNING id, status, stats_ingested_at IS NOT NULL"#,
    )
    .bind(league.as_str())
    .bind(&g.home.team_espn_id)
    .bind(&g.away.team_espn_id)
    .bind(&g.espn_id)
    .bind(g.season)
    .bind(g.season_type)
    .bind(g.week)
    .bind(g.start_at)
    .bind(g.status)
    .bind(&g.status_detail)
    .bind(g.home.score)
    .bind(g.away.score)
    .fetch_optional(pool)
    .await?;
    if let Some((id, status, _)) = &row {
        // Moving the start time also moves open market locks.
        sqlx::query("UPDATE markets SET lock_at = $2 WHERE game_id = $1 AND status = 'open'")
            .bind(id)
            .bind(g.start_at)
            .execute(pool)
            .await?;
        if status == "postponed" || status == "canceled" {
            void_game_markets(pool, *id).await?;
        }
    }
    Ok(row.map(|(id, status, stats_ingested)| GameUpsert {
        id,
        status,
        stats_ingested,
    }))
}

async fn void_game_markets(pool: &PgPool, game_id: i64) -> Result<()> {
    let ids: Vec<i64> = sqlx::query_scalar(
        "SELECT id FROM markets WHERE game_id = $1 AND status IN ('open','locked')",
    )
    .bind(game_id)
    .fetch_all(pool)
    .await?;
    for id in ids {
        insert_result_if_changed(pool, id, 0, "dnp").await?;
    }
    Ok(())
}

#[derive(sqlx::FromRow)]
struct StatDef {
    key: String,
    espn_category: Option<String>,
    espn_key: String,
}

/// Stores a final box score and writes a market result for every market on
/// the game. Returns the market ids whose result changed.
pub async fn record_box_score(
    pool: &PgPool,
    game_id: i64,
    league: League,
    box_score: &BoxScore,
) -> Result<Vec<i64>> {
    let defs: Vec<StatDef> = sqlx::query_as(
        "SELECT key, espn_category, espn_key FROM stat_definitions WHERE league = $1",
    )
    .bind(league.as_str())
    .fetch_all(pool)
    .await?;
    let players: HashMap<String, i64> =
        sqlx::query_as::<_, (String, i64)>("SELECT espn_id, id FROM players WHERE league = $1")
            .bind(league.as_str())
            .fetch_all(pool)
            .await?
            .into_iter()
            .collect();

    let mut values: HashMap<(i64, String), i32> = HashMap::new();
    let mut appeared: HashSet<i64> = HashSet::new();
    for s in &box_score.stats {
        let Some(&pid) = players.get(&s.athlete_espn_id) else {
            continue;
        };
        appeared.insert(pid);
        for d in &defs {
            if d.espn_key == s.key && (d.espn_category.is_none() || d.espn_category == s.category) {
                values.insert((pid, d.key.clone()), s.value_x10);
            }
        }
    }

    let mut tx = pool.begin().await?;
    // Keep stats, results and their durable grading jobs in one commit.
    sqlx::query("SELECT id FROM games WHERE id=$1 FOR UPDATE")
        .bind(game_id)
        .execute(&mut *tx)
        .await?;
    for ((pid, key), v) in &values {
        sqlx::query(
            r#"INSERT INTO player_game_stats (game_id, player_id, stat_key, revision, value_x10, source)
               SELECT $1, $2, $3, COALESCE(MAX(revision), 0) + 1, $4, 'espn'
               FROM player_game_stats WHERE game_id = $1 AND player_id = $2 AND stat_key = $3
               HAVING COALESCE((SELECT value_x10 FROM player_game_stats
                                WHERE game_id = $1 AND player_id = $2 AND stat_key = $3
                                ORDER BY revision DESC LIMIT 1), -2147483648) <> $4"#,
        )
        .bind(game_id)
        .bind(pid)
        .bind(key)
        .bind(v)
        .execute(&mut *tx)
        .await?;
    }
    sqlx::query("UPDATE games SET stats_ingested_at = now() WHERE id = $1")
        .bind(game_id)
        .execute(&mut *tx)
        .await?;

    let markets: Vec<(i64, i64, String)> =
        sqlx::query_as("SELECT id, player_id, stat_key FROM markets WHERE game_id = $1")
            .bind(game_id)
            .fetch_all(&mut *tx)
            .await?;
    let score: Option<(Option<i32>, Option<i32>, String)> =
        sqlx::query_as("SELECT home_score, away_score, status FROM games WHERE id = $1")
            .bind(game_id)
            .fetch_optional(&mut *tx)
            .await?;
    let mut changed = Vec::new();
    for (mid, pid, key) in markets {
        if ss_core::lines::is_game_stat(&key) {
            let Some((Some(h), Some(a), status)) = &score else {
                continue;
            };
            if status != "final" {
                continue;
            }
            let (value, source) = match key.as_str() {
                "total" => ((h + a) * 10, "espn"),
                // A moneyline tie has no winner: void it like a scratch.
                "moneyline" if h == a => (0, "dnp"),
                _ => ((h - a) * 10, "espn"),
            };
            if insert_result_if_changed_tx(&mut tx, mid, value, source).await? {
                changed.push(mid);
            }
            continue;
        }
        // A player who appears anywhere in the box score played; a missing
        // category means zero. A player absent entirely did not play.
        let (value, source) = match values.get(&(pid, key.clone())) {
            Some(v) => (*v, "espn"),
            None if appeared.contains(&pid) => (0, "espn"),
            None => (0, "dnp"),
        };
        if insert_result_if_changed_tx(&mut tx, mid, value, source).await? {
            changed.push(mid);
        }
    }
    tx.commit().await?;
    Ok(changed)
}

/// Appends a new result revision unless the latest one already says the same.
pub async fn insert_result_if_changed(
    pool: &PgPool,
    market_id: i64,
    value_x10: i32,
    source: &str,
) -> Result<bool> {
    let mut tx = pool.begin().await?;
    let changed = insert_result_if_changed_tx(&mut tx, market_id, value_x10, source).await?;
    tx.commit().await?;
    Ok(changed)
}

async fn insert_result_if_changed_tx(
    tx: &mut Transaction<'_, Postgres>,
    market_id: i64,
    value_x10: i32,
    source: &str,
) -> Result<bool> {
    let status: String = sqlx::query_scalar("SELECT status FROM markets WHERE id=$1 FOR UPDATE")
        .bind(market_id)
        .fetch_one(&mut **tx)
        .await?;
    let latest: Option<(i32, String, i32)> = sqlx::query_as(
        "SELECT value_x10, source, revision FROM market_results WHERE market_id = $1 ORDER BY revision DESC LIMIT 1",
    ).bind(market_id).fetch_optional(&mut **tx).await?;
    if let Some((v, s, revision)) = latest {
        let same =
            (s == "dnp" && source == "dnp") || (v == value_x10 && s != "dnp" && source != "dnp");
        if same {
            // Repair work left behind by an older worker or an interrupted job.
            let pending: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM entry_legs WHERE market_id=$1 AND (result_revision IS NULL OR result_revision<$2))")
                .bind(market_id).bind(revision).fetch_one(&mut **tx).await?;
            if pending || (status != "settled" && status != "void") {
                crate::jobs::enqueue(
                    &mut **tx,
                    "grade_market",
                    Some(&format!("grade_market:{market_id}")),
                    serde_json::json!({"marketId":market_id}),
                )
                .await?;
            }
            return Ok(false);
        }
    }
    sqlx::query(
        r#"INSERT INTO market_results (market_id, revision, value_x10, source, final)
           SELECT $1, COALESCE(MAX(revision), 0) + 1, $2, $3, true FROM market_results WHERE market_id = $1"#,
    ).bind(market_id).bind(value_x10).bind(source).execute(&mut **tx).await?;
    crate::jobs::enqueue(
        &mut **tx,
        "grade_market",
        Some(&format!("grade_market:{market_id}")),
        serde_json::json!({"marketId":market_id}),
    )
    .await?;
    Ok(true)
}
