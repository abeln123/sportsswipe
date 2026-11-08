use super::plan::{Plan, STATS};
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Datelike, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::PgPool;
use std::collections::BTreeMap;

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct Subject {
    pub id: i64,
    pub espn_id: String,
    pub name: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Game {
    pub event_id: String,
    pub date: DateTime<Utc>,
    pub season: i32,
    pub postseason: bool,
    pub opponent: String,
    pub opponent_id: String,
    pub team_id: String,
    pub home: bool,
    pub value: f64,
    pub result: String,
    pub points_for: i32,
    pub points_against: i32,
    pub rest_days: Option<i64>,
    pub origin: String,
}
pub struct Evidence {
    pub subject: Subject,
    pub games: Vec<Game>,
    pub warnings: Vec<String>,
    pub requests: usize,
    pub cached: usize,
    pub db_games: usize,
}

pub async fn resolve(pool: &PgPool, plan: &Plan) -> Result<Subject> {
    let name = if plan.subject == "player" {
        plan.player.as_deref()
    } else {
        plan.team.as_deref()
    }
    .context("Name a player or team")?;
    let rows: Vec<Subject> = if plan.subject == "player" {
        sqlx::query_as("SELECT id,espn_id,full_name AS name,league,team_id FROM players WHERE league=$1 AND COALESCE(position,'')<>'TEAM' AND (lower(full_name)=lower($2) OR lower(last_name)=lower($2)) ORDER BY (lower(full_name)=lower($2)) DESC LIMIT 3")
    .bind(&plan.league).bind(name).fetch_all(pool).await?
    } else {
        sqlx::query_as("SELECT id,espn_id,name,league,id AS team_id FROM teams WHERE league=$1 AND (lower(name)=lower($2) OR lower(abbr)=lower($2) OR lower(short_name)=lower($2) OR lower(location)=lower($2)) LIMIT 3")
    .bind(&plan.league).bind(name).fetch_all(pool).await?
    };
    if rows.len() != 1 {
        bail!(
            "I couldn't identify one {} named {name}. Use the full {} name.",
            plan.subject,
            plan.subject
        );
    }
    Ok(rows.into_iter().next().unwrap())
}
pub async fn opponent(pool: &PgPool, plan: &Plan) -> Result<Option<(String, String)>> {
    let Some(name) = &plan.opponent else {
        return Ok(None);
    };
    let rows:Vec<(String,String)>=sqlx::query_as("SELECT espn_id,abbr FROM teams WHERE league=$1 AND (lower(name)=lower($2) OR lower(abbr)=lower($2) OR lower(short_name)=lower($2) OR lower(location)=lower($2)) LIMIT 3")
  .bind(&plan.league).bind(name).fetch_all(pool).await?;
    if rows.len() != 1 {
        bail!("Which opponent do you mean by {name}? Please use the full team name.");
    }
    Ok(rows.into_iter().next())
}
fn sport(league: &str) -> &str {
    if league == "nfl" {
        "football/nfl"
    } else {
        "basketball/nba"
    }
}
fn number(v: &Value) -> Option<i32> {
    v.as_f64()
        .or_else(|| v.as_str()?.replace(',', "").parse().ok())
        .map(|n| n.round() as i32)
}
fn string(v: &Value) -> String {
    v.as_str()
        .map(str::to_string)
        .or_else(|| v.as_i64().map(|n| n.to_string()))
        .unwrap_or_default()
}
pub fn box_url(league: &str, id: &str) -> String {
    format!("https://www.espn.com/{league}/boxscore/_/gameId/{id}")
}

async fn source(
    pool: &PgPool,
    http: &reqwest::Client,
    resource: &str,
    old: bool,
) -> Result<(Value, bool, bool)> {
    let cached: Option<(Value, DateTime<Utc>)> =
        sqlx::query_as("SELECT body,fetched_at FROM analyst_source_cache WHERE resource=$1")
            .bind(resource)
            .fetch_optional(pool)
            .await?;
    let ttl = if old {
        chrono::Duration::days(7)
    } else {
        chrono::Duration::minutes(15)
    };
    if let Some((body, at)) = &cached {
        if Utc::now() - *at < ttl {
            return Ok((body.clone(), true, false));
        }
    }
    let origin = if resource.starts_with("logs/") {
        std::env::var("ANALYST_ESPN_WEB_BASE")
            .unwrap_or_else(|_| "https://site.web.api.espn.com/apis/common/v3/sports".into())
    } else {
        std::env::var("ESPN_BASE_URL")
            .unwrap_or_else(|_| "https://site.api.espn.com/apis/site/v2/sports".into())
    };
    let path = resource.split_once('/').context("Invalid ESPN resource")?.1;
    let fetched: Result<Value> = async {
        let r = http
            .get(format!("{}/{path}", origin.trim_end_matches('/')))
            .send()
            .await?
            .error_for_status()?;
        if r.content_length().is_some_and(|n| n > 4_000_000) {
            bail!("ESPN response too large");
        }
        let bytes = r.bytes().await?;
        if bytes.len() > 4_000_000 {
            bail!("ESPN response too large");
        }
        Ok(serde_json::from_slice(&bytes)?)
    }
    .await;
    match fetched {
        Ok(body) => {
            sqlx::query("INSERT INTO analyst_source_cache(resource,body) VALUES($1,$2) ON CONFLICT(resource) DO UPDATE SET body=EXCLUDED.body,fetched_at=now()")
   .bind(resource).bind(&body).execute(pool).await?;
            Ok((body, false, false))
        }
        Err(e) => match cached {
            Some((body, _)) => Ok((body, true, true)),
            None => Err(e),
        },
    }
}

pub fn parse_logs(body: &Value, season: i32, stat: &str, league: &str) -> Vec<Game> {
    let Some(column) = STATS
        .iter()
        .find(|s| s.0 == stat && s.1 == league)
        .map(|s| s.3)
    else {
        return vec![];
    };
    let Some(index) = body["names"].as_array().and_then(|a| {
        a.iter().position(|v| {
            v.as_str()
                .is_some_and(|name| name == column || name.starts_with(&format!("{column}-")))
        })
    }) else {
        return vec![];
    };
    let mut out = Vec::new();
    for kind in body["seasonTypes"].as_array().into_iter().flatten() {
        for category in kind["categories"].as_array().into_iter().flatten() {
            let split = string(&category["splitType"]);
            if !["2", "3"].contains(&split.as_str()) {
                continue;
            }
            for item in category["events"].as_array().into_iter().flatten() {
                let id = string(&item["eventId"]);
                let e = &body["events"][&id];
                let Some(date) = e["gameDate"].as_str().and_then(ss_espn::parse_espn_date) else {
                    continue;
                };
                if (league == "nfl"
                    && !(date.year() == season || (date.year() == season + 1 && date.month() <= 3)))
                    || (league == "nba"
                        && !((date.year() == season && date.month() <= 8)
                            || (date.year() == season - 1 && date.month() >= 9)))
                {
                    continue;
                }
                if date > Utc::now()
                    || !["W", "L", "T"].contains(&e["gameResult"].as_str().unwrap_or(""))
                {
                    continue;
                }
                let Some(value) = item["stats"]
                    .get(index)
                    .and_then(Value::as_str)
                    .and_then(|s| {
                        ss_espn::parse_stat_cell(&s.replace(',', "")).map(|n| n as f64 / 10.)
                    })
                    .filter(|v| v.is_finite())
                else {
                    continue;
                };
                let home = e["atVs"] == "vs";
                let team_id = string(&e[if home { "homeTeamId" } else { "awayTeamId" }]);
                let Some(pf) = number(
                    &e[if home {
                        "homeTeamScore"
                    } else {
                        "awayTeamScore"
                    }],
                ) else {
                    continue;
                };
                let Some(pa) = number(
                    &e[if home {
                        "awayTeamScore"
                    } else {
                        "homeTeamScore"
                    }],
                ) else {
                    continue;
                };
                if !id.bytes().all(|b| b.is_ascii_digit()) || team_id.is_empty() {
                    continue;
                }
                out.push(Game {
                    event_id: id,
                    date,
                    season,
                    postseason: split == "3",
                    opponent: string(&e["opponent"]["abbreviation"]),
                    opponent_id: string(&e["opponent"]["id"]),
                    team_id,
                    home,
                    value,
                    result: string(&e["gameResult"]),
                    points_for: pf,
                    points_against: pa,
                    rest_days: None,
                    origin: "espn".into(),
                });
            }
        }
    }
    out
}
pub fn parse_schedule(body: &Value, season: i32, team: &str, stat: &str) -> Vec<Game> {
    let mut out = Vec::new();
    for e in body["events"].as_array().into_iter().flatten() {
        let Some(comp) = e.pointer("/competitions/0") else {
            continue;
        };
        if comp.pointer("/status/type/completed") != Some(&Value::Bool(true)) {
            continue;
        }
        let Some(date) = e["date"].as_str().and_then(ss_espn::parse_espn_date) else {
            continue;
        };
        if date > Utc::now() {
            continue;
        }
        let kind = e
            .pointer("/seasonType/type")
            .and_then(Value::as_i64)
            .or_else(|| {
                e.pointer("/seasonType/id")
                    .and_then(Value::as_str)
                    .and_then(|x| x.parse().ok())
            })
            .unwrap_or(2);
        if kind != 2 && kind != 3 {
            continue;
        }
        // Event season, not the response's current-season banner.
        let actual = e
            .pointer("/season/year")
            .and_then(Value::as_i64)
            .unwrap_or(season as i64) as i32;
        if actual != season {
            continue;
        }
        let Some(competitors) = comp["competitors"].as_array() else {
            continue;
        };
        let Some(own) = competitors
            .iter()
            .find(|c| string(&c["team"]["id"]) == team)
        else {
            continue;
        };
        let Some(opp) = competitors
            .iter()
            .find(|c| string(&c["team"]["id"]) != team)
        else {
            continue;
        };
        let Some(pf) = number(&own["score"]["value"]).or_else(|| number(&own["score"])) else {
            continue;
        };
        let Some(pa) = number(&opp["score"]["value"]).or_else(|| number(&opp["score"])) else {
            continue;
        };
        let id = string(&e["id"]);
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let value = match stat {
            "points_for" => pf as f64,
            "points_against" => pa as f64,
            "total_points" => (pf + pa) as f64,
            _ => (pf - pa) as f64,
        };
        out.push(Game {
            event_id: id,
            date,
            season,
            postseason: kind == 3,
            opponent: string(&opp["team"]["abbreviation"]),
            opponent_id: string(&opp["team"]["id"]),
            team_id: team.into(),
            home: own["homeAway"] == "home",
            value,
            result: if pf > pa {
                "W"
            } else if pf < pa {
                "L"
            } else {
                "T"
            }
            .into(),
            points_for: pf,
            points_against: pa,
            rest_days: None,
            origin: "espn".into(),
        });
    }
    out
}
#[derive(sqlx::FromRow)]
struct DbPoint {
    event_id: String,
    date: DateTime<Utc>,
    season: i32,
    season_type: i32,
    home: bool,
    opponent: String,
    opponent_id: String,
    team_id: String,
    value: f64,
    points_for: i32,
    points_against: i32,
}
async fn database(pool: &PgPool, sub: &Subject, p: &Plan) -> Result<Vec<Game>> {
    let rows: Vec<DbPoint> = if p.subject == "player" {
        sqlx::query_as(r#"SELECT g.espn_id AS event_id,g.start_at AS date,g.season,g.season_type,p.team_id=g.home_team_id AS home,
   CASE WHEN p.team_id=g.home_team_id THEN a.abbr ELSE h.abbr END AS opponent,
   CASE WHEN p.team_id=g.home_team_id THEN a.espn_id ELSE h.espn_id END AS opponent_id,t.espn_id AS team_id,
   x.value_x10::float8/10 AS value,CASE WHEN p.team_id=g.home_team_id THEN g.home_score ELSE g.away_score END AS points_for,
   CASE WHEN p.team_id=g.home_team_id THEN g.away_score ELSE g.home_score END AS points_against
   FROM players p JOIN teams t ON t.id=p.team_id JOIN games g ON p.team_id IN(g.home_team_id,g.away_team_id)
   JOIN teams h ON h.id=g.home_team_id JOIN teams a ON a.id=g.away_team_id
   JOIN LATERAL(SELECT value_x10 FROM player_game_stats WHERE game_id=g.id AND player_id=p.id AND stat_key=$2 AND source='espn' ORDER BY revision DESC LIMIT 1)x ON true
   WHERE p.id=$1 AND g.status='final' AND g.season BETWEEN $3 AND $4 AND g.season_type IN(2,3) AND g.home_score IS NOT NULL AND g.away_score IS NOT NULL"#)
   .bind(sub.id).bind(&p.stat).bind(p.start_season).bind(p.end_season).fetch_all(pool).await?
    } else {
        sqlx::query_as(r#"SELECT g.espn_id AS event_id,g.start_at AS date,g.season,g.season_type,t.id=g.home_team_id AS home,
   CASE WHEN t.id=g.home_team_id THEN a.abbr ELSE h.abbr END AS opponent,
   CASE WHEN t.id=g.home_team_id THEN a.espn_id ELSE h.espn_id END AS opponent_id,t.espn_id AS team_id,0::float8 AS value,
   CASE WHEN t.id=g.home_team_id THEN g.home_score ELSE g.away_score END AS points_for,
   CASE WHEN t.id=g.home_team_id THEN g.away_score ELSE g.home_score END AS points_against
   FROM teams t JOIN games g ON t.id IN(g.home_team_id,g.away_team_id) JOIN teams h ON h.id=g.home_team_id JOIN teams a ON a.id=g.away_team_id
   WHERE t.id=$1 AND g.status='final' AND g.season BETWEEN $2 AND $3 AND g.season_type IN(2,3) AND g.home_score IS NOT NULL AND g.away_score IS NOT NULL"#)
   .bind(sub.id).bind(p.start_season).bind(p.end_season).fetch_all(pool).await?
    };
    Ok(rows
        .into_iter()
        .filter(|r| r.date <= Utc::now())
        .map(|r| {
            let value = if p.subject == "player" {
                r.value
            } else {
                match p.stat.as_str() {
                    "points_for" => r.points_for as f64,
                    "points_against" => r.points_against as f64,
                    "total_points" => (r.points_for + r.points_against) as f64,
                    _ => (r.points_for - r.points_against) as f64,
                }
            };
            Game {
                event_id: r.event_id,
                date: r.date,
                season: r.season,
                postseason: r.season_type == 3,
                opponent: r.opponent,
                opponent_id: r.opponent_id,
                team_id: r.team_id,
                home: r.home,
                value,
                result: if r.points_for > r.points_against {
                    "W"
                } else if r.points_for < r.points_against {
                    "L"
                } else {
                    "T"
                }
                .into(),
                points_for: r.points_for,
                points_against: r.points_against,
                rest_days: None,
                origin: "database".into(),
            }
        })
        .collect())
}

pub fn assign_rest(games: &mut [Game]) {
    games.sort_by_key(|g| g.date);
    let mut prev: BTreeMap<(String, i32), DateTime<Utc>> = BTreeMap::new();
    for g in games {
        let key = (g.team_id.clone(), g.season);
        g.rest_days = prev.insert(key, g.date).map(|date| {
            (g.date.with_timezone(&ss_db::GAME_ZONE).date_naive()
                - date.with_timezone(&ss_db::GAME_ZONE).date_naive())
            .num_days()
        });
    }
}

pub async fn gather(pool: &PgPool, p: &Plan, sub: Subject) -> Result<Evidence> {
    let stored = database(pool, &sub, p).await?;
    let db_games = stored.len();
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(9))
        .user_agent("sportsswipe-research/1.0")
        .build()?;
    let mut tasks = tokio::task::JoinSet::new();
    let semaphore = std::sync::Arc::new(tokio::sync::Semaphore::new(4));
    for season in p.start_season..=p.end_season {
        let pool = pool.clone();
        let http = http.clone();
        let sub = sub.clone();
        let p = p.clone();
        let sem = semaphore.clone();
        tasks.spawn(async move {
            let _permit = sem.acquire_owned().await?;
            let resource = if p.subject == "player" {
                format!(
                    "logs/{}/athletes/{}/gamelog?season={season}",
                    sport(&p.league),
                    sub.espn_id
                )
            } else {
                format!(
                    "schedule/{}/teams/{}/schedule?season={season}&seasontype=2",
                    sport(&p.league),
                    sub.espn_id
                )
            };
            let (body, cached, stale) =
                source(&pool, &http, &resource, season < Utc::now().year() - 1).await?;
            let mut cache_count = usize::from(cached);
            let mut fetch_count = usize::from(!cached);
            let mut notes = Vec::new();
            if stale {
                notes.push(format!("The {season} ESPN source could not refresh; its saved snapshot was used."));
            }
            let mut games = if p.subject == "player" {
                parse_logs(&body, season, &p.stat, &p.league)
            } else {
                parse_schedule(&body, season, &sub.espn_id, &p.stat)
            };
            // Fetch postseason schedules as well, including for rest context even when only regular games are analyzed.
            if p.subject == "team" && p.season_type != "regular" {
                let post = resource.replace("seasontype=2", "seasontype=3");
                match source(&pool, &http, &post, season < Utc::now().year() - 1).await {
                    Ok((body, hit, saved)) => {
                        cache_count += usize::from(hit);
                        fetch_count += usize::from(!hit);
                        if saved { notes.push(format!("A saved postseason schedule was used for {season}.")); }
                        games.extend(parse_schedule(&body, season, &sub.espn_id, &p.stat));
                    },
                    Err(_) => notes.push(format!("The {season} postseason schedule was unavailable; the regular-season records were retained.")),
                }
            }
            Ok::<_, anyhow::Error>((games, cache_count, fetch_count, notes))
        });
    }
    let mut all = BTreeMap::new();
    let mut warnings = Vec::new();
    let mut requests = 0;
    let mut cached = 0;
    while let Some(result) = tasks.join_next().await {
        match result {
            Ok(Ok((games, hits, fresh, notes))) => {
                cached += hits;
                requests += fresh;
                warnings.extend(notes);
                for g in games {
                    all.insert(g.event_id.clone(), g);
                }
            }
            _ => warnings.push(
                "An ESPN season source could not be retrieved. This sample may be incomplete."
                    .into(),
            ),
        }
    }
    // Latest official database revision wins where the same event is already stored.
    for g in stored {
        all.insert(g.event_id.clone(), g);
    }
    let mut games: Vec<Game> = all.into_values().collect();
    if p.subject == "team" {
        assign_rest(&mut games)
    } else if p.rest_min.is_some() || p.rest_max.is_some() {
        // Rest follows each historical TEAM, including trades and games the player missed.
        let pairs: std::collections::BTreeSet<_> = games
            .iter()
            .map(|g| (g.season, g.team_id.clone()))
            .collect();
        let mut schedule = Vec::new();
        let mut context = tokio::task::JoinSet::new();
        let sem = std::sync::Arc::new(tokio::sync::Semaphore::new(4));
        for (season, team_id) in pairs {
            let pool = pool.clone();
            let http = http.clone();
            let league = p.league.clone();
            let include_post = p.season_type != "regular";
            let sem = sem.clone();
            context.spawn(async move {
                let _permit = sem.acquire_owned().await?;
                let mut rows = Vec::new();
                let mut hits = 0;
                let mut fresh = 0;
                let mut stale = false;
                for kind in if include_post { vec![2, 3] } else { vec![2] } {
                    let resource = format!(
                        "schedule/{}/teams/{}/schedule?season={season}&seasontype={kind}",
                        sport(&league),
                        team_id
                    );
                    let (body, hit, saved) =
                        source(&pool, &http, &resource, season < Utc::now().year() - 1).await?;
                    if hit {
                        hits += 1
                    } else {
                        fresh += 1
                    }
                    stale |= saved;
                    rows.extend(parse_schedule(&body, season, &team_id, "result"));
                }
                Ok::<_, anyhow::Error>((rows, hits, fresh, stale))
            });
        }
        while let Some(result) = context.join_next().await {
            match result {
    Ok(Ok((rows,hits,fresh,stale)))=>{cached+=hits;requests+=fresh;if stale{warnings.push("Saved team schedule used for rest calculation.".into())}schedule.extend(rows);},
    _=>warnings.push("A historical team schedule was unavailable; games with unverified rest are excluded.".into()),
   }
        }
        let unique: BTreeMap<_, _> = schedule
            .into_iter()
            .map(|g| ((g.team_id.clone(), g.event_id.clone()), g))
            .collect();
        let mut schedule: Vec<_> = unique.into_values().collect();
        assign_rest(&mut schedule);
        let rests: BTreeMap<_, _> = schedule
            .iter()
            .map(|g| ((g.team_id.clone(), g.event_id.clone()), g.rest_days))
            .collect();
        for g in &mut games {
            g.rest_days = rests
                .get(&(g.team_id.clone(), g.event_id.clone()))
                .copied()
                .flatten();
        }
    }
    games.sort_by_key(|g| g.date);
    warnings.sort();
    warnings.dedup();
    Ok(Evidence {
        subject: sub,
        games,
        warnings,
        requests,
        cached,
        db_games,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn log_column_is_selected_by_name_not_position() {
        let d = serde_json::json!({"names":["passingYards","interceptions"],"events":{"1":{"gameDate":"2024-09-29T20:20Z","atVs":"@","awayTeamId":"2","homeTeamId":"33","awayTeamScore":"10","homeTeamScore":"35","gameResult":"L","opponent":{"id":"33","abbreviation":"BAL"}}},"seasonTypes":[{"categories":[{"splitType":"2","events":[{"eventId":"1","stats":["180","0"]}]}]}]});
        let gs = parse_logs(&d, 2024, "pass_int", "nfl");
        assert_eq!(gs.len(), 1);
        assert_eq!(gs[0].value, 0.);
        assert_eq!(gs[0].opponent, "BAL");
    }
    #[test]
    fn missed_or_missing_cells_are_not_zero() {
        let d = serde_json::json!({"names":["interceptions"],"events":{"1":{"gameDate":"2024-09-29T20:20Z","gameResult":"L"}},"seasonTypes":[{"categories":[{"splitType":"2","events":[{"eventId":"1","stats":["--"]}]}]}]});
        assert!(parse_logs(&d, 2024, "pass_int", "nfl").is_empty());
    }
    #[test]
    fn nba_combined_shooting_cells_use_makes_and_correct_season() {
        let d = serde_json::json!({"names":["threePointFieldGoalsMade-threePointFieldGoalsAttempted"],"events":{"1":{"gameDate":"2025-03-10T20:20Z","atVs":"vs","awayTeamId":"13","homeTeamId":"9","awayTeamScore":"100","homeTeamScore":"110","gameResult":"W","opponent":{"id":"13","abbreviation":"LAL"}}},"seasonTypes":[{"categories":[{"splitType":"2","events":[{"eventId":"1","stats":["3-7"]}]}]}]});
        assert_eq!(parse_logs(&d, 2025, "fg3m", "nba")[0].value, 3.);
        assert!(parse_logs(&d, 2023, "fg3m", "nba").is_empty());
    }
    #[test]
    fn schedule_uses_event_season_not_current_banner_and_accepts_object_scores() {
        let d = serde_json::json!({"season":{"year":2026},"events":[{"id":"401671617","date":"2024-09-08T17:00Z","season":{"year":2024},"seasonType":{"type":2},"competitions":[{"status":{"type":{"completed":true}},"competitors":[{"team":{"id":"2","abbreviation":"BUF"},"homeAway":"home","score":{"value":34}},{"team":{"id":"22","abbreviation":"ARI"},"homeAway":"away","score":{"value":28}}]}]}]});
        let games = parse_schedule(&d, 2024, "2", "result");
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].result, "W");
        assert_eq!(games[0].value, 6.);
        assert!(parse_schedule(&d, 2026, "2", "result").is_empty());
    }
}
