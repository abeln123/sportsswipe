//! Friends, blocks, direct and league threads, and leagues. Access is
//! re-checked on every read and send.

use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::{
    extract::{Path, Query, State},
    routing::{get, post},
    Json, Router,
};
use rand::Rng;
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/users/search", get(search))
        .route("/friend-requests", get(list_requests).post(send_request))
        .route("/friend-requests/{id}/accept", post(accept_request))
        .route("/friend-requests/{id}/decline", post(decline_request))
        .route("/friends", get(friends))
        .route("/blocks", post(block))
        .route("/threads", get(threads))
        .route("/threads/dm", post(open_dm))
        .route("/threads/{id}/messages", get(messages).post(send_message))
        .route("/leagues", get(my_leagues).post(create_league))
        .route("/leagues/join", post(join_league))
        .route("/leagues/{id}", get(league_detail))
}

fn pair(a: Uuid, b: Uuid) -> (Uuid, Uuid) {
    if a < b { (a, b) } else { (b, a) }
}

pub async fn blocked_either(pool: &PgPool, a: Uuid, b: Uuid) -> ApiResult<bool> {
    Ok(sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM blocks WHERE (blocker = $1 AND blocked = $2) OR (blocker = $2 AND blocked = $1))",
    )
    .bind(a)
    .bind(b)
    .fetch_one(pool)
    .await?)
}

pub async fn are_friends(pool: &PgPool, a: Uuid, b: Uuid) -> ApiResult<bool> {
    let (x, y) = pair(a, b);
    Ok(sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM friendships WHERE user_a = $1 AND user_b = $2)")
        .bind(x)
        .bind(y)
        .fetch_one(pool)
        .await?)
}

async fn relation(pool: &PgPool, me: Uuid, other: Uuid) -> ApiResult<&'static str> {
    if me == other {
        return Ok("self");
    }
    if are_friends(pool, me, other).await? {
        return Ok("friend");
    }
    let pending: Option<Uuid> = sqlx::query_scalar(
        "SELECT from_user FROM friend_requests WHERE status = 'pending' AND ((from_user = $1 AND to_user = $2) OR (from_user = $2 AND to_user = $1))",
    )
    .bind(me)
    .bind(other)
    .fetch_optional(pool)
    .await?;
    Ok(match pending {
        Some(from) if from == me => "requested",
        Some(_) => "incoming",
        None => "none",
    })
}

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
}

