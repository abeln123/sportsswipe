//! Pack store: list packs, buy and open one, and return leftover cards.

use crate::auth::AuthUser;
use crate::error::{outcome, ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::{Query, State},
    response::Response,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/packs", get(store))
        .route("/packs/buy", post(buy))
        .route("/packs/leftovers", get(leftovers))
}

#[derive(Deserialize)]
struct SportQuery {
    sport: Option<String>,
}

fn league(sport: Option<&str>) -> ApiResult<Option<&str>> {
    match sport {
        None | Some("all") | Some("") => Ok(None),
        Some(s @ ("nba" | "nfl")) => Ok(Some(s)),
        Some(_) => Err(ApiError::BadRequest("Unknown sport.".into())),
    }
}

async fn store(State(state): State<AppState>, user: AuthUser, Query(q): Query<SportQuery>) -> ApiResult<Json<Value>> {
    let league = league(q.sport.as_deref())?;
    let mut packs = Vec::new();
    for p in ss_db::packs::pack_types(&state.pool).await? {
        if p.league_for(league).is_err() {
            continue;
        }
        let available = ss_db::packs::available(&state.pool, user.id, &p, league).await?;
        packs.push(p.json(available));
    }
    let leftover_count: i64 = sqlx::query_scalar(
        r#"SELECT count(*) FROM pack_cards pc JOIN pack_purchases pp ON pp.id = pc.purchase_id
           JOIN markets m ON m.id = pc.market_id JOIN players p ON p.id = m.player_id
           WHERE pp.user_id = $1 AND pc.entry_id IS NULL AND m.status = 'open' AND m.lock_at > now()
             AND ($2::text IS NULL OR p.league = $2)
             AND NOT EXISTS (SELECT 1 FROM entries e WHERE e.user_id = $1 AND e.single_market_id = m.id)"#,
    )
    .bind(user.id)
    .bind(league)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(json!({
        "packs": packs, "presentationAvailable": user.is_admin,
        "leftoverCount": leftover_count,
        "challenges": ss_db::packs::open_challenges(&state.pool, user.id).await?,
    })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuyBody {
    command_id: Uuid,
    pack_key: String,
    sport: Option<String>,
}

async fn buy(State(state): State<AppState>, user: AuthUser, Json(b): Json<BuyBody>) -> ApiResult<Response> {
    let league = league(b.sport.as_deref())?;
    let o = ss_db::packs::buy(&state.pool, user.id, b.command_id, &b.pack_key, league).await?;
    Ok(outcome(o))
}

async fn leftovers(State(state): State<AppState>, user: AuthUser, Query(q): Query<SportQuery>) -> ApiResult<Json<Value>> {
    let league = league(q.sport.as_deref())?;
    Ok(Json(json!({ "cards": ss_db::packs::leftovers(&state.pool, user.id, league).await? })))
}
