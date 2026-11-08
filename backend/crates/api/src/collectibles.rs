//! Devnet-only adapter. The chain service is private; browser clients never
//! receive its shared secret or issuer key.
use crate::{
    auth::AuthUser,
    error::{ApiError, ApiResult},
    state::AppState,
};
use axum::{
    body::{Body, Bytes},
    extract::{Path, State},
    http::{HeaderMap, Method, StatusCode},
    response::Response,
    routing::any,
    Router,
};

pub fn routes() -> Router<AppState> {
    Router::new().route("/collectibles/{*path}", any(proxy))
}
async fn proxy(
    State(state): State<AppState>,
    Path(path): Path<String>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> ApiResult<Response> {
    let base = std::env::var("COLLECTIBLES_SERVICE_URL")
        .map_err(|_| ApiError::BadRequest("Devnet collectibles are not configured yet.".into()))?;
    let key = std::env::var("COLLECTIBLES_SERVICE_KEY")
        .map_err(|_| ApiError::BadRequest("Devnet collectibles are not configured yet.".into()))?;
    if !base.starts_with("http://127.0.0.1:") && !base.starts_with("http://collectibles:") {
        return Err(ApiError::BadRequest("Collectibles service must use the private local network.".into()));
    }
    if path.contains("..") || path.contains('?') || body.len() > 20000 {
        return Err(ApiError::BadRequest("Invalid collectibles request.".into()));
    }
    let session = headers.get("x-collectible-session").and_then(|v| v.to_str().ok());
    let public = path.starts_with("public/") && method == Method::GET;
    let mut request = reqwest::Client::new()
        .request(method.clone(), format!("{}/{path}", base.trim_end_matches('/')))
        .header("x-service-key", key)
        .header("content-type", "application/json")
        .timeout(std::time::Duration::from_secs(45));
    if let Some(session) = session {
        request = request.header("x-collectible-session", session);
    } else if !public && path != "session" {
        let (mut parts, _) = axum::http::Request::builder().body(()).unwrap().into_parts();
        parts.headers = headers;
        use axum::extract::FromRequestParts;
        let user = AuthUser::from_request_parts(&mut parts, &state).await?;
        request = request.header("x-user-id", user.id.to_string());
    }
    let upstream =
        request.body(body).send().await.map_err(|_| ApiError::BadRequest("Devnet service unavailable. Try again shortly.".into()))?;
    let status = StatusCode::from_u16(upstream.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let content_type = upstream.headers().get("content-type").and_then(|h| h.to_str().ok()).unwrap_or("application/json").to_owned();
    let bytes = upstream.bytes().await.map_err(|_| ApiError::BadRequest("Devnet response unavailable.".into()))?;
    Ok(Response::builder()
        .status(status)
        .header("content-type", content_type)
        .header("cache-control", "no-store")
        .body(Body::from(bytes))
        .unwrap())
}
