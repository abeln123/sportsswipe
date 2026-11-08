// Synthetic history is explicit, local-only and restricted to new demo accounts.
import pg from 'pg';
import { randomUUID } from 'node:crypto';
const url=new URL(process.env.DATABASE_URL||'');
if(!['localhost','127.0.0.1'].includes(url.hostname))throw new Error('Demo seeding is allowed only on an isolated localhost database.');
const base=process.env.DEMO_API_URL||'http://localhost:8080';
if(!['localhost','127.0.0.1'].includes(new URL(base).hostname))throw new Error('Use a local demo API.');
async function api(path,body,token){const r=await fetch(`${base}/v1${path}`,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});const j=await r.json();if(!r.ok)throw new Error(j.message||JSON.stringify(j));return j;}
const pool=new pg.Pool({connectionString:process.env.DATABASE_URL});
const password=process.env.DEMO_PASSWORD||'SportsSwipe-devnet-demo-2026';
const stamp=randomUUID().slice(0,8);
const earner=await api('/auth/signup',{email:`maya-demo-${stamp}@example.invalid`,password,displayName:'Maya · DEMO'});
const buyer=await api('/auth/signup',{email:`jordan-demo-${stamp}@example.invalid`,password,displayName:'Jordan · DEMO'});
const db=await pool.connect();
try{
 await db.query('BEGIN');
 const team=(await db.query("INSERT INTO teams(league,espn_id,abbr,name,short_name,color_primary) VALUES ('nfl',$1,'SWP','Swipe City Demo','Swipe City','784CC6') RETURNING id",[`diamond-demo-${stamp}`])).rows[0].id;
 const opponent=(await db.query("INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES ('nfl',$1,'LAB','Lab City Demo','Lab City') RETURNING id",[`diamond-lab-${stamp}`])).rows[0].id;
 const player=(await db.query("INSERT INTO players(league,espn_id,team_id,full_name,first_name,last_name,jersey,position,collectible_demo) VALUES ('nfl',$1,$2,'Riley Swift · FICTIONAL','Riley','Swift','7','RB',true) RETURNING id",[`riley-demo-${stamp}`,team])).rows[0].id;
 // 399 explicitly fabricated completed free singles. All remain auditable in the local DB.
 for(let i=1;i<=400;i++){
  const game=(await db.query("INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at,status) VALUES ('nfl',$1,2026,$2,$3,now()+interval '1 day',$4) RETURNING id",[`${stamp}-${i}`,team,opponent,i===400?'scheduled':'final'])).rows[0].id;
  const market=(await db.query("INSERT INTO markets(game_id,player_id,stat_key,lock_at,status) VALUES ($1,$2,'rush_yds',now()+interval '1 day',$3) RETURNING id",[game,player,i===400?'open':'settled'])).rows[0].id;
  await db.query('INSERT INTO line_versions(market_id,version,line_x10) VALUES ($1,1,500)',[market]);
  if(i===400){
   await db.query('COMMIT');
   const pick=await api('/picks',{commandId:randomUUID(),marketId:Number(market),lineVersion:1,side:'over',stake:0},earner.sessionToken);
   console.log(JSON.stringify({earnerEmail:`maya-demo-${stamp}@example.invalid`,buyerEmail:`jordan-demo-${stamp}@example.invalid`,password,playerId:player,finalMarketId:market,entryId:pick.entryId},null,2));
   console.log('Seeded DEMO at 399. To earn the final call through normal settlement, run with the printed finalMarketId and this local earner account:');
   console.log('Use scripts/settle_diamond_demo.py. Both users connect their own devnet wallets in separate browser profiles.');
  }else{
   const entry=(await db.query("INSERT INTO entries(user_id,kind,command_id,stake,rule_version,potential_return,status,credited,single_market_id) VALUES ($1,'single',$2,0,1,25,'won',25,$3) RETURNING id",[earner.id,randomUUID(),market])).rows[0].id;
   await db.query("INSERT INTO market_results(market_id,revision,value_x10,source) VALUES ($1,1,600,'admin_demo')",[market]);
   await db.query("INSERT INTO entry_legs(entry_id,leg_no,market_id,line_version,line_x10,side,result,result_revision) VALUES ($1,1,$2,1,500,'over','win',1)",[entry,market]);
   await db.query('INSERT INTO mastery_events(user_id,player_id,market_id,entry_id) VALUES ($1,$2,$3,$4)',[earner.id,player,market,entry]);
  }
 }
 await db.query('INSERT INTO mastery_totals(user_id,player_id,correct_count) VALUES ($1,$2,399)',[earner.id,player]);
 await db.query('INSERT INTO card_series(player_id) VALUES ($1) ON CONFLICT DO NOTHING',[player]);
}catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();await pool.end();}
