//! Database-backed research with bounded ESPN enrichment and server-computed evidence.
use super::{
    data::{self, Evidence, Game},
    plan::{self, Plan},
};
use crate::{error::ApiResult, state::AppState};
use serde_json::{json, Value};

fn matches_season(g: &Game, p: &Plan) -> bool {
    g.season >= p.start_season
        && g.season <= p.end_season
        && match p.season_type.as_str() {
            "regular" => !g.postseason,
            "postseason" => g.postseason,
            _ => true,
        }
}
fn matches_filter(g: &Game, p: &Plan, opp: Option<&str>) -> bool {
    opp.is_none_or(|o| g.opponent_id == o)
        && match p.venue.as_str() {
            "home" => g.home,
            "away" => !g.home,
            _ => true,
        }
        && p.rest_min
            .is_none_or(|min| g.rest_days.is_some_and(|d| d >= min))
        && p.rest_max
            .is_none_or(|max| g.rest_days.is_some_and(|d| d <= max))
}
pub fn hit(g: &Game, p: &Plan) -> bool {
    match p.measure.as_str() {
        "win_rate" => g.result == "W",
        "loss_rate" => g.result == "L",
        _ => {
            let t = p.threshold.unwrap_or(0.);
            match p.operator.as_str() {
                "gt" => g.value > t,
                "gte" => g.value >= t,
                "lt" => g.value < t,
                "lte" => g.value <= t,
                _ => (g.value - t).abs() < 1e-8,
            }
        }
    }
}
fn num(n: f64) -> String {
    if n.fract().abs() < 0.000001 {
        format!("{n:.0}")
    } else {
        format!("{n:.1}")
    }
}
fn percentage(hits: usize, n: usize) -> f64 {
    if n == 0 {
        0.
    } else {
        hits as f64 / n as f64 * 100.
    }
}
fn rounded(n: f64) -> f64 {
    (n * 10.).round() / 10.
}
fn stat_label(p: &Plan) -> String {
    plan::STATS
        .iter()
        .find(|s| s.0 == p.stat && s.1 == p.league)
        .map(|s| s.2.to_string())
        .unwrap_or_else(|| {
            match p.stat.as_str() {
                "points_for" => "Points scored",
                "points_against" => "Points allowed",
                "total_points" => "Combined points",
                "margin" => "Scoring margin",
                _ => "Game results",
            }
            .into()
        })
}
fn predicate(p: &Plan, label: &str) -> String {
    match p.measure.as_str() {
        "loss_rate" => "lost".into(),
        "win_rate" => "won".into(),
        _ if p.stat == "pass_int" && p.operator == "gt" && p.threshold == Some(0.) => {
            "threw at least one interception".into()
        }
        _ => format!(
            "recorded {} {} {}",
            match p.operator.as_str() {
                "gt" => "more than",
                "gte" => "at least",
                "lt" => "fewer than",
                "lte" => "at most",
                _ => "exactly",
            },
            num(p.threshold.unwrap_or(0.)),
            label.to_lowercase()
        ),
    }
}
fn filters(p: &Plan, opp: Option<&str>) -> Vec<String> {
    let mut f = Vec::new();
    if let Some(o) = opp {
        f.push(format!("vs {o}"));
    }
    if p.venue != "any" {
        f.push(format!("{} games", p.venue));
    }
    if let Some(max) = p.rest_max {
        f.push(format!(
            "{}–{max} days between team games",
            p.rest_min.unwrap_or(0)
        ));
    } else if let Some(min) = p.rest_min {
        f.push(format!("at least {min} days between team games"));
    }
    f
}

