//! Card packs: a priced bundle of open lines. Buying debits coins and deals
//! the cards; each card is then picked like any single. Challenge packs pay
//! a multiple of the price when enough of their picks win.

use anyhow::Result;
use serde_json::{json, Value};
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::picks::Outcome;

#[derive(sqlx::FromRow, Clone)]
pub struct PackType {
    pub key: String,
    pub name: String,
    pub tagline: String,
    pub price: i64,
    pub size: i32,
    pub league: Option<String>,
    pub kind: String,
    pub positions: Option<Vec<String>>,
    pub team_id: Option<i64>,
    pub target_pct: Option<i32>,
    pub multiplier: Option<i32>,
    pub foil: String,
}

impl PackType {
    pub fn payout(&self) -> i64 {
        self.multiplier.map(|m| m as i64 * self.price).unwrap_or(0)
    }

    /// The league this pack deals from under the shopper's sport filter, or
    /// None (any league). Err means the pack has nothing for that sport.
    pub fn league_for(&self, sport: Option<&str>) -> std::result::Result<Option<String>, ()> {
        match (&self.league, sport) {
            (Some(l), Some(s)) if l != s => Err(()),
            (Some(l), _) => Ok(Some(l.clone())),
            (None, s) => Ok(s.map(str::to_string)),
        }
    }

    pub fn json(&self, available: i64) -> Value {
        json!({
            "key": self.key, "name": self.name, "tagline": self.tagline, "price": self.price,
            "size": self.size, "teamId": self.team_id, "packsRemaining": available / i64::from(self.size), "league": self.league, "kind": self.kind,
            "targetPct": self.target_pct, "multiplier": self.multiplier, "payout": self.payout(),
            "foil": self.foil.split(',').collect::<Vec<_>>(), "available": available,
        })
    }
}

const PACK_COLS: &str = "key, name, tagline, price, size, league, kind, positions, team_id, target_pct, multiplier, foil";

pub async fn pack_types(pool: &PgPool) -> Result<Vec<PackType>> {
    Ok(sqlx::query_as(&format!("SELECT {PACK_COLS} FROM pack_types WHERE active ORDER BY sort")).fetch_all(pool).await?)
}

/// Open lines a pack could deal to this user: still well before lock, not
/// already played in any entry or ever dealt in another pack.
const CANDIDATES: &str = r#"
    WITH ranked AS (
        SELECT m.id, p.league, p.position, p.team_id, g.home_team_id, g.away_team_id, m.stat_key,
               row_number() OVER (PARTITION BY m.stat_key ORDER BY lv.line_x10 DESC, m.id) AS stat_rank
        FROM markets m
        JOIN players p ON p.id = m.player_id
        JOIN games g ON g.id = m.game_id
        JOIN line_versions lv ON lv.market_id = m.id AND lv.version = m.current_version
        WHERE m.status = 'open' AND m.lock_at > now() + interval '5 minutes'
    )
    SELECT {select} FROM ranked r
    WHERE ($2::text IS NULL OR r.league = $2)
      AND ($6::bigint IS NULL OR (r.team_id = $6 AND NOT (r.stat_key = ANY($5)))
           OR (r.stat_key = ANY($5) AND $6 IN (r.home_team_id, r.away_team_id)))
      AND CASE $3
            WHEN 'game' THEN r.stat_key = ANY($5)
            WHEN 'position' THEN r.position = ANY($4) AND NOT (r.stat_key = ANY($5))
            WHEN 'allstar' THEN r.stat_rank <= 6 AND NOT (r.stat_key = ANY($5))
            ELSE true END
      AND NOT EXISTS (SELECT 1 FROM entries e WHERE e.user_id = $1 AND e.single_market_id = r.id)
      AND NOT EXISTS (SELECT 1 FROM pack_cards pc JOIN pack_purchases pp ON pp.id = pc.purchase_id
                      WHERE pp.user_id = $1 AND pc.market_id = r.id)
      AND NOT EXISTS (SELECT 1 FROM entry_legs el JOIN entries e ON e.id = el.entry_id
                      WHERE e.user_id = $1 AND el.market_id = r.id)
