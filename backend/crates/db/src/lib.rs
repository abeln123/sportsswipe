//! Database access shared by the API and the worker. Money-moving and grading
//! logic lives here so both processes run the exact same transactions.

pub mod cards;
pub mod catalog;
pub mod contests;
pub mod grading;
pub mod jobs;
pub mod picks;
pub mod slate;

use sqlx::postgres::{PgPool, PgPoolOptions};

pub use sqlx;

pub async fn connect(url: &str, max_connections: u32) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(max_connections)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(url)
        .await?;
    Ok(pool)
}

pub async fn migrate(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::migrate!("./migrations").run(pool).await?;
    Ok(())
}

pub fn x10_to_f64(v: i32) -> f64 {
    v as f64 / 10.0
}

pub fn sha256_hex(input: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(input))
}

/// Game-day calendar used for decks and contests.
pub const GAME_ZONE: chrono_tz::Tz = chrono_tz::America::New_York;
