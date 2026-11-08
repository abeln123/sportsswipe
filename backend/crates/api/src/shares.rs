use crate::{
    auth::AuthUser,
    error::{ApiError, ApiResult},
    state::AppState,
};
use axum::{extract::State, routing::post, Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new().route("/shares", post(create))
}

pub async fn save(state: &AppState, owner: Uuid, kind: &str, payload: Value) -> ApiResult<Uuid> {
    Ok(sqlx::query_scalar("INSERT INTO shared_items(owner_id,kind,payload) VALUES ($1,$2,$3) RETURNING id")
        .bind(owner)
        .bind(kind)
        .bind(payload)
        .fetch_one(&state.pool)
        .await?)
}

pub async fn visible(state: &AppState, viewer: Uuid, id: Uuid) -> ApiResult<Value> {
    let (owner, kind, payload): (Uuid, String, Value) = sqlx::query_as("SELECT owner_id,kind,payload FROM shared_items WHERE id=$1")
        .bind(id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or(ApiError::NotFound)?;
    if crate::social::blocked_either(&state.pool, viewer, owner).await?
        || (kind != "research" && !crate::profile::can_view(state, viewer, owner).await?)
    {
        return Ok(json!({"kind":"unavailable","title":"This item is private"}));
    }
    Ok(json!({"id":id,"kind":kind,"payload":payload}))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Create {
    kind: String,
    player_id: Option<i64>,
    entry_id: Option<Uuid>,
}
async fn create(State(state): State<AppState>, user: AuthUser, Json(b): Json<Create>) -> ApiResult<Json<Value>> {
    let payload = match b.kind.as_str() {
        "card" => {
            let id = b.player_id.ok_or(ApiError::NotFound)?;
            let owned: bool =
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM mastery_totals WHERE user_id=$1 AND player_id=$2 AND correct_count>0)")
                    .bind(user.id)
                    .bind(id)
                    .fetch_one(&state.pool)
                    .await?;
            if !owned {
                return Err(ApiError::NotFound);
            }
            let cards = ss_db::cards::card_specs(&state.pool, &[id]).await?;
            let finish: Option<String> = sqlx::query_scalar("SELECT finish FROM equipped_finishes WHERE user_id=$1 AND player_id=$2")
                .bind(user.id)
                .bind(id)
                .fetch_optional(&state.pool)
                .await?;
            json!({"card":cards.get(&id),"finish":finish.unwrap_or_else(||"base".into()),"title":"Earned card"})
        }
        "pick" => {
            let id = b.entry_id.ok_or(ApiError::NotFound)?;
            let status: String = sqlx::query_scalar("SELECT status FROM entries WHERE id=$1 AND user_id=$2 AND status<>'pending'")
                .bind(id)
                .bind(user.id)
                .fetch_optional(&state.pool)
                .await?
                .ok_or(ApiError::NotFound)?;
            let legs: Vec<(i64,String,i32,String,Option<String>)> = sqlx::query_as("SELECT m.player_id,l.side,l.line_x10,s.label,l.result FROM entry_legs l JOIN markets m ON m.id=l.market_id JOIN stat_definitions s ON s.key=m.stat_key WHERE l.entry_id=$1 ORDER BY l.leg_no")
                .bind(id).fetch_all(&state.pool).await?;
            let cards = ss_db::cards::card_specs(&state.pool, &legs.iter().map(|l| l.0).collect::<Vec<_>>()).await?;
            json!({"title":format!("Settled pick · {status}"),"card":legs.first().and_then(|l|cards.get(&l.0)),
                "legs":legs.iter().map(|l|json!({"card":cards.get(&l.0),"side":l.1,"line":ss_db::x10_to_f64(l.2),"statLabel":l.3,"result":l.4})).collect::<Vec<_>>()})
        }
        _ => return Err(ApiError::BadRequest("Choose an earned card or settled pick.".into())),
    };
    let id = save(&state, user.id, &b.kind, payload).await?;
    Ok(Json(json!({"shareId":id})))
}