pub fn summarize(e: &Evidence, p: &Plan, opp: Option<&(String, String)>) -> Value {
    let all: Vec<_> = e.games.iter().filter(|g| matches_season(g, p)).collect();
    let mut sample: Vec<_> = all
        .iter()
        .copied()
        .filter(|g| matches_filter(g, p, opp.map(|o| o.0.as_str())))
        .collect();
    if let Some(n) = p.last_games {
        let skip = sample.len().saturating_sub(n);
        sample.drain(..skip);
    }
    let filter_labels = filters(p, opp.map(|o| o.1.as_str()));
    let scope = format!(
        "{}–{} · {}{}",
        p.start_season,
        p.end_season,
        match p.season_type.as_str() {
            "postseason" => "postseason",
            "all" => "regular season + playoffs",
            _ => "regular season",
        },
        if filter_labels.is_empty() {
            String::new()
        } else {
            format!(" · {}", filter_labels.join(" · "))
        }
    );
    let label = stat_label(p);
    if sample.is_empty() {
        return json!({"kind":"research_note","subjectName":e.subject.name,"answer":"I checked the database and ESPN history, but could not verify matching completed games for this exact scope. Try widening the seasons or changing the filter.","scope":scope,"warnings":e.warnings,"definition":"No missing statistic is treated as zero. A missing sample is different from an event happening zero times.","sources":[],"researchPlan":p});
    }
    let average = sample.iter().map(|g| g.value).sum::<f64>() / sample.len() as f64;
    let hits = sample.iter().filter(|g| hit(g, p)).count();
    let rate = percentage(hits, sample.len());
    let frequency = p.measure != "average";
    let headline = if frequency {
        format!("{hits} of {} games · {}%", sample.len(), num(rounded(rate)))
    } else {
        format!("{} per game", num(rounded(average)))
    };
    let result = if frequency {
        format!(
            "{} {} in {hits} of {} matching games ({}%).",
            e.subject.name,
            predicate(p, &label),
            sample.len(),
            num(rounded(rate))
        )
    } else {
        format!(
            "{} averaged {} {} across {} matching games.",
            e.subject.name,
            num(rounded(average)),
            label.to_lowercase(),
            sample.len()
        )
    };
    let has_filter =
        p.opponent.is_some() || p.venue != "any" || p.rest_max.is_some() || p.rest_min.is_some();
    // Complement cohort in the SAME season range. Unknown rest never joins either cohort.
    let reference: Vec<_> = all
        .iter()
        .copied()
        .filter(|g| {
            !matches_filter(g, p, opp.map(|o| o.0.as_str()))
                && (p.rest_min.is_none() && p.rest_max.is_none() || g.rest_days.is_some())
        })
        .collect();
    let reference_hits = reference.iter().filter(|g| hit(g, p)).count();
    let reference_rate = percentage(reference_hits, reference.len());
    let reference_average = if reference.is_empty() {
        0.
    } else {
        reference.iter().map(|g| g.value).sum::<f64>() / reference.len() as f64
    };
    let mut interpretation = String::new();
    let comparison = if has_filter && !reference.is_empty() {
        interpretation = if frequency {
            format!("In the other {} comparable games, the rate was {}% ({reference_hits}/{}): {} percentage points {} than in the selected games.",reference.len(),num(rounded(reference_rate)),reference.len(),num(rounded((rate-reference_rate).abs())),if reference_rate>=rate{"higher"}else{"lower"})
        } else {
            format!(
                "The other {} games averaged {} {}, compared with {} in the selected games.",
                reference.len(),
                num(rounded(reference_average)),
                label.to_lowercase(),
                num(rounded(average))
            )
        };
        Some(
            json!({"label":"Other games","games":reference.len(),"hits":reference_hits,"rate":rounded(reference_rate),"average":rounded(reference_average)}),
        )
    } else {
        None
    };
    if p.measure == "loss_rate" && comparison.is_some() {
        let assessment = if rate < reference_rate {
            "The sample does not support a higher loss rate under this condition."
        } else if rate > reference_rate {
            "Losses were more frequent under this condition in the observed sample."
        } else {
            "The observed loss rate is the same in both groups."
        };
        interpretation = format!("{assessment} {interpretation}");
    }
    let mut caveats = e.warnings.clone();
    if sample.len() < 10 {
        caveats.push(format!("Small sample: only {} matching games. This historical rate is not a prediction of the next game.",sample.len()));
    }
    if p.rest_min.is_some() || p.rest_max.is_some() {
        let unknown = all.iter().filter(|g| g.rest_days.is_none()).count();
        caveats.push(format!("Rest is the calendar-day gap between this team's games in America/New_York, not the player's appearances. {unknown} games without a verified prior team game are excluded from the rest comparison. Opponents, venue and roster changes can also affect results; this does not establish causation."));
    }
    if p.last_games.is_some_and(|n| sample.len() < n) {
        caveats.push(format!(
            "Requested {} matching games; only {} could be verified in this period.",
            p.last_games.unwrap(),
            sample.len()
        ));
    }
    let first = sample.first().unwrap().date;
    let last = sample.last().unwrap().date;
    let graph = if ["loss_rate", "win_rate"].contains(&p.measure.as_str()) && comparison.is_some() {
        json!({"label":if p.measure=="loss_rate"{"Loss rate (%)"}else{"Win rate (%)"},"bars":[
   {"label":if p.rest_max.is_some_and(|n|n<=6){"Short rest"}else{"Selected"},"detail":format!("{hits}/{} games",sample.len()),"value":rounded(rate)},
   {"label":"Other games","detail":format!("{reference_hits}/{} games",reference.len()),"value":rounded(reference_rate)}],"emphasis":[0],"percent":true})
    } else {
        // The headline covers the full cohort. Chart stays readable; the log retains every game.
        let tail = &sample[sample.len().saturating_sub(10)..];
        json!({"label":label,"bars":tail.iter().map(|g|json!({"label":g.opponent,"detail":g.date.format("%b %Y").to_string(),"value":g.value})).collect::<Vec<_>>(),
    "threshold":if p.measure=="frequency"{p.threshold}else{None},"operator":p.operator,
    "caption":format!("Most recent {} matching games · {} in the full sample",tail.len(),sample.len()),"latest":tail.len()-1})
    };
    json!({"kind":"analysis","subjectName":e.subject.name,"headline":headline,"answer":result,"interpretation":interpretation,
  "scope":scope,"statLabel":label,"metric":{"games":sample.len(),"hits":hits,"rate":rounded(rate),"average":rounded(average),"threshold":p.threshold},
  "comparison":comparison,"chart":graph,"warnings":caveats,"range":{"first":first,"last":last},
  "games":sample.iter().map(|g|json!({"date":g.date,"eventId":g.event_id,"opponent":g.opponent,"home":g.home,"value":g.value,"result":g.result,"pointsFor":g.points_for,"pointsAgainst":g.points_against,"restDays":g.rest_days,"matched":hit(g,p),"source":g.origin,"url":data::box_url(&p.league,&g.event_id)})).collect::<Vec<_>>(),
  "sources":sample.iter().map(|g|json!({"label":format!("{} {} · ESPN box score",g.date.format("%b %-d, %Y"),g.opponent),"url":data::box_url(&p.league,&g.event_id)})).collect::<Vec<_>>(),
  "definition":format!("{scope}. Filters are applied before taking the most recent N games. Latest official stored box-score revisions are combined with ESPN game logs/schedules and deduplicated by event ID. Missing/DNP statistics are excluded, never treated as zero. Dates shown oldest to latest. Regular season is the default; playoffs are included only when requested. Rest comparisons use complete team schedules, not just player appearances. Calculation: {}. This is descriptive history, not a causal claim.",match p.measure.as_str(){"loss_rate"=>"losses divided by all matching games; ties remain in the denominator".to_string(),"win_rate"=>"wins divided by all matching games; ties remain in the denominator".to_string(),"frequency"=>format!("{} {}",p.operator,p.threshold.map(num).unwrap_or_default()),_=>"sum of verified values divided by the number of matching games".to_string()}),
  "provenance":{"databaseGames":e.db_games,"fetchedSources":e.requests,"cachedSources":e.cached,"source":"Sports Swipe database + ESPN historical records"},"dataAsOf":chrono::Utc::now(),"researchPlan":p})
}