async fn search(State(state): State<AppState>, user: AuthUser, Query(q): Query<SearchQuery>) -> ApiResult<Json<Value>> {
    let raw = q.q.trim();
    if raw.len() < 2 {
        return Ok(Json(json!({ "users": [] })));
    }
    let (handle, tag) = match raw.split_once('#') {
        Some((h, t)) => (h.trim().to_uppercase(), Some(t.trim().to_string())),
        None => (raw.to_uppercase(), None),
    };
    let rows: Vec<(Uuid, String, String, String)> = sqlx::query_as(
        r#"SELECT p.user_id, p.display_name, p.handle, p.tag FROM profiles p
           WHERE p.user_id <> $1
             AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker = $1 AND b.blocked = p.user_id) OR (b.blocker = p.user_id AND b.blocked = $1))
             AND (CASE WHEN $3::text IS NOT NULL THEN upper(p.handle) = $2 AND p.tag = $3
                       ELSE upper(p.handle) LIKE $2 || '%' OR upper(p.display_name) LIKE $2 || '%' END)
           ORDER BY p.display_name LIMIT 20"#,
    )
    .bind(user.id)
    .bind(&handle)
    .bind(tag)
    .fetch_all(&state.pool)
    .await?;
    let mut users = Vec::new();
    for (id, name, handle, tag) in rows {
        users.push(json!({
            "userId": id, "displayName": name, "handleTag": format!("{handle}#{tag}"),
            "relation": relation(&state.pool, user.id, id).await?,
        }));
    }
    Ok(Json(json!({ "users": users })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UserBody {
    user_id: Uuid,
}

async fn make_friends(pool: &PgPool, a: Uuid, b: Uuid) -> ApiResult<()> {
    let (x, y) = pair(a, b);
    sqlx::query("INSERT INTO friendships (user_a, user_b) VALUES ($1,$2) ON CONFLICT DO NOTHING")
        .bind(x)
        .bind(y)
        .execute(pool)
        .await?;
    sqlx::query(
        "UPDATE friend_requests SET status = 'accepted' WHERE status = 'pending' AND ((from_user = $1 AND to_user = $2) OR (from_user = $2 AND to_user = $1))",
    )
    .bind(a)
    .bind(b)
    .execute(pool)
    .await?;
    Ok(())
}

async fn send_request(State(state): State<AppState>, user: AuthUser, Json(b): Json<UserBody>) -> ApiResult<Json<Value>> {
    if b.user_id == user.id {
        return Err(ApiError::BadRequest("You can't add yourself.".into()));
    }
    if blocked_either(&state.pool, user.id, b.user_id).await? {
        return Err(ApiError::NotFound);
    }
    match relation(&state.pool, user.id, b.user_id).await? {
        "friend" => return Ok(Json(json!({ "relation": "friend" }))),
        "incoming" => {
            make_friends(&state.pool, user.id, b.user_id).await?;
            return Ok(Json(json!({ "relation": "friend" })));
        }
        _ => {}
    }
    sqlx::query(
        r#"INSERT INTO friend_requests (from_user, to_user) VALUES ($1, $2)
           ON CONFLICT (from_user, to_user) DO UPDATE SET status = 'pending', created_at = now()"#,
    )
    .bind(user.id)
    .bind(b.user_id)
    .execute(&state.pool)
    .await?;
    Ok(Json(json!({ "relation": "requested" })))
}

async fn list_requests(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows: Vec<(i64, Uuid, Uuid, String, String, String, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        r#"SELECT r.id, r.from_user, r.to_user, p.display_name, p.handle, p.tag, r.created_at
           FROM friend_requests r JOIN profiles p ON p.user_id = CASE WHEN r.from_user = $1 THEN r.to_user ELSE r.from_user END
           WHERE r.status = 'pending' AND (r.from_user = $1 OR r.to_user = $1) ORDER BY r.created_at DESC"#,
    )
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    let item = |(id, from, to, name, handle, tag, at): &(i64, Uuid, Uuid, String, String, String, chrono::DateTime<chrono::Utc>)| {
        json!({ "requestId": id, "userId": if *from == user.id { to } else { from }, "displayName": name,
                "handleTag": format!("{handle}#{tag}"), "createdAt": at })
    };
    Ok(Json(json!({
        "incoming": rows.iter().filter(|r| r.2 == user.id).map(item).collect::<Vec<_>>(),
        "outgoing": rows.iter().filter(|r| r.1 == user.id).map(item).collect::<Vec<_>>(),
    })))
}

async fn accept_request(State(state): State<AppState>, user: AuthUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    let from: Option<Uuid> =
        sqlx::query_scalar("SELECT from_user FROM friend_requests WHERE id = $1 AND to_user = $2 AND status = 'pending'")
            .bind(id)
            .bind(user.id)
            .fetch_optional(&state.pool)
            .await?;
    let from = from.ok_or(ApiError::NotFound)?;
    if blocked_either(&state.pool, user.id, from).await? {
        return Err(ApiError::NotFound);
    }
    make_friends(&state.pool, user.id, from).await?;
    Ok(Json(json!({ "relation": "friend" })))
}

async fn decline_request(State(state): State<AppState>, user: AuthUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    sqlx::query("UPDATE friend_requests SET status = 'declined' WHERE id = $1 AND to_user = $2 AND status = 'pending'")
        .bind(id)
        .bind(user.id)
        .execute(&state.pool)
        .await?;
    Ok(Json(json!({ "ok": true })))
}

async fn friends(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows: Vec<(Uuid, String, String, String)> = sqlx::query_as(
        r#"SELECT p.user_id, p.display_name, p.handle, p.tag FROM friendships f
           JOIN profiles p ON p.user_id = CASE WHEN f.user_a = $1 THEN f.user_b ELSE f.user_a END
           WHERE f.user_a = $1 OR f.user_b = $1 ORDER BY p.display_name"#,
    )
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(json!({ "friends": rows.iter().map(|(id, name, h, t)| json!({
        "userId": id, "displayName": name, "handleTag": format!("{h}#{t}"),
    })).collect::<Vec<_>>() })))
}

async fn block(State(state): State<AppState>, user: AuthUser, Json(b): Json<UserBody>) -> ApiResult<Json<Value>> {
    if b.user_id == user.id {
        return Err(ApiError::BadRequest("You can't block yourself.".into()));
    }
    let (x, y) = pair(user.id, b.user_id);
    let mut tx = state.pool.begin().await?;
    sqlx::query("INSERT INTO blocks (blocker, blocked) VALUES ($1,$2) ON CONFLICT DO NOTHING")
        .bind(user.id)
        .bind(b.user_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM friendships WHERE user_a = $1 AND user_b = $2").bind(x).bind(y).execute(&mut *tx).await?;
    sqlx::query("UPDATE friend_requests SET status = 'declined' WHERE status = 'pending' AND ((from_user = $1 AND to_user = $2) OR (from_user = $2 AND to_user = $1))")
        .bind(user.id)
        .bind(b.user_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(json!({ "blocked": true })))
}

/// Returns the thread if the user may read and post in it right now.
async fn thread_access(pool: &PgPool, user_id: Uuid, thread_id: Uuid) -> ApiResult<()> {
    let row: Option<(String, Option<Uuid>, Option<Uuid>)> = sqlx::query_as("SELECT kind, dm_a, dm_b FROM threads WHERE id = $1")
        .bind(thread_id)
        .fetch_optional(pool)
        .await?;
    let (kind, a, b) = row.ok_or(ApiError::NotFound)?;
    let ok = if kind == "dm" {
        let (a, b) = (a.unwrap_or_default(), b.unwrap_or_default());
        let other = if a == user_id { b } else if b == user_id { a } else { return Err(ApiError::NotFound) };
        are_friends(pool, user_id, other).await? && !blocked_either(pool, user_id, other).await?
    } else {
        sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM leagues l JOIN league_members m ON m.league_id = l.id WHERE l.thread_id = $1 AND m.user_id = $2)",
        )
        .bind(thread_id)
        .bind(user_id)
        .fetch_one(pool)
        .await?
    };
    if ok { Ok(()) } else { Err(ApiError::NotFound) }
}

