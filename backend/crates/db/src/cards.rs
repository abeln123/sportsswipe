//! Builds the `CardSpec` and market payloads the Flutter card renders.

use anyhow::Result;
use serde_json::{json, Value};
use sqlx::PgPool;
use std::collections::HashMap;
use uuid::Uuid;

#[derive(sqlx::FromRow)]
struct CardRow {
    player_id: i64,
    league: String,
    team_abbr: Option<String>,
    team_name: Option<String>,
    color_primary: Option<String>,
    color_alt: Option<String>,
    logo_url: Option<String>,
    jersey: Option<String>,
    first_name: String,
    last_name: String,
    full_name: String,
    position: Option<String>,
    headshot_url: Option<String>,
    card_no: Option<i32>,
    cw_base: Option<String>,
    cw_trim: Option<String>,
    cw_accent: Option<String>,
    cw_number_fill: Option<String>,
    cw_number_outline: Option<String>,
}

fn colorway(r: &CardRow) -> Value {
    let cw = match (&r.cw_base, &r.cw_trim, &r.cw_accent, &r.cw_number_fill, &r.cw_number_outline) {
        (Some(base), Some(trim), Some(accent), Some(fill), Some(outline)) => ss_core::colorway::Colorway {
            base: base.clone(),
            trim: trim.clone(),
            accent: accent.clone(),
            number_fill: fill.clone(),
            number_outline: outline.clone(),
        },
        _ => ss_core::colorway::derive(
            r.color_primary.as_deref().unwrap_or("1F2937"),
            r.color_alt.as_deref().unwrap_or("FFFFFF"),
        ),
    };
    serde_json::to_value(cw).unwrap_or(Value::Null)
}

pub async fn card_specs(pool: &PgPool, player_ids: &[i64]) -> Result<HashMap<i64, Value>> {
    let rows: Vec<CardRow> = sqlx::query_as(
        r#"SELECT p.id AS player_id, p.league, t.abbr AS team_abbr, t.name AS team_name,
                  t.color_primary, t.color_alt, t.logo_url, p.jersey, p.first_name, p.last_name,
                  p.full_name, p.position, p.headshot_url, cs.card_no,
                  cw.base AS cw_base, cw.trim AS cw_trim, cw.accent AS cw_accent,
                  cw.number_fill AS cw_number_fill, cw.number_outline AS cw_number_outline
           FROM players p
           LEFT JOIN teams t ON t.id = p.team_id
           LEFT JOIN card_series cs ON cs.player_id = p.id
           LEFT JOIN team_colorways cw ON cw.league = p.league AND cw.abbr = t.abbr AND cw.kind = 'home'
           WHERE p.id = ANY($1)"#,
    )
    .bind(player_ids)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| {
            let spec = json!({
                "playerId": r.player_id,
                "league": r.league,
                "teamAbbr": r.team_abbr,
                "teamName": r.team_name,
                "logoUrl": r.logo_url,
                "cardNo": r.card_no,
                "series": "Debut Series",
                "colorway": colorway(&r),
                "jerseyNumber": r.jersey,
                "firstName": r.first_name,
                "lastName": r.last_name,
                "fullName": r.full_name,
                "position": r.position,
                "headshotUrl": r.headshot_url,
            });
            (r.player_id, spec)
        })
        .collect())
}

pub async fn mastery_for(pool: &PgPool, user_id: Option<Uuid>, player_ids: &[i64]) -> Result<HashMap<i64, Value>> {
    let counts: HashMap<i64, i64> = match user_id {
        Some(uid) => sqlx::query_as::<_, (i64, i64)>(
            "SELECT player_id, correct_count FROM mastery_totals WHERE user_id = $1 AND player_id = ANY($2)",
        )
        .bind(uid)
        .bind(player_ids)
        .fetch_all(pool)
        .await?
        .into_iter()
        .collect(),
        None => HashMap::new(),
    };
    Ok(player_ids
        .iter()
        .map(|pid| {
            let count = counts.get(pid).copied().unwrap_or(0);
            (*pid, mastery_json(count))
        })
        .collect())
}

