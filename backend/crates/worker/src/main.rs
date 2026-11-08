//! Background worker: ESPN ingestion, market creation, grading jobs, outbox
//! relay and contest publication.
//!
//! Usage:
//!   worker              run the scheduler loop (default)
//!   worker backfill [N] load the current NFL season and the last N NBA days
//!   worker catalog      sync teams and rosters once
//!   worker tick         run one scheduler pass and exit

mod ingest;

use anyhow::Result;
use std::time::{Duration, Instant};
use tracing::{error, info};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info,sqlx=warn".into()))
        .init();
    let url = std::env::var("DATABASE_URL")?;
    let pool = ss_db::connect(&url, env_u32("WORKER_DB_POOL", 5)).await?;
    ss_db::migrate(&pool).await?;
    let espn = ss_espn::Client::new(
        std::env::var("ESPN_BASE_URL").unwrap_or_else(|_| "https://site.api.espn.com/apis/site/v2/sports".into()),
    );
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("grade-jobs") => drain_jobs(&pool, &espn).await?,
        Some("backfill") => {
            let days = args.get(1).and_then(|d| d.parse().ok()).unwrap_or(21);
            ingest::sync_catalog(&pool, &espn).await?;
            ingest::backfill(&pool, &espn, days).await?;
            ingest::tick(&pool, &espn, true).await?;
            drain_jobs(&pool, &espn).await?;
        }
        Some("catalog") => ingest::sync_catalog(&pool, &espn).await?,
        Some("tick") => {
            ingest::tick(&pool, &espn, true).await?;
            drain_jobs(&pool, &espn).await?;
        }
        _ => run(pool, espn).await,
    }
    Ok(())
}

fn env_u32(key: &str, default: u32) -> u32 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

async fn run(pool: sqlx::PgPool, espn: ss_espn::Client) {
    let teams: i64 = sqlx::query_scalar("SELECT count(*) FROM teams").fetch_one(&pool).await.unwrap_or(0);
    if teams == 0 {
        if let Err(e) = ingest::sync_catalog(&pool, &espn).await {
            error!(error = %e, "initial catalog sync failed");
        }
    }
    let mut last_scoreboard: Option<Instant> = None;
    let mut last_catalog_day = ss_db::contests::today_local();
    loop {
        let live = ingest::games_active_soon(&pool).await.unwrap_or(false);
        let interval = if live { Duration::from_secs(60) } else { Duration::from_secs(15 * 60) };
        if last_scoreboard.map_or(true, |t| t.elapsed() >= interval) {
            if let Err(e) = ingest::tick(&pool, &espn, false).await {
                error!(error = %e, "scoreboard tick failed");
            }
            last_scoreboard = Some(Instant::now());
        }
        let today = ss_db::contests::today_local();
        let local_hour = chrono::Timelike::hour(&chrono::Utc::now().with_timezone(&ss_db::GAME_ZONE));
        if today != last_catalog_day && local_hour >= 5 {
            if let Err(e) = ingest::sync_catalog(&pool, &espn).await {
                error!(error = %e, "catalog sync failed");
            }
            last_catalog_day = today;
        }
        if let Err(e) = drain_jobs(&pool, &espn).await {
            error!(error = %e, "job loop failed");
        }
        if let Err(e) = ss_db::picks::relay_outbox(&pool, 500).await {
            error!(error = %e, "outbox relay failed");
        }
        if let Err(e) = ss_db::slate::lock_due_markets(&pool).await {
            error!(error = %e, "locking markets failed");
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

const KINDS: [&str; 4] = ["ingest_game", "grade_market", "grade_contest_day", "create_markets"];

/// Runs ready jobs until none remain. Each job kind has its own failure
/// budget through the shared retry/backoff in `ss_db::jobs`.
async fn drain_jobs(pool: &sqlx::PgPool, espn: &ss_espn::Client) -> Result<()> {
    while let Some(job) = ss_db::jobs::claim(pool, &KINDS).await? {
        let started = Instant::now();
        let res = run_job(pool, espn, &job).await;
        match res {
            Ok(()) => {
                ss_db::jobs::complete(pool, job.id).await?;
                info!(kind = %job.kind, id = job.id, ms = started.elapsed().as_millis() as u64, "job done");
            }
            Err(e) => {
                error!(kind = %job.kind, id = job.id, attempts = job.attempts, error = %e, "job failed");
                ss_db::jobs::fail(pool, &job, &e.to_string()).await?;
            }
        }
    }
    Ok(())
}

async fn run_job(pool: &sqlx::PgPool, espn: &ss_espn::Client, job: &ss_db::jobs::Job) -> Result<()> {
    let p = &job.payload;
    match job.kind.as_str() {
        "ingest_game" => {
            let game_id = p["gameId"].as_i64().unwrap_or_default();
            ingest::ingest_game(pool, espn, game_id).await
        }
        "grade_market" => {
            let s = ss_db::grading::grade_market(pool, p["marketId"].as_i64().unwrap_or_default()).await?;
            info!(market = s.market_id, legs = s.legs_graded, entries = s.entries_settled, coins = s.coins_credited, "graded");
            for d in s.contest_days {
                ss_db::contests::grade_day(pool, d).await?;
            }
            Ok(())
        }
        "grade_contest_day" => ss_db::contests::grade_day(pool, p["dayId"].as_i64().unwrap_or_default()).await,
        "create_markets" => {
            let n = ss_db::slate::create_markets(pool, 48).await?;
            ss_db::contests::ensure_week(pool).await?;
            info!(created = n, "markets created");
            Ok(())
        }
        other => anyhow::bail!("unknown job kind {other}"),
    }
}
