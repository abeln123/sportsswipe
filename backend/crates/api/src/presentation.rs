//! Repeatable, explicitly synthetic judging pack. Every entry point requires admin.
use crate::{auth::AdminUser, error::ApiResult, state::AppState};
use axum::{extract::State, routing::post, Json, Router};
use serde_json::{json, Value};
pub fn routes() -> Router<AppState> {
    Router::new().route("/admin/presentation-pack", post(open))
}
async fn open(State(state): State<AppState>, AdminUser(admin): AdminUser) -> ApiResult<Json<Value>> {
    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(761245001)").execute(&mut *tx).await?;
    let team:i64=sqlx::query_scalar("INSERT INTO teams(league,espn_id,abbr,name,short_name,color_primary,color_alt) VALUES ('nfl','ss-presentation','SSP','Sports Swipe Presentation','Presentation','784CC6','DDEAFF') ON CONFLICT(league,espn_id) DO UPDATE SET name=EXCLUDED.name RETURNING id").fetch_one(&mut *tx).await?;
    let away:i64=sqlx::query_scalar("INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES ('nfl','ss-presentation-opponent','LAB','Judges Lab','Lab') ON CONFLICT(league,espn_id) DO UPDATE SET name=EXCLUDED.name RETURNING id").fetch_one(&mut *tx).await?;
    let mut ids = Vec::new();
    for (i, (first, last, pos, stat)) in [
        ("Riley", "Swift", "RB", "rush_yds"),
        ("Alex", "North", "QB", "pass_yds"),
        ("Cameron", "Reed", "WR", "rec_yds"),
        ("Morgan", "Stone", "TE", "rec"),
        ("Taylor", "Blaze", "RB", "rush_yds"),
    ]
    .iter()
    .enumerate()
    {
        let pid:i64=sqlx::query_scalar("INSERT INTO players(league,espn_id,team_id,full_name,first_name,last_name,jersey,position,collectible_demo) VALUES ('nfl',$1,$2,$3,$4,$5,$6,$7,true) ON CONFLICT(league,espn_id) DO UPDATE SET collectible_demo=true RETURNING id")
   .bind(format!("ss-presentation-{}",i+1)).bind(team).bind(format!("{first} {last} · DEMO")).bind(first).bind(last).bind(format!("{}",i+7)).bind(pos).fetch_one(&mut *tx).await?;
        sqlx::query("INSERT INTO presentation_cards VALUES ($1,$2) ON CONFLICT(position) DO NOTHING")
            .bind(i as i32 + 1)
            .bind(pid)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO card_series(player_id) VALUES ($1) ON CONFLICT DO NOTHING").bind(pid).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO mastery_totals(user_id,player_id,correct_count) VALUES ($1,$2,$3) ON CONFLICT(user_id,player_id) DO UPDATE SET correct_count=GREATEST(mastery_totals.correct_count,EXCLUDED.correct_count)").bind(admin.id).bind(pid).bind(if i==0{400i64}else{1i64}).execute(&mut *tx).await?;
        if i == 0 {
            sqlx::query("INSERT INTO presentation_entitlements(user_id,player_id,season) VALUES ($1,$2,EXTRACT(YEAR FROM now())) ON CONFLICT DO NOTHING").bind(admin.id).bind(pid).execute(&mut *tx).await?;
            let purchase:uuid::Uuid=sqlx::query_scalar("INSERT INTO cosmetic_purchases(user_id,command_id,finish,price,player_id) SELECT $1,gen_random_uuid(),'diamond',0,$2 WHERE NOT EXISTS(SELECT 1 FROM equipped_finishes WHERE user_id=$1 AND player_id=$2) RETURNING id").bind(admin.id).bind(pid).fetch_optional(&mut *tx).await?.unwrap_or(uuid::Uuid::nil());
            if !purchase.is_nil() {
                sqlx::query("INSERT INTO equipped_finishes VALUES ($1,$2,'diamond',$3) ON CONFLICT DO NOTHING")
                    .bind(admin.id)
                    .bind(pid)
                    .bind(purchase)
                    .execute(&mut *tx)
                    .await?;
            }
        }
        let game:i64=sqlx::query_scalar("INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at) VALUES ('nfl',$1,EXTRACT(YEAR FROM now()),$2,$3,now()+interval '7 days') ON CONFLICT(league,espn_id) DO UPDATE SET start_at=CASE WHEN games.start_at<now() THEN now()+interval '7 days' ELSE games.start_at END RETURNING id").bind(format!("ss-presentation-{}",i+1)).bind(team).bind(away).fetch_one(&mut *tx).await?;
        let market:i64=sqlx::query_scalar("INSERT INTO markets(game_id,player_id,stat_key,lock_at) VALUES ($1,$2,$3,now()+interval '7 days') ON CONFLICT(game_id,player_id,stat_key) DO UPDATE SET lock_at=CASE WHEN markets.lock_at<now() THEN now()+interval '7 days' ELSE markets.lock_at END RETURNING id").bind(game).bind(pid).bind(stat).fetch_one(&mut *tx).await?;
        sqlx::query("INSERT INTO line_versions(market_id,version,line_x10) VALUES ($1,1,$2) ON CONFLICT DO NOTHING")
            .bind(market)
            .bind([865, 2455, 725, 45, 625][i])
            .execute(&mut *tx)
            .await?;
        ids.push(market);
    }
    tx.commit().await?;
    let cards = ss_db::cards::playable_cards(&state.pool, Some(admin.id), &ids).await?;
    Ok(Json(json!({"cards":cards,"name":"Presentation Pack","presentation":true})))
}
