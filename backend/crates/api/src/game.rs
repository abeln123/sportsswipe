//! Solo play: deck, single picks, parlays, command status, My picks and the
//! results reveal.

use crate::auth::AuthUser;
use crate::error::{outcome, ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::{Path, Query, State},
    response::Response,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use ss_core::Side;
use ss_db::picks::{EntryKind, LegRequest};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/me/summary", get(summary))
        .route("/deck", get(deck))
        .route("/picks", post(post_pick))
        .route("/parlays", post(post_parlay))
        .route("/commands/{id}", get(command))
        .route("/me/picks", get(my_picks))
        .route("/entries/{id}", get(entry_detail))
        .route("/me/results/unrevealed", get(unrevealed))
        .route("/me/results/reveal", post(reveal))
}

async fn summary(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let (balance, version): (i64, i64) = sqlx::query_as("SELECT balance, version FROM coin_accounts WHERE user_id = $1")
        .bind(user.id)
        .fetch_one(&state.pool)
        .await?;
    let (pending, unrevealed): (i64, i64) = sqlx::query_as(
        r#"SELECT count(*) FILTER (WHERE status = 'pending'),
                  count(*) FILTER (WHERE status <> 'pending' AND revealed_at IS NULL)
           FROM entries WHERE user_id = $1"#,
    )
    .bind(user.id)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(json!({
        "balance": balance, "balanceVersion": version, "pendingCount": pending,
        "unrevealedCount": unrevealed, "isAdmin": user.is_admin, "serverTime": chrono::Utc::now(),
    })))
}

#[derive(Deserialize)]
struct DeckQuery {
    sport: Option<String>,
    limit: Option<i64>,
}

