//! Grading: the single path that turns market results into leg results,
//! entry settlements, coin credits and mastery. Every effect is keyed so a
//! replay of the same result revision changes nothing.

use anyhow::Result;
use serde::Serialize;
use sqlx::{PgPool, Postgres, Transaction};
use ss_core::grading::{grade_leg, settle_parlay, settle_single, LegResult};
use ss_core::Side;
use uuid::Uuid;

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GradeSummary {
    pub market_id: i64,
    pub result_revision: Option<i32>,
    pub legs_graded: usize,
    pub entries_settled: usize,
    pub coins_credited: i64,
    pub mastery_awarded: usize,
    pub contest_days: Vec<i64>,
}

#[derive(sqlx::FromRow)]
struct LegRow {
    id: i64,
    entry_id: Uuid,
    side: String,
    line_x10: i32,
}

#[derive(sqlx::FromRow)]
struct EntryRow {
    user_id: Uuid,
    kind: String,
    stake: i64,
    rule_version: i32,
    credited: i64,
    status: String,
}

#[derive(sqlx::FromRow)]
struct EntryLeg {
    market_id: i64,
    result: Option<String>,
    result_revision: Option<i32>,
    player_id: i64,
}

pub async fn grade_market(pool: &PgPool, market_id: i64) -> Result<GradeSummary> {
    let mut tx = pool.begin().await?;
    let summary = grade_market_tx(&mut tx, market_id).await?;
    tx.commit().await?;
    Ok(summary)
}

async fn grade_market_tx(tx: &mut Transaction<'_, Postgres>, market_id: i64) -> Result<GradeSummary> {
    let mut summary = GradeSummary { market_id, ..Default::default() };
    // Serialize graders on this market.
    sqlx::query("SELECT id FROM markets WHERE id = $1 FOR UPDATE")
        .bind(market_id)
        .execute(&mut **tx)
        .await?;
    let latest: Option<(i32, i32, String)> = sqlx::query_as(
        "SELECT revision, value_x10, source FROM market_results WHERE market_id = $1 AND final ORDER BY revision DESC LIMIT 1",
    )
    .bind(market_id)
    .fetch_optional(&mut **tx)
    .await?;
    let Some((revision, value_x10, source)) = latest else { return Ok(summary) };
    summary.result_revision = Some(revision);
    let void = source == "dnp";

    sqlx::query("UPDATE markets SET status = $2 WHERE id = $1")
        .bind(market_id)
        .bind(if void { "void" } else { "settled" })
        .execute(&mut **tx)
        .await?;

    let legs: Vec<LegRow> = sqlx::query_as(
        r#"SELECT id, entry_id, side, line_x10 FROM entry_legs
           WHERE market_id = $1 AND (result_revision IS NULL OR result_revision < $2)
           ORDER BY id FOR UPDATE"#,
    )
    .bind(market_id)
    .bind(revision)
    .fetch_all(&mut **tx)
    .await?;

    let mut entry_ids: Vec<Uuid> = Vec::new();
    for leg in &legs {
        let side = Side::parse(&leg.side).unwrap_or(Side::Over);
        let result = if void { LegResult::Void } else { grade_leg(side, leg.line_x10, value_x10) };
        sqlx::query("UPDATE entry_legs SET result = $2, result_revision = $3 WHERE id = $1")
            .bind(leg.id)
            .bind(result.as_str())
            .bind(revision)
            .execute(&mut **tx)
            .await?;
        if !entry_ids.contains(&leg.entry_id) {
            entry_ids.push(leg.entry_id);
        }
    }
    summary.legs_graded = legs.len();
    entry_ids.sort();

    for entry_id in entry_ids {
        let (credited, mastery) = settle_entry(tx, entry_id).await?;
        if let Some(c) = credited {
            summary.entries_settled += 1;
            summary.coins_credited += c;
        }
        summary.mastery_awarded += mastery;
    }

    // Contest questions on this market.
    let days: Vec<i64> = sqlx::query_scalar(
        r#"UPDATE contest_questions SET result = CASE
              WHEN $2 THEN 'void' WHEN $3 > line_x10 THEN 'over' WHEN $3 < line_x10 THEN 'under' ELSE 'void' END
           WHERE market_id = $1 RETURNING contest_day_id"#,
    )
    .bind(market_id)
    .bind(void)
    .bind(value_x10)
    .fetch_all(&mut **tx)
    .await?;
    let mut days = days;
    days.sort_unstable();
    days.dedup();
    for d in &days {
        crate::jobs::enqueue(&mut **tx, "grade_contest_day", Some(&format!("grade_contest_day:{d}")), serde_json::json!({ "dayId": d })).await?;
    }
    summary.contest_days = days;
    Ok(summary)
}