pub fn mastery_json(count: i64) -> Value {
    let tier = ss_core::mastery::tier_for(count);
    let next = ss_core::mastery::next_tier(count);
    json!({
        "tier": tier.as_str(),
        "count": count,
        "nextTier": next.map(|(t, _)| t.as_str()),
        "nextAt": next.map(|(_, n)| n),
    })
}

#[derive(sqlx::FromRow)]
pub struct MarketRow {
    pub market_id: i64,
    pub player_id: i64,
    pub stat_key: String,
    pub stat_label: String,
    pub stat_short: String,
    pub lock_at: chrono::DateTime<chrono::Utc>,
    pub status: String,
    pub line_version: i32,
    pub line_x10: i32,
    pub game_id: i64,
    pub start_at: chrono::DateTime<chrono::Utc>,
    pub game_status: String,
    pub home_abbr: String,
    pub away_abbr: String,
    pub is_home: bool,
    pub over_count: i32,
    pub under_count: i32,
    pub open_now: bool,
}

const MARKET_SELECT: &str = r#"
    SELECT m.id AS market_id, m.player_id, m.stat_key, sd.label AS stat_label, sd.short_label AS stat_short,
           m.lock_at, m.status, m.current_version AS line_version, lv.line_x10, g.id AS game_id, g.start_at,
           g.status AS game_status, ht.abbr AS home_abbr, at.abbr AS away_abbr,
           (p.team_id = g.home_team_id) AS is_home,
           COALESCE(pc.over_count, 0) AS over_count, COALESCE(pc.under_count, 0) AS under_count,
           (m.status = 'open' AND now() < m.lock_at) AS open_now
    FROM markets m
    JOIN line_versions lv ON lv.market_id = m.id AND lv.version = m.current_version
    JOIN stat_definitions sd ON sd.key = m.stat_key
    JOIN games g ON g.id = m.game_id
    JOIN teams ht ON ht.id = g.home_team_id
    JOIN teams at ON at.id = g.away_team_id
    JOIN players p ON p.id = m.player_id
    LEFT JOIN market_pick_counts pc ON pc.market_id = m.id
"#;

pub async fn market_rows(pool: &PgPool, market_ids: &[i64]) -> Result<Vec<MarketRow>> {
    Ok(sqlx::query_as(&format!("{MARKET_SELECT} WHERE m.id = ANY($1)"))
        .bind(market_ids)
        .fetch_all(pool)
        .await?)
}

/// Open markets for the deck, soonest lock first, skipping ones the user has
/// already picked as a single.
pub async fn deck_market_ids(pool: &PgPool, user_id: Uuid, league: Option<&str>, limit: i64) -> Result<Vec<i64>> {
    Ok(sqlx::query_scalar(
        r#"SELECT m.id FROM markets m JOIN players p ON p.id = m.player_id
           WHERE m.status = 'open' AND m.lock_at > now()
             AND ($2::text IS NULL OR p.league = $2)
             AND NOT EXISTS (SELECT 1 FROM entries e WHERE e.user_id = $1 AND e.single_market_id = m.id)
           ORDER BY m.lock_at, m.id LIMIT $3"#,
    )
    .bind(user_id)
    .bind(league)
    .bind(limit)
    .fetch_all(pool)
    .await?)
}

pub struct FormPoint {
    pub game_id: i64,
    pub value_x10: i32,
    pub start_at: chrono::DateTime<chrono::Utc>,
    pub opponent: String,
}

/// Last `n` final games for a player and stat, oldest first.
pub async fn recent_form(pool: &PgPool, player_id: i64, stat_key: &str, n: i64) -> Result<Vec<FormPoint>> {
    let mut rows: Vec<(i64, i32, chrono::DateTime<chrono::Utc>, String)> = sqlx::query_as(
        r#"SELECT s.game_id, s.value_x10, g.start_at,
                  CASE WHEN g.home_team_id = s.team_id THEN at.abbr ELSE ht.abbr END
           FROM (SELECT DISTINCT ON (pgs.game_id) pgs.game_id, pgs.value_x10, p.team_id
                 FROM player_game_stats pgs JOIN players p ON p.id = pgs.player_id
                 WHERE pgs.player_id = $1 AND pgs.stat_key = $2 AND pgs.source = 'espn'
                 ORDER BY pgs.game_id, pgs.revision DESC) s
           JOIN games g ON g.id = s.game_id AND g.status = 'final'
           JOIN teams ht ON ht.id = g.home_team_id
           JOIN teams at ON at.id = g.away_team_id
           ORDER BY g.start_at DESC LIMIT $3"#,
    )
    .bind(player_id)
    .bind(stat_key)
    .bind(n)
    .fetch_all(pool)
    .await?;
    rows.reverse();
    Ok(rows
        .into_iter()
        .map(|(game_id, value_x10, start_at, opponent)| FormPoint { game_id, value_x10, start_at, opponent })
        .collect())
}

