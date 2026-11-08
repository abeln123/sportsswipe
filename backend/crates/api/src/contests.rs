use crate::auth::AuthUser;
use crate::error::{outcome, ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::{Path, State},
    response::Response,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use ss_core::Side;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/contests/current", get(current))
        .route("/contest-days/{id}/slate", get(slate))
        .route("/contest-days/{id}/entries", post(submit))
        .route("/contests/{id}/standings", get(standings))
}

#[derive(sqlx::FromRow)]
struct DayRow {
    id: i64,
    day_index: i32,
    game_date: chrono::NaiveDate,
    lock_at: Option<chrono::DateTime<chrono::Utc>>,
    slate_version: i32,
    questions: i64,
    graded: i64,
    my_entry: Option<Uuid>,
    my_points: Option<i32>,
    open_now: bool,
}

async fn current(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let contest_id = ss_db::contests::ensure_week(&state.pool).await?;
    let (name, week_start): (String, chrono::NaiveDate) = sqlx::query_as("SELECT name, week_start FROM contests WHERE id = $1")
        .bind(contest_id)
        .fetch_one(&state.pool)
        .await?;
    let days: Vec<DayRow> = sqlx::query_as(
        r#"SELECT d.id, d.day_index, d.game_date, d.lock_at, d.slate_version,
                  (SELECT count(*) FROM contest_questions q WHERE q.contest_day_id = d.id) AS questions,
                  (SELECT count(*) FROM contest_questions q WHERE q.contest_day_id = d.id AND q.result IS NOT NULL) AS graded,
                  e.id AS my_entry, e.points AS my_points,
                  (d.lock_at IS NOT NULL AND now() < d.lock_at) AS open_now
           FROM contest_days d LEFT JOIN contest_entries e ON e.contest_day_id = d.id AND e.user_id = $2
           WHERE d.contest_id = $1 ORDER BY d.day_index"#,
    )
    .bind(contest_id)
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    let today = ss_db::contests::today_local();
    let day_json: Vec<Value> = days
        .iter()
        .map(|d| {
            let status = if d.slate_version == 0 {
                if d.game_date < today { "unavailable" } else { "upcoming" }
            } else if d.questions > 0 && d.graded == d.questions {
                "graded"
            } else if d.open_now {
                "open"
            } else {
                "locked"
            };
            json!({
                "dayId": d.id, "dayIndex": d.day_index, "date": d.game_date, "lockAt": d.lock_at,
                "status": status, "questionCount": d.questions, "isToday": d.game_date == today,
                "entered": d.my_entry.is_some(), "points": d.my_points,
            })
        })
        .collect();
    let me: Option<(i32, i32, i32)> =
        sqlx::query_as("SELECT points, days_counted, rank FROM standings WHERE contest_id = $1 AND user_id = $2")
            .bind(contest_id)
            .bind(user.id)
            .fetch_optional(&state.pool)
            .await?;
    let entrants: i64 = sqlx::query_scalar("SELECT count(*) FROM standings WHERE contest_id = $1")
        .bind(contest_id)
        .fetch_one(&state.pool)
        .await?;
    Ok(Json(json!({
        "contestId": contest_id, "name": name, "weekStart": week_start, "days": day_json,
        "todayIndex": (today - week_start).num_days(),
        "me": { "points": me.map(|m| m.0).unwrap_or(0), "daysCounted": me.map(|m| m.1).unwrap_or(0), "rank": me.map(|m| m.2) },
        "entrants": entrants, "maxPoints": 50, "countedDays": ss_core::contest::COUNTED_DAYS,
    })))
}

