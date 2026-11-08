//! Durable job queue on Postgres (`FOR UPDATE SKIP LOCKED`). A job that keeps
//! failing stops after `MAX_ATTEMPTS` and stays visible as a dead letter.

use anyhow::Result;
use serde_json::Value;
use sqlx::{PgExecutor, PgPool};

pub const MAX_ATTEMPTS: i32 = 8;

pub async fn enqueue<'e>(db: impl PgExecutor<'e>, kind: &str, dedupe_key: Option<&str>, payload: Value) -> Result<()> {
    sqlx::query(
        r#"INSERT INTO jobs (kind, dedupe_key, payload) VALUES ($1, $2, $3)
           ON CONFLICT (dedupe_key) WHERE done_at IS NULL DO NOTHING"#,
    )
    .bind(kind)
    .bind(dedupe_key)
    .bind(payload)
    .execute(db)
    .await?;
    Ok(())
}

pub struct Job {
    pub id: i64,
    pub kind: String,
    pub payload: Value,
    pub attempts: i32,
}

pub async fn claim(pool: &PgPool, kinds: &[&str]) -> Result<Option<Job>> {
    let kinds: Vec<String> = kinds.iter().map(|k| k.to_string()).collect();
    let row: Option<(i64, String, Value, i32)> = sqlx::query_as(
        r#"UPDATE jobs SET locked_until = now() + interval '2 minutes', attempts = attempts + 1
           WHERE id = (
             SELECT id FROM jobs
             WHERE done_at IS NULL AND run_at <= now() AND kind = ANY($1) AND attempts < $2
               AND (locked_until IS NULL OR locked_until < now())
             ORDER BY run_at, id
             FOR UPDATE SKIP LOCKED LIMIT 1)
           RETURNING id, kind, payload, attempts"#,
    )
    .bind(&kinds)
    .bind(MAX_ATTEMPTS)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(id, kind, payload, attempts)| Job { id, kind, payload, attempts }))
}

pub async fn complete(pool: &PgPool, id: i64) -> Result<()> {
    sqlx::query("UPDATE jobs SET done_at = now(), locked_until = NULL WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn fail(pool: &PgPool, job: &Job, err: &str) -> Result<()> {
    let backoff_secs = 2i32.pow(job.attempts.clamp(1, 10) as u32);
    sqlx::query(
        "UPDATE jobs SET last_error = $2, locked_until = NULL, run_at = now() + make_interval(secs => $3) WHERE id = $1",
    )
    .bind(job.id)
    .bind(err)
    .bind(backoff_secs as f64)
    .execute(pool)
    .await?;
    Ok(())
}
