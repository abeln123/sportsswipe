//! Demo controls. Settling injects a final stat value as a new result revision
//! and runs the same grading function the worker uses.

use crate::auth::AdminUser;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{HeaderMap, Method},
    response::Response,
    routing::{get, post},
    Json, Router,
};
use rand::Rng;
use serde::Deserialize;
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/admin/markets", get(markets))
        .route("/admin/settle-market", post(settle_market))
        .route("/admin/settle-contest-day", post(settle_contest_day))
        .route("/admin/lock-market", post(lock_market))
        .route("/admin/reset-presentation", post(reset_presentation))
}

#[derive(Deserialize)]
struct MarketsQuery {
    status: Option<String>,
    q: Option<String>,
}

async fn markets(State(state): State<AppState>, _: AdminUser, Query(q): Query<MarketsQuery>) -> ApiResult<Json<Value>> {
    let rows: Vec<(i64, String, String, i32, String, chrono::DateTime<chrono::Utc>, i64)> = sqlx::query_as(
        r#"SELECT m.id, p.full_name, sd.label, lv.line_x10, m.status, m.lock_at,
                  (SELECT count(*) FROM entry_legs el WHERE el.market_id = m.id)
           FROM markets m JOIN players p ON p.id = m.player_id JOIN stat_definitions sd ON sd.key = m.stat_key
           JOIN line_versions lv ON lv.market_id = m.id AND lv.version = m.current_version
           WHERE ($1::text IS NULL OR m.status = $1) AND ($2::text IS NULL OR p.full_name ILIKE '%' || $2 || '%')
           ORDER BY (SELECT count(*) FROM entry_legs el WHERE el.market_id = m.id) DESC, m.lock_at LIMIT 100"#,
    )
    .bind(q.status)
    .bind(q.q)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({ "markets": rows.iter().map(|(id, name, label, line, status, lock_at, picks)| json!({
        "marketId": id, "playerName": name, "statLabel": label, "line": ss_db::x10_to_f64(*line),
        "status": status, "lockAt": lock_at, "picks": picks,
    })).collect::<Vec<_>>() })))
}

/// A plausible value near the line, so demo settlements land on either side.
fn random_value_x10(line_x10: i32) -> i32 {
    let mut rng = rand::thread_rng();
    let spread = ((line_x10 as f64) * 0.35).max(30.0) as i32;
    let whole = (line_x10 + rng.gen_range(-spread..=spread)).max(0) / 10;
    whole * 10
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SettleBody {
    market_id: i64,
    value: Option<f64>,
}

async fn settle_market(State(state): State<AppState>, AdminUser(admin): AdminUser, Json(b): Json<SettleBody>) -> ApiResult<Json<Value>> {
    let line: Option<i32> = sqlx::query_scalar(
        "SELECT lv.line_x10 FROM markets m JOIN line_versions lv ON lv.market_id = m.id AND lv.version = m.current_version WHERE m.id = $1",
    )
    .bind(b.market_id)
    .fetch_optional(&state.pool)
    .await?;
    let line = line.ok_or(ApiError::NotFound)?;
    let value_x10 = match b.value {
        Some(v) if v >= 0.0 && v < 100_000.0 => (v * 10.0).round() as i32,
        Some(_) => return Err(ApiError::BadRequest("Value out of range.".into())),
        None => random_value_x10(line),
    };
    let summary = ss_db::grading::admin_settle(&state.pool, b.market_id, value_x10).await?;
    tracing::info!(admin = %admin.id, market = b.market_id, value_x10, "admin settle");
    Ok(Json(json!({ "value": ss_db::x10_to_f64(value_x10), "line": ss_db::x10_to_f64(line), "summary": summary })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DayBody {
    day_id: i64,
}

async fn settle_contest_day(State(state): State<AppState>, _: AdminUser, Json(b): Json<DayBody>) -> ApiResult<Json<Value>> {
    let qs: Vec<(i64, i32)> = sqlx::query_as("SELECT market_id, line_x10 FROM contest_questions WHERE contest_day_id = $1 ORDER BY q_no")
        .bind(b.day_id)
        .fetch_all(&state.pool)
        .await?;
    if qs.is_empty() {
        return Err(ApiError::NotFound);
    }
    // Lock the day first so entries cannot arrive after results exist.
    sqlx::query("UPDATE contest_days SET lock_at = LEAST(lock_at, now()) WHERE id = $1")
        .bind(b.day_id)
        .execute(&state.pool)
        .await?;
    let mut settled = Vec::new();
    for (market_id, line) in qs {
        sqlx::query("UPDATE markets SET lock_at = LEAST(lock_at, now()) WHERE id = $1").bind(market_id).execute(&state.pool).await?;
        let v = random_value_x10(line);
        ss_db::grading::admin_settle(&state.pool, market_id, v).await?;
        settled.push(json!({ "marketId": market_id, "value": ss_db::x10_to_f64(v), "line": ss_db::x10_to_f64(line) }));
    }
    ss_db::contests::grade_day(&state.pool, b.day_id).await?;
    Ok(Json(json!({ "settled": settled })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LockBody {
    market_id: i64,
}

async fn lock_market(State(state): State<AppState>, _: AdminUser, Json(b): Json<LockBody>) -> ApiResult<Json<Value>> {
    let n = sqlx::query("UPDATE markets SET lock_at = now(), status = CASE WHEN status = 'open' THEN 'locked' ELSE status END WHERE id = $1")
        .bind(b.market_id)
        .execute(&state.pool)
        .await?
        .rows_affected();
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(Json(json!({ "locked": true })))
}

async fn reset_presentation(State(state): State<AppState>, _: AdminUser, headers: HeaderMap, body: Bytes) -> ApiResult<Response> {
    // Compatibility route shares the on-chain reset; never delete provenance.
    crate::collectibles::proxy(State(state),Path("presentation/reset".to_string()),Method::POST,headers,body).await
}
