//! Email/password accounts with argon2id hashes and an httpOnly session
//! cookie. The user id always comes from the verified session.

use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use argon2::password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use axum::{
    extract::{FromRequestParts, State},
    http::{header, request::Parts, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use axum_extra::extract::CookieJar;
use base64::Engine;
use rand::RngCore;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub const COOKIE: &str = "ss_session";
const SESSION_DAYS: i64 = 30;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/auth/signup", post(signup))
        .route("/auth/login", post(login))
        .route("/auth/logout", post(logout))
        .route("/auth/me", get(me))
}

#[derive(Clone, Copy, Debug)]
pub struct AuthUser {
    pub id: Uuid,
    pub is_admin: bool,
}

pub struct AdminUser(pub AuthUser);

fn bearer(parts: &Parts) -> Option<String> {
    parts
        .headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::to_string)
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let jar = CookieJar::from_headers(&parts.headers);
        let token = jar.get(COOKIE).map(|c| c.value().to_string()).or_else(|| bearer(parts));
        let Some(token) = token else { return Err(ApiError::Unauthorized) };
        let row: Option<(Uuid, bool)> = sqlx::query_as(
            r#"SELECT u.id, u.is_admin FROM sessions s JOIN users u ON u.id = s.user_id
               WHERE s.token_hash = $1 AND s.expires_at > now()"#,
        )
        .bind(ss_db::sha256_hex(token.as_bytes()))
        .fetch_optional(&state.pool)
        .await?;
        row.map(|(id, is_admin)| AuthUser { id, is_admin }).ok_or(ApiError::Unauthorized)
    }
}

impl FromRequestParts<AppState> for AdminUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let user = AuthUser::from_request_parts(parts, state).await?;
        if !user.is_admin {
            return Err(ApiError::Forbidden("Admin only.".into()));
        }
        Ok(AdminUser(user))
    }
}

pub fn random_token(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut buf);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf)
}

fn session_cookie(state: &AppState, token: &str, max_age_secs: i64) -> HeaderValue {
    let secure = if state.config.cookie_secure { "; Secure" } else { "" };
    HeaderValue::from_str(&format!(
        "{COOKIE}={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age={max_age_secs}{secure}"
    ))
    .expect("valid cookie")
}

async fn start_session(state: &AppState, user_id: Uuid) -> ApiResult<(String, HeaderValue)> {
    let token = random_token(32);
    sqlx::query("INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, now() + make_interval(days => $3))")
        .bind(ss_db::sha256_hex(token.as_bytes()))
        .bind(user_id)
        .bind(SESSION_DAYS as i32)
        .execute(&state.pool)
        .await?;
    let cookie = session_cookie(state, &token, SESSION_DAYS * 86400);
    Ok((token, cookie))
}

fn with_cookie(cookie: HeaderValue, body: Value) -> Response {
    let mut headers = HeaderMap::new();
    headers.insert(header::SET_COOKIE, cookie);
    (headers, Json(body)).into_response()
}

