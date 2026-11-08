use anyhow::Result;
use chrono::{Duration, Utc};
use serde_json::json;
use sqlx::PgPool;
use ss_espn::{Client, League};
use tracing::{info, warn};

pub async fn sync_catalog(pool: &PgPool, espn: &Client) -> Result<()> {
    for league in League::ALL {
        let body = espn.teams_raw(league).await?;
        let teams = ss_espn::parse_teams(&body);
        for t in &teams {
            ss_db::catalog::upsert_team(pool, league, t).await?;
        }
        let mut players = 0;
        for (team_id, espn_id) in ss_db::catalog::team_ids(pool, league).await? {
            match espn.roster_raw(league, &espn_id).await {
                Ok(body) => {
                    let roster = ss_espn::parse_roster(&body);
                    players += ss_db::catalog::sync_roster(pool, league, team_id, &roster).await?;
                }
                Err(e) => {
                    warn!(league = league.as_str(), team = %espn_id, error = %e, "roster fetch failed")
                }
            }
        }
        info!(
            league = league.as_str(),
            teams = teams.len(),
            players,
            "catalog synced"
        );
    }
    Ok(())
}

pub async fn games_active_soon(pool: &PgPool) -> Result<bool> {
    Ok(sqlx::query_scalar(
        r#"SELECT EXISTS (SELECT 1 FROM games WHERE status = 'in'
                          OR (status = 'scheduled' AND start_at BETWEEN now() - interval '1 hour' AND now() + interval '30 minutes'))"#,
    )
    .fetch_one(pool)
    .await?)
}

async fn sync_scoreboard(
    pool: &PgPool,
    espn: &Client,
    league: League,
    dates: Option<&str>,
    week: Option<i32>,
) -> Result<Vec<ss_espn::ScoreboardGame>> {
    let body = espn.scoreboard_raw(league, dates, week).await?;
    let games = ss_espn::parse_scoreboard(&body);
    for g in &games {
        if let Some(up) = ss_db::catalog::upsert_game(pool, league, g).await? {
            if up.status == "final" && !up.stats_ingested {
                ss_db::jobs::enqueue(
                    pool,
                    "ingest_game",
                    Some(&format!("ingest_game:{}", up.id)),
                    json!({ "gameId": up.id }),
                )
                .await?;
            }
        }
    }
    Ok(games)
}

/// One scheduler pass: refresh scoreboards around today, re-check recent
/// finals for stat corrections, then create markets and publish contests.
pub async fn tick(pool: &PgPool, espn: &Client, force_markets: bool) -> Result<()> {
    let today = ss_db::contests::today_local();
    for offset in [-1i64, 0, 1, 2] {
        let d = (today + Duration::days(offset))
            .format("%Y%m%d")
            .to_string();
        sync_scoreboard(pool, espn, League::Nba, Some(&d), None).await?;
    }
    let current = sync_scoreboard(pool, espn, League::Nfl, None, None).await?;
    if let Some(week) = current.iter().filter_map(|g| g.week).max() {
        sync_scoreboard(pool, espn, League::Nfl, None, Some(week + 1)).await?;
    }

    // A temporary ESPN outage must not strand a final after its retry budget.
    // Retry a fresh budget after a cooling period; result processing is idempotent.
    let recovered = sqlx::query("UPDATE jobs j SET attempts=0,run_at=now(),locked_until=NULL WHERE kind='ingest_game' AND done_at IS NULL AND attempts>=8 AND run_at<now()-interval '5 minutes' AND EXISTS(SELECT 1 FROM games g WHERE g.id::text=j.payload->>'gameId' AND g.status='final' AND g.start_at>now()-interval '48 hours')")
        .execute(pool).await?.rows_affected();
    if recovered > 0 {
        info!(recovered, "retrying final box scores after provider outage");
    }

    // Stat corrections arrive for a while after a final; re-read recent finals.
    let recent: Vec<i64> = sqlx::query_scalar(
        r#"SELECT id FROM games WHERE status = 'final' AND start_at > now() - interval '48 hours'
             AND (stats_ingested_at IS NULL OR stats_ingested_at < now() - interval '30 minutes')"#,
    )
    .fetch_all(pool)
    .await?;
    for id in recent {
        ss_db::jobs::enqueue(
            pool,
            "ingest_game",
            Some(&format!("ingest_game:{id}")),
            json!({ "gameId": id }),
        )
        .await?;
    }
    if force_markets {
        let n = ss_db::slate::create_markets(pool, 48).await?;
        ss_db::contests::ensure_week(pool).await?;
        info!(created = n, "markets created");
    } else {
        ss_db::jobs::enqueue(pool, "create_markets", Some("create_markets"), json!({})).await?;
    }
    Ok(())
}

