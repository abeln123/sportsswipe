//! Practice weekly contests: seven daily slates of up to ten shared questions,
//! frozen at publication. No coins or cash are involved.

use anyhow::Result;
use chrono::{Datelike, Duration, NaiveDate, TimeZone, Utc};
use serde_json::{json, Value};
use sqlx::PgPool;
use ss_core::contest::{rank_key, weekly_score, DayScore, QUESTIONS_PER_DAY};
use uuid::Uuid;

pub fn today_local() -> NaiveDate {
    Utc::now().with_timezone(&crate::GAME_ZONE).date_naive()
}

pub fn week_start(d: NaiveDate) -> NaiveDate {
    d - Duration::days(d.weekday().num_days_from_monday() as i64)
}

/// Creates this week's contest and its seven days if missing, then publishes
/// any unpublished day whose games have markets.
pub async fn ensure_week(pool: &PgPool) -> Result<i64> {
    let start = week_start(today_local());
    let contest_id: i64 = sqlx::query_scalar(
        r#"INSERT INTO contests (week_start, name) VALUES ($1, $2)
           ON CONFLICT (week_start) DO UPDATE SET name = contests.name RETURNING id"#,
    )
    .bind(start)
    .bind(format!("Week of {}", start.format("%b %-d")))
    .fetch_one(pool)
    .await?;
    for i in 0..7 {
        sqlx::query("INSERT INTO contest_days (contest_id, day_index, game_date) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING")
            .bind(contest_id)
            .bind(i)
            .bind(start + Duration::days(i as i64))
            .execute(pool)
            .await?;
    }
    let pending: Vec<(i64, NaiveDate)> = sqlx::query_as(
        "SELECT id, game_date FROM contest_days WHERE contest_id = $1 AND slate_version = 0 AND game_date >= $2 ORDER BY day_index",
    )
    .bind(contest_id)
    .bind(today_local())
    .fetch_all(pool)
    .await?;
    for (day_id, date) in pending {
        publish_day(pool, day_id, date).await?;
    }
    Ok(contest_id)
}