async fn slate(State(state): State<AppState>, user: AuthUser, Path(day_id): Path<i64>) -> ApiResult<Json<Value>> {
    let day: Option<(i64, i32, chrono::NaiveDate, Option<chrono::DateTime<chrono::Utc>>, i32, Option<String>, bool)> = sqlx::query_as(
        r#"SELECT contest_id, day_index, game_date, lock_at, slate_version, tiebreak_label,
                  (lock_at IS NOT NULL AND now() < lock_at) FROM contest_days WHERE id = $1"#,
    )
    .bind(day_id)
    .fetch_optional(&state.pool)
    .await?;
    let (contest_id, day_index, date, lock_at, version, tb_label, open) = day.ok_or(ApiError::NotFound)?;
    let qs: Vec<(i64, i32, i64, i32, Option<String>)> = sqlx::query_as(
        "SELECT id, q_no, market_id, line_x10, result FROM contest_questions WHERE contest_day_id = $1 ORDER BY q_no",
    )
    .bind(day_id)
    .fetch_all(&state.pool)
    .await?;
    let market_ids: Vec<i64> = qs.iter().map(|q| q.2).collect();
    let cards = ss_db::cards::playable_cards(&state.pool, Some(user.id), &market_ids).await?;
    let questions: Vec<Value> = qs
        .iter()
        .zip(cards)
        .map(|((id, no, _, line, result), mut card)| {
            // The contest line is frozen at publication.
            card["market"]["line"] = json!(ss_db::x10_to_f64(*line));
            json!({ "questionId": id, "qNo": no, "result": result, "playable": card })
        })
        .collect();
    let my_entry: Option<Uuid> = sqlx::query_scalar("SELECT id FROM contest_entries WHERE contest_day_id = $1 AND user_id = $2")
        .bind(day_id)
        .bind(user.id)
        .fetch_optional(&state.pool)
        .await?;
    let receipt = match my_entry {
        Some(id) => Some(ss_db::contests::receipt(&state.pool, id).await?),
        None => None,
    };
    Ok(Json(json!({
        "dayId": day_id, "contestId": contest_id, "dayIndex": day_index, "date": date, "lockAt": lock_at,
        "open": open, "slateVersion": version, "tiebreakLabel": tb_label, "questions": questions, "receipt": receipt,
    })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnswerBody {
    question_id: i64,
    side: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntryBody {
    command_id: Uuid,
    slate_version: i32,
    tiebreak: f64,
    answers: Vec<AnswerBody>,
}

async fn submit(State(state): State<AppState>, user: AuthUser, Path(day_id): Path<i64>, Json(b): Json<EntryBody>) -> ApiResult<Response> {
    if !(0.0..100_000.0).contains(&b.tiebreak) {
        return Err(ApiError::BadRequest("Enter a tiebreaker prediction.".into()));
    }
    let answers = b
        .answers
        .iter()
        .map(|a| {
            Ok(ss_db::contests::Answer {
                question_id: a.question_id,
                side: Side::parse(&a.side).ok_or_else(|| ApiError::BadRequest("Side must be over or under.".into()))?,
            })
        })
        .collect::<ApiResult<Vec<_>>>()?;
    let o = ss_db::contests::submit_entry(
        &state.pool,
        user.id,
        day_id,
        b.command_id,
        b.slate_version,
        (b.tiebreak * 10.0).round() as i32,
        &answers,
    )
    .await?;
    Ok(outcome(o))
}

async fn standings(State(state): State<AppState>, user: AuthUser, Path(contest_id): Path<i64>) -> ApiResult<Json<Value>> {
    let rows: Vec<(Uuid, i32, i32, i64, i32, String, String, String, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        r#"SELECT s.user_id, s.points, s.days_counted, s.tiebreak_error_x10, s.rank, p.display_name, p.handle, p.tag, s.updated_at
           FROM standings s JOIN profiles p ON p.user_id = s.user_id
           WHERE s.contest_id = $1 ORDER BY s.rank, p.display_name LIMIT 100"#,
    )
    .bind(contest_id)
    .fetch_all(&state.pool)
    .await?;
    let updated = rows.iter().map(|r| r.8).max();
    Ok(Json(json!({
        "updatedAt": updated,
        "rows": rows.iter().map(|(uid, pts, days, err, rank, name, handle, tag, _)| json!({
            "userId": uid, "isMe": *uid == user.id, "points": pts, "daysCounted": days,
            "tiebreakError": ss_db::x10_to_f64(*err as i32), "rank": rank, "displayName": name,
            "handleTag": format!("{handle}#{tag}"),
        })).collect::<Vec<_>>(),
    })))
}
