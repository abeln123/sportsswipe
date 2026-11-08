//! Profiles, record stats, the card collection and the cosmetic store.

use crate::auth::{me_json, AuthUser};
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::{Path, Query, State},
    response::Response,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/me/profile", get(my_profile).patch(update_profile))
        .route("/profiles/{id}", get(profile))
        .route("/profiles/{id}/stats", get(stats))
        .route("/teams", get(teams))
        .route("/me/collection", get(collection))
        .route("/me/collection/{player_id}/equip", post(equip))
        .route("/store/skus", get(skus))
        .route("/store/purchases", post(purchase))
}

async fn my_profile(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    Ok(Json(me_json(&state, user.id).await?))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProfilePatch {
    display_name: Option<String>,
    bio: Option<String>,
    favorite_team_id: Option<Option<i64>>,
    visibility: Option<String>,
}

async fn update_profile(State(state): State<AppState>, user: AuthUser, Json(b): Json<ProfilePatch>) -> ApiResult<Json<Value>> {
    if let Some(n) = &b.display_name {
        let n = n.trim();
        if n.is_empty() || n.chars().count() > 40 {
            return Err(ApiError::BadRequest("Display names are 1 to 40 characters.".into()));
        }
        sqlx::query("UPDATE profiles SET display_name = $2 WHERE user_id = $1").bind(user.id).bind(n).execute(&state.pool).await?;
    }
    if let Some(bio) = &b.bio {
        if bio.chars().count() > 160 {
            return Err(ApiError::BadRequest("Bios are up to 160 characters.".into()));
        }
        sqlx::query("UPDATE profiles SET bio = $2 WHERE user_id = $1").bind(user.id).bind(bio.trim()).execute(&state.pool).await?;
    }
    if let Some(team) = b.favorite_team_id {
        sqlx::query("UPDATE profiles SET favorite_team_id = $2 WHERE user_id = $1").bind(user.id).bind(team).execute(&state.pool).await?;
    }
    if let Some(v) = &b.visibility {
        if !["public", "friends", "private"].contains(&v.as_str()) {
            return Err(ApiError::BadRequest("Unknown visibility.".into()));
        }
        sqlx::query("UPDATE profiles SET visibility = $2 WHERE user_id = $1").bind(user.id).bind(v).execute(&state.pool).await?;
    }
    Ok(Json(me_json(&state, user.id).await?))
}

pub(crate) async fn can_view(state: &AppState, viewer: Uuid, target: Uuid) -> ApiResult<bool> {
    if viewer == target {
        return Ok(true);
    }
    if crate::social::blocked_either(&state.pool, viewer, target).await? {
        return Err(ApiError::NotFound);
    }
    let vis: Option<String> = sqlx::query_scalar("SELECT visibility FROM profiles WHERE user_id = $1")
        .bind(target)
        .fetch_optional(&state.pool)
        .await?;
    Ok(match vis.ok_or(ApiError::NotFound)?.as_str() {
        "public" => true,
        "friends" => crate::social::are_friends(&state.pool, viewer, target).await?,
        _ => false,
    })
}

async fn stats_json(state: &AppState, user_id: Uuid) -> ApiResult<Value> {
    let (won, lost, returned, net): (i64, i64, i64, i64) = sqlx::query_as(
        r#"SELECT count(*) FILTER (WHERE status = 'won'), count(*) FILTER (WHERE status = 'lost'),
                  COALESCE(sum(credited) FILTER (WHERE status = 'won'), 0)::bigint,
                  COALESCE(sum(credited - stake) FILTER (WHERE status IN ('won','lost')), 0)::bigint
           FROM entries WHERE user_id = $1"#,
    )
    .bind(user_id)
    .fetch_one(&state.pool)
    .await?;
    let graded = won + lost;
    let contest: Option<(i32, i32, i32)> = sqlx::query_as(
        r#"SELECT s.points, s.days_counted, s.rank FROM standings s JOIN contests c ON c.id = s.contest_id
           WHERE c.week_start = $2 AND s.user_id = $1"#,
    )
    .bind(user_id)
    .bind(ss_db::contests::week_start(ss_db::contests::today_local()))
    .fetch_optional(&state.pool)
    .await?;
    let top_rows: Vec<(i64, i64, Option<String>)> = sqlx::query_as(
        r#"SELECT mt.player_id, mt.correct_count, ef.finish
           FROM mastery_totals mt
           LEFT JOIN equipped_finishes ef ON ef.user_id = mt.user_id AND ef.player_id = mt.player_id
           WHERE mt.user_id = $1
           ORDER BY mt.correct_count DESC, mt.first_earned_at
           LIMIT 3"#,
    )
    .bind(user_id)
    .fetch_all(&state.pool)
    .await?;
    let top_ids: Vec<i64> = top_rows.iter().map(|r| r.0).collect();
    let top_specs = ss_db::cards::card_specs(&state.pool, &top_ids).await?;
    let top_cards: Vec<Value> = top_rows
        .iter()
        .map(|(pid, count, finish)| {
            json!({
                "card": top_specs.get(pid),
                "mastery": ss_db::cards::mastery_json(*count),
                "finish": finish.clone().unwrap_or_else(|| "base".into()),
            })
        })
        .collect();
    let best_card = top_cards.first().cloned();
    Ok(json!({
        // Win rate: settled, non-void Solo entries won / graded. A parlay is one entry.
        "won": won, "lost": lost,
        "winRate": if graded > 0 { Some((won as f64 * 100.0 / graded as f64).round() as i64) } else { None },
        "coinsReturned": returned, "netSettled": net, "cashAwards": 0,
        "weeklyContest": { "points": contest.map(|c| c.0).unwrap_or(0), "daysCounted": contest.map(|c| c.1).unwrap_or(0),
                           "rank": contest.map(|c| c.2), "maxPoints": 50 },
        "bestCard": best_card,
        "topCards": top_cards,
    }))
}

async fn stats(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>) -> ApiResult<Json<Value>> {
    if !can_view(&state, user.id, id).await? {
        return Err(ApiError::Forbidden("This profile is private.".into()));
    }
    Ok(Json(stats_json(&state, id).await?))
}

async fn profile(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>) -> ApiResult<Json<Value>> {
    let row: Option<(String, String, String, String, Option<String>)> = sqlx::query_as(
        r#"SELECT p.display_name, p.handle, p.tag, p.bio, t.name FROM profiles p
           LEFT JOIN teams t ON t.id = p.favorite_team_id WHERE p.user_id = $1"#,
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await?;
    let (name, handle, tag, bio, team) = row.ok_or(ApiError::NotFound)?;
    let visible = can_view(&state, user.id, id).await?;
    let stats = if visible { Some(stats_json(&state, id).await?) } else { None };
    Ok(Json(json!({
        "userId": id, "displayName": name, "handleTag": format!("{handle}#{tag}"), "bio": bio,
        "favoriteTeam": team, "visible": visible, "stats": stats, "isMe": id == user.id,
    })))
}

#[derive(Deserialize)]
struct TeamsQuery {
    league: Option<String>,
}

async fn teams(State(state): State<AppState>, _: AuthUser, Query(q): Query<TeamsQuery>) -> ApiResult<Json<Value>> {
    let rows: Vec<(i64, String, String, String)> = sqlx::query_as(
        "SELECT id, league, abbr, name FROM teams WHERE ($1::text IS NULL OR league = $1) ORDER BY league, name",
    )
    .bind(q.league)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({ "teams": rows.iter().map(|(id, l, a, n)| json!({ "teamId": id, "league": l, "abbr": a, "name": n })).collect::<Vec<_>>() })))
}