"#;

fn game_keys() -> Vec<String> {
    ss_core::lines::GAME_STATS.iter().map(|s| s.to_string()).collect()
}

pub async fn available(pool: &PgPool, user_id: Uuid, pack: &PackType, sport: Option<&str>) -> Result<i64> {
    let Ok(league) = pack.league_for(sport) else { return Ok(0) };
    Ok(sqlx::query_scalar(&CANDIDATES.replace("{select}", "count(*)"))
        .bind(user_id)
        .bind(league)
        .bind(&pack.kind)
        .bind(pack.positions.clone().unwrap_or_default())
        .bind(game_keys())
        .bind(pack.team_id)
        .fetch_one(pool)
        .await?)
}

async fn deal(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    pack: &PackType,
    league: Option<String>,
) -> Result<Vec<i64>> {
    Ok(sqlx::query_scalar(&format!("{} ORDER BY random() LIMIT $7", CANDIDATES.replace("{select}", "r.id")))
        .bind(user_id)
        .bind(league)
        .bind(&pack.kind)
        .bind(pack.positions.clone().unwrap_or_default())
        .bind(game_keys())
        .bind(pack.team_id)
        .bind(pack.size as i64)
        .fetch_all(&mut **tx)
        .await?)
}

fn reject(http_status: u16, code: &str, message: &str) -> Outcome {
    Outcome { http_status, body: json!({ "status": "rejected", "code": code, "message": message }) }
}