/// Settles an entry once all its legs are graded. Returns the coin delta
/// applied (None when nothing changed) and mastery credits awarded.
async fn settle_entry(tx: &mut Transaction<'_, Postgres>, entry_id: Uuid) -> Result<(Option<i64>, usize)> {
    let entry: EntryRow = sqlx::query_as(
        "SELECT user_id, kind, stake, rule_version, credited, status FROM entries WHERE id = $1 FOR UPDATE",
    )
    .bind(entry_id)
    .fetch_one(&mut **tx)
    .await?;
    let legs: Vec<EntryLeg> = sqlx::query_as(
        r#"SELECT el.market_id, el.result, el.result_revision, m.player_id
           FROM entry_legs el JOIN markets m ON m.id = el.market_id
           WHERE el.entry_id = $1 ORDER BY el.leg_no"#,
    )
    .bind(entry_id)
    .fetch_all(&mut **tx)
    .await?;
    if legs.iter().any(|l| l.result.is_none()) {
        return Ok((None, 0));
    }
    let results: Vec<LegResult> = legs
        .iter()
        .map(|l| l.result.as_deref().and_then(LegResult::parse).unwrap_or(LegResult::Void))
        .collect();
    let settlement = if entry.kind == "single" {
        settle_single(entry.rule_version, entry.stake, results[0])
    } else {
        settle_parlay(entry.rule_version, entry.stake, &results)
    };
    let revision_key = legs
        .iter()
        .map(|l| format!("m{}r{}", l.market_id, l.result_revision.unwrap_or(0)))
        .collect::<Vec<_>>()
        .join("|");

    let inserted = sqlx::query(
        "INSERT INTO grade_events (entry_id, revision_key, status, credit) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING",
    )
    .bind(entry_id)
    .bind(&revision_key)
    .bind(settlement.status.as_str())
    .bind(settlement.credit)
    .execute(&mut **tx)
    .await?
    .rows_affected();
    if inserted == 0 {
        return Ok((None, 0));
    }

    // A correction credits or reverses only the difference from what was
    // already paid on this entry.
    let delta = settlement.credit - entry.credited;
    if delta != 0 {
        let ledger = sqlx::query(
            r#"INSERT INTO coin_ledger (user_id, delta, reason, source_key, entry_id)
               VALUES ($1, $2, $3, $4, $5) ON CONFLICT (source_key) DO NOTHING"#,
        )
        .bind(entry.user_id)
        .bind(delta)
        .bind(if entry.status == "pending" { "grade" } else { "regrade" })
        .bind(format!("grade:{entry_id}:{revision_key}"))
        .bind(entry_id)
        .execute(&mut **tx)
        .await?
        .rows_affected();
        if ledger == 1 {
            sqlx::query("UPDATE coin_accounts SET balance = balance + $2, version = version + 1 WHERE user_id = $1")
                .bind(entry.user_id)
                .bind(delta)
                .execute(&mut **tx)
                .await?;
        }
    }
    let status_changed = entry.status != settlement.status.as_str();
    sqlx::query(
        r#"UPDATE entries SET status = $2, credited = $3, settled_at = COALESCE(settled_at, now()),
                  revealed_at = CASE WHEN $4 THEN NULL ELSE revealed_at END
           WHERE id = $1"#,
    )
    .bind(entry_id)
    .bind(settlement.status.as_str())
    .bind(settlement.credit)
    .bind(status_changed)
    .execute(&mut **tx)
    .await?;
    crate::packs::settle_for_entry(tx, entry_id).await?;

    // Mastery: one credit per person, athlete and market regardless of entry
    // point. Losing parlays earn none.
    let mut mastery = 0;
    if settlement.status == ss_core::grading::EntryStatus::Won {
        for (leg, r) in legs.iter().zip(&results) {
            if *r != LegResult::Win {
                continue;
            }
            let added = sqlx::query(
                "INSERT INTO mastery_events (user_id, player_id, market_id, entry_id) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING",
            )
            .bind(entry.user_id)
            .bind(leg.player_id)
            .bind(leg.market_id)
            .bind(entry_id)
            .execute(&mut **tx)
            .await?
            .rows_affected();
            if added == 1 {
                sqlx::query(
                    r#"INSERT INTO mastery_totals (user_id, player_id, correct_count) VALUES ($1, $2, 1)
                       ON CONFLICT (user_id, player_id) DO UPDATE SET correct_count = mastery_totals.correct_count + 1"#,
                )
                .bind(entry.user_id)
                .bind(leg.player_id)
                .execute(&mut **tx)
                .await?;
                sqlx::query("INSERT INTO card_series (player_id) VALUES ($1) ON CONFLICT DO NOTHING")
                    .bind(leg.player_id)
                    .execute(&mut **tx)
                    .await?;
                mastery += 1;
            }
        }
    }
    Ok((Some(delta), mastery))
}

/// Demo override: records an admin-supplied final value as a new result
/// revision and runs the real grading path immediately.
pub async fn admin_settle(pool: &PgPool, market_id: i64, value_x10: i32) -> Result<GradeSummary> {
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT id FROM markets WHERE id = $1 FOR UPDATE")
        .bind(market_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        r#"INSERT INTO market_results (market_id, revision, value_x10, source, final)
           SELECT $1, COALESCE(MAX(revision), 0) + 1, $2, 'admin_demo', true FROM market_results WHERE market_id = $1"#,
    )
    .bind(market_id)
    .bind(value_x10)
    .execute(&mut *tx)
    .await?;
    let summary = grade_market_tx(&mut tx, market_id).await?;
    tx.commit().await?;
    for d in &summary.contest_days {
        crate::contests::grade_day(pool, *d).await?;
    }
    Ok(summary)
}
