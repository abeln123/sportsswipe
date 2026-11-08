//! Admin data export for presentations: CSV per dataset plus summary stats.
//! Admin accounts are excluded from the stats but listed in `users.csv`.

use crate::auth::AdminUser;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::{Path, State},
    http::header,
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/admin/export/{dataset}", get(export_csv))
        .route("/admin/stats", get(stats))
}

const QUICK_DOMAIN: &str = "%@quick.sportsswipe";

struct Dataset {
    columns: &'static [&'static str],
    sql: &'static str,
}

fn dataset(name: &str) -> Option<Dataset> {
    Some(match name {
        "users" => Dataset {
            columns: &["user_id", "display_name", "handle", "email", "quick_signup", "is_admin", "signed_up_at", "balance", "picks", "contest_entries"],
            sql: r#"SELECT u.id AS user_id, p.display_name, p.handle || '#' || p.tag AS handle,
                           CASE WHEN u.email LIKE '%@quick.sportsswipe' THEN '' ELSE u.email END AS email,
                           u.email LIKE '%@quick.sportsswipe' AS quick_signup, u.is_admin,
                           u.created_at AS signed_up_at, c.balance,
                           (SELECT count(*) FROM entries e WHERE e.user_id = u.id) AS picks,
                           (SELECT count(*) FROM contest_entries ce WHERE ce.user_id = u.id) AS contest_entries
                    FROM users u JOIN profiles p ON p.user_id = u.id JOIN coin_accounts c ON c.user_id = u.id
                    ORDER BY u.created_at"#,
        },
        "picks" => Dataset {
            columns: &[
                "entry_id", "user_id", "handle", "is_admin", "kind", "legs", "stake", "potential_return", "status", "credited",
                "accepted_at", "settled_at", "leg_no", "league", "player", "team", "stat", "line", "side", "leg_result",
            ],
            sql: r#"SELECT e.id AS entry_id, e.user_id, p.handle || '#' || p.tag AS handle, u.is_admin, e.kind,
                           (SELECT count(*) FROM entry_legs x WHERE x.entry_id = e.id) AS legs,
                           e.stake, e.potential_return, e.status, e.credited, e.accepted_at, e.settled_at,
                           el.leg_no, pl.league, pl.full_name AS player, t.abbr AS team, sd.label AS stat,
                           el.line_x10 / 10.0 AS line, el.side, el.result AS leg_result
                    FROM entries e JOIN users u ON u.id = e.user_id JOIN profiles p ON p.user_id = e.user_id
                    JOIN entry_legs el ON el.entry_id = e.id JOIN markets m ON m.id = el.market_id
                    JOIN players pl ON pl.id = m.player_id LEFT JOIN teams t ON t.id = pl.team_id
                    JOIN stat_definitions sd ON sd.key = m.stat_key
                    ORDER BY e.accepted_at, el.leg_no"#,
        },
        "contest_entries" => Dataset {
            columns: &["contest_entry_id", "user_id", "handle", "is_admin", "game_date", "submitted_at", "tiebreak", "points"],
            sql: r#"SELECT ce.id AS contest_entry_id, ce.user_id, p.handle || '#' || p.tag AS handle, u.is_admin,
                           cd.game_date, ce.submitted_at, ce.tiebreak_x10 / 10.0 AS tiebreak, ce.points
                    FROM contest_entries ce JOIN users u ON u.id = ce.user_id JOIN profiles p ON p.user_id = ce.user_id
                    JOIN contest_days cd ON cd.id = ce.contest_day_id
                    ORDER BY ce.submitted_at"#,
        },
        "contest_answers" => Dataset {
            columns: &["contest_entry_id", "handle", "game_date", "q_no", "league", "player", "stat", "line", "side", "result"],
            sql: r#"SELECT ce.id AS contest_entry_id, p.handle || '#' || p.tag AS handle, cd.game_date, q.q_no,
                           pl.league, pl.full_name AS player, sd.label AS stat, q.line_x10 / 10.0 AS line,
                           ca.side, q.result
                    FROM contest_answers ca JOIN contest_entries ce ON ce.id = ca.entry_id
                    JOIN profiles p ON p.user_id = ce.user_id JOIN contest_days cd ON cd.id = ce.contest_day_id
                    JOIN contest_questions q ON q.id = ca.question_id JOIN markets m ON m.id = q.market_id
                    JOIN players pl ON pl.id = m.player_id JOIN stat_definitions sd ON sd.key = m.stat_key
                    ORDER BY ce.submitted_at, q.q_no"#,
        },
        _ => return None,
    })
}

fn csv_field(v: &Value) -> String {
    let s = match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    if s.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s
    }
}