/// Buys and deals a pack. Retrying the same command id returns the same pack
/// without charging twice.
pub async fn buy(pool: &PgPool, user_id: Uuid, command_id: Uuid, pack_key: &str, sport: Option<&str>) -> Result<Outcome> {
    let mut tx = pool.begin().await?;
    crate::picks::lock_wallet(&mut tx, user_id).await?;
    let prior: Option<Uuid> = sqlx::query_scalar("SELECT id FROM pack_purchases WHERE user_id = $1 AND command_id = $2")
        .bind(user_id)
        .bind(command_id)
        .fetch_optional(&mut *tx)
        .await?;
    if let Some(id) = prior {
        tx.rollback().await?;
        return Ok(Outcome { http_status: 200, body: purchase_json(pool, user_id, id).await? });
    }
    let pack: Option<PackType> = sqlx::query_as(&format!("SELECT {PACK_COLS} FROM pack_types WHERE key = $1 AND active"))
        .bind(pack_key)
        .fetch_optional(&mut *tx)
        .await?;
    let Some(pack) = pack else { return Ok(reject(404, "unknown_pack", "That pack isn't available.")) };
    let Ok(league) = pack.league_for(sport) else {
        return Ok(reject(409, "sold_out", "This pack has no cards for that sport."));
    };
    let cards = deal(&mut tx, user_id, &pack, league).await?;
    if cards.len() < pack.size as usize {
        return Ok(reject(409, "sold_out", "Not enough open lines for this pack right now. Check back before the next games."));
    }
    let wallet: Option<(i64, i64)> = sqlx::query_as(
        "UPDATE coin_accounts SET balance = balance - $2, version = version + 1 WHERE user_id = $1 AND balance >= $2 RETURNING balance, version",
    )
    .bind(user_id)
    .bind(pack.price)
    .fetch_optional(&mut *tx)
    .await?;
    if wallet.is_none() {
        return Ok(reject(409, "insufficient_coins", "Not enough coins for this pack."));
    }
    let id: Uuid = sqlx::query_scalar(
        r#"INSERT INTO pack_purchases (user_id, pack_key, command_id, sport, price, size, target_pct, payout)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id"#,
    )
    .bind(user_id)
    .bind(&pack.key)
    .bind(command_id)
    .bind(sport.unwrap_or("all"))
    .bind(pack.price)
    .bind(cards.len() as i32)
    .bind(pack.target_pct)
    .bind(pack.payout())
    .fetch_one(&mut *tx)
    .await?;
    for (i, m) in cards.iter().enumerate() {
        sqlx::query("INSERT INTO pack_cards (purchase_id, position, market_id) VALUES ($1,$2,$3)")
            .bind(id)
            .bind(i as i32 + 1)
            .bind(m)
            .execute(&mut *tx)
            .await?;
    }
    if pack.price > 0 {
        sqlx::query("INSERT INTO coin_ledger (user_id, delta, reason, source_key) VALUES ($1, $2, 'pack', $3)")
            .bind(user_id)
            .bind(-pack.price)
            .bind(format!("pack:{id}"))
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(Outcome { http_status: 201, body: purchase_json(pool, user_id, id).await? })
}

/// A purchase with its unplayed cards, ready to swipe.
pub async fn purchase_json(pool: &PgPool, user_id: Uuid, id: Uuid) -> Result<Value> {
    let row: (String, String, i64, i32, Option<i32>, i64, String, String) = sqlx::query_as(
        r#"SELECT pp.pack_key, pt.name, pp.price, pp.size, pp.target_pct, pp.payout, pp.status, pt.foil
           FROM pack_purchases pp JOIN pack_types pt ON pt.key = pp.pack_key
           WHERE pp.id = $1 AND pp.user_id = $2"#,
    )
    .bind(id)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    let (balance, version): (i64, i64) = sqlx::query_as("SELECT balance, version FROM coin_accounts WHERE user_id = $1")
        .bind(user_id)
        .fetch_one(pool)
        .await?;
    let ids: Vec<i64> = sqlx::query_scalar(
        r#"SELECT pc.market_id FROM pack_cards pc JOIN markets m ON m.id = pc.market_id
           WHERE pc.purchase_id = $1 AND pc.entry_id IS NULL AND m.status = 'open' AND m.lock_at > now()
           ORDER BY pc.position"#,
    )
    .bind(id)
    .fetch_all(pool)
    .await?;
    let cards = with_pack(crate::cards::playable_cards(pool, Some(user_id), &ids).await?, id);
    Ok(json!({
        "status": "accepted", "packId": id, "packKey": row.0, "name": row.1, "price": row.2, "size": row.3,
        "targetPct": row.4, "payout": row.5, "packStatus": row.6, "foil": row.7.split(',').collect::<Vec<_>>(),
        "cards": cards, "balance": balance, "balanceVersion": version,
    }))
}

fn with_pack(cards: Vec<Value>, pack: Uuid) -> Vec<Value> {
    cards
        .into_iter()
        .map(|mut c| {
            c["packId"] = json!(pack);
            c
        })
        .collect()
}

/// Cards bought but not yet picked, across all packs, still open.
pub async fn leftovers(pool: &PgPool, user_id: Uuid, league: Option<&str>) -> Result<Vec<Value>> {
    let rows: Vec<(Uuid, i64)> = sqlx::query_as(
        r#"SELECT pc.purchase_id, pc.market_id
           FROM pack_cards pc JOIN pack_purchases pp ON pp.id = pc.purchase_id
           JOIN markets m ON m.id = pc.market_id JOIN players p ON p.id = m.player_id
           WHERE pp.user_id = $1 AND pc.entry_id IS NULL AND m.status = 'open' AND m.lock_at > now()
             AND ($2::text IS NULL OR p.league = $2)
             AND NOT EXISTS (SELECT 1 FROM entries e WHERE e.user_id = $1 AND e.single_market_id = m.id)
           ORDER BY m.lock_at, pp.created_at, pc.position LIMIT 40"#,
    )
    .bind(user_id)
    .bind(league)
    .fetch_all(pool)
    .await?;
    let ids: Vec<i64> = rows.iter().map(|r| r.1).collect();
    let packs: std::collections::HashMap<i64, Uuid> = rows.iter().map(|(p, m)| (*m, *p)).collect();
    let cards = crate::cards::playable_cards(pool, Some(user_id), &ids).await?;
    Ok(cards
        .into_iter()
        .map(|mut c| {
            let pack = c["market"]["marketId"].as_i64().and_then(|m| packs.get(&m)).copied();
            c["packId"] = json!(pack);
            c
        })
        .collect())
}

/// Settles a challenge pack once every pick in it has settled. Unplayed cards
/// count as misses; voided picks leave the pack.
pub async fn settle_for_entry(tx: &mut Transaction<'_, Postgres>, entry_id: Uuid) -> Result<()> {
    let pack: Option<Uuid> = sqlx::query_scalar("SELECT purchase_id FROM pack_cards WHERE entry_id = $1")
        .bind(entry_id)
        .fetch_optional(&mut **tx)
        .await?;
    let Some(pack) = pack else { return Ok(()) };
    let row: Option<(Uuid, Option<i32>, i64, String)> =
        sqlx::query_as("SELECT user_id, target_pct, payout, status FROM pack_purchases WHERE id = $1 FOR UPDATE")
            .bind(pack)
            .fetch_optional(&mut **tx)
            .await?;
    let Some((user_id, Some(target), payout, status)) = row else { return Ok(()) };
    if status != "open" {
        return Ok(());
    }
    let cards: Vec<(Option<String>, bool)> = sqlx::query_as(
        r#"SELECT e.status, m.lock_at <= now() FROM pack_cards pc
           JOIN markets m ON m.id = pc.market_id LEFT JOIN entries e ON e.id = pc.entry_id
           WHERE pc.purchase_id = $1"#,
    )
    .bind(pack)
    .fetch_all(&mut **tx)
    .await?;
    let undecided = cards.iter().any(|(s, locked)| match s {
        Some(s) => s == "pending",
        None => !locked,
    });
    if undecided {
        return Ok(());
    }
    let won = cards.iter().filter(|(s, _)| s.as_deref() == Some("won")).count() as i64;
    let counted = cards.iter().filter(|(s, _)| s.as_deref() != Some("void")).count() as i64;
    let (status, credit) = if counted == 0 {
        ("void", 0)
    } else if won * 100 >= target as i64 * counted {
        ("won", payout)
    } else {
        ("lost", 0)
    };
    if credit > 0 {
        let added = sqlx::query(
            "INSERT INTO coin_ledger (user_id, delta, reason, source_key) VALUES ($1, $2, 'pack_win', $3) ON CONFLICT (source_key) DO NOTHING",
        )
        .bind(user_id)
        .bind(credit)
        .bind(format!("pack-win:{pack}"))
        .execute(&mut **tx)
        .await?
        .rows_affected();
        if added == 1 {
            sqlx::query("UPDATE coin_accounts SET balance = balance + $2, version = version + 1 WHERE user_id = $1")
                .bind(user_id)
                .bind(credit)
                .execute(&mut **tx)
                .await?;
        }
    }
    sqlx::query("UPDATE pack_purchases SET status = $2, credited = $3, settled_at = now() WHERE id = $1")
        .bind(pack)
        .bind(status)
        .bind(credit)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// The user's challenge packs still waiting on results.
pub async fn open_challenges(pool: &PgPool, user_id: Uuid) -> Result<Vec<Value>> {
    let rows: Vec<(Uuid, String, i32, i32, i64, i64, i64)> = sqlx::query_as(
        r#"SELECT pp.id, pt.name, pp.size, pp.target_pct, pp.payout,
                  count(e.id) FILTER (WHERE e.status = 'won'),
                  count(pc.entry_id)
           FROM pack_purchases pp JOIN pack_types pt ON pt.key = pp.pack_key
           JOIN pack_cards pc ON pc.purchase_id = pp.id LEFT JOIN entries e ON e.id = pc.entry_id
           WHERE pp.user_id = $1 AND pp.status = 'open' AND pp.target_pct IS NOT NULL
           GROUP BY pp.id, pt.name ORDER BY pp.created_at DESC LIMIT 10"#,
    )
    .bind(user_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, name, size, target, payout, won, picked)| {
            json!({ "packId": id, "name": name, "size": size, "targetPct": target, "payout": payout, "won": won, "picked": picked })
        })
        .collect())
}