/// A slate shortcut already has an exact player/stat; it needs no model call.
pub async fn fill_form(
    state: &AppState,
    player_id: i64,
    stat: &str,
    n: i64,
    opponent: Option<&str>,
) -> anyhow::Result<Value> {
    use chrono::Datelike;
    let (espn_id, name, league): (String, String, String) =
        sqlx::query_as("SELECT espn_id,full_name,league FROM players WHERE id=$1")
            .bind(player_id)
            .fetch_one(&state.pool)
            .await?;
    let now = chrono::Utc::now();
    let end = now.year()
        + if league == "nba" && now.month() >= 9 {
            1
        } else {
            0
        };
    let p = Plan {
        subject: "player".into(),
        player: Some(name.clone()),
        team: None,
        league,
        stat: stat.into(),
        opponent: opponent.map(str::to_string),
        start_season: if opponent.is_some() { end - 9 } else { end - 2 },
        end_season: end,
        last_games: Some(n.clamp(1, 20) as usize),
        season_type: "regular".into(),
        venue: "any".into(),
        rest_min: None,
        rest_max: None,
        measure: "average".into(),
        operator: "gt".into(),
        threshold: None,
        clarification: None,
    };
    p.validate()?;
    let opp = data::opponent(&state.pool, &p).await?;
    let evidence = tokio::time::timeout(
        std::time::Duration::from_secs(48),
        data::gather(
            &state.pool,
            &p,
            data::Subject {
                id: player_id,
                espn_id,
                name,
            },
        ),
    )
    .await??;
    Ok(summarize(&evidence, &p, opp.as_ref()))
}