async fn deck(State(state): State<AppState>, user: AuthUser, Query(q): Query<DeckQuery>) -> ApiResult<Json<Value>> {
    let league = match q.sport.as_deref() {
        None | Some("all") | Some("") => None,
        Some(s @ ("nba" | "nfl")) => Some(s),
        Some(_) => return Err(ApiError::BadRequest("Unknown sport.".into())),
    };
    let limit = q.limit.unwrap_or(8).clamp(1, 20);
    let ids = ss_db::cards::deck_market_ids(&state.pool, user.id, league, limit).await?;
    let cards = ss_db::cards::playable_cards(&state.pool, Some(user.id), &ids).await?;
    Ok(Json(json!({ "serverTime": chrono::Utc::now(), "ruleVersion": ss_core::payout::RULE_VERSION, "cards": cards })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegBody {
    market_id: i64,
    line_version: i32,
    side: String,
}

impl LegBody {
    fn to_req(&self) -> ApiResult<LegRequest> {
        Ok(LegRequest {
            market_id: self.market_id,
            line_version: self.line_version,
            side: Side::parse(&self.side).ok_or_else(|| ApiError::BadRequest("Side must be over or under.".into()))?,
        })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PickBody {
    command_id: Uuid,
    #[serde(flatten)]
    leg: LegBody,
    stake: i64,
    pack_id: Option<Uuid>,
}

async fn post_pick(State(state): State<AppState>, user: AuthUser, Json(b): Json<PickBody>) -> ApiResult<Response> {
    let o = ss_db::picks::accept_entry(
        &state.pool,
        user.id,
        b.command_id,
        EntryKind::Single,
        b.stake,
        vec![b.leg.to_req()?],
        b.pack_id,
    )
    .await?;
    Ok(outcome(o))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParlayBody {
    command_id: Uuid,
    legs: Vec<LegBody>,
    stake: i64,
}

async fn post_parlay(State(state): State<AppState>, user: AuthUser, Json(b): Json<ParlayBody>) -> ApiResult<Response> {
    let legs = b.legs.iter().map(LegBody::to_req).collect::<ApiResult<Vec<_>>>()?;
    let o = ss_db::picks::accept_entry(&state.pool, user.id, b.command_id, EntryKind::Parlay, b.stake, legs, None).await?;
    Ok(outcome(o))
}

async fn command(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>) -> ApiResult<Response> {
    match ss_db::picks::command_status(&state.pool, user.id, id).await? {
        Some(o) => Ok(outcome(o)),
        // Unknown does not prove an in-flight request failed.
        None => Ok(outcome(ss_db::picks::Outcome {
            http_status: 404,
            body: json!({ "status": "unknown", "code": "unknown_command", "message": "No result recorded for this command yet." }),
        })),
    }
}

#[derive(sqlx::FromRow)]
struct EntryRow {
    id: Uuid,
    kind: String,
    stake: i64,
    potential_return: i64,
    status: String,
    credited: i64,
    accepted_at: chrono::DateTime<chrono::Utc>,
    settled_at: Option<chrono::DateTime<chrono::Utc>>,
    rule_version: i32,
}

#[derive(sqlx::FromRow)]
struct LegRow {
    entry_id: Uuid,
    leg_no: i32,
    market_id: i64,
    line_version: i32,
    line_x10: i32,
    side: String,
    result: Option<String>,
    player_id: i64,
    stat_label: String,
    stat_key: String,
    game_status: String,
    home_abbr: String,
    away_abbr: String,
    result_value_x10: Option<i32>,
}

impl LegRow {
    /// "BUF -3.5" for game markets; None for player lines.
    fn side_label(&self) -> Option<String> {
        let (over, under) = ss_core::lines::side_labels(&self.stat_key, self.line_x10, &self.home_abbr, &self.away_abbr)?;
        Some(if self.side == "over" { over } else { under })
    }
}

/// Entries with legs, card specs and a stage for the 3-segment status bar
/// (locked, live, final).
async fn entries_json(state: &AppState, entries: Vec<EntryRow>) -> ApiResult<Vec<Value>> {
    let ids: Vec<Uuid> = entries.iter().map(|e| e.id).collect();
    let legs: Vec<LegRow> = sqlx::query_as(
        r#"SELECT el.entry_id, el.leg_no, el.market_id, el.line_version, el.line_x10, el.side, el.result,
                  m.player_id, sd.label AS stat_label, m.stat_key, g.status AS game_status,
                  ht.abbr AS home_abbr, at.abbr AS away_abbr,
                  (SELECT value_x10 FROM market_results r WHERE r.market_id = m.id ORDER BY revision DESC LIMIT 1) AS result_value_x10
           FROM entry_legs el JOIN markets m ON m.id = el.market_id
           JOIN stat_definitions sd ON sd.key = m.stat_key JOIN games g ON g.id = m.game_id
           JOIN teams ht ON ht.id = g.home_team_id JOIN teams at ON at.id = g.away_team_id
           WHERE el.entry_id = ANY($1) ORDER BY el.entry_id, el.leg_no"#,
    )
    .bind(&ids)
    .fetch_all(&state.pool)
    .await?;
    let player_ids: Vec<i64> = legs.iter().map(|l| l.player_id).collect();
    let specs = ss_db::cards::card_specs(&state.pool, &player_ids).await?;
    Ok(entries
        .iter()
        .map(|e| {
            let my_legs: Vec<Value> = legs
                .iter()
                .filter(|l| l.entry_id == e.id)
                .map(|l| {
                    let stage = if l.result.is_some() { "final" } else if l.game_status == "in" || l.game_status == "final" { "live" } else { "locked" };
                    json!({
                        "legNo": l.leg_no, "marketId": l.market_id, "lineVersion": l.line_version,
                        "line": ss_db::x10_to_f64(l.line_x10), "side": l.side, "result": l.result,
                        "statLabel": l.stat_label, "stage": stage, "card": specs.get(&l.player_id),
                        "sideLabel": l.side_label(),
                        "resultValue": l.result.as_ref().and(l.result_value_x10).map(ss_db::x10_to_f64),
                    })
                })
                .collect();
            let stage = if e.status != "pending" {
                "final"
            } else if my_legs.iter().any(|l| l["stage"] != "locked") {
                "live"
            } else {
                "locked"
            };
            json!({
                "entryId": e.id, "kind": e.kind, "stake": e.stake, "potentialReturn": e.potential_return,
                "status": e.status, "credited": e.credited, "net": e.credited - e.stake,
                "acceptedAt": e.accepted_at, "settledAt": e.settled_at, "ruleVersion": e.rule_version,
                "stage": stage, "legs": my_legs,
                "multiplier": ss_core::payout::parlay_multiplier(e.rule_version, my_legs.len()),
            })
        })
        .collect())
}

#[derive(Deserialize)]
struct PicksQuery {
    status: Option<String>,
    cursor: Option<String>,
    limit: Option<i64>,
}

const ENTRY_COLS: &str = "id, kind, stake, potential_return, status, credited, accepted_at, settled_at, rule_version";

async fn my_picks(State(state): State<AppState>, user: AuthUser, Query(q): Query<PicksQuery>) -> ApiResult<Json<Value>> {
    let pending = q.status.as_deref() != Some("settled");
    let limit = q.limit.unwrap_or(20).clamp(1, 50);
    // Cursor is "<accepted_at rfc3339>|<entry id>" for stable pagination.
    let (c_time, c_id) = match q.cursor.as_deref().and_then(|c| c.split_once('|')) {
        Some((t, id)) => (
            Some(chrono::DateTime::parse_from_rfc3339(t).map_err(|_| ApiError::BadRequest("Bad cursor.".into()))?.with_timezone(&chrono::Utc)),
            Some(Uuid::parse_str(id).map_err(|_| ApiError::BadRequest("Bad cursor.".into()))?),
        ),
        None => (None, None),
    };
    let entries: Vec<EntryRow> = sqlx::query_as(&format!(
        r#"SELECT {ENTRY_COLS} FROM entries
           WHERE user_id = $1 AND (status = 'pending') = $2
             AND ($3::timestamptz IS NULL OR (accepted_at, id) < ($3, $4))
           ORDER BY accepted_at DESC, id DESC LIMIT $5"#
    ))
    .bind(user.id)
    .bind(pending)
    .bind(c_time)
    .bind(c_id)
    .bind(limit)
    .fetch_all(&state.pool)
    .await?;
    let next = (entries.len() as i64 == limit)
        .then(|| entries.last().map(|e| format!("{}|{}", e.accepted_at.to_rfc3339(), e.id)))
        .flatten();
    let items = entries_json(&state, entries).await?;
    let (pending_count, settled_count, wagered, possible): (i64, i64, i64, i64) = sqlx::query_as(
        r#"SELECT count(*) FILTER (WHERE status = 'pending'), count(*) FILTER (WHERE status <> 'pending'),
                  COALESCE(sum(stake) FILTER (WHERE status = 'pending'), 0)::bigint,
                  COALESCE(sum(potential_return) FILTER (WHERE status = 'pending'), 0)::bigint
           FROM entries WHERE user_id = $1"#,
    )
    .bind(user.id)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(json!({
        "items": items, "nextCursor": next,
        "summary": { "pendingCount": pending_count, "settledCount": settled_count, "wagered": wagered, "possibleReturn": possible },
    })))
}

async fn entry_detail(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>) -> ApiResult<Json<Value>> {
    let entries: Vec<EntryRow> = sqlx::query_as(&format!("SELECT {ENTRY_COLS} FROM entries WHERE id = $1 AND user_id = $2"))
        .bind(id)
        .bind(user.id)
        .fetch_all(&state.pool)
        .await?;
    if entries.is_empty() {
        return Err(ApiError::NotFound);
    }
    let mut items = entries_json(&state, entries).await?;
    Ok(Json(items.remove(0)))
}

async fn unrevealed(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let entries: Vec<EntryRow> = sqlx::query_as(&format!(
        "SELECT {ENTRY_COLS} FROM entries WHERE user_id = $1 AND status <> 'pending' AND revealed_at IS NULL ORDER BY settled_at, id LIMIT 50"
    ))
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    let ids: Vec<Uuid> = entries.iter().map(|e| e.id).collect();
    let returned: i64 = entries.iter().map(|e| e.credited).sum();
    let change: i64 = entries.iter().map(|e| e.credited - e.stake).sum();
    let won = entries.iter().filter(|e| e.status == "won").count();
    // Cards whose first-ever mastery credit came from one of these entries.
    let new_players: Vec<i64> = sqlx::query_scalar(
        r#"SELECT DISTINCT me.player_id FROM mastery_events me
           WHERE me.user_id = $1 AND me.entry_id = ANY($2)
             AND NOT EXISTS (SELECT 1 FROM mastery_events o WHERE o.user_id = me.user_id
                             AND o.player_id = me.player_id AND o.created_at < me.created_at)"#,
    )
    .bind(user.id)
    .bind(&ids)
    .fetch_all(&state.pool)
    .await?;
    let specs = ss_db::cards::card_specs(&state.pool, &new_players).await?;
    let items = entries_json(&state, entries).await?;
    Ok(Json(json!({
        "entries": items, "won": won, "total": ids.len(), "coinsReturned": returned, "roundChange": change,
        "newCards": new_players.iter().filter_map(|p| specs.get(p)).collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RevealBody {
    entry_ids: Vec<Uuid>,
}

async fn reveal(State(state): State<AppState>, user: AuthUser, Json(b): Json<RevealBody>) -> ApiResult<Json<Value>> {
    let n = sqlx::query("UPDATE entries SET revealed_at = now() WHERE user_id = $1 AND id = ANY($2) AND status <> 'pending'")
        .bind(user.id)
        .bind(&b.entry_ids)
        .execute(&state.pool)
        .await?
        .rows_affected();
    Ok(Json(json!({ "revealed": n })))
}
