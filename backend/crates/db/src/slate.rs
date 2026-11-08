//! Market creation for upcoming games. Lines come from `ss_core::lines`.

use anyhow::Result;
use sqlx::PgPool;
use std::collections::HashMap;

/// (stat_key, how many players per team get a market for it)
fn market_plan(league: &str) -> &'static [(&'static str, usize)] {
    match league {
        "nba" => &[("pts", 3), ("reb", 1), ("ast", 1), ("fg3m", 1)],
        _ => &[("pass_yds", 1), ("rush_yds", 1), ("rec_yds", 2)],
    }
}

/// Creates markets for scheduled games starting within `horizon_hours` that
/// have none yet. Returns the number of markets created.
pub async fn create_markets(pool: &PgPool, horizon_hours: i64) -> Result<usize> {
    let games: Vec<(i64, String, i64, i64, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        r#"SELECT g.id, g.league, g.home_team_id, g.away_team_id, g.start_at FROM games g
           WHERE g.status = 'scheduled' AND g.start_at > now() + interval '10 minutes'
             AND g.start_at < now() + make_interval(hours => $1::int)
             AND NOT EXISTS (SELECT 1 FROM markets m WHERE m.game_id = g.id)"#,
    )
    .bind(horizon_hours as i32)
    .fetch_all(pool)
    .await?;

    let mut created = 0;
    for (game_id, league, home, away, start_at) in games {
        for team_id in [home, away] {
            created += create_team_markets(pool, game_id, &league, team_id, start_at).await?;
        }
    }
    created += create_game_markets(pool, horizon_hours).await?;
    Ok(created)
}

/// Recent finals for a team, newest first, as (margin for the team, total).
async fn team_results(pool: &PgPool, team_id: i64) -> Result<Vec<(i32, i32)>> {
    Ok(sqlx::query_as(
        r#"SELECT CASE WHEN home_team_id = $1 THEN home_score - away_score ELSE away_score - home_score END,
                  home_score + away_score
           FROM games WHERE status = 'final' AND home_score IS NOT NULL AND away_score IS NOT NULL
             AND (home_team_id = $1 OR away_team_id = $1)
           ORDER BY start_at DESC LIMIT $2"#,
    )
    .bind(team_id)
    .bind(ss_core::lines::FORM_GAMES as i64)
    .fetch_all(pool)
    .await?)
}

/// The stand-in player row a team's game markets hang off.
pub async fn team_player(pool: &PgPool, team_id: i64) -> Result<i64> {
    Ok(sqlx::query_scalar(
        r#"INSERT INTO players (league, espn_id, team_id, full_name, first_name, last_name, position, active)
           SELECT league, 'team-' || espn_id, id, name, location, short_name, 'TEAM', true FROM teams WHERE id = $1
           ON CONFLICT (league, espn_id) DO UPDATE SET full_name = EXCLUDED.full_name,
             first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name, updated_at = now()
           RETURNING id"#,
    )
    .bind(team_id)
    .fetch_one(pool)
    .await?)
}

/// Moneyline, spread and total for scheduled games that don't have them yet.
async fn create_game_markets(pool: &PgPool, horizon_hours: i64) -> Result<usize> {
    let games: Vec<(i64, String, i64, i64, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        r#"SELECT g.id, g.league, g.home_team_id, g.away_team_id, g.start_at FROM games g
           WHERE g.status = 'scheduled' AND g.start_at > now() + interval '10 minutes'
             AND g.start_at < now() + make_interval(hours => $1::int)
             AND NOT EXISTS (SELECT 1 FROM markets m WHERE m.game_id = g.id AND m.stat_key = 'moneyline')"#,
    )
    .bind(horizon_hours as i32)
    .fetch_all(pool)
    .await?;
    let mut created = 0;
    for (game_id, league, home, away, start_at) in games {
        let Some(lines) =
            ss_core::lines::game_lines(&league, &team_results(pool, home).await?, &team_results(pool, away).await?)
        else {
            continue;
        };
        let pid = team_player(pool, home).await?;
        let mut tx = pool.begin().await?;
        for (stat, line) in [
            ("moneyline", ss_core::lines::MONEYLINE_X10),
            ("spread", lines.spread_x10),
            ("total", lines.total_x10),
        ] {
            let id: Option<i64> = sqlx::query_scalar(
                r#"INSERT INTO markets (game_id, player_id, stat_key, lock_at) VALUES ($1,$2,$3,$4)
                   ON CONFLICT (game_id, player_id, stat_key) DO NOTHING RETURNING id"#,
            )
            .bind(game_id)
            .bind(pid)
            .bind(stat)
            .bind(start_at)
            .fetch_optional(&mut *tx)
            .await?;
            if let Some(id) = id {
                sqlx::query("INSERT INTO line_versions (market_id, version, line_x10) VALUES ($1, 1, $2)")
                    .bind(id)
                    .bind(line)
                    .execute(&mut *tx)
                    .await?;
                created += 1;
            }
        }
        sqlx::query("INSERT INTO card_series (player_id) VALUES ($1) ON CONFLICT DO NOTHING")
            .bind(pid)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
    }
    Ok(created)
}

