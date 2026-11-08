//! Idempotent pick acceptance. The receipt, accepted line, debit and balance
//! are written in one transaction and agree at commit.

use anyhow::Result;
use serde_json::{json, Value};
use sqlx::{PgPool, Postgres, Transaction};
use ss_core::{payout, Side};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct LegRequest {
    pub market_id: i64,
    pub line_version: i32,
    pub side: Side,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    Single,
    Parlay,
}

impl EntryKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EntryKind::Single => "single",
            EntryKind::Parlay => "parlay",
        }
    }
}

/// HTTP status plus JSON body; identical for every retry of a command.
#[derive(Debug, Clone)]
pub struct Outcome {
    pub http_status: u16,
    pub body: Value,
}

fn payload_hash(kind: EntryKind, stake: i64, legs: &[LegRequest]) -> String {
    let canonical = json!({
        "kind": kind.as_str(),
        "stake": stake,
        "legs": legs.iter().map(|l| json!([l.market_id, l.line_version, l.side.as_str()])).collect::<Vec<_>>(),
    });
    crate::sha256_hex(canonical.to_string().as_bytes())
}

fn reject(http_status: u16, code: &str, message: &str, extra: Value) -> Outcome {
    let mut body = json!({ "status": "rejected", "code": code, "message": message });
    if let (Value::Object(b), Value::Object(e)) = (&mut body, extra) {
        b.extend(e);
    }
    Outcome { http_status, body }
}

/// Looks up a prior result for this command. A different payload under the
/// same command id is an explicit conflict.
async fn replay(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    command_id: Uuid,
    hash: &str,
) -> Result<Option<Outcome>> {
    let prior: Option<(String, i32, Value)> = sqlx::query_as(
        "SELECT payload_hash, http_status, result FROM commands WHERE user_id = $1 AND command_id = $2",
    )
    .bind(user_id)
    .bind(command_id)
    .fetch_optional(&mut **tx)
    .await?;
    Ok(prior.map(|(h, status, result)| {
        if h == hash {
            Outcome { http_status: status as u16, body: result }
        } else {
            reject(409, "command_conflict", "This command id was already used for a different request.", json!({}))
        }
    }))
}