async fn threads(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows: Vec<(Uuid, String, String, Option<Uuid>, i64, i64, Option<String>, Option<chrono::DateTime<chrono::Utc>>, Option<Uuid>)> = sqlx::query_as(
        r#"WITH mine AS (
             SELECT t.id, t.kind, p.display_name AS title, p.user_id AS other_id, t.last_seq FROM threads t
             JOIN profiles p ON p.user_id = CASE WHEN t.dm_a = $1 THEN t.dm_b ELSE t.dm_a END
             JOIN friendships f ON f.user_a = LEAST(t.dm_a, t.dm_b) AND f.user_b = GREATEST(t.dm_a, t.dm_b)
             WHERE t.kind = 'dm' AND (t.dm_a = $1 OR t.dm_b = $1)
             UNION ALL
             SELECT t.id, t.kind, l.name, NULL, t.last_seq FROM threads t
             JOIN leagues l ON l.thread_id = t.id JOIN league_members m ON m.league_id = l.id AND m.user_id = $1
           )
           SELECT mine.id, mine.kind, mine.title, mine.other_id, mine.last_seq,
                  COALESCE(r.last_read_seq, 0), msg.body, msg.created_at, msg.share_id
           FROM mine LEFT JOIN thread_reads r ON r.thread_id = mine.id AND r.user_id = $1
           LEFT JOIN messages msg ON msg.thread_id = mine.id AND msg.seq = mine.last_seq
           ORDER BY msg.created_at DESC NULLS LAST"#,
    )
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    let mut out = Vec::new();
    for (id,kind,title,other,last,read,body,at,share) in rows {
        if let Some(other) = other { if blocked_either(&state.pool,user.id,other).await? { continue; } }
        let shared = match share { Some(s) => Some(crate::shares::visible(&state,user.id,s).await?), None => None };
        let preview = body.filter(|b|!b.is_empty()).or_else(||shared.as_ref().map(|_|"Shared an item".to_string()));
        out.push(json!({"threadId":id,"kind":kind,"title":title,"otherUserId":other,
            "unread":(last-read).max(0),"lastMessage":preview,"lastAt":at,"shared":shared}));
    }
    Ok(Json(json!({"threads":out})))
}