pub async fn answer(
    state: &AppState,
    user: uuid::Uuid,
    question: &str,
    history: &[Value],
) -> ApiResult<Value> {
    let count:i32=sqlx::query_scalar("INSERT INTO analyst_request_limits(user_id,minute) VALUES($1,date_trunc('minute',now())) ON CONFLICT(user_id,minute) DO UPDATE SET requests=analyst_request_limits.requests+1 RETURNING requests").bind(user).fetch_one(&state.pool).await?;
    if count > 6 {
        return Ok(
            json!({"kind":"research_note","answer":"Please wait a minute before starting another research question."}),
        );
    }
    let p = match plan::interpret(&state.pool, question, history).await {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(error=%e,"analyst planning unavailable");
            return Ok(
                json!({"kind":"research_note","answer":"I couldn't finish interpreting that question right now. Please try again. You can still open a recent-form question from the slate."}),
            );
        }
    };
    if p.subject == "clarify" {
        return Ok(
            json!({"kind":"clarification","answer":p.clarification.unwrap_or_else(||"Which player or team and statistic should I investigate?".into())}),
        );
    }
    let sub = match data::resolve(&state.pool, &p).await {
        Ok(s) => s,
        Err(e) => return Ok(json!({"kind":"clarification","answer":e.to_string()})),
    };
    let opponent = match data::opponent(&state.pool, &p).await {
        Ok(s) => s,
        Err(e) => return Ok(json!({"kind":"clarification","answer":e.to_string()})),
    };
    let evidence = match tokio::time::timeout(
        std::time::Duration::from_secs(48),
        data::gather(&state.pool, &p, sub),
    )
    .await
    {
        Ok(Ok(e)) => e,
        _ => {
            return Ok(
                json!({"kind":"research_note","answer":"The historical source took too long to respond. Please retry; completed source lookups have been saved for the next attempt."}),
            )
        }
    };
    let mut report = summarize(&evidence, &p, opponent.as_ref());
    if p.subject == "player" {
        let specs = ss_db::cards::card_specs(&state.pool, &[evidence.subject.id]).await?;
        report["card"] = specs
            .get(&evidence.subject.id)
            .cloned()
            .unwrap_or(Value::Null);
        let mid:Option<i64>=sqlx::query_scalar("SELECT m.id FROM markets m JOIN games g ON g.id=m.game_id WHERE m.player_id=$1 AND m.stat_key=$2 AND m.status='open' AND m.lock_at>now() AND ($3::text IS NULL OR EXISTS(SELECT 1 FROM teams t WHERE t.espn_id=$3 AND t.league=$4 AND t.id IN(g.home_team_id,g.away_team_id))) ORDER BY m.lock_at LIMIT 1")
   .bind(evidence.subject.id).bind(&p.stat).bind(opponent.as_ref().map(|o|&o.0)).bind(&p.league).fetch_optional(&state.pool).await?;
        if let Some(mid) = mid {
            report["playable"] = ss_db::cards::playable_cards(&state.pool, Some(user), &[mid])
                .await?
                .into_iter()
                .next()
                .unwrap_or(Value::Null);
            let prior: Option<uuid::Uuid> = sqlx::query_scalar(
                "SELECT id FROM entries WHERE user_id=$1 AND single_market_id=$2",
            )
            .bind(user)
            .bind(mid)
            .fetch_optional(&state.pool)
            .await?;
            report["alreadyPickedEntryId"] = json!(prior);
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    fn p() -> Plan {
        Plan {
            subject: "team".into(),
            player: None,
            team: Some("Dallas Cowboys".into()),
            league: "nfl".into(),
            stat: "result".into(),
            opponent: None,
            start_season: 2022,
            end_season: 2024,
            last_games: None,
            season_type: "regular".into(),
            venue: "any".into(),
            rest_min: None,
            rest_max: Some(6),
            measure: "loss_rate".into(),
            operator: "gt".into(),
            threshold: None,
            clarification: None,
        }
    }
    fn game(n: u32, rest: Option<i64>, result: &str) -> Game {
        Game {
            event_id: n.to_string(),
            date: chrono::Utc.with_ymd_and_hms(2024, 10, n, 17, 0, 0).unwrap(),
            season: 2024,
            postseason: false,
            opponent: "BAL".into(),
            opponent_id: "33".into(),
            team_id: "6".into(),
            home: true,
            value: 0.,
            result: result.into(),
            points_for: 10,
            points_against: 20,
            rest_days: rest,
            origin: "database".into(),
        }
    }
    #[test]
    fn compares_losses_with_other_known_rest_and_keeps_ties_in_denominator() {
        let e = Evidence {
            subject: data::Subject {
                id: 1,
                espn_id: "6".into(),
                name: "Dallas Cowboys".into(),
            },
            games: vec![
                game(1, None, "L"),
                game(2, Some(4), "L"),
                game(3, Some(6), "W"),
                game(4, Some(7), "L"),
                game(5, Some(8), "T"),
            ],
            warnings: vec![],
            requests: 0,
            cached: 0,
            db_games: 5,
        };
        let a = summarize(&e, &p(), None);
        assert_eq!(a["metric"]["games"], 2);
        assert_eq!(a["metric"]["hits"], 1);
        assert_eq!(a["comparison"]["games"], 2);
        assert_eq!(a["comparison"]["rate"], 50.);
        assert_eq!(a["chart"]["bars"][0]["value"], 50.);
    }
    #[test]
    fn equal_to_threshold_is_not_above() {
        let mut p = p();
        p.measure = "frequency".into();
        p.threshold = Some(0.);
        let g = game(1, Some(4), "W");
        assert!(!hit(&g, &p));
        p.operator = "gte".into();
        assert!(hit(&g, &p));
    }
    #[test]
    fn rest_uses_calendar_days_across_daylight_saving() {
        let mut games = vec![game(1, None, "W"), game(2, None, "L")];
        games[0].date = chrono::Utc
            .with_ymd_and_hms(2024, 10, 27, 17, 0, 0)
            .unwrap();
        games[1].date = chrono::Utc.with_ymd_and_hms(2024, 11, 3, 18, 0, 0).unwrap();
        data::assign_rest(&mut games);
        assert_eq!(games[1].rest_days, Some(7));
        games[1].season = 2025;
        data::assign_rest(&mut games);
        assert_eq!(games[1].rest_days, None);
    }
}