async fn export_csv(State(state): State<AppState>, _: AdminUser, Path(file): Path<String>) -> ApiResult<Response> {
    let name = file.strip_suffix(".csv").unwrap_or(&file);
    let ds = dataset(name).ok_or(ApiError::NotFound)?;
    let rows: Vec<Value> = sqlx::query_scalar(&format!("SELECT row_to_json(t) FROM ({}) t", ds.sql))
        .fetch_all(&state.pool)
        .await?;
    let mut out = ds.columns.join(",");
    out.push('\n');
    for row in &rows {
        let line: Vec<String> = ds.columns.iter().map(|c| csv_field(row.get(*c).unwrap_or(&Value::Null))).collect();
        out.push_str(&line.join(","));
        out.push('\n');
    }
    Ok((
        [
            (header::CONTENT_TYPE, "text/csv; charset=utf-8".to_string()),
            (header::CONTENT_DISPOSITION, format!("attachment; filename=\"{name}.csv\"")),
        ],
        out,
    )
        .into_response())
}

async fn stats(State(state): State<AppState>, _: AdminUser) -> ApiResult<Json<Value>> {
    let pool = &state.pool;
    let (users, quick): (i64, i64) = sqlx::query_as(
        "SELECT count(*), count(*) FILTER (WHERE email LIKE $1) FROM users WHERE NOT is_admin",
    )
    .bind(QUICK_DOMAIN)
    .fetch_one(pool)
    .await?;
    let (entries, singles, parlays, free, coins_wagered, won, lost, settled): (i64, i64, i64, i64, i64, i64, i64, i64) =
        sqlx::query_as(
            r#"SELECT count(*), count(*) FILTER (WHERE kind = 'single'), count(*) FILTER (WHERE kind = 'parlay'),
                      count(*) FILTER (WHERE stake = 0), coalesce(sum(stake), 0)::bigint,
                      count(*) FILTER (WHERE status = 'won'), count(*) FILTER (WHERE status = 'lost'),
                      count(*) FILTER (WHERE status IN ('won', 'lost'))
               FROM entries e JOIN users u ON u.id = e.user_id WHERE NOT u.is_admin"#,
        )
        .fetch_one(pool)
        .await?;
    let (legs, overs): (i64, i64) = sqlx::query_as(
        r#"SELECT count(*), count(*) FILTER (WHERE el.side = 'over')
           FROM entry_legs el JOIN entries e ON e.id = el.entry_id JOIN users u ON u.id = e.user_id WHERE NOT u.is_admin"#,
    )
    .fetch_one(pool)
    .await?;
    let by_league: Vec<(String, i64)> = sqlx::query_as(
        r#"SELECT pl.league, count(*) FROM entry_legs el JOIN entries e ON e.id = el.entry_id
           JOIN users u ON u.id = e.user_id JOIN markets m ON m.id = el.market_id JOIN players pl ON pl.id = m.player_id
           WHERE NOT u.is_admin GROUP BY pl.league ORDER BY 2 DESC"#,
    )
    .fetch_all(pool)
    .await?;
    let top_players: Vec<(String, String, i64, i64)> = sqlx::query_as(
        r#"SELECT pl.full_name, pl.league, count(*), count(*) FILTER (WHERE el.side = 'over')
           FROM entry_legs el JOIN entries e ON e.id = el.entry_id JOIN users u ON u.id = e.user_id
           JOIN markets m ON m.id = el.market_id JOIN players pl ON pl.id = m.player_id
           WHERE NOT u.is_admin GROUP BY pl.full_name, pl.league ORDER BY 3 DESC LIMIT 10"#,
    )
    .fetch_all(pool)
    .await?;
    let (contest_entries, contest_users): (i64, i64) = sqlx::query_as(
        r#"SELECT count(*), count(DISTINCT ce.user_id) FROM contest_entries ce JOIN users u ON u.id = ce.user_id
           WHERE NOT u.is_admin"#,
    )
    .fetch_one(pool)
    .await?;
    let active: i64 = sqlx::query_scalar(
        r#"SELECT count(DISTINCT e.user_id) FROM entries e JOIN users u ON u.id = e.user_id WHERE NOT u.is_admin"#,
    )
    .fetch_one(pool)
    .await?;
    let pct = |a: i64, b: i64| if b == 0 { Value::Null } else { json!(((a as f64) * 1000.0 / b as f64).round() / 10.0) };
    let ratio = |a: i64, b: i64| if b == 0 { Value::Null } else { json!(((a as f64) * 10.0 / b as f64).round() / 10.0) };
    Ok(Json(json!({
        "users": { "total": users, "quickSignups": quick, "withAtLeastOnePick": active },
        "picks": {
            "entries": entries, "singles": singles, "parlays": parlays, "freePicks": free,
            "picksPerActiveUser": ratio(entries, active),
            "coinsWagered": coins_wagered, "averageStake": ratio(coins_wagered, entries),
            "legs": legs, "overPct": pct(overs, legs),
            "settled": settled, "won": won, "lost": lost, "winPct": pct(won, settled),
        },
        "legsByLeague": by_league.into_iter().map(|(l, n)| json!({ "league": l, "legs": n })).collect::<Vec<_>>(),
        "topPlayers": top_players.into_iter().map(|(name, league, n, o)| json!({
            "player": name, "league": league, "picks": n, "overPct": pct(o, n),
        })).collect::<Vec<_>>(),
        "contests": { "entries": contest_entries, "players": contest_users },
    })))
}