async fn open_dm(State(state): State<AppState>, user: AuthUser, Json(b): Json<UserBody>) -> ApiResult<Json<Value>> {
    if !are_friends(&state.pool, user.id, b.user_id).await? || blocked_either(&state.pool, user.id, b.user_id).await? {
        return Err(ApiError::Forbidden("Messages are open between friends.".into()));
    }
    let (x, y) = pair(user.id, b.user_id);
    let id: Uuid = sqlx::query_scalar(
        r#"INSERT INTO threads (kind, dm_a, dm_b) VALUES ('dm', $1, $2)
           ON CONFLICT (dm_a, dm_b) DO UPDATE SET kind = 'dm' RETURNING id"#,
    )
    .bind(x)
    .bind(y)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(json!({ "threadId": id })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessagesQuery {
    after_seq: Option<i64>,
}

async fn messages(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, Query(q): Query<MessagesQuery>) -> ApiResult<Json<Value>> {
    thread_access(&state.pool, user.id, id).await?;
    let read: i64 = sqlx::query_scalar("SELECT COALESCE((SELECT last_read_seq FROM thread_reads WHERE thread_id=$1 AND user_id=$2),0)")
        .bind(id).bind(user.id).fetch_one(&state.pool).await?;
    let after = q.after_seq.unwrap_or(read.saturating_sub(20));
    let rows: Vec<(i64, Uuid, String, String, chrono::DateTime<chrono::Utc>, Uuid, Option<Uuid>)> = sqlx::query_as(
        r#"SELECT m.seq, m.sender_id, p.display_name, m.body, m.created_at, m.client_msg_id, m.share_id FROM messages m
           JOIN profiles p ON p.user_id = m.sender_id
           WHERE m.thread_id = $1 AND m.seq > $2
             AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.blocker = $3 AND b.blocked = m.sender_id)
           ORDER BY m.seq LIMIT 200"#,
    )
    .bind(id)
    .bind(after)
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    if let Some(last) = rows.last() {
        sqlx::query(
            r#"INSERT INTO thread_reads (thread_id, user_id, last_read_seq) VALUES ($1,$2,$3)
               ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_seq = GREATEST(thread_reads.last_read_seq, EXCLUDED.last_read_seq)"#,
        )
        .bind(id)
        .bind(user.id)
        .bind(last.0)
        .execute(&state.pool)
        .await?;
    }
    let mut out = Vec::new();
    for (seq,sender,name,body,at,cid,share) in rows {
        let shared = match share { Some(s) => Some(crate::shares::visible(&state,user.id,s).await?), None => None };
        out.push(json!({"seq":seq,"senderId":sender,"senderName":name,"body":body,"createdAt":at,
            "clientMsgId":cid,"mine":sender==user.id,"shared":shared}));
    }
    Ok(Json(json!({"messages":out,"firstUnreadSeq":read+1})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendBody {
    client_msg_id: Uuid,
    body: String,
    share_id: Option<Uuid>,
}

async fn send_message(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, Json(b): Json<SendBody>) -> ApiResult<Json<Value>> {
    let body = b.body.trim();
    if (body.is_empty() && b.share_id.is_none()) || body.chars().count() > 2000 {
        return Err(ApiError::BadRequest("Messages are 1 to 2000 characters.".into()));
    }
    thread_access(&state.pool, user.id, id).await?;
    if let Some(share) = b.share_id {
        let owned: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM shared_items WHERE id=$1 AND owner_id=$2)")
            .bind(share).bind(user.id).fetch_one(&state.pool).await?;
        if !owned { return Err(ApiError::NotFound); }
    }
    let mut tx = state.pool.begin().await?;
    // Serialize duplicate checks as well as sequence allocation.
    sqlx::query("SELECT id FROM threads WHERE id=$1 FOR UPDATE").bind(id).execute(&mut *tx).await?;
    let existing: Option<i64> = sqlx::query_scalar("SELECT seq FROM messages WHERE sender_id = $1 AND client_msg_id = $2 AND thread_id=$3")
        .bind(user.id)
        .bind(b.client_msg_id)
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
    if let Some(seq) = existing {
        return Ok(Json(json!({ "seq": seq, "duplicate": true })));
    }
    let seq: i64 = sqlx::query_scalar("UPDATE threads SET last_seq = last_seq + 1 WHERE id = $1 RETURNING last_seq")
        .bind(id)
        .fetch_one(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO messages (thread_id, seq, sender_id, client_msg_id, body, share_id) VALUES ($1,$2,$3,$4,$5,$6)")
        .bind(id)
        .bind(seq)
        .bind(user.id)
        .bind(b.client_msg_id)
        .bind(body)
        .bind(b.share_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        r#"INSERT INTO thread_reads (thread_id, user_id, last_read_seq) VALUES ($1,$2,$3)
           ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_seq = EXCLUDED.last_read_seq"#,
    )
    .bind(id)
    .bind(user.id)
    .bind(seq)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "seq": seq, "duplicate": false })))
}