async fn publish_day(pool: &PgPool, day_id: i64, date: NaiveDate) -> Result<bool> {
    let from = crate::GAME_ZONE
        .from_local_datetime(&date.and_hms_opt(0, 0, 0).expect("midnight"))
        .earliest()
        .expect("valid local time")
        .with_timezone(&Utc);
    let to = from + Duration::days(1);
    // Alternate leagues and stats so the slate is varied; the earliest game
    // sets the lock for the whole day.
    let candidates: Vec<(i64, i32, chrono::DateTime<Utc>, String, String, String)> = sqlx::query_as(
        r#"SELECT m.id, lv.line_x10, m.lock_at, p.league, p.last_name, sd.label
           FROM markets m
           JOIN line_versions lv ON lv.market_id = m.id AND lv.version = m.current_version
           JOIN players p ON p.id = m.player_id
           JOIN stat_definitions sd ON sd.key = m.stat_key
           WHERE m.status = 'open' AND m.lock_at >= $1 AND m.lock_at < $2 AND m.lock_at > now() + interval '30 minutes'
             AND p.position IS DISTINCT FROM 'TEAM'
           ORDER BY row_number() OVER (PARTITION BY p.league, m.stat_key ORDER BY lv.line_x10 DESC, m.id), m.id"#,
    )
    .bind(from)
    .bind(to)
    .fetch_all(pool)
    .await?;
    if candidates.len() < 3 {
        return Ok(false);
    }
    let chosen: Vec<_> = candidates.into_iter().take(QUESTIONS_PER_DAY).collect();
    let lock_at = chosen.iter().map(|c| c.2).min().expect("non-empty");
    let tiebreak = &chosen[..2];
    let label = format!("{} {} + {} {}", tiebreak[0].4, tiebreak[0].5.to_lowercase(), tiebreak[1].4, tiebreak[1].5.to_lowercase());
    let tb_ids: Vec<i64> = tiebreak.iter().map(|c| c.0).collect();

    let mut tx = pool.begin().await?;
    let updated = sqlx::query(
        r#"UPDATE contest_days SET slate_version = 1, lock_at = $2, tiebreak_label = $3, tiebreak_market_ids = $4
           WHERE id = $1 AND slate_version = 0"#,
    )
    .bind(day_id)
    .bind(lock_at)
    .bind(&label)
    .bind(&tb_ids)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if updated == 0 {
        return Ok(false);
    }
    for (i, c) in chosen.iter().enumerate() {
        sqlx::query("INSERT INTO contest_questions (contest_day_id, q_no, market_id, line_x10) VALUES ($1,$2,$3,$4)")
            .bind(day_id)
            .bind(i as i32 + 1)
            .bind(c.0)
            .bind(c.1)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(true)
}

pub struct Answer {
    pub question_id: i64,
    pub side: ss_core::Side,
}

/// Accepts one complete, immutable daily entry. Retries with the same command
/// id return the original receipt even after lock.
pub async fn submit_entry(
    pool: &PgPool,
    user_id: Uuid,
    day_id: i64,
    command_id: Uuid,
    slate_version: i32,
    tiebreak_x10: i32,
    answers: &[Answer],
) -> Result<crate::picks::Outcome> {
    use crate::picks::Outcome;
    let mut tx = pool.begin().await?;
    let existing: Option<(Uuid, Uuid)> = sqlx::query_as(
        "SELECT id, command_id FROM contest_entries WHERE contest_day_id = $1 AND user_id = $2",
    )
    .bind(day_id)
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await?;
    if let Some((entry_id, prior_cmd)) = existing {
        let body = entry_receipt(&mut tx, entry_id).await?;
        return Ok(if prior_cmd == command_id {
            Outcome { http_status: 201, body }
        } else {
            Outcome { http_status: 409, body: json!({ "status": "rejected", "code": "already_entered", "message": "You already entered today.", "receipt": body }) }
        });
    }
    let day: Option<(i32, Option<chrono::DateTime<Utc>>, bool)> = sqlx::query_as(
        "SELECT slate_version, lock_at, (lock_at IS NOT NULL AND clock_timestamp() < lock_at) FROM contest_days WHERE id = $1 FOR SHARE",
    )
    .bind(day_id)
    .fetch_optional(&mut *tx)
    .await?;
    let Some((version, _, open)) = day else {
        return Ok(Outcome { http_status: 404, body: json!({ "status": "rejected", "code": "not_found", "message": "Contest day not found." }) });
    };
    if !open {
        return Ok(Outcome { http_status: 409, body: json!({ "status": "rejected", "code": "locked", "message": "This day is locked." }) });
    }
    if version != slate_version {
        return Ok(Outcome { http_status: 409, body: json!({ "status": "rejected", "code": "slate_changed", "message": "The slate changed. Review again." }) });
    }
    let question_ids: Vec<i64> = sqlx::query_scalar("SELECT id FROM contest_questions WHERE contest_day_id = $1 ORDER BY q_no")
        .bind(day_id)
        .fetch_all(&mut *tx)
        .await?;
    let mut answered: Vec<i64> = answers.iter().map(|a| a.question_id).collect();
    answered.sort_unstable();
    let mut expected = question_ids.clone();
    expected.sort_unstable();
    if answered != expected {
        return Ok(Outcome { http_status: 422, body: json!({ "status": "rejected", "code": "incomplete", "message": "Answer every question before submitting." }) });
    }
    let entry_id: Uuid = sqlx::query_scalar(
        r#"INSERT INTO contest_entries (contest_day_id, user_id, command_id, slate_version, tiebreak_x10)
           VALUES ($1,$2,$3,$4,$5) RETURNING id"#,
    )
    .bind(day_id)
    .bind(user_id)
    .bind(command_id)
    .bind(version)
    .bind(tiebreak_x10)
    .fetch_one(&mut *tx)
    .await?;
    for a in answers {
        sqlx::query("INSERT INTO contest_answers (entry_id, question_id, side) VALUES ($1,$2,$3)")
            .bind(entry_id)
            .bind(a.question_id)
            .bind(a.side.as_str())
            .execute(&mut *tx)
            .await?;
    }
    let body = entry_receipt(&mut tx, entry_id).await?;
    tx.commit().await?;
    Ok(Outcome { http_status: 201, body })
}

async fn entry_receipt(tx: &mut sqlx::Transaction<'_, sqlx::Postgres>, entry_id: Uuid) -> Result<Value> {
    let (day_id, submitted_at, tiebreak_x10, points): (i64, chrono::DateTime<Utc>, i32, Option<i32>) = sqlx::query_as(
        "SELECT contest_day_id, submitted_at, tiebreak_x10, points FROM contest_entries WHERE id = $1",
    )
    .bind(entry_id)
    .fetch_one(&mut **tx)
    .await?;
    let answers: Vec<(i64, i32, String, String, String, i32, Option<String>)> = sqlx::query_as(
        r#"SELECT q.id, q.q_no, a.side, p.full_name, sd.label, q.line_x10, q.result
           FROM contest_answers a JOIN contest_questions q ON q.id = a.question_id
           JOIN markets m ON m.id = q.market_id JOIN players p ON p.id = m.player_id
           JOIN stat_definitions sd ON sd.key = m.stat_key
           WHERE a.entry_id = $1 ORDER BY q.q_no"#,
    )
    .bind(entry_id)
    .fetch_all(&mut **tx)
    .await?;
    Ok(json!({
        "status": "accepted",
        "entryId": entry_id,
        "dayId": day_id,
        "submittedAt": submitted_at,
        "tiebreak": crate::x10_to_f64(tiebreak_x10),
        "points": points,
        "answers": answers.iter().map(|(qid, no, side, name, label, line, result)| json!({
            "questionId": qid, "qNo": no, "side": side, "playerName": name, "statLabel": label,
            "line": crate::x10_to_f64(*line), "result": result,
            "correct": result.as_ref().map(|r| r == side),
        })).collect::<Vec<_>>(),
    }))
}

/// Scores every entry on a day from graded questions, then recomputes the
/// week's standings.
pub async fn grade_day(pool: &PgPool, day_id: i64) -> Result<()> {
    let (contest_id, tb_ids): (i64, Vec<i64>) =
        sqlx::query_as("SELECT contest_id, tiebreak_market_ids FROM contest_days WHERE id = $1")
            .bind(day_id)
            .fetch_one(pool)
            .await?;
    let tb_values: Vec<Option<i32>> = sqlx::query_scalar(
        r#"SELECT (SELECT value_x10 FROM market_results r WHERE r.market_id = m AND r.final ORDER BY revision DESC LIMIT 1)
           FROM unnest($1::bigint[]) AS m"#,
    )
    .bind(&tb_ids)
    .fetch_all(pool)
    .await?;
    let actual: Option<i32> = if !tb_values.is_empty() && tb_values.iter().all(Option::is_some) {
        Some(tb_values.iter().flatten().sum())
    } else {
        None
    };
    let mut tx = pool.begin().await?;
    sqlx::query("UPDATE contest_days SET tiebreak_actual_x10 = $2, graded_at = now() WHERE id = $1")
        .bind(day_id)
        .bind(actual)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        r#"UPDATE contest_entries e SET
             points = (SELECT count(*) FROM contest_answers a JOIN contest_questions q ON q.id = a.question_id
                       WHERE a.entry_id = e.id AND q.result = a.side),
             tiebreak_error_x10 = CASE WHEN $2::int IS NULL THEN NULL ELSE abs(e.tiebreak_x10 - $2::int) END
           WHERE e.contest_day_id = $1"#,
    )
    .bind(day_id)
    .bind(actual)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    recompute_standings(pool, contest_id).await
}

