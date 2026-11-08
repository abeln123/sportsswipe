mod admin;
mod analyst;
mod auth;
mod contests;
mod error;
mod export;
mod game;
mod invites;
mod packs;
mod profile;
mod social;
mod state;

use axum::{routing::get, Router};
use std::net::SocketAddr;
use tower_http::{
    cors::{AllowHeaders, AllowMethods, AllowOrigin, CorsLayer},
    services::{ServeDir, ServeFile},
    trace::TraceLayer,
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info,sqlx=warn,tower_http=info".into()))
        .init();
    let config = state::Config::from_env()?;
    let pool = ss_db::connect(&config.database_url, config.db_pool).await?;
    ss_db::migrate(&pool).await?;
    let static_dir = config.static_dir.clone();
    let cors_origin = config.cors_origin.clone();
    let port = config.port;
    let state = state::AppState::new(pool, config);

    let api = Router::new()
        .merge(auth::routes())
        .merge(game::routes())
        .merge(admin::routes())
        .merge(contests::routes())
        .merge(social::routes())
        .merge(invites::routes())
        .merge(profile::routes())
        .merge(analyst::routes())
        .merge(export::routes())
        .merge(packs::routes())
        .route("/healthz", get(|| async { "ok" }));

    let mut app = Router::new()
        .nest("/v1", api)
        .route("/i/{token}", get(invites::landing_page))
        .with_state(state);

    let index = format!("{static_dir}/index.html");
    app = app.fallback_service(ServeDir::new(&static_dir).not_found_service(ServeFile::new(index)));

    if let Some(origin) = cors_origin {
        app = app.layer(
            CorsLayer::new()
                .allow_origin(AllowOrigin::exact(origin.parse()?))
                .allow_credentials(true)
                .allow_methods(AllowMethods::mirror_request())
                .allow_headers(AllowHeaders::mirror_request()),
        );
    }
    let app = app.layer(TraceLayer::new_for_http());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    tracing::info!(%addr, "api listening");
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
