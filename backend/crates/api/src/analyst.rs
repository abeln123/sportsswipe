//! Sports analyst. Answers are computed from stored ESPN box scores with an
//! explicit definition, sample size and sources; nothing is generated or
//! guessed. Free text is matched to a player and stat, and unsupported
//! questions get an explicit "insufficient data" answer.

use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/analyst/suggestions", get(suggestions))
        .route("/analyst/form", post(form))
        .route("/analyst/ask", post(ask))
}

async fn suggestions(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let ids = ss_db::cards::deck_market_ids(&state.pool, user.id, None, 6).await?;
    let rows = ss_db::cards::market_rows(&state.pool, &ids).await?;
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for r in rows {
        if ss_core::lines::is_game_stat(&r.stat_key) { continue; }
        if !seen.insert(r.player_id) {
            continue;
        }
        let name: String = sqlx::query_scalar("SELECT full_name FROM players WHERE id = $1")
            .bind(r.player_id)
            .fetch_one(&state.pool)
            .await?;
        let specs = ss_db::cards::card_specs(&state.pool, &[r.player_id]).await?;
        out.push(json!({
            "label": format!("{name}'s recent {}", r.stat_label.to_lowercase()),
            "playerId": r.player_id, "statKey": r.stat_key, "card": specs.get(&r.player_id),
        }));
        if out.len() == 2 {
            break;
        }
    }
    Ok(Json(json!({ "suggestions": out })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FormBody {
    player_id: i64,
    stat_key: String,
    n: Option<i64>,
    opponent: Option<String>,
}

async fn form(State(state): State<AppState>, user: AuthUser, Json(b): Json<FormBody>) -> ApiResult<Json<Value>> {
    let mut report = form_report(&state, user.id, b.player_id, &b.stat_key, b.n.unwrap_or(5), b.opponent.as_deref()).await?;
    attach_share(&state, user.id, &mut report).await?;
    Ok(Json(report))
}

async fn form_report(
    state: &AppState,
    user_id: uuid::Uuid,
    player_id: i64,
    stat_key: &str,
    n: i64,
    opponent: Option<&str>,
) -> ApiResult<Value> {
    let n = n.clamp(1, 20);
    let stat: Option<(String, String)> = sqlx::query_as("SELECT label, league FROM stat_definitions WHERE key = $1")
        .bind(stat_key)
        .fetch_optional(&state.pool)
        .await?;
    let (stat_label, league) = stat.ok_or_else(|| ApiError::BadRequest("Unknown stat.".into()))?;
    let specs = ss_db::cards::card_specs(&state.pool, &[player_id]).await?;
    let card = specs.get(&player_id).cloned().ok_or(ApiError::NotFound)?;

    // Pull extra history when filtering by opponent.
    let pool_n = if opponent.is_some() { 60 } else { n };
    let mut games = ss_db::cards::recent_form(&state.pool, player_id, stat_key, pool_n).await?;
    if let Some(opp) = opponent {
        games.retain(|g| g.opponent.eq_ignore_ascii_case(opp));
        let skip = games.len().saturating_sub(n as usize);
        games.drain(..skip);
    }
    let espn_ids: Vec<(i64, String)> = sqlx::query_as("SELECT id, espn_id FROM games WHERE id = ANY($1)")
        .bind(games.iter().map(|g| g.game_id).collect::<Vec<_>>())
        .fetch_all(&state.pool)
        .await?;

    // The current open line for this player and stat, if any, plus a playable card.
    let market: Option<i64> = sqlx::query_scalar(
        r#"SELECT id FROM markets WHERE player_id = $1 AND stat_key = $2 AND status = 'open' AND lock_at > now()
           ORDER BY lock_at LIMIT 1"#,
    )
    .bind(player_id)
    .bind(stat_key)
    .fetch_optional(&state.pool)
    .await?;
    let playable = match market {
        Some(m) => ss_db::cards::playable_cards(&state.pool, Some(user_id), &[m]).await?.into_iter().next(),
        None => None,
    };
    let already_picked: Option<uuid::Uuid> = match market {
        Some(m) => sqlx::query_scalar("SELECT id FROM entries WHERE user_id = $1 AND single_market_id = $2")
            .bind(user_id)
            .bind(m)
            .fetch_optional(&state.pool)
            .await?,
        None => None,
    };
    let line = playable.as_ref().and_then(|p| p["market"]["line"].as_f64());
    let values: Vec<f64> = games.iter().map(|g| ss_db::x10_to_f64(g.value_x10)).collect();
    let name = card["fullName"].as_str().unwrap_or("This player").to_string();
    let vs = opponent.map(|o| format!(" against {o}")).unwrap_or_default();

    if values.is_empty() {
        return Ok(json!({
            "kind": "insufficient_data", "card": card, "statLabel": stat_label,
            "answer": format!("No final {} box scores for {name}{vs} are in our data yet.", stat_label.to_lowercase()),
            "playable": playable,
        }));
    }
    let avg = values.iter().sum::<f64>() / values.len() as f64;
    let min = values.iter().cloned().fold(f64::INFINITY, f64::min);
    let max = values.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let above = line.map(|l| values.iter().filter(|v| **v > l).count());
    let answer = match (line, above) {
        (Some(l), Some(a)) => format!(
            "{name} went over {l} {} in {a} of his last {} games{vs} ({}%). The average is {:.1}.",
            stat_label.to_lowercase(), values.len(), (a as f64 * 100.0 / values.len() as f64).round(), avg
        ),
        _ => format!("{name} averaged {:.1} {} over his last {} games{vs}.", avg, stat_label.to_lowercase(), values.len()),
    };
    let sport = if league == "nfl" { "nfl" } else { "nba" };
    Ok(json!({
        "kind": "form",
        "card": card,
        "statKey": stat_key,
        "statLabel": stat_label,
        "answer": answer,
        "metric": { "average": (avg * 10.0).round() / 10.0, "aboveLine": above, "games": values.len(), "line": line,
                    "rangeMin": min, "rangeMax": max },
        "games": games.iter().map(|g| json!({
            "gameId": g.game_id, "date": g.start_at, "opponent": g.opponent, "value": ss_db::x10_to_f64(g.value_x10),
            "aboveLine": line.map(|l| ss_db::x10_to_f64(g.value_x10) > l),
        })).collect::<Vec<_>>(),
        "definition": format!(
            "{stat_label} from final ESPN box scores, most recent {} completed games{vs}, oldest to latest. Games a player missed are excluded, not counted as zero.",
            values.len()
        ),
        "sources": espn_ids.iter().map(|(_, e)| json!({
            "label": format!("ESPN box score {e}"), "url": format!("https://www.espn.com/{sport}/boxscore/_/gameId/{e}"),
        })).collect::<Vec<_>>(),
        "dataAsOf": chrono::Utc::now(),
        "playable": playable,
        "alreadyPickedEntryId": already_picked,
    }))
}

/// Keyword to stat key, checked in order so "passing yards" wins over "yards".
const STAT_WORDS: &[(&str, &str)] = &[
    ("passing yard", "pass_yds"), ("pass yard", "pass_yds"), ("passing td", "pass_td"), ("passing touchdown", "pass_td"),
    ("rushing yard", "rush_yds"), ("rush yard", "rush_yds"), ("receiving yard", "rec_yds"), ("rec yard", "rec_yds"),
    ("reception", "rec"), ("catches", "rec"), ("rebound", "reb"), ("assist", "ast"), ("three", "fg3m"),
    ("3-point", "fg3m"), ("3 point", "fg3m"), ("3pt", "fg3m"), ("point", "pts"), ("scor", "pts"),
];

const UNSUPPORTED_WORDS: &[&str] = &["interception", "sack", "fumble", "steal", "block", "turnover", "tackle", "field goal %"];

#[derive(Deserialize)]
struct AskBody {
    question: String,
}

async fn ask(State(state): State<AppState>, user: AuthUser, Json(b): Json<AskBody>) -> ApiResult<Json<Value>> {
    let q = b.question.trim().to_lowercase();
    if q.len() < 3 || q.len() > 300 {
        return Err(ApiError::BadRequest("Ask a question about an NFL or NBA player.".into()));
    }
    // Longest player name contained in the question, falling back to a unique last name.
    let players: Vec<(i64, String, String, String, Option<String>)> = sqlx::query_as(
        r#"SELECT id, full_name, last_name, league, position FROM players
           WHERE active AND (position(lower(full_name) in $1) > 0 OR position(lower(last_name) in $1) > 0)
           ORDER BY (position(lower(full_name) in $1) > 0) DESC, length(full_name) DESC LIMIT 10"#,
    )
    .bind(&q)
    .fetch_all(&state.pool)
    .await?;
    let full: Vec<_> = players.iter().filter(|p| q.contains(&p.1.to_lowercase())).collect();
    let player = match full.first() {
        Some(p) => Some(*p),
        None => {
            let by_last: Vec<_> = players.iter().filter(|p| p.2.len() >= 4 && q.contains(&p.2.to_lowercase())).collect();
            if by_last.len() == 1 { Some(by_last[0]) } else { None }
        }
    };
    let Some((player_id, full_name, _, league, position)) = player.cloned() else {
        return Ok(Json(json!({
            "kind": "unmatched",
            "answer": "I couldn't match that to a current NFL or NBA player. Try a full name, like \"Josh Allen passing yards last 5 games\".",
        })));
    };
    if let Some(word) = UNSUPPORTED_WORDS.iter().find(|w| q.contains(*w)) {
        return Ok(Json(json!({
            "kind": "insufficient_data",
            "answer": format!("{word}s for {full_name} aren't in our verified data yet. Supported stats: passing, rushing and receiving yards, receptions, passing TDs, points, rebounds, assists and 3-pointers.",
                word = word.trim_end_matches('s')),
        })));
    }
    let stat_key = STAT_WORDS.iter().find(|(w, _)| q.contains(w)).map(|(_, k)| *k).unwrap_or_else(|| {
        match (league.as_str(), position.as_deref()) {
            ("nba", _) => "pts",
            (_, Some("QB")) => "pass_yds",
            (_, Some("RB")) => "rush_yds",
            _ => "rec_yds",
        }
    });
    let stat_league: Option<String> = sqlx::query_scalar("SELECT league FROM stat_definitions WHERE key = $1")
        .bind(stat_key)
        .fetch_optional(&state.pool)
        .await?;
    if stat_league.as_deref() != Some(league.as_str()) {
        return Ok(Json(json!({ "kind": "insufficient_data", "answer": format!("That stat doesn't apply to {full_name}.") })));
    }
    let n = q.split_once("last ").and_then(|(_, rest)| rest.split_whitespace().next())
        .and_then(|n| n.parse::<i64>().ok()).unwrap_or(5).clamp(1,20);
    // "against X" / "vs X": match an opponent by team name, location or abbreviation.
    let opponent = match q.split_once(" against ").or_else(|| q.split_once(" vs ")).or_else(|| q.split_once(" versus ")) {
        Some((_, rest)) => {
            let rest = rest.trim().trim_end_matches('?');
            sqlx::query_scalar::<_, String>(
                r#"SELECT abbr FROM teams WHERE league = $1 AND (
                     position(lower(short_name) in $2) > 0 OR position(lower(location) in $2) > 0 OR lower(abbr) = split_part($2, ' ', 1))
                   LIMIT 1"#,
            )
            .bind(&league)
            .bind(rest)
            .fetch_optional(&state.pool)
            .await?
        }
        None => None,
    };
    let mut report = form_report(&state, user.id, player_id, stat_key, n, opponent.as_deref()).await?;
    report["focus"] = json!(if ["clear", "over ", "above", "how often"].iter().any(|w| q.contains(w)) { "line" } else { "form" });
    if report["kind"] == "form" && report["focus"] == "line" {
        let threshold = ["cleared ", "clear ", "over ", "above "].iter()
            .find_map(|word|q.split_once(word).and_then(|(_,rest)|rest.split_whitespace().next())
                .and_then(|n|n.trim_end_matches('?').parse::<f64>().ok())).filter(|n|n.is_finite());
        if let Some(line) = threshold {
            let above = report["games"].as_array().unwrap().iter().filter(|g|g["value"].as_f64().unwrap_or(0.0)>line).count();
            report["metric"]["requestedLine"] = json!(line);
            report["metric"]["aboveRequestedLine"] = json!(above);
        }
    }
    attach_share(&state,user.id,&mut report).await?;
    Ok(Json(report))
}

async fn attach_share(state: &AppState, user: uuid::Uuid, report: &mut Value) -> ApiResult<()> {
    if report["kind"] == "form" {
        let mut snapshot = report.clone();
        // Public box-score research carries no private pick or wager state.
        snapshot.as_object_mut().unwrap().remove("alreadyPickedEntryId");
        snapshot.as_object_mut().unwrap().remove("playable");
        let id = crate::shares::save(state,user,"research",snapshot).await?;
        report["shareId"] = json!(id);
    }
    Ok(())
}