pub async fn me_json(state: &AppState, user_id: Uuid) -> ApiResult<Value> {
    let row: Option<(String, bool, String, String, String, String, Option<i64>, String, i64, i64)> = sqlx::query_as(
        r#"SELECT u.email, u.is_admin, p.display_name, p.handle, p.tag, p.bio, p.favorite_team_id, p.visibility,
                  c.balance, c.version
           FROM users u JOIN profiles p ON p.user_id = u.id JOIN coin_accounts c ON c.user_id = u.id
           WHERE u.id = $1"#,
    )
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await?;
    let (email, is_admin, display_name, handle, tag, bio, fav, visibility, balance, version) =
        row.ok_or(ApiError::Unauthorized)?;
    Ok(json!({
        "id": user_id, "email": email, "isAdmin": is_admin, "displayName": display_name,
        "handle": handle, "tag": tag, "handleTag": format!("{handle}#{tag}"), "bio": bio,
        "favoriteTeamId": fav, "visibility": visibility, "balance": balance, "balanceVersion": version,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignupReq {
    email: String,
    password: String,
    display_name: String,
}

fn normalize_handle(display_name: &str) -> String {
    let h: String = display_name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(12)
        .collect::<String>()
        .to_uppercase();
    if h.is_empty() { "PLAYER".into() } else { h }
}

async fn signup(State(state): State<AppState>, Json(req): Json<SignupReq>) -> ApiResult<Response> {
    let email = req.email.trim().to_lowercase();
    let display_name = req.display_name.trim().to_string();
    if !email.contains('@') || email.len() > 200 {
        return Err(ApiError::BadRequest("Enter a valid email.".into()));
    }
    if req.password.len() < 8 {
        return Err(ApiError::BadRequest("Use at least 8 characters for your password.".into()));
    }
    if display_name.is_empty() || display_name.chars().count() > 40 {
        return Err(ApiError::BadRequest("Enter a display name up to 40 characters.".into()));
    }
    let hash = Argon2::default()
        .hash_password(req.password.as_bytes(), &SaltString::generate(&mut OsRng))
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("hash: {e}")))?
        .to_string();
    let is_admin = state.config.admin_emails.contains(&email);
    let handle = normalize_handle(&display_name);

    let mut tx = state.pool.begin().await?;
    let user_id: Option<Uuid> = sqlx::query_scalar(
        "INSERT INTO users (email, password_hash, is_admin) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING RETURNING id",
    )
    .bind(&email)
    .bind(&hash)
    .bind(is_admin)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(user_id) = user_id else {
        return Err(ApiError::Conflict("email_taken", "An account with this email already exists.".into()));
    };
    // Pick a free 4-digit tag for the handle.
    let mut inserted = false;
    for _ in 0..20 {
        let tag = format!("{:04}", rand::random::<u16>() % 10000);
        let n = sqlx::query(
            r#"INSERT INTO profiles (user_id, display_name, handle, tag) VALUES ($1,$2,$3,$4)
               ON CONFLICT ((upper(handle)), tag) DO NOTHING"#,
        )
        .bind(user_id)
        .bind(&display_name)
        .bind(&handle)
        .bind(&tag)
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if n == 1 {
            inserted = true;
            break;
        }
    }
    if !inserted {
        return Err(ApiError::Conflict("handle_full", "Try a different display name.".into()));
    }
    let grant = ss_core::payout::SIGNUP_GRANT;
    sqlx::query("INSERT INTO coin_accounts (user_id, balance, version) VALUES ($1, $2, 1)")
        .bind(user_id)
        .bind(grant)
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO coin_ledger (user_id, delta, reason, source_key) VALUES ($1, $2, 'signup_grant', $3)")
        .bind(user_id)
        .bind(grant)
        .bind(format!("signup:{user_id}"))
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    let (token, cookie) = start_session(&state, user_id).await?;
    let mut body = me_json(&state, user_id).await?;
    body["sessionToken"] = json!(token);
    Ok(with_cookie(cookie, body))
}

#[derive(Deserialize)]
struct LoginReq {
    email: String,
    password: String,
}

async fn login(State(state): State<AppState>, Json(req): Json<LoginReq>) -> ApiResult<Response> {
    let email = req.email.trim().to_lowercase();
    let row: Option<(Uuid, String)> = sqlx::query_as("SELECT id, password_hash FROM users WHERE lower(email) = $1")
        .bind(&email)
        .fetch_optional(&state.pool)
        .await?;
    let bad = || ApiError::BadRequest("Email or password is incorrect.".into());
    let (user_id, hash) = row.ok_or_else(bad)?;
    let parsed = PasswordHash::new(&hash).map_err(|_| bad())?;
    Argon2::default().verify_password(req.password.as_bytes(), &parsed).map_err(|_| bad())?;
    if state.config.admin_emails.contains(&email) {
        sqlx::query("UPDATE users SET is_admin = true WHERE id = $1").bind(user_id).execute(&state.pool).await?;
    }
    let (token, cookie) = start_session(&state, user_id).await?;
    let mut body = me_json(&state, user_id).await?;
    body["sessionToken"] = json!(token);
    Ok(with_cookie(cookie, body))
}

async fn logout(State(state): State<AppState>, jar: CookieJar) -> ApiResult<Response> {
    if let Some(c) = jar.get(COOKIE) {
        sqlx::query("DELETE FROM sessions WHERE token_hash = $1")
            .bind(ss_db::sha256_hex(c.value().as_bytes()))
            .execute(&state.pool)
            .await?;
    }
    Ok(with_cookie(session_cookie(&state, "", 0), json!({ "ok": true })))
}

async fn me(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    Ok(Json(me_json(&state, user.id).await?))
}