async fn collection(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    crate::presentation::ensure(&state, user).await?;
    let presentation:Vec<i64>=sqlx::query_scalar("SELECT player_id FROM presentation_entitlements WHERE user_id=$1").bind(user.id).fetch_all(&state.pool).await?;
    let total: i64 = sqlx::query_scalar("SELECT count(*) FROM card_series").fetch_one(&state.pool).await?;
    let owned: Vec<(i64, i64, Option<String>)> = sqlx::query_as(
        r#"SELECT mt.player_id, mt.correct_count, ef.finish FROM mastery_totals mt
           LEFT JOIN card_series cs ON cs.player_id = mt.player_id
           LEFT JOIN equipped_finishes ef ON ef.user_id = mt.user_id AND ef.player_id = mt.player_id
           WHERE mt.user_id = $1 ORDER BY cs.card_no NULLS LAST"#,
    )
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    let ids: Vec<i64> = owned.iter().map(|o| o.0).collect();
    let specs = ss_db::cards::card_specs(&state.pool, &ids).await?;
    let unassigned: Vec<(String, i64)> = sqlx::query_as(
        r#"SELECT finish, count(*) FROM cosmetic_purchases cp
           WHERE user_id = $1 AND NOT EXISTS (SELECT 1 FROM equipped_finishes ef WHERE ef.purchase_id = cp.id)
           GROUP BY finish"#,
    )
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({
        "series": "Debut Series", "collected": owned.len(), "total": total,
        "cards": owned.iter().map(|(pid, count, finish)| json!({
            "card": specs.get(pid), "mastery": ss_db::cards::mastery_json(*count), "presentation":user.is_admin&&presentation.contains(pid),
            "finish": finish.clone().unwrap_or_else(|| "base".into()),
        })).collect::<Vec<_>>(),
        "unassignedFinishes": unassigned.iter().map(|(f, n)| json!({ "finish": f, "count": n })).collect::<Vec<_>>(),
    })))
}