async fn record(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    command_id: Uuid,
    kind: &str,
    hash: &str,
    o: &Outcome,
) -> Result<()> {
    let status = if o.http_status < 300 { "accepted" } else { "rejected" };
    sqlx::query(
        "INSERT INTO commands (user_id, command_id, kind, payload_hash, status, http_status, result) VALUES ($1,$2,$3,$4,$5,$6,$7)",
    )
    .bind(user_id)
    .bind(command_id)
    .bind(kind)
    .bind(hash)
    .bind(status)
    .bind(o.http_status as i32)
    .bind(&o.body)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Serializes all commands for one user so wallet checks see a stable balance.
pub async fn lock_wallet(tx: &mut Transaction<'_, Postgres>, user_id: Uuid) -> Result<(i64, i64)> {
    let row: (i64, i64) = sqlx::query_as("SELECT balance, version FROM coin_accounts WHERE user_id = $1 FOR UPDATE")
        .bind(user_id)
        .fetch_one(&mut **tx)
        .await?;
    Ok(row)
}

#[derive(sqlx::FromRow)]
struct LockedMarket {
    id: i64,
    status: String,
    current_version: i32,
    line_x10: i32,
    open_now: bool,
}

pub async fn accept_entry(
    pool: &PgPool,
    user_id: Uuid,
    command_id: Uuid,
    kind: EntryKind,
    stake: i64,
    legs: Vec<LegRequest>,
) -> Result<Outcome> {
    let hash = payload_hash(kind, stake, &legs);
    let mut tx = pool.begin().await?;
    let (_, _) = lock_wallet(&mut tx, user_id).await?;
    if let Some(prior) = replay(&mut tx, user_id, command_id, &hash).await? {
        tx.rollback().await?;
        return Ok(prior);
    }

    let outcome = decide(&mut tx, user_id, command_id, kind, stake, &legs).await?;
    record(&mut tx, user_id, command_id, kind.as_str(), &hash, &outcome).await?;
    tx.commit().await?;
    Ok(outcome)
}

async fn decide(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    command_id: Uuid,
    kind: EntryKind,
    stake: i64,
    legs: &[LegRequest],
) -> Result<Outcome> {
    if !(0..=payout::MAX_STAKE).contains(&stake) {
        return Ok(reject(422, "invalid_stake", "Stake is out of range.", json!({})));
    }
    let n = legs.len();
    let valid_count = match kind {
        EntryKind::Single => n == 1,
        EntryKind::Parlay => (payout::MIN_PARLAY_LEGS..=payout::MAX_PARLAY_LEGS).contains(&n),
    };
    if !valid_count {
        return Ok(reject(422, "invalid_legs", "Wrong number of selections.", json!({})));
    }
    let mut ids: Vec<i64> = legs.iter().map(|l| l.market_id).collect();
    ids.sort_unstable();
    ids.dedup();
    if ids.len() != n {
        return Ok(reject(422, "duplicate_legs", "Each line can appear once per entry.", json!({})));
    }

    // Shared row locks in id order: concurrent swipes on a popular card do not
    // block each other, while a line publish (exclusive update) waits.
    let markets: Vec<LockedMarket> = sqlx::query_as(
        r#"SELECT m.id, m.status, m.current_version, lv.line_x10,
                  (m.status = 'open' AND clock_timestamp() < m.lock_at) AS open_now
           FROM markets m JOIN line_versions lv ON lv.market_id = m.id AND lv.version = m.current_version
           WHERE m.id = ANY($1) ORDER BY m.id FOR SHARE OF m"#,
    )
    .bind(&ids)
    .fetch_all(&mut **tx)
    .await?;

    let mut stale = Vec::new();
    for leg in legs {
        match markets.iter().find(|m| m.id == leg.market_id) {
            None => stale.push(json!({ "marketId": leg.market_id, "reason": "not_found" })),
            Some(m) if !m.open_now => stale.push(json!({ "marketId": m.id, "reason": "locked", "status": m.status })),
            Some(m) if m.current_version != leg.line_version => stale.push(json!({
                "marketId": m.id, "reason": "line_moved",
                "currentVersion": m.current_version, "currentLine": crate::x10_to_f64(m.line_x10),
            })),
            _ => {}
        }
    }
    if !stale.is_empty() {
        return Ok(reject(409, "pick_closed", "Pick closed · no coins used.", json!({ "staleLegs": stale })));
    }

    if kind == EntryKind::Single {
        let existing: Option<Uuid> =
            sqlx::query_scalar("SELECT id FROM entries WHERE user_id = $1 AND single_market_id = $2")
                .bind(user_id)
                .bind(legs[0].market_id)
                .fetch_optional(&mut **tx)
                .await?;
        if let Some(entry_id) = existing {
            return Ok(reject(409, "already_picked", "You already made this call.", json!({ "entryId": entry_id })));
        }
    }

    let potential = match kind {
        EntryKind::Single => payout::single_return(payout::RULE_VERSION, stake),
        EntryKind::Parlay => payout::parlay_return(payout::RULE_VERSION, stake, n).unwrap_or(0),
    };

    let wallet: Option<(i64, i64)> = sqlx::query_as(
        r#"UPDATE coin_accounts SET balance = balance - $2, version = version + CASE WHEN $2 > 0 THEN 1 ELSE 0 END
           WHERE user_id = $1 AND balance >= $2 RETURNING balance, version"#,
    )
    .bind(user_id)
    .bind(stake)
    .fetch_optional(&mut **tx)
    .await?;
    let Some((balance, balance_version)) = wallet else {
        let (balance, version): (i64, i64) =
            sqlx::query_as("SELECT balance, version FROM coin_accounts WHERE user_id = $1")
                .bind(user_id)
                .fetch_one(&mut **tx)
                .await?;
        return Ok(reject(
            409,
            "insufficient_coins",
            "Not enough coins. You can still make a free pick.",
            json!({ "balance": balance, "balanceVersion": version }),
        ));
    };

    let single_market = (kind == EntryKind::Single).then(|| legs[0].market_id);
    let (entry_id, accepted_at): (Uuid, chrono::DateTime<chrono::Utc>) = sqlx::query_as(
        r#"INSERT INTO entries (user_id, kind, command_id, stake, rule_version, potential_return, single_market_id)
           VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id, accepted_at"#,
    )
    .bind(user_id)
    .bind(kind.as_str())
    .bind(command_id)
    .bind(stake)
    .bind(payout::RULE_VERSION)
    .bind(potential)
    .bind(single_market)
    .fetch_one(&mut **tx)
    .await?;

    for (i, leg) in legs.iter().enumerate() {
        let m = markets.iter().find(|m| m.id == leg.market_id).expect("validated");
        sqlx::query(
            "INSERT INTO entry_legs (entry_id, leg_no, market_id, line_version, line_x10, side) VALUES ($1,$2,$3,$4,$5,$6)",
        )
        .bind(entry_id)
        .bind(i as i32 + 1)
        .bind(m.id)
        .bind(m.current_version)
        .bind(m.line_x10)
        .bind(leg.side.as_str())
        .execute(&mut **tx)
        .await?;
    }

    if stake > 0 {
        sqlx::query(
            "INSERT INTO coin_ledger (user_id, delta, reason, source_key, entry_id) VALUES ($1, $2, 'stake', $3, $4)",
        )
        .bind(user_id)
        .bind(-stake)
        .bind(format!("stake:{entry_id}"))
        .bind(entry_id)
        .execute(&mut **tx)
        .await?;
    }

    let event_legs: Vec<Value> = legs
        .iter()
        .map(|l| json!({ "marketId": l.market_id, "side": l.side.as_str() }))
        .collect();
    sqlx::query("INSERT INTO outbox (topic, payload) VALUES ('entry_accepted', $1)")
        .bind(json!({ "entryId": entry_id, "userId": user_id, "legs": event_legs }))
        .execute(&mut **tx)
        .await?;

    let body = json!({
        "status": "accepted",
        "commandId": command_id,
        "entryId": entry_id,
        "kind": kind.as_str(),
        "stake": stake,
        "potentialReturn": potential,
        "ruleVersion": payout::RULE_VERSION,
        "acceptedAt": accepted_at,
        "legs": legs.iter().enumerate().map(|(i, l)| {
            let m = markets.iter().find(|m| m.id == l.market_id).expect("validated");
            json!({
                "legNo": i + 1, "marketId": m.id, "lineVersion": m.current_version,
                "line": crate::x10_to_f64(m.line_x10), "side": l.side.as_str(),
            })
        }).collect::<Vec<_>>(),
        "balance": balance,
        "balanceVersion": balance_version,
    });
    Ok(Outcome { http_status: 201, body })
}

pub async fn command_status(pool: &PgPool, user_id: Uuid, command_id: Uuid) -> Result<Option<Outcome>> {
    let row: Option<(i32, Value)> =
        sqlx::query_as("SELECT http_status, result FROM commands WHERE user_id = $1 AND command_id = $2")
            .bind(user_id)
            .bind(command_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.map(|(s, body)| Outcome { http_status: s as u16, body }))
}

/// Applies committed `entry_accepted` events to community pick counts. Each
/// event is processed and marked in the same transaction, so a crash between
/// the two cannot double count.
pub async fn relay_outbox(pool: &PgPool, batch: i64) -> Result<usize> {
    let mut tx = pool.begin().await?;
    let events: Vec<(i64, String, Value)> = sqlx::query_as(
        "SELECT id, topic, payload FROM outbox WHERE processed_at IS NULL ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED",
    )
    .bind(batch)
    .fetch_all(&mut *tx)
    .await?;
    for (id, topic, payload) in &events {
        if topic == "entry_accepted" {
            for leg in payload["legs"].as_array().into_iter().flatten() {
                let market_id = leg["marketId"].as_i64().unwrap_or_default();
                let over = leg["side"] == "over";
                sqlx::query(
                    r#"INSERT INTO market_pick_counts (market_id, over_count, under_count) VALUES ($1, $2, $3)
                       ON CONFLICT (market_id) DO UPDATE SET
                         over_count = market_pick_counts.over_count + EXCLUDED.over_count,
                         under_count = market_pick_counts.under_count + EXCLUDED.under_count"#,
                )
                .bind(market_id)
                .bind(over as i32)
                .bind((!over) as i32)
                .execute(&mut *tx)
                .await?;
            }
        }
        sqlx::query("UPDATE outbox SET processed_at = now() WHERE id = $1")
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(events.len())
}