/// Full playable card: spec, market, recent form, community split and the
/// viewer's mastery progress.
pub async fn playable_cards(pool: &PgPool, user_id: Option<Uuid>, market_ids: &[i64]) -> Result<Vec<Value>> {
    let rows = market_rows(pool, market_ids).await?;
    let player_ids: Vec<i64> = rows.iter().map(|r| r.player_id).collect();
    let specs = card_specs(pool, &player_ids).await?;
    let mastery = mastery_for(pool, user_id, &player_ids).await?;
    let mut by_id: HashMap<i64, Value> = HashMap::new();
    for r in &rows {
        let form: Vec<f64> = if ss_core::lines::is_game_stat(&r.stat_key) {
            team_form(pool, r.player_id, &r.stat_key).await?
        } else {
            recent_form(pool, r.player_id, &r.stat_key, ss_core::lines::FORM_GAMES as i64)
                .await?
                .iter()
                .map(|f| crate::x10_to_f64(f.value_x10))
                .collect()
        };
        by_id.insert(r.market_id, json!({
            "card": specs.get(&r.player_id),
            "market": market_json(r),
            "recentForm": form,
            "mastery": mastery.get(&r.player_id),
        }));
    }
    Ok(market_ids.iter().filter_map(|id| by_id.remove(id)).collect())
}

/// A team's last finals, oldest first: its margin, or combined points for totals.
async fn team_form(pool: &PgPool, team_player_id: i64, stat_key: &str) -> Result<Vec<f64>> {
    let mut rows: Vec<(i32, i32)> = sqlx::query_as(
        r#"SELECT CASE WHEN g.home_team_id = p.team_id THEN g.home_score - g.away_score ELSE g.away_score - g.home_score END,
                  g.home_score + g.away_score
           FROM players p JOIN games g ON g.home_team_id = p.team_id OR g.away_team_id = p.team_id
           WHERE p.id = $1 AND g.status = 'final' AND g.home_score IS NOT NULL AND g.away_score IS NOT NULL
           ORDER BY g.start_at DESC LIMIT $2"#,
    )
    .bind(team_player_id)
    .bind(ss_core::lines::FORM_GAMES as i64)
    .fetch_all(pool)
    .await?;
    rows.reverse();
    Ok(rows.into_iter().map(|(m, t)| if stat_key == "total" { t as f64 } else { m as f64 }).collect())
}

pub fn market_json(r: &MarketRow) -> Value {
    let total = r.over_count + r.under_count;
    let (team, opp) = if r.is_home { (&r.home_abbr, &r.away_abbr) } else { (&r.away_abbr, &r.home_abbr) };
    let labels = ss_core::lines::side_labels(&r.stat_key, r.line_x10, &r.home_abbr, &r.away_abbr);
    json!({
        "kind": if labels.is_some() { "game" } else { "player" },
        "overLabel": labels.as_ref().map(|l| &l.0),
        "underLabel": labels.as_ref().map(|l| &l.1),
        "homeAbbr": r.home_abbr,
        "awayAbbr": r.away_abbr,
        "marketId": r.market_id,
        "lineVersion": r.line_version,
        "line": crate::x10_to_f64(r.line_x10),
        "statKey": r.stat_key,
        "statLabel": r.stat_label,
        "statShort": r.stat_short,
        "lockAt": r.lock_at,
        "startAt": r.start_at,
        "status": r.status,
        "open": r.open_now,
        "gameId": r.game_id,
        "gameStatus": r.game_status,
        "matchup": format!("{team} vs {opp}"),
        "community": {
            "total": total,
            "overPct": if total > 0 { (r.over_count as f64 * 100.0 / total as f64).round() as i64 } else { 50 },
        },
    })
}
