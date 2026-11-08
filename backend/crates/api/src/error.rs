use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("{0}")]
    BadRequest(String),
    #[error("Sign in to continue.")]
    Unauthorized,
    #[error("{0}")]
    Forbidden(String),
    #[error("Not found.")]
    NotFound,
    #[error("{1}")]
    Conflict(&'static str, String),
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> Self {
        ApiError::Internal(e.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code) = match &self {
            ApiError::BadRequest(_) => (StatusCode::BAD_REQUEST, "bad_request"),
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            ApiError::Forbidden(_) => (StatusCode::FORBIDDEN, "forbidden"),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not_found"),
            ApiError::Conflict(code, _) => (StatusCode::CONFLICT, *code),
            ApiError::Internal(e) => {
                tracing::error!(error = ?e, "internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal")
            }
        };
        let message = match &self {
            ApiError::Internal(_) => "Something went wrong. Try again.".to_string(),
            other => other.to_string(),
        };
        (status, Json(json!({ "code": code, "message": message }))).into_response()
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

/// Renders a stored command outcome with its original status code.
pub fn outcome(o: ss_db::picks::Outcome) -> Response {
    let status = StatusCode::from_u16(o.http_status).unwrap_or(StatusCode::OK);
    (status, Json(o.body)).into_response()
}
