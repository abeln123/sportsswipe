//! League invitations. Only a hash of the token is stored. Previewing a link
//! (including by a crawler) never creates membership; acceptance requires an
//! authenticated, explicit POST.

use crate::auth::{random_token, AuthUser};
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::{Path, State},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/invites", post(create))
        .route("/invites/{token}", get(preview))
        .route("/invites/{token}/accept", post(accept))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateBody {
    league_id: Uuid,
}

async fn create(State(state): State<AppState>, user: AuthUser, Json(b): Json<CreateBody>) -> ApiResult<Json<Value>> {
    let member: Option<String> = sqlx::query_scalar(
        "SELECT l.name FROM leagues l JOIN league_members m ON m.league_id = l.id WHERE l.id = $1 AND m.user_id = $2",
    )
    .bind(b.league_id)
    .bind(user.id)
    .fetch_optional(&state.pool)
    .await?;
    let league_name = member.ok_or(ApiError::NotFound)?;
    let token = random_token(24);
    let expires_at: chrono::DateTime<chrono::Utc> = sqlx::query_scalar(
        r#"INSERT INTO invites (token_hash, league_id, creator_id, expires_at)
           VALUES ($1, $2, $3, now() + interval '14 days') RETURNING expires_at"#,
    )
    .bind(ss_db::sha256_hex(token.as_bytes()))
    .bind(b.league_id)
    .bind(user.id)
    .fetch_one(&state.pool)
    .await?;
    let url = format!("{}/i/{}", state.config.public_base_url.trim_end_matches('/'), token);
    Ok(Json(json!({
        "url": url, "token": token, "expiresAt": expires_at,
        "smsBody": format!("Join my league \"{league_name}\" on Sports Swipe: {url}"),
    })))
}

struct InviteInfo {
    league_id: Uuid,
    league_name: String,
    inviter: String,
    member_count: i64,
    valid: bool,
}

async fn load(state: &AppState, token: &str) -> ApiResult<Option<InviteInfo>> {
    let row: Option<(Uuid, String, String, i64, bool)> = sqlx::query_as(
        r#"SELECT l.id, l.name, p.display_name,
                  (SELECT count(*) FROM league_members m WHERE m.league_id = l.id),
                  (NOT i.revoked AND i.expires_at > now() AND i.uses < i.max_uses)
           FROM invites i JOIN leagues l ON l.id = i.league_id JOIN profiles p ON p.user_id = i.creator_id
           WHERE i.token_hash = $1"#,
    )
    .bind(ss_db::sha256_hex(token.as_bytes()))
    .fetch_optional(&state.pool)
    .await?;
    Ok(row.map(|(league_id, league_name, inviter, member_count, valid)| InviteInfo {
        league_id,
        league_name,
        inviter,
        member_count,
        valid,
    }))
}

async fn preview(State(state): State<AppState>, Path(token): Path<String>) -> ApiResult<Json<Value>> {
    let info = load(&state, &token).await?.ok_or(ApiError::NotFound)?;
    Ok(Json(json!({
        "leagueName": info.league_name, "inviter": info.inviter, "memberCount": info.member_count, "valid": info.valid,
    })))
}

async fn accept(State(state): State<AppState>, user: AuthUser, Path(token): Path<String>) -> ApiResult<Json<Value>> {
    let hash = ss_db::sha256_hex(token.as_bytes());
    let info = load(&state, &token).await?.ok_or(ApiError::NotFound)?;
    if !info.valid {
        return Err(ApiError::Conflict("invite_expired", "This invite has expired. Ask for a new link.".into()));
    }
    let already: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM league_members WHERE league_id = $1 AND user_id = $2)")
        .bind(info.league_id)
        .bind(user.id)
        .fetch_one(&state.pool)
        .await?;
    if !already {
        let claimed = sqlx::query(
            "UPDATE invites SET uses = uses + 1 WHERE token_hash = $1 AND NOT revoked AND expires_at > now() AND uses < max_uses",
        )
        .bind(&hash)
        .execute(&state.pool)
        .await?
        .rows_affected();
        if claimed == 0 {
            return Err(ApiError::Conflict("invite_expired", "This invite has expired. Ask for a new link.".into()));
        }
        crate::social::add_member(&state.pool, info.league_id, user.id).await?;
    }
    Ok(Json(json!({ "leagueId": info.league_id, "leagueName": info.league_name })))
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Server-rendered preview page for messaging apps, which read Open Graph
/// tags without running the Flutter app. Private league details are limited
/// to the name and inviter's display name.
pub async fn landing_page(State(state): State<AppState>, Path(token): Path<String>) -> Response {
    let base = state.config.public_base_url.trim_end_matches('/').to_string();
    let info = load(&state, &token).await.ok().flatten();
    let (title, desc) = match &info {
        Some(i) if i.valid => (
            format!("Join {} on Sports Swipe", i.league_name),
            format!("{} invited you to their league. Make your calls and climb the weekly standings.", i.inviter),
        ),
        _ => ("Sports Swipe".to_string(), "Make your calls on NFL and NBA player lines.".to_string()),
    };
    let app_url = format!("{base}/invite/{}", esc(&token));
    let html = format!(
        r##"<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta property="og:type" content="website">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:image" content="{base}/og/invite.png">
<meta property="og:url" content="{base}/i/{token}">
<meta name="twitter:card" content="summary_large_image">
<meta http-equiv="refresh" content="0; url={app_url}">
<style>body{{background:#0B1A17;color:#E8F0EC;font-family:-apple-system,Inter,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}}a{{color:#7BEA87}}</style>
</head><body><p>Opening Sports Swipe… <a href="{app_url}">Continue</a></p>
<script>location.replace({app_url_js});</script>
</body></html>"##,
        title = esc(&title),
        desc = esc(&desc),
        token = esc(&token),
        app_url_js = serde_json::to_string(&app_url).unwrap_or_default(),
    );
    Html(html).into_response()
}
