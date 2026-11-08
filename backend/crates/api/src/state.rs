use sqlx::PgPool;
use std::sync::Arc;

pub struct Config {
    pub database_url: String,
    pub db_pool: u32,
    pub port: u16,
    /// Public origin used in invite links, e.g. https://sportsswipe.fly.dev
    pub public_base_url: String,
    pub admin_emails: Vec<String>,
    pub cookie_secure: bool,
    pub static_dir: String,
    pub cors_origin: Option<String>,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        Ok(Self {
            database_url: var("DATABASE_URL").ok_or_else(|| anyhow::anyhow!("DATABASE_URL is required"))?,
            db_pool: var("API_DB_POOL").and_then(|v| v.parse().ok()).unwrap_or(10),
            port: var("PORT").and_then(|v| v.parse().ok()).unwrap_or(8080),
            public_base_url: var("PUBLIC_BASE_URL").unwrap_or_else(|| "http://localhost:8080".into()),
            admin_emails: var("ADMIN_EMAILS")
                .map(|v| v.split(',').map(|e| e.trim().to_lowercase()).filter(|e| !e.is_empty()).collect())
                .unwrap_or_default(),
            cookie_secure: var("COOKIE_SECURE").map(|v| v == "true" || v == "1").unwrap_or(false),
            static_dir: var("STATIC_DIR").unwrap_or_else(|| "../app/build/web".into()),
            cors_origin: var("CORS_ORIGIN"),
        })
    }
}

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
}

impl AppState {
    pub fn new(pool: PgPool, config: Config) -> Self {
        Self { pool, config: Arc::new(config) }
    }
}
