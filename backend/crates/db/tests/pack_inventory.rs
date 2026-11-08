use sqlx::PgPool;
use ss_db::packs;
use uuid::Uuid;

async fn fixture(pool: &PgPool) -> (Uuid, i64) {
    let user: Uuid = sqlx::query_scalar(
        "INSERT INTO users(email,password_hash) VALUES ('packs@test','unused') RETURNING id",
    )
    .fetch_one(pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO coin_accounts(user_id,balance) VALUES ($1,1000)")
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    let own: i64 = sqlx::query_scalar("INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES ('nfl','test-own','OWN','Own Team','Own') RETURNING id").fetch_one(pool).await.unwrap();
    let other: i64 = sqlx::query_scalar("INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES ('nfl','test-other','OPP','Opponent','Opponent') RETURNING id").fetch_one(pool).await.unwrap();
    // Selected team is away: its game lines must still be available.
    let game: i64 = sqlx::query_scalar("INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at) VALUES ('nfl','test-game',2026,$1,$2,now()+interval '1 day') RETURNING id").bind(other).bind(own).fetch_one(pool).await.unwrap();
    for i in 0..21 {
        let team = if i < 15 { own } else { other };
        let pos = if i >= 18 {
            "TEAM"
        } else if i < 5 || i >= 15 {
            "QB"
        } else if i < 10 {
            "RB"
        } else {
            "WR"
        };
        let stat = if i >= 18 {
            ["moneyline", "spread", "total"][i - 18]
        } else {
            "pass_yds"
        };
        let player: i64 = sqlx::query_scalar("INSERT INTO players(league,espn_id,team_id,full_name,position) VALUES ('nfl',$1,$2,$1,$3) RETURNING id").bind(format!("test-{i}")).bind(team).bind(pos).fetch_one(pool).await.unwrap();
        let market: i64 = sqlx::query_scalar("INSERT INTO markets(game_id,player_id,stat_key,lock_at) VALUES ($1,$2,$3,now()+interval '1 day') RETURNING id").bind(game).bind(player).bind(stat).fetch_one(pool).await.unwrap();
        sqlx::query("INSERT INTO line_versions(market_id,version,line_x10) VALUES ($1,1,100)")
            .bind(market)
            .execute(pool)
            .await
            .unwrap();
    }
    (user, own)
}

#[sqlx::test(migrations = "./migrations")]
#[ignore = "requires local PostgreSQL; run with DATABASE_URL and --ignored"]
async fn team_membership_full_packs_and_idempotent_retry(pool: PgPool) {
    let (user, team) = fixture(&pool).await;
    let all = packs::pack_types(&pool).await.unwrap();
    let pack = all.iter().find(|p| p.team_id == Some(team)).unwrap();
    assert_eq!(pack.price, 50);
    assert_eq!(packs::available(&pool, user, pack, None).await.unwrap(), 18);
    assert!(pack.league_for(Some("nba")).is_err());
    let command = Uuid::new_v4();
    let first = packs::buy(&pool, user, command, &pack.key, None)
        .await
        .unwrap();
    assert_eq!(first.http_status, 201);
    assert_eq!(first.body["cards"].as_array().unwrap().len(), 5);
    let retry = packs::buy(&pool, user, command, &pack.key, None)
        .await
        .unwrap();
    assert_eq!(first.body["cards"], retry.body["cards"]);
    assert_eq!(retry.body["balance"], 950);
    let starter = all.iter().find(|p| p.key == "starter").unwrap();
    assert_eq!(
        packs::available(&pool, user, starter, None).await.unwrap(),
        16
    );
    // Dealing history excludes cards even if the entry link changes later.
    for _ in 0..3 {
        assert_eq!(
            packs::buy(&pool, user, Uuid::new_v4(), "starter", None)
                .await
                .unwrap()
                .http_status,
            201
        );
    }
    let rejected = packs::buy(&pool, user, Uuid::new_v4(), "starter", None)
        .await
        .unwrap();
    assert_eq!(rejected.http_status, 409);
    let (total, unique): (i64, i64) =
        sqlx::query_as("SELECT count(*),count(DISTINCT market_id) FROM pack_cards")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!((total, unique), (20, 20));
    let balance: i64 = sqlx::query_scalar("SELECT balance FROM coin_accounts WHERE user_id=$1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(balance, 920);
}

#[sqlx::test(migrations = "./migrations")]
#[ignore = "requires local PostgreSQL; run with DATABASE_URL and --ignored"]
async fn concurrent_packs_never_share_cards(pool: PgPool) {
    let (user, team) = fixture(&pool).await;
    let key = format!("team-{team}");
    let (a, b) = tokio::join!(
        packs::buy(&pool, user, Uuid::new_v4(), "starter", None),
        packs::buy(&pool, user, Uuid::new_v4(), &key, None)
    );
    assert_eq!(a.unwrap().http_status, 201);
    assert_eq!(b.unwrap().http_status, 201);
    let (total, unique): (i64, i64) =
        sqlx::query_as("SELECT count(*),count(DISTINCT market_id) FROM pack_cards")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!((total, unique), (10, 10));
}

#[sqlx::test(migrations = "./migrations")]
#[ignore = "requires local PostgreSQL; run with DATABASE_URL and --ignored"]
async fn early_kickoff_locks_only_its_game_later_picks_and_packs_stay_open(pool: PgPool) {
    use ss_db::{picks::{self, EntryKind, LegRequest}, slate};
    use ss_core::Side;
    let (user, _) = fixture(&pool).await;
    let early: i64 = sqlx::query_scalar("SELECT id FROM games WHERE espn_id='test-game'").fetch_one(&pool).await.unwrap();
    let later: i64 = sqlx::query_scalar("INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at) SELECT league,'later-game',season,home_team_id,away_team_id,now()+interval '3 hours' FROM games WHERE id=$1 RETURNING id").bind(early).fetch_one(&pool).await.unwrap();
    sqlx::query("UPDATE markets SET game_id=$2,lock_at=now()+interval '3 hours' WHERE id IN(SELECT id FROM markets WHERE game_id=$1 ORDER BY id OFFSET 5)").bind(early).bind(later).execute(&pool).await.unwrap();
    sqlx::query("UPDATE games SET start_at=now()-interval '1 minute',status='in' WHERE id=$1").bind(early).execute(&pool).await.unwrap();
    sqlx::query("UPDATE markets SET lock_at=now()-interval '1 minute' WHERE game_id=$1").bind(early).execute(&pool).await.unwrap();
    assert_eq!(slate::lock_due_markets(&pool).await.unwrap(),5);
    let early_market: i64 = sqlx::query_scalar("SELECT min(id) FROM markets WHERE game_id=$1").bind(early).fetch_one(&pool).await.unwrap();
    let late_markets: Vec<i64> = sqlx::query_scalar("SELECT id FROM markets WHERE game_id=$1 ORDER BY id").bind(later).fetch_all(&pool).await.unwrap();
    let leg=|market_id|LegRequest{market_id,line_version:1,side:Side::Over};
    let blocked=picks::accept_entry(&pool,user,Uuid::new_v4(),EntryKind::Single,25,vec![leg(early_market)],None).await.unwrap();
    assert_eq!(blocked.http_status,409);
    assert_eq!(blocked.body["code"],"pick_closed");
    let starter=packs::pack_types(&pool).await.unwrap().into_iter().find(|p|p.key=="starter").unwrap();
    assert_eq!(packs::available(&pool,user,&starter,None).await.unwrap(),16);
    let accepted=picks::accept_entry(&pool,user,Uuid::new_v4(),EntryKind::Single,0,vec![leg(late_markets[0])],None).await.unwrap();
    assert_eq!(accepted.http_status,201);
    let parlay=picks::accept_entry(&pool,user,Uuid::new_v4(),EntryKind::Parlay,0,vec![leg(late_markets[1]),leg(late_markets[2])],None).await.unwrap();
    assert_eq!(parlay.http_status,201);
    let pack=packs::buy(&pool,user,Uuid::new_v4(),"starter",None).await.unwrap();
    assert_eq!(pack.http_status,201);
    let dealt: Vec<i64>=sqlx::query_scalar("SELECT DISTINCT m.game_id FROM pack_cards pc JOIN markets m ON m.id=pc.market_id").fetch_all(&pool).await.unwrap();
    assert_eq!(dealt,vec![later]);
    let early_locked: i64=sqlx::query_scalar("SELECT count(*) FROM markets WHERE game_id=$1 AND status='locked'").bind(early).fetch_one(&pool).await.unwrap();
    let later_open: i64=sqlx::query_scalar("SELECT count(*) FROM markets WHERE game_id=$1 AND status='open'").bind(later).fetch_one(&pool).await.unwrap();
    assert_eq!((early_locked,later_open),(5,16));
}
