//! Real ESPN fixture -> durable grading job -> wallet and mastery, isolated DB.
use sqlx::PgPool;
use ss_core::Side;
use ss_db::{
    catalog, grading, jobs,
    picks::{self, EntryKind, LegRequest},
};
use ss_espn::{BoxScore, League};
use uuid::Uuid;

async fn fixture(pool: &PgPool) -> (i64, i64, BoxScore, Vec<Uuid>) {
    let raw =
        serde_json::from_str(include_str!("../../espn/tests/fixtures/nfl_summary.json")).unwrap();
    let parsed = ss_espn::parse_box_score(&raw);
    let stat = parsed
        .stats
        .iter()
        .find(|s| s.key == "rushingYards" && s.value_x10 > 100)
        .unwrap()
        .clone();
    let home: i64 = sqlx::query_scalar("INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES('nfl','settle-home','HOM','Home','Home') RETURNING id").fetch_one(pool).await.unwrap();
    let away: i64 = sqlx::query_scalar("INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES('nfl','settle-away','AWY','Away','Away') RETURNING id").fetch_one(pool).await.unwrap();
    let game: i64 = sqlx::query_scalar("INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at) VALUES('nfl','settle-game',2026,$1,$2,now()+interval '1 day') RETURNING id").bind(home).bind(away).fetch_one(pool).await.unwrap();
    let player: i64 = sqlx::query_scalar("INSERT INTO players(league,espn_id,team_id,full_name,position) VALUES('nfl',$1,$2,'Fixture running back','RB') RETURNING id").bind(&stat.athlete_espn_id).bind(home).fetch_one(pool).await.unwrap();
    let market: i64 = sqlx::query_scalar("INSERT INTO markets(game_id,player_id,stat_key,lock_at) VALUES($1,$2,'rush_yds',now()+interval '1 day') RETURNING id").bind(game).bind(player).fetch_one(pool).await.unwrap();
    sqlx::query("INSERT INTO line_versions VALUES($1,1,$2,now())")
        .bind(market)
        .bind(stat.value_x10 - 5)
        .execute(pool)
        .await
        .unwrap();
    let mut users = Vec::new();
    for (i, side, stake) in [(0, Side::Over, 50), (1, Side::Under, 0)] {
        let user: Uuid = sqlx::query_scalar(
            "INSERT INTO users(email,password_hash) VALUES($1,'unused') RETURNING id",
        )
        .bind(format!("settle-{i}@example.invalid"))
        .fetch_one(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO coin_accounts(user_id,balance) VALUES($1,1000)")
            .bind(user)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO coin_ledger(user_id,delta,reason,source_key) VALUES($1,1000,'signup',$2)",
        )
        .bind(user)
        .bind(format!("signup:{user}"))
        .execute(pool)
        .await
        .unwrap();
        let pick = picks::accept_entry(
            pool,
            user,
            Uuid::new_v4(),
            EntryKind::Single,
            stake,
            vec![LegRequest {
                market_id: market,
                line_version: 1,
                side,
            }],
            None,
        )
        .await
        .unwrap();
        assert_eq!(pick.http_status, 201);
        users.push(user);
    }
    sqlx::query("UPDATE games SET status='final',home_score=21,away_score=17 WHERE id=$1")
        .bind(game)
        .execute(pool)
        .await
        .unwrap();
    (
        game,
        market,
        BoxScore {
            stats: vec![stat],
            did_not_play: vec![],
        },
        users,
    )
}
async fn drain(pool: &PgPool) {
    while let Some(job) = jobs::claim(pool, &["grade_market"]).await.unwrap() {
        grading::grade_market(pool, job.payload["marketId"].as_i64().unwrap())
            .await
            .unwrap();
        jobs::complete(pool, job.id).await.unwrap();
    }
}
async fn state(pool: &PgPool, user: Uuid) -> (i64, String, i64) {
    sqlx::query_as("SELECT c.balance,e.status,e.credited FROM coin_accounts c JOIN entries e ON e.user_id=c.user_id WHERE c.user_id=$1").bind(user).fetch_one(pool).await.unwrap()
}
#[sqlx::test(migrations = "./migrations")]
#[ignore = "requires isolated local PostgreSQL"]
async fn box_score_settles_once_and_corrections_adjust_only_the_difference(pool: PgPool) {
    let (game, market, mut score, users) = fixture(&pool).await;
    assert_eq!(
        catalog::record_box_score(&pool, game, League::Nfl, &score)
            .await
            .unwrap(),
        vec![market]
    );
    let queued: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM jobs WHERE kind='grade_market' AND done_at IS NULL",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(queued, 1);
    drain(&pool).await;
    let first = state(&pool, users[0]).await;
    assert_eq!(first.1, "won");
    assert!(first.0 > 1000);
    assert_eq!(state(&pool, users[1]).await, (1000, "lost".into(), 0));
    assert!(catalog::record_box_score(&pool, game, League::Nfl, &score)
        .await
        .unwrap()
        .is_empty());
    drain(&pool).await;
    assert_eq!(state(&pool, users[0]).await, first);
    score.stats[0].value_x10 -= 10;
    catalog::record_box_score(&pool, game, League::Nfl, &score)
        .await
        .unwrap();
    drain(&pool).await;
    assert_eq!(state(&pool, users[0]).await, (950, "lost".into(), 0));
    assert_eq!(state(&pool, users[1]).await, (1025, "won".into(), 25));
    // A DNP correction can be reversed by a later complete box score.
    let absent = BoxScore::default();
    catalog::record_box_score(&pool, game, League::Nfl, &absent)
        .await
        .unwrap();
    drain(&pool).await;
    assert_eq!(state(&pool, users[0]).await, (1000, "void".into(), 50));
    catalog::record_box_score(&pool, game, League::Nfl, &score)
        .await
        .unwrap();
    drain(&pool).await;
    assert_eq!(state(&pool, users[0]).await, (950, "lost".into(), 0));
    for user in users {
        let balanced: bool=sqlx::query_scalar("SELECT c.balance=(SELECT sum(delta) FROM coin_ledger WHERE user_id=$1) FROM coin_accounts c WHERE c.user_id=$1").bind(user).fetch_one(&pool).await.unwrap();
        assert!(balanced);
    }
}
#[sqlx::test(migrations = "./migrations")]
#[ignore = "requires isolated local PostgreSQL"]
async fn a_failed_grading_enqueue_rolls_back_stats_results_and_ingestion_timestamp(pool: PgPool) {
    let (game, _, score, _) = fixture(&pool).await;
    sqlx::raw_sql("CREATE FUNCTION reject_grading_job() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated queue outage'; END $$; CREATE TRIGGER reject_job BEFORE INSERT ON jobs FOR EACH ROW EXECUTE FUNCTION reject_grading_job();").execute(&pool).await.unwrap();
    assert!(catalog::record_box_score(&pool, game, League::Nfl, &score)
        .await
        .is_err());
    let row: (bool,i64,i64)=sqlx::query_as("SELECT stats_ingested_at IS NULL,(SELECT count(*) FROM player_game_stats WHERE game_id=$1),(SELECT count(*) FROM market_results r JOIN markets m ON m.id=r.market_id WHERE m.game_id=$1) FROM games WHERE id=$1").bind(game).fetch_one(&pool).await.unwrap();
    assert_eq!(row, (true, 0, 0));
    sqlx::query("DROP TRIGGER reject_job ON jobs")
        .execute(&pool)
        .await
        .unwrap();
    catalog::record_box_score(&pool, game, League::Nfl, &score)
        .await
        .unwrap();
    drain(&pool).await;
}