fn join_code() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::thread_rng();
    (0..6).map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char).collect()
}

#[derive(Deserialize)]
struct CreateLeague {
    name: String,
}

async fn create_league(State(state): State<AppState>, user: AuthUser, Json(b): Json<CreateLeague>) -> ApiResult<Json<Value>> {
    let name = b.name.trim();
    if name.is_empty() || name.chars().count() > 40 {
        return Err(ApiError::BadRequest("League names are 1 to 40 characters.".into()));
    }
    let mut tx = state.pool.begin().await?;
    let thread_id: Uuid = sqlx::query_scalar("INSERT INTO threads (kind) VALUES ('league') RETURNING id")
        .fetch_one(&mut *tx)
        .await?;
    let mut league_id = None;
    for _ in 0..10 {
        league_id = sqlx::query_scalar(
            "INSERT INTO leagues (name, owner_id, join_code, thread_id) VALUES ($1,$2,$3,$4) ON CONFLICT (join_code) DO NOTHING RETURNING id",
        )
        .bind(name)
        .bind(user.id)
        .bind(join_code())
        .bind(thread_id)
        .fetch_optional(&mut *tx)
        .await?;
        if league_id.is_some() {
            break;
        }
    }
    let league_id: Uuid = league_id.ok_or_else(|| ApiError::Internal(anyhow::anyhow!("no free join code")))?;
    sqlx::query("INSERT INTO league_members (league_id, user_id, role) VALUES ($1,$2,'owner')")
        .bind(league_id)
        .bind(user.id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    league_json(&state, user.id, league_id).await.map(Json)
}

/// Adds a member after capacity and block checks. Shared with invites.
pub async fn add_member(pool: &PgPool, league_id: Uuid, user_id: Uuid) -> ApiResult<()> {
    let mut tx = pool.begin().await?;
    let (capacity, owner): (i32, Uuid) = sqlx::query_as("SELECT capacity, owner_id FROM leagues WHERE id = $1 FOR UPDATE")
        .bind(league_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(ApiError::NotFound)?;
    let already: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM league_members WHERE league_id = $1 AND user_id = $2)")
        .bind(league_id)
        .bind(user_id)
        .fetch_one(&mut *tx)
        .await?;
    if already {
        return Ok(());
    }
    if blocked_either(pool, owner, user_id).await? {
        return Err(ApiError::NotFound);
    }
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM league_members WHERE league_id = $1")
        .bind(league_id)
        .fetch_one(&mut *tx)
        .await?;
    if count >= capacity as i64 {
        return Err(ApiError::Conflict("league_full", "This league is full.".into()));
    }
    sqlx::query("INSERT INTO league_members (league_id, user_id) VALUES ($1,$2)")
        .bind(league_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

#[derive(Deserialize)]
struct JoinBody {
    code: String,
}

async fn join_league(State(state): State<AppState>, user: AuthUser, Json(b): Json<JoinBody>) -> ApiResult<Json<Value>> {
    let id: Option<Uuid> = sqlx::query_scalar("SELECT id FROM leagues WHERE join_code = $1")
        .bind(b.code.trim().to_uppercase())
        .fetch_optional(&state.pool)
        .await?;
    let id = id.ok_or_else(|| ApiError::BadRequest("No league matches that code.".into()))?;
    add_member(&state.pool, id, user.id).await?;
    league_json(&state, user.id, id).await.map(Json)
}

async fn my_leagues(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows: Vec<(Uuid, String, String, i64, Uuid)> = sqlx::query_as(
        r#"SELECT l.id, l.name, m.role, (SELECT count(*) FROM league_members x WHERE x.league_id = l.id), l.thread_id
           FROM leagues l JOIN league_members m ON m.league_id = l.id AND m.user_id = $1 ORDER BY l.created_at"#,
    )
    .bind(user.id)
    .fetch_all(&state.pool)
    .await?;
    let mut out = Vec::new();
    for (id,name,role,n,thread) in rows {
        let detail = league_json(&state,user.id,id).await?;
        let mine = detail["members"].as_array().and_then(|m|m.iter().find(|m|m["isMe"]==true));
        out.push(json!({"leagueId":id,"name":name,"role":role,"memberCount":n,"threadId":thread,
            "rank":mine.map(|m|&m["rank"]),"weeklyPoints":mine.map(|m|&m["weeklyPoints"])}));
    }
    Ok(Json(json!({"leagues":out})))
}

async fn league_json(state: &AppState, user_id: Uuid, league_id: Uuid) -> ApiResult<Value> {
    let row: Option<(String, String, Uuid, Uuid, i32)> = sqlx::query_as(
        r#"SELECT l.name, l.join_code, l.thread_id, l.owner_id, l.capacity FROM leagues l
           JOIN league_members m ON m.league_id = l.id AND m.user_id = $2 WHERE l.id = $1"#,
    )
    .bind(league_id)
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await?;
    let (name, code, thread_id, owner, capacity) = row.ok_or(ApiError::NotFound)?;
    // League standings reuse this week's contest points.
    let members: Vec<(Uuid, String, String, String, String, i32, i32)> = sqlx::query_as(
        r#"SELECT m.user_id, p.display_name, p.handle, p.tag, m.role,
                  COALESCE(s.points, 0), COALESCE(s.days_counted, 0)
           FROM league_members m JOIN profiles p ON p.user_id = m.user_id
           LEFT JOIN contests c ON c.week_start = $2
           LEFT JOIN standings s ON s.contest_id = c.id AND s.user_id = m.user_id
           WHERE m.league_id = $1 ORDER BY COALESCE(s.points, 0) DESC, p.display_name"#,
    )
    .bind(league_id)
    .bind(ss_db::contests::week_start(ss_db::contests::today_local()))
    .fetch_all(&state.pool)
    .await?;
    Ok(json!({
        "leagueId": league_id, "name": name, "joinCode": code, "threadId": thread_id,
        "isOwner": owner == user_id, "capacity": capacity,
        "members": members.iter().enumerate().map(|(i, (id, n, h, t, role, pts, days))| json!({
            "rank": i + 1, "userId": id, "displayName": n, "handleTag": format!("{h}#{t}"), "role": role,
            "weeklyPoints": pts, "daysCounted": days, "isMe": *id == user_id,
        })).collect::<Vec<_>>(),
    }))
}

async fn league_detail(State(state): State<AppState>, user: AuthUser, Path(id): Path<Uuid>) -> ApiResult<Json<Value>> {
    league_json(&state, user.id, id).await.map(Json)
}