async fn create_team_markets(
    pool: &PgPool,
    game_id: i64,
    league: &str,
    team_id: i64,
    lock_at: chrono::DateTime<chrono::Utc>,
) -> Result<usize> {
    let plan = market_plan(league);
    let keys: Vec<String> = plan.iter().map(|(k, _)| k.to_string()).collect();
    // Newest-first values from each active player's most recent final games.
    let rows: Vec<(i64, String, i32)> = sqlx::query_as(
        r#"SELECT player_id, stat_key, value_x10 FROM (
             SELECT s.player_id, s.stat_key, s.value_x10,
                    row_number() OVER (PARTITION BY s.player_id, s.stat_key ORDER BY g.start_at DESC) AS rn
             FROM (SELECT DISTINCT ON (game_id, player_id, stat_key) game_id, player_id, stat_key, value_x10
                   FROM player_game_stats
                   WHERE stat_key = ANY($2) AND source = 'espn'
                     AND player_id IN (SELECT id FROM players WHERE team_id = $1 AND active)
                   ORDER BY game_id, player_id, stat_key, revision DESC) s
             JOIN games g ON g.id = s.game_id AND g.status = 'final'
           ) t WHERE rn <= $3
           ORDER BY player_id, stat_key, rn"#,
    )
    .bind(team_id)
    .bind(&keys)
    .bind(ss_core::lines::FORM_GAMES as i64)
    .fetch_all(pool)
    .await?;

    let mut series: HashMap<(i64, String), Vec<i32>> = HashMap::new();
    for (pid, key, v) in rows {
        series.entry((pid, key)).or_default().push(v);
    }

    let mut created = 0;
    for (stat, count) in plan {
        let mut candidates: Vec<(i64, i32, f64)> = series
            .iter()
            .filter(|((_, k), _)| k == stat)
            .filter_map(|((pid, _), vals)| {
                let line = ss_core::lines::generate_line(vals)?;
                let avg = vals.iter().map(|v| *v as f64).sum::<f64>() / vals.len() as f64;
                Some((*pid, line, avg))
            })
            .collect();
        candidates.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal).then(a.0.cmp(&b.0)));
        for (pid, line, _) in candidates.into_iter().take(*count) {
            let mut tx = pool.begin().await?;
            let id: Option<i64> = sqlx::query_scalar(
                r#"INSERT INTO markets (game_id, player_id, stat_key, lock_at) VALUES ($1,$2,$3,$4)
                   ON CONFLICT (game_id, player_id, stat_key) DO NOTHING RETURNING id"#,
            )
            .bind(game_id)
            .bind(pid)
            .bind(stat)
            .bind(lock_at)
            .fetch_optional(&mut *tx)
            .await?;
            if let Some(id) = id {
                sqlx::query("INSERT INTO line_versions (market_id, version, line_x10) VALUES ($1, 1, $2)")
                    .bind(id)
                    .bind(line)
                    .execute(&mut *tx)
                    .await?;
                sqlx::query("INSERT INTO card_series (player_id) VALUES ($1) ON CONFLICT DO NOTHING")
                    .bind(pid)
                    .execute(&mut *tx)
                    .await?;
                created += 1;
            }
            tx.commit().await?;
        }
    }
    Ok(created)
}

/// Marks markets whose lock time has passed. Acceptance re-checks the clock
/// itself, so this only keeps listings tidy.
pub async fn lock_due_markets(pool: &PgPool) -> Result<u64> {
    Ok(sqlx::query("UPDATE markets SET status = 'locked' WHERE status = 'open' AND lock_at <= now()")
        .execute(pool)
        .await?
        .rows_affected())
}