async fn skus(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows: Vec<(String, i64)> = sqlx::query_as("SELECT finish, price FROM cosmetic_skus ORDER BY sort")
        .fetch_all(&state.pool)
        .await?;
    let balance: i64 = sqlx::query_scalar("SELECT balance FROM coin_accounts WHERE user_id = $1")
        .bind(user.id)
        .fetch_one(&state.pool)
        .await?;
    Ok(Json(json!({
        "balance": balance,
        "skus": rows.iter().map(|(f, p)| json!({ "finish": f, "price": p })).collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PurchaseBody {
    command_id: Uuid,
    finish: String,
}

async fn purchase(State(state): State<AppState>, user: AuthUser, Json(b): Json<PurchaseBody>) -> ApiResult<Response> {
    use ss_db::picks::Outcome;
    let mut tx = state.pool.begin().await?;
    ss_db::picks::lock_wallet(&mut tx, user.id).await?;
    let prior: Option<(Uuid, String, i64)> =
        sqlx::query_as("SELECT id, finish, price FROM cosmetic_purchases WHERE user_id = $1 AND command_id = $2")
            .bind(user.id)
            .bind(b.command_id)
            .fetch_optional(&mut *tx)
            .await?;
    if let Some((id, finish, price)) = prior {
        let (balance, version): (i64, i64) = sqlx::query_as("SELECT balance, version FROM coin_accounts WHERE user_id = $1")
            .bind(user.id)
            .fetch_one(&mut *tx)
            .await?;
        return Ok(crate::error::outcome(Outcome {
            http_status: 201,
            body: json!({ "status": "accepted", "purchaseId": id, "finish": finish, "price": price, "balance": balance, "balanceVersion": version }),
        }));
    }
    let price: Option<i64> = sqlx::query_scalar("SELECT price FROM cosmetic_skus WHERE finish = $1")
        .bind(&b.finish)
        .fetch_optional(&mut *tx)
        .await?;
    let price = price.ok_or_else(|| ApiError::BadRequest("Unknown finish.".into()))?;
    let wallet: Option<(i64, i64)> = sqlx::query_as(
        "UPDATE coin_accounts SET balance = balance - $2, version = version + 1 WHERE user_id = $1 AND balance >= $2 RETURNING balance, version",
    )
    .bind(user.id)
    .bind(price)
    .fetch_optional(&mut *tx)
    .await?;
    let Some((balance, version)) = wallet else {
        return Ok(crate::error::outcome(Outcome {
            http_status: 409,
            body: json!({ "status": "rejected", "code": "insufficient_coins", "message": "Not enough coins for this finish." }),
        }));
    };
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO cosmetic_purchases (user_id, command_id, finish, price) VALUES ($1,$2,$3,$4) RETURNING id",
    )
    .bind(user.id)
    .bind(b.command_id)
    .bind(&b.finish)
    .bind(price)
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query("INSERT INTO coin_ledger (user_id, delta, reason, source_key) VALUES ($1, $2, 'store', $3)")
        .bind(user.id)
        .bind(-price)
        .bind(format!("store:{id}"))
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(crate::error::outcome(Outcome {
        http_status: 201,
        body: json!({ "status": "accepted", "purchaseId": id, "finish": b.finish, "price": price, "balance": balance, "balanceVersion": version }),
    }))
}

#[derive(Deserialize)]
struct EquipBody {
    finish: String,
}

/// Applies an owned, unassigned finish to an earned card. "base" removes it
/// and frees the finish for another card.
async fn equip(State(state): State<AppState>, user: AuthUser, Path(player_id): Path<i64>, Json(b): Json<EquipBody>) -> ApiResult<Json<Value>> {
    let mut tx = state.pool.begin().await?;
    let earned: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM mastery_totals WHERE user_id = $1 AND player_id = $2)")
        .bind(user.id)
        .bind(player_id)
        .fetch_one(&mut *tx)
        .await?;
    if !earned {
        return Err(ApiError::BadRequest("Earn this card before applying a finish.".into()));
    }
    sqlx::query("DELETE FROM equipped_finishes WHERE user_id = $1 AND player_id = $2")
        .bind(user.id)
        .bind(player_id)
        .execute(&mut *tx)
        .await?;
    if b.finish != "base" {
        let purchase: Option<Uuid> = sqlx::query_scalar(
            r#"SELECT id FROM cosmetic_purchases cp WHERE user_id = $1 AND finish = $2
                 AND NOT EXISTS (SELECT 1 FROM equipped_finishes ef WHERE ef.purchase_id = cp.id)
               ORDER BY created_at LIMIT 1 FOR UPDATE"#,
        )
        .bind(user.id)
        .bind(&b.finish)
        .fetch_optional(&mut *tx)
        .await?;
        let purchase = purchase.ok_or_else(|| ApiError::BadRequest("Buy this finish in the store first.".into()))?;
        sqlx::query("UPDATE cosmetic_purchases SET player_id = $2 WHERE id = $1").bind(purchase).bind(player_id).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO equipped_finishes (user_id, player_id, finish, purchase_id) VALUES ($1,$2,$3,$4)")
            .bind(user.id)
            .bind(player_id)
            .bind(&b.finish)
            .bind(purchase)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(Json(json!({ "playerId": player_id, "finish": b.finish })))
}
