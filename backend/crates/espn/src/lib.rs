//! ESPN site API client. Responses are parsed from `serde_json::Value` because
//! the public payloads are large, undocumented and vary between leagues; only
//! the fields we store are extracted.

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum League {
    Nfl,
    Nba,
}

impl League {
    pub fn as_str(self) -> &'static str {
        match self {
            League::Nfl => "nfl",
            League::Nba => "nba",
        }
    }
    pub fn parse(s: &str) -> Option<League> {
        match s {
            "nfl" => Some(League::Nfl),
            "nba" => Some(League::Nba),
            _ => None,
        }
    }
    fn path(self) -> &'static str {
        match self {
            League::Nfl => "football/nfl",
            League::Nba => "basketball/nba",
        }
    }
    pub const ALL: [League; 2] = [League::Nfl, League::Nba];
}

#[derive(Debug, Clone, PartialEq)]
pub struct Team {
    pub espn_id: String,
    pub abbr: String,
    pub name: String,
    pub short_name: String,
    pub location: String,
    pub color: String,
    pub alternate_color: String,
    pub logo_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RosterPlayer {
    pub espn_id: String,
    pub full_name: String,
    pub first_name: String,
    pub last_name: String,
    pub jersey: Option<String>,
    pub position: Option<String>,
    pub headshot_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GameSide {
    pub team_espn_id: String,
    pub score: Option<i32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ScoreboardGame {
    pub espn_id: String,
    pub start_at: DateTime<Utc>,
    pub season: i32,
    pub season_type: i32,
    pub week: Option<i32>,
    /// One of scheduled, in, final, postponed, canceled.
    pub status: &'static str,
    pub status_detail: String,
    pub home: GameSide,
    pub away: GameSide,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BoxStat {
    pub athlete_espn_id: String,
    pub team_espn_id: String,
    pub category: Option<String>,
    pub key: String,
    pub value_x10: i32,
}

#[derive(Debug, Clone, Default)]
pub struct BoxScore {
    pub stats: Vec<BoxStat>,
    /// Athletes listed in the box score who did not play.
    pub did_not_play: Vec<String>,
}

fn s(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(x)) => x.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn opt(v: &Value, key: &str) -> Option<String> {
    let x = s(v, key);
    (!x.is_empty()).then_some(x)
}

pub fn parse_teams(body: &Value) -> Vec<Team> {
    let teams = body
        .pointer("/sports/0/leagues/0/teams")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    teams
        .iter()
        .filter_map(|t| t.get("team"))
        .filter(|t| t.get("isActive").and_then(Value::as_bool).unwrap_or(true))
        .map(|t| Team {
            espn_id: s(t, "id"),
            abbr: s(t, "abbreviation"),
            name: s(t, "displayName"),
            short_name: s(t, "shortDisplayName"),
            location: s(t, "location"),
            color: opt(t, "color").unwrap_or_else(|| "1F2937".into()),
            alternate_color: opt(t, "alternateColor").unwrap_or_else(|| "FFFFFF".into()),
            logo_url: t.pointer("/logos/0/href").and_then(Value::as_str).map(str::to_string),
        })
        .collect()
}

fn parse_athlete(a: &Value) -> Option<RosterPlayer> {
    let espn_id = opt(a, "id")?;
    Some(RosterPlayer {
        espn_id,
        full_name: s(a, "fullName"),
        first_name: s(a, "firstName"),
        last_name: s(a, "lastName"),
        jersey: opt(a, "jersey"),
        position: a.pointer("/position/abbreviation").and_then(Value::as_str).map(str::to_string),
        headshot_url: a.pointer("/headshot/href").and_then(Value::as_str).map(str::to_string),
    })
}

/// NFL rosters group athletes as `athletes[].items[]`; NBA rosters are a flat
/// `athletes[]` list.
pub fn parse_roster(body: &Value) -> Vec<RosterPlayer> {
    let groups = body.get("athletes").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut out = Vec::new();
    for g in &groups {
        if let Some(items) = g.get("items").and_then(Value::as_array) {
            out.extend(items.iter().filter_map(parse_athlete));
        } else if let Some(p) = parse_athlete(g) {
            out.push(p);
        }
    }
    out
}

fn status_of(event: &Value) -> &'static str {
    let name = event.pointer("/status/type/name").and_then(Value::as_str).unwrap_or("");
    let state = event.pointer("/status/type/state").and_then(Value::as_str).unwrap_or("");
    match name {
        "STATUS_POSTPONED" => "postponed",
        "STATUS_CANCELED" | "STATUS_CANCELLED" => "canceled",
        _ => match state {
            "in" => "in",
            "post" => "final",
            _ => "scheduled",
        },
    }
}

pub fn parse_scoreboard(body: &Value) -> Vec<ScoreboardGame> {
    let events = body.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
    let board_week = body.pointer("/week/number").and_then(Value::as_i64).map(|w| w as i32);
    events
        .iter()
        .filter_map(|e| {
            let comp = e.pointer("/competitions/0")?;
            let competitors = comp.get("competitors")?.as_array()?;
            let side = |which: &str| -> Option<GameSide> {
                let c = competitors.iter().find(|c| c.get("homeAway").and_then(Value::as_str) == Some(which))?;
                Some(GameSide {
                    team_espn_id: c.pointer("/team/id")?.as_str()?.to_string(),
                    score: c.get("score").and_then(Value::as_str).and_then(|x| x.parse().ok()),
                })
            };
            let date = s(e, "date");
            let start_at = parse_espn_date(&date)?;
            Some(ScoreboardGame {
                espn_id: s(e, "id"),
                start_at,
                season: e.pointer("/season/year").and_then(Value::as_i64).unwrap_or(0) as i32,
                season_type: e.pointer("/season/type").and_then(Value::as_i64).unwrap_or(2) as i32,
                week: e.pointer("/week/number").and_then(Value::as_i64).map(|w| w as i32).or(board_week),
                status: status_of(e),
                status_detail: e.pointer("/status/type/shortDetail").and_then(Value::as_str).unwrap_or("").to_string(),
                home: side("home")?,
                away: side("away")?,
            })
        })
        .collect()
}

/// ESPN dates are UTC and usually omit seconds, e.g. `2026-11-06T01:15Z`.
pub fn parse_espn_date(raw: &str) -> Option<DateTime<Utc>> {
    if let Ok(d) = DateTime::parse_from_rfc3339(raw) {
        return Some(d.with_timezone(&Utc));
    }
    chrono::NaiveDateTime::parse_from_str(raw.trim_end_matches('Z'), "%Y-%m-%dT%H:%M")
        .ok()
        .map(|n| n.and_utc())
}

/// Parses a raw stat cell such as "242", "5-12" (first number) or "--".
pub fn parse_stat_cell(raw: &str) -> Option<i32> {
    let raw = raw.trim();
    // A whole-cell number covers negatives such as -3 rushing yards.
    let v: f64 = match raw.parse() {
        Ok(v) => v,
        Err(_) => raw.split(['-', '/']).next()?.trim().parse().ok()?,
    };
    Some((v * 10.0).round() as i32)
}

pub fn parse_box_score(body: &Value) -> BoxScore {
    let mut out = BoxScore::default();
    let teams = body.pointer("/boxscore/players").and_then(Value::as_array).cloned().unwrap_or_default();
    for team in &teams {
        let team_id = team.pointer("/team/id").and_then(Value::as_str).unwrap_or("").to_string();
        for block in team.get("statistics").and_then(Value::as_array).into_iter().flatten() {
            let category = block.get("name").and_then(Value::as_str).map(str::to_string);
            let keys: Vec<String> = block
                .get("keys")
                .and_then(Value::as_array)
                .map(|k| k.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            for a in block.get("athletes").and_then(Value::as_array).into_iter().flatten() {
                let Some(id) = a.pointer("/athlete/id").and_then(Value::as_str) else { continue };
                if a.get("didNotPlay").and_then(Value::as_bool).unwrap_or(false) {
                    out.did_not_play.push(id.to_string());
                    continue;
                }
                let stats = a.get("stats").and_then(Value::as_array).cloned().unwrap_or_default();
                for (key, raw) in keys.iter().zip(stats.iter()) {
                    let Some(value_x10) = raw.as_str().and_then(parse_stat_cell) else { continue };
                    out.stats.push(BoxStat {
                        athlete_espn_id: id.to_string(),
                        team_espn_id: team_id.clone(),
                        category: category.clone(),
                        key: key.clone(),
                        value_x10,
                    });
                }
            }
        }
    }
    out
}

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    base: String,
}

impl Client {
    pub fn new(base: impl Into<String>) -> Self {
        let http = reqwest::Client::builder()
            .user_agent("sportsswipe/0.1")
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .expect("http client");
        Self { http, base: base.into() }
    }

    async fn get(&self, url: String) -> Result<Value> {
        let res = self.http.get(&url).send().await.with_context(|| format!("GET {url}"))?;
        let res = res.error_for_status().with_context(|| format!("GET {url}"))?;
        Ok(res.json().await?)
    }

    pub async fn teams_raw(&self, league: League) -> Result<Value> {
        self.get(format!("{}/{}/teams", self.base, league.path())).await
    }

    pub async fn roster_raw(&self, league: League, team_espn_id: &str) -> Result<Value> {
        self.get(format!("{}/{}/teams/{}/roster", self.base, league.path(), team_espn_id)).await
    }

    /// `dates` is `YYYYMMDD` (NBA). `week` selects an NFL regular-season week.
    pub async fn scoreboard_raw(&self, league: League, dates: Option<&str>, week: Option<i32>) -> Result<Value> {
        let mut url = format!("{}/{}/scoreboard?limit=200", self.base, league.path());
        if let Some(d) = dates {
            url.push_str(&format!("&dates={d}"));
        }
        if let Some(w) = week {
            url.push_str(&format!("&week={w}&seasontype=2"));
        }
        self.get(url).await
    }

    pub async fn summary_raw(&self, league: League, event_id: &str) -> Result<Value> {
        self.get(format!("{}/{}/summary?event={}", self.base, league.path(), event_id)).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Value {
        let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    #[test]
    fn stat_cells() {
        assert_eq!(parse_stat_cell("242"), Some(2420));
        assert_eq!(parse_stat_cell("5-12"), Some(50));
        assert_eq!(parse_stat_cell("16/26"), Some(160));
        assert_eq!(parse_stat_cell("9.3"), Some(93));
        assert_eq!(parse_stat_cell("-3"), Some(-30));
        assert_eq!(parse_stat_cell("--"), None);
    }

    #[test]
    fn nfl_teams_have_colors() {
        let teams = parse_teams(&fixture("nfl_teams.json"));
        assert_eq!(teams.len(), 32);
        let buf = teams.iter().find(|t| t.abbr == "BUF").unwrap();
        assert!(!buf.color.is_empty());
        assert!(buf.logo_url.is_some());
    }

    #[test]
    fn nfl_roster_is_grouped() {
        let players = parse_roster(&fixture("nfl_roster.json"));
        let allen = players.iter().find(|p| p.full_name == "Josh Allen").unwrap();
        assert_eq!(allen.jersey.as_deref(), Some("17"));
        assert_eq!(allen.position.as_deref(), Some("QB"));
        assert!(players.len() > 40);
    }

    #[test]
    fn nba_roster_is_flat() {
        let players = parse_roster(&fixture("nba_roster.json"));
        assert!(players.len() >= 10);
        assert!(players.iter().all(|p| !p.espn_id.is_empty()));
    }

    #[test]
    fn scoreboards_parse() {
        let nfl = parse_scoreboard(&fixture("nfl_scoreboard.json"));
        assert!(!nfl.is_empty());
        assert!(nfl.iter().all(|g| g.week.is_some()));
        let nba = parse_scoreboard(&fixture("nba_scoreboard.json"));
        assert!(!nba.is_empty());
    }

    #[test]
    fn nfl_box_score() {
        let b = parse_box_score(&fixture("nfl_summary.json"));
        let lawrence = b
            .stats
            .iter()
            .find(|s| s.athlete_espn_id == "4360310" && s.key == "passingYards")
            .unwrap();
        assert_eq!(lawrence.value_x10, 2420);
        assert_eq!(lawrence.category.as_deref(), Some("passing"));
    }

    #[test]
    fn nba_box_score() {
        let b = parse_box_score(&fixture("nba_summary.json"));
        assert!(b.stats.iter().any(|s| s.key == "points"));
        assert!(b.stats.iter().any(|s| s.key.starts_with("threePointFieldGoalsMade")));
    }
}
