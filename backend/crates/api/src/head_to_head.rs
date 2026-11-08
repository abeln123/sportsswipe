//! Ten fixed lines, equal questions, no wallet/ledger/mastery effects.
use crate::{
    auth::{random_token, AuthUser},
    error::{ApiError, ApiResult},
    state::AppState,
};
use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use ss_core::{LegResult, Side};
use uuid::Uuid;
#[derive(sqlx::FromRow)]
struct Match {
    id: Uuid,
    creator_id: Uuid,
    opponent_id: Option<Uuid>,
    token: String,
    lock_at: DateTime<Utc>,
    tie_game_id: i64,
    shared_market_id: i64,
    accepted_at: Option<DateTime<Utc>>,
    invited_user_id: Option<Uuid>,
}
const COLS: &str = "id,creator_id,opponent_id,token,lock_at,tie_game_id,shared_market_id,accepted_at,invited_user_id";
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/head-to-heads", get(list).post(create))
        .route("/head-to-heads/{id}", get(detail))
        .route("/head-to-heads/{id}/submit", post(submit))
        .route("/head-to-head-invites/{token}", get(preview))
        .route("/head-to-head-invites/{token}/accept", post(accept))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Create {
    command_id: Uuid,
    market_id: Option<i64>,
    player_id: i64,
    opponent_id: Option<Uuid>,
}
fn bad(s: &str) -> ApiError {
    ApiError::BadRequest(s.into())
}
async fn create(State(state): State<AppState>, user: AuthUser, Json(b): Json<Create>) -> ApiResult<Json<Value>> {
    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))").bind(user.id.to_string()).execute(&mut *tx).await?;
    if let Some(old) = sqlx::query_as::<_, Match>(&format!("SELECT {COLS} FROM head_to_heads WHERE creator_id=$1 AND command_id=$2"))
        .bind(user.id)
        .bind(b.command_id)
        .fetch_optional(&mut *tx)
        .await?
    {
        if old.invited_user_id != b.opponent_id || b.market_id.is_some_and(|m| m != old.shared_market_id) {
            return Err(bad("This invitation command was already used for a different challenge."));
        }
        return Ok(Json(json!({"id":old.id,"url":format!("{}/duel/{}",state.config.public_base_url.trim_end_matches('/'),old.token)})));
    }
    if let Some(other) = b.opponent_id {
        if other == user.id
            || !crate::social::are_friends(&state.pool, user.id, other).await?
            || crate::social::blocked_either(&state.pool, user.id, other).await?
        {
            return Err(ApiError::Forbidden("Choose a friend to invite.".into()));
        }
    }
    let selected:Option<(i64,String,i64)>=sqlx::query_as("SELECT m.id,p.league,m.game_id FROM markets m JOIN players p ON p.id=m.player_id WHERE p.id=$1 AND ($2::bigint IS NULL OR m.id=$2) AND m.status='open' AND NOT EXISTS(SELECT 1 FROM market_results known WHERE known.market_id=m.id AND known.final) AND m.lock_at>now()+interval '5 minutes' AND (NOT EXISTS(SELECT 1 FROM presentation_cards pc WHERE pc.player_id=p.id) OR $3) ORDER BY m.lock_at,m.id LIMIT 1").bind(b.player_id).bind(b.market_id).bind(user.is_admin).fetch_optional(&mut *tx).await?;
    let (shared, league, game) = selected.ok_or_else(|| bad("This card has no open line to challenge right now."))?;
    // A challenge always includes the actual shared line, plus nine distinct open lines.
    let rows:Vec<(i64,i32,i32,DateTime<Utc>)>=sqlx::query_as("SELECT m.id,m.current_version,lv.line_x10,m.lock_at FROM markets m JOIN players p ON p.id=m.player_id JOIN line_versions lv ON lv.market_id=m.id AND lv.version=m.current_version WHERE p.league=$1 AND m.status='open' AND NOT EXISTS(SELECT 1 FROM market_results known WHERE known.market_id=m.id AND known.final) AND m.lock_at>now()+interval '5 minutes' AND (m.id=$2 OR NOT EXISTS(SELECT 1 FROM presentation_cards pc WHERE pc.player_id=p.id)) ORDER BY (m.id=$2) DESC,m.lock_at,m.id LIMIT 10 FOR SHARE OF m").bind(league).bind(shared).fetch_all(&mut *tx).await?;
    if rows.len() != 10 || rows[0].0 != shared {
        return Err(bad("Ten open cards are needed for a head-to-head. Try again when more lines are available."));
    }
    let lock = rows.iter().map(|r| r.3).min().unwrap();
    let token = random_token(24);
    let id:Uuid=sqlx::query_scalar("INSERT INTO head_to_heads(creator_id,opponent_id,token_hash,token,lock_at,tie_game_id,shared_market_id,command_id,invited_user_id) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$2) RETURNING id").bind(user.id).bind(b.opponent_id).bind(ss_db::sha256_hex(token.as_bytes())).bind(&token).bind(lock).bind(game).bind(shared).bind(b.command_id).fetch_one(&mut *tx).await?;
    for (i, r) in rows.iter().enumerate() {
        sqlx::query("INSERT INTO head_to_head_questions VALUES ($1,$2,$3,$4,$5)")
            .bind(id)
            .bind(i as i32 + 1)
            .bind(r.0)
            .bind(r.1)
            .bind(r.2)
            .execute(&mut *tx)
            .await?;
    }
    if let Some(other) = b.opponent_id {
        let (a, z) = if user.id < other { (user.id, other) } else { (other, user.id) };
        let thread: Uuid = sqlx::query_scalar(
            "INSERT INTO threads(kind,dm_a,dm_b) VALUES ('dm',$1,$2) ON CONFLICT(dm_a,dm_b) DO UPDATE SET kind='dm' RETURNING id",
        )
        .bind(a)
        .bind(z)
        .fetch_one(&mut *tx)
        .await?;
        let specs = ss_db::cards::card_specs(&state.pool, &[b.player_id]).await?;
        let item: Uuid = sqlx::query_scalar("INSERT INTO shared_items(owner_id,kind,payload) VALUES ($1,'head_to_head',$2) RETURNING id")
            .bind(user.id)
            .bind(json!({"challengeId":id,"token":token,"card":specs.get(&b.player_id),"title":"10-card head-to-head · no coins"}))
            .fetch_one(&mut *tx)
            .await?;
        let seq: i64 = sqlx::query_scalar("UPDATE threads SET last_seq=last_seq+1 WHERE id=$1 RETURNING last_seq")
            .bind(thread)
            .fetch_one(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO messages(thread_id,seq,sender_id,client_msg_id,body,share_id) VALUES ($1,$2,$3,$4,'I challenged you to a 10-card head-to-head.', $5)").bind(thread).bind(seq).bind(user.id).bind(b.command_id).bind(item).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO thread_reads(thread_id,user_id,last_read_seq) VALUES ($1,$2,$3) ON CONFLICT(thread_id,user_id) DO UPDATE SET last_read_seq=GREATEST(thread_reads.last_read_seq,EXCLUDED.last_read_seq)").bind(thread).bind(user.id).bind(seq).execute(&mut *tx).await?;
        sqlx::query("UPDATE head_to_heads SET thread_id=$2 WHERE id=$1").bind(id).bind(thread).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(Json(json!({"id":id,"url":format!("{}/duel/{token}",state.config.public_base_url.trim_end_matches('/'))})))
}
async fn load(state: &AppState, id: Uuid) -> ApiResult<Match> {
    sqlx::query_as(&format!("SELECT {COLS} FROM head_to_heads WHERE id=$1"))
        .bind(id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or(ApiError::NotFound)
}
async fn permitted(state: &AppState, user: Uuid, m: &Match) -> ApiResult<()> {
    if user != m.creator_id && Some(user) != m.opponent_id {
        return Err(ApiError::NotFound);
    }
    if let Some(other) = m.opponent_id {
        if crate::social::blocked_either(&state.pool, m.creator_id, other).await? {
            return Err(ApiError::NotFound);
        }
    }
    Ok(())
}
async fn list(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows: Vec<Uuid> =
        sqlx::query_scalar("SELECT id FROM head_to_heads WHERE creator_id=$1 OR opponent_id=$1 ORDER BY created_at DESC LIMIT 30")
            .bind(user.id)
            .fetch_all(&state.pool)
            .await?;
    let mut out = Vec::new();
    for id in rows {
        let m = load(&state, id).await?;
        if permitted(&state, user.id, &m).await.is_ok() {
            out.push(report(&state, &m, user.id, false).await?);
        }
    }
    Ok(Json(json!({"matches":out})))
}
async fn detail(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>) -> ApiResult<Json<Value>> {
    let m = load(&state, id).await?;
    permitted(&state, user.id, &m).await?;
    Ok(Json(report(&state, &m, user.id, true).await?))
}
async fn preview(State(state): State<AppState>, Path(token): Path<String>) -> ApiResult<Json<Value>> {
    let m: Match = sqlx::query_as(&format!("SELECT {COLS} FROM head_to_heads WHERE token_hash=$1"))
        .bind(ss_db::sha256_hex(token.as_bytes()))
        .fetch_optional(&state.pool)
        .await?
        .ok_or(ApiError::NotFound)?;
    let name: String =
        sqlx::query_scalar("SELECT display_name FROM profiles WHERE user_id=$1").bind(m.creator_id).fetch_one(&state.pool).await?;
    let pid: i64 = sqlx::query_scalar("SELECT player_id FROM markets WHERE id=$1").bind(m.shared_market_id).fetch_one(&state.pool).await?;
    let specs = ss_db::cards::card_specs(&state.pool, &[pid]).await?;
    Ok(Json(
        json!({"id":m.id,"creatorName":name,"card":specs.get(&pid),"lockAt":m.lock_at,"open":Utc::now()<m.lock_at,"questionCount":10,"noCoins":true}),
    ))
}
async fn accept(State(state): State<AppState>, user: AuthUser, Path(token): Path<String>) -> ApiResult<Json<Value>> {
    let mut tx = state.pool.begin().await?;
    let m: Match = sqlx::query_as(&format!("SELECT {COLS} FROM head_to_heads WHERE token_hash=$1 FOR UPDATE"))
        .bind(ss_db::sha256_hex(token.as_bytes()))
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(ApiError::NotFound)?;
    if m.creator_id == user.id {
        return Ok(Json(json!({"id":m.id})));
    }
    if crate::social::blocked_either(&state.pool, user.id, m.creator_id).await? {
        return Err(ApiError::NotFound);
    }
    if m.opponent_id.is_some_and(|id| id != user.id) {
        return Err(ApiError::Forbidden("This challenge is reserved for another player.".into()));
    }
    if m.accepted_at.is_some() {
        return Ok(Json(json!({"id":m.id})));
    }
    if Utc::now() >= m.lock_at {
        return Err(bad("This challenge has locked. Ask for a new invitation."));
    }
    let (a, b) = if user.id < m.creator_id { (user.id, m.creator_id) } else { (m.creator_id, user.id) };
    sqlx::query("INSERT INTO friendships(user_a,user_b) VALUES ($1,$2) ON CONFLICT DO NOTHING").bind(a).bind(b).execute(&mut *tx).await?;
    sqlx::query("UPDATE friend_requests SET status='accepted' WHERE status='pending' AND ((from_user=$1 AND to_user=$2) OR(from_user=$2 AND to_user=$1))").bind(a).bind(b).execute(&mut *tx).await?;
    sqlx::query("UPDATE head_to_heads SET opponent_id=$2,accepted_at=now() WHERE id=$1").bind(m.id).bind(user.id).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(json!({"id":m.id})))
}
#[derive(Deserialize)]
struct Submit {
    answers: Vec<String>,
    tiebreak: i32,
}
async fn submit(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, Json(b): Json<Submit>) -> ApiResult<Json<Value>> {
    if b.answers.len() != 10 || b.answers.iter().any(|s| !matches!(s.as_str(), "over" | "under")) || !(0..=2000).contains(&b.tiebreak) {
        return Err(bad("Choose all ten picks and a total-points tiebreaker between 0 and 2000."));
    }
    let mut tx = state.pool.begin().await?;
    let m: Match = sqlx::query_as(&format!("SELECT {COLS} FROM head_to_heads WHERE id=$1 FOR UPDATE"))
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(ApiError::NotFound)?;
    permitted(&state, user.id, &m).await?;
    if Utc::now() >= m.lock_at {
        return Err(bad("Picks are locked."));
    }
    sqlx::query("SELECT m.id FROM markets m JOIN head_to_head_questions q ON q.market_id=m.id WHERE q.challenge_id=$1 FOR SHARE OF m")
        .bind(id)
        .fetch_all(&mut *tx)
        .await?;
    let closed:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM head_to_head_questions q JOIN markets m ON m.id=q.market_id WHERE q.challenge_id=$1 AND (m.status<>'open' OR m.lock_at<=now() OR EXISTS(SELECT 1 FROM market_results r WHERE r.market_id=m.id AND r.final)))").bind(id).fetch_one(&mut *tx).await?;
    if closed {
        return Err(bad("One of the match cards has closed. Picks are locked."));
    }

    if Some(user.id) == m.opponent_id && m.accepted_at.is_none() {
        return Err(bad("Accept the challenge first."));
    }
    let old: Option<(Value, i32)> =
        sqlx::query_as("SELECT answers,tiebreak FROM head_to_head_entries WHERE challenge_id=$1 AND user_id=$2")
            .bind(id)
            .bind(user.id)
            .fetch_optional(&mut *tx)
            .await?;
    if let Some((answers, tie)) = old {
        if answers != json!(b.answers) || tie != b.tiebreak {
            return Err(bad("Your picks were already submitted and cannot be changed."));
        }
    } else {
        sqlx::query("INSERT INTO head_to_head_entries(challenge_id,user_id,answers,tiebreak) VALUES ($1,$2,$3,$4)")
            .bind(id)
            .bind(user.id)
            .bind(json!(b.answers))
            .bind(b.tiebreak)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(Json(json!({"submitted":true,"noCoins":true})))
}
async fn report(state: &AppState, m: &Match, user: Uuid, include_cards: bool) -> ApiResult<Value> {
    let qs:Vec<(i64,i32,Option<i32>,Option<String>,String)>=sqlx::query_as("SELECT q.market_id,q.line_x10,r.value_x10,r.source,m.status FROM head_to_head_questions q JOIN markets m ON m.id=q.market_id LEFT JOIN LATERAL(SELECT value_x10,source FROM market_results WHERE market_id=m.id AND final ORDER BY revision DESC LIMIT 1) r ON true WHERE q.challenge_id=$1 ORDER BY q.position").bind(m.id).fetch_all(&state.pool).await?;
    let tie:(Option<i32>,Option<i32>,String,String,String)=sqlx::query_as("SELECT g.home_score,g.away_score,g.status,h.abbr,a.abbr FROM games g JOIN teams h ON h.id=g.home_team_id JOIN teams a ON a.id=g.away_team_id WHERE g.id=$1").bind(m.tie_game_id).fetch_one(&state.pool).await?;
    let tie_actual = if tie.2 == "final" { tie.0.zip(tie.1).map(|(a, b)| a + b) } else { None };
    let tie_void = tie.2 == "canceled";
    let all_results = qs.len() == 10 && qs.iter().all(|q| q.2.is_some() || q.4 == "void");
    let rows: Vec<(Uuid, Value, i32)> = sqlx::query_as("SELECT user_id,answers,tiebreak FROM head_to_head_entries WHERE challenge_id=$1")
        .bind(m.id)
        .fetch_all(&state.pool)
        .await?;
    let locked = Utc::now() >= m.lock_at;
    let mut people = Vec::new();
    let mut scores = Vec::new();
    for id in [Some(m.creator_id), m.opponent_id].into_iter().flatten() {
        let name: String = sqlx::query_scalar("SELECT display_name FROM profiles WHERE user_id=$1").bind(id).fetch_one(&state.pool).await?;
        let entry = rows.iter().find(|r| r.0 == id);
        let points = entry
            .map(|e| {
                qs.iter()
                    .enumerate()
                    .filter(|(i, q)| {
                        let side = if e.1.get(*i).and_then(Value::as_str) == Some("over") { Side::Over } else { Side::Under };
                        q.4 != "void"
                            && q.3.as_deref() != Some("dnp")
                            && q.2.is_some_and(|v| ss_core::grading::grade_leg(side, q.1, v) == LegResult::Win)
                    })
                    .count() as i32
            })
            .unwrap_or(0);
        let error = entry.and_then(|e| if tie_void { Some(0) } else { tie_actual.map(|actual| (e.2 - actual).abs()) });
        scores.push((id, points, error.unwrap_or(i32::MAX), entry.is_some()));
        people.push(json!({"userId":id,"name":name,"isMe":id==user,"submitted":entry.is_some(),"points":if locked{Some(points)}else{None},"answers":if locked||id==user{entry.map(|e|&e.1)}else{None},"tiebreak":if locked||id==user{entry.map(|e|e.2)}else{None},"tiebreakError":if locked{error}else{None}}));
    }
    let finished = locked && all_results && (tie_actual.is_some() || tie_void) && m.accepted_at.is_some();
    let winner = if finished && scores.len() == 2 {
        let a = &scores[0];
        let b = &scores[1];
        let ka = (a.1, -a.2, a.3);
        let kb = (b.1, -b.2, b.3);
        if ka > kb {
            Some(a.0)
        } else if kb > ka {
            Some(b.0)
        } else {
            None
        }
    } else {
        None
    };
    let cards = if include_cards {
        let ids = qs.iter().map(|q| q.0).collect::<Vec<_>>();
        let mut cards = ss_db::cards::playable_cards(&state.pool, Some(user), &ids).await?;
        for (c, q) in cards.iter_mut().zip(&qs) {
            c["market"]["line"] = json!(ss_db::x10_to_f64(q.1));
        }
        cards
    } else {
        Vec::new()
    };
    Ok(
        json!({"id":m.id,"lockAt":m.lock_at,"accepted":m.accepted_at.is_some(),"isCreator":user==m.creator_id,"inviteUrl":format!("{}/duel/{}",state.config.public_base_url.trim_end_matches('/'),m.token),"status":if finished{"complete"}else if locked{"locked"}else if m.accepted_at.is_none(){"invited"}else{"open"},"people":people,"cards":cards,"winnerId":winner,"draw":finished&&winner.is_none(),"graded":qs.iter().filter(|q|q.2.is_some()||q.4=="void").count(),"tiebreakLabel":format!("Total points · {} at {}",tie.4,tie.3),"tiebreakActual":tie_actual,"tiebreakVoid":tie_void,"noCoins":true}),
    )
}