pub async fn ingest_game(pool: &PgPool, espn: &Client, game_id: i64) -> Result<()> {
    let (league, espn_id): (String, String) =
        sqlx::query_as("SELECT league, espn_id FROM games WHERE id = $1")
            .bind(game_id)
            .fetch_one(pool)
            .await?;
    let league = League::parse(&league).expect("valid league");
    let body = espn.summary_raw(league, &espn_id).await?;
    let box_score = verified_final_box_score(&body)?;
    // Replaying a final is safe. In particular, never mark the response as
    // processed before its stats/results/jobs commit successfully.
    let changed = ss_db::catalog::record_box_score(pool, game_id, league, &box_score).await?;
    let checksum = ss_db::sha256_hex(body.to_string().as_bytes());
    sqlx::query("INSERT INTO ingest_registry(provider,resource,checksum) VALUES ('espn',$1,$2) ON CONFLICT(provider,resource) DO UPDATE SET checksum=EXCLUDED.checksum,fetched_at=now()")
        .bind(format!("summary:{}:{}", league.as_str(), espn_id)).bind(checksum).execute(pool).await?;
    info!(
        game = game_id,
        stats = box_score.stats.len(),
        markets = changed.len(),
        "box score ingested"
    );
    Ok(())
}

fn verified_final_box_score(body: &serde_json::Value) -> Result<ss_espn::BoxScore> {
    anyhow::ensure!(
        body.pointer("/header/competitions/0/status/type/completed")
            .and_then(serde_json::Value::as_bool)
            == Some(true),
        "ESPN summary is not final yet; retry without settling"
    );
    anyhow::ensure!(
        body.pointer("/boxscore/players")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|teams| teams.len() >= 2),
        "Final player box score is incomplete; retry without voiding players"
    );
    let parsed = ss_espn::parse_box_score(body);
    anyhow::ensure!(
        !parsed.stats.is_empty(),
        "Final player box score contains no usable stats; retry"
    );
    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_complete_final_summaries_can_settle() {
        let mut body: serde_json::Value =
            serde_json::from_str(include_str!("../../espn/tests/fixtures/nfl_summary.json"))
                .unwrap();
        assert!(verified_final_box_score(&body).is_ok());
        body["header"]["competitions"][0]["status"]["type"]["completed"] = json!(false);
        assert!(verified_final_box_score(&body).is_err());
        body["header"]["competitions"][0]["status"]["type"]["completed"] = json!(true);
        body["boxscore"]["players"] = json!([]);
        assert!(verified_final_box_score(&body).is_err());
    }
}

/// Loads recent history so lines and recent form have data on day one.
pub async fn backfill(pool: &PgPool, espn: &Client, nba_days: i64) -> Result<()> {
    let today = Utc::now().with_timezone(&ss_db::GAME_ZONE).date_naive();
    for offset in (1..=nba_days).rev() {
        let d = (today - Duration::days(offset))
            .format("%Y%m%d")
            .to_string();
        sync_scoreboard(pool, espn, League::Nba, Some(&d), None).await?;
    }
    let current = sync_scoreboard(pool, espn, League::Nfl, None, None).await?;
    let week = current.iter().filter_map(|g| g.week).max().unwrap_or(1);
    for w in 1..week {
        sync_scoreboard(pool, espn, League::Nfl, None, Some(w)).await?;
    }
    let pending: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM games WHERE status = 'final' AND stats_ingested_at IS NULL ORDER BY start_at")
            .fetch_all(pool)
            .await?;
    info!(games = pending.len(), "ingesting final box scores");
    for (i, id) in pending.iter().enumerate() {
        if let Err(e) = ingest_game(pool, espn, *id).await {
            warn!(game = id, error = %e, "box score ingest failed");
        }
        if i % 25 == 0 {
            info!(done = i, total = pending.len(), "backfill progress");
        }
    }
    sqlx::query("UPDATE jobs SET done_at = now() WHERE kind = 'ingest_game' AND done_at IS NULL")
        .execute(pool)
        .await?;
    Ok(())
}