pub async fn recompute_standings(pool: &PgPool, contest_id: i64) -> Result<()> {
    let rows: Vec<(Uuid, i32, i32, Option<i32>)> = sqlx::query_as(
        r#"SELECT e.user_id, d.day_index, COALESCE(e.points, 0), e.tiebreak_error_x10
           FROM contest_entries e JOIN contest_days d ON d.id = e.contest_day_id
           WHERE d.contest_id = $1"#,
    )
    .bind(contest_id)
    .fetch_all(pool)
    .await?;
    let mut by_user: std::collections::HashMap<Uuid, Vec<DayScore>> = Default::default();
    for (u, day_index, points, err) in rows {
        by_user.entry(u).or_default().push(DayScore { day_index, points, tiebreak_error_x10: err });
    }
    let mut scored: Vec<(Uuid, ss_core::contest::WeeklyScore)> =
        by_user.into_iter().map(|(u, days)| (u, weekly_score(&days))).collect();
    scored.sort_by(|a, b| rank_key(&a.1).cmp(&rank_key(&b.1)).then(a.0.cmp(&b.0)));

    let mut tx = pool.begin().await?;
    let mut rank = 0;
    let mut prev: Option<(i32, i32, i64)> = None;
    for (i, (user, w)) in scored.iter().enumerate() {
        let key = rank_key(w);
        if prev != Some(key) {
            rank = i as i32 + 1;
            prev = Some(key);
        }
        sqlx::query(
            r#"INSERT INTO standings (contest_id, user_id, points, days_counted, tiebreak_error_x10, rank, updated_at)
               VALUES ($1,$2,$3,$4,$5,$6,now())
               ON CONFLICT (contest_id, user_id) DO UPDATE SET points = EXCLUDED.points, days_counted = EXCLUDED.days_counted,
                 tiebreak_error_x10 = EXCLUDED.tiebreak_error_x10, rank = EXCLUDED.rank, updated_at = now()"#,
        )
        .bind(contest_id)
        .bind(user)
        .bind(w.points)
        .bind(w.days_counted)
        .bind(w.tiebreak_error_x10)
        .bind(rank)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(())
}

pub async fn receipt(pool: &PgPool, entry_id: Uuid) -> Result<Value> {
    let mut tx = pool.begin().await?;
    let r = entry_receipt(&mut tx, entry_id).await?;
    tx.commit().await?;
    Ok(r)
}
