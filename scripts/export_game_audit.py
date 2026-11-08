#!/usr/bin/env python3
"""Read-only, game-specific production evidence. No database password is exported.

python3 scripts/export_game_audit.py --game-id 33 --app sportsswipe
python3 scripts/export_game_audit.py --game-id 33 --out exports/atl-cin-2026-11-08 --watch-final

The watcher runs locally, saves a before snapshot, and creates after/ only once
ESPN final stats and every market/pick leg on this game have been graded.
Parlays spanning other games may legitimately remain pending.
"""
import argparse, csv, datetime as dt, html, json, pathlib, re, shlex, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
COHORT = "SELECT DISTINCT e.user_id FROM entries e JOIN entry_legs el ON el.entry_id=e.id JOIN markets m ON m.id=el.market_id WHERE m.game_id=$1"
QUERIES = {
 'game': """SELECT now() AS captured_at,g.*,h.abbr AS home_team,a.abbr AS away_team,
 (SELECT count(*) FROM markets m WHERE m.game_id=g.id) AS market_count,
 (SELECT count(*) FROM markets m WHERE m.game_id=g.id AND m.status NOT IN ('settled','void')) AS unsettled_markets,
 (SELECT count(*) FROM entry_legs el JOIN markets m ON m.id=el.market_id WHERE m.game_id=g.id AND el.result IS NULL) AS ungraded_pick_legs
 FROM games g JOIN teams h ON h.id=g.home_team_id JOIN teams a ON a.id=g.away_team_id WHERE g.id=$1""",
 'users': f"""WITH cohort AS ({COHORT}), ge AS (SELECT DISTINCT e.* FROM entries e JOIN entry_legs el ON el.entry_id=e.id JOIN markets m ON m.id=el.market_id WHERE m.game_id=$1)
 SELECT u.id AS user_id,p.display_name,p.handle||'#'||p.tag AS handle,u.is_admin,u.created_at AS signed_up_at,
 ca.balance AS current_balance,ca.version AS balance_version,
 (SELECT coalesce(sum(delta),0) FROM coin_ledger cl WHERE cl.user_id=u.id) AS ledger_balance,
 (SELECT count(*) FROM ge WHERE ge.user_id=u.id) AS game_entries,
 (SELECT count(*) FROM ge WHERE ge.user_id=u.id AND stake=0) AS free_entries,
 (SELECT count(*) FROM ge WHERE ge.user_id=u.id AND status='pending') AS pending_entries,
 (SELECT count(*) FROM ge WHERE ge.user_id=u.id AND status='won') AS won_entries,
 (SELECT count(*) FROM ge WHERE ge.user_id=u.id AND status='lost') AS lost_entries,
 (SELECT coalesce(sum(stake),0) FROM ge WHERE ge.user_id=u.id) AS game_entry_stakes,
 (SELECT coalesce(sum(credited),0) FROM ge WHERE ge.user_id=u.id) AS game_entry_credits
 FROM cohort JOIN users u ON u.id=cohort.user_id JOIN profiles p ON p.user_id=u.id JOIN coin_accounts ca ON ca.user_id=u.id ORDER BY u.is_admin,p.display_name""",
 'picks': """SELECT e.id AS entry_id,el.id AS leg_id,u.id AS user_id,p.display_name,p.handle||'#'||p.tag AS handle,u.is_admin,
 e.kind,(SELECT count(*) FROM entry_legs all_legs WHERE all_legs.entry_id=e.id) AS entry_leg_count,
 pl.full_name AS athlete,t.abbr AS team,m.stat_key,sd.label AS stat,el.side,el.line_x10/10.0 AS submitted_line,
 el.line_version,e.stake AS entry_stake,e.potential_return AS entry_potential_return,e.credited AS entry_credited,
 el.result AS leg_result,el.result_revision,e.status AS entry_status,e.accepted_at,e.settled_at,
 ca.balance AS current_wallet_balance,r.value_x10/10.0 AS final_stat,r.source AS result_source,r.recorded_at AS result_recorded_at,m.id AS market_id
 FROM entries e JOIN users u ON u.id=e.user_id JOIN profiles p ON p.user_id=u.id JOIN coin_accounts ca ON ca.user_id=u.id
 JOIN entry_legs el ON el.entry_id=e.id JOIN markets m ON m.id=el.market_id JOIN players pl ON pl.id=m.player_id
 LEFT JOIN teams t ON t.id=pl.team_id JOIN stat_definitions sd ON sd.key=m.stat_key
 LEFT JOIN LATERAL(SELECT * FROM market_results WHERE market_id=m.id AND final ORDER BY revision DESC LIMIT 1)r ON true
 WHERE m.game_id=$1 ORDER BY u.is_admin,p.display_name,e.accepted_at,el.leg_no""",
 'ledger': f"""SELECT cl.id,cl.user_id,p.display_name,p.handle||'#'||p.tag AS handle,u.is_admin,cl.delta,cl.reason,cl.entry_id,cl.source_key,cl.created_at,
 sum(cl.delta) OVER(PARTITION BY cl.user_id ORDER BY cl.id) AS balance_after_event
 FROM coin_ledger cl JOIN users u ON u.id=cl.user_id JOIN profiles p ON p.user_id=u.id WHERE cl.user_id IN ({COHORT}) ORDER BY cl.user_id,cl.id""",
 'markets': """SELECT m.id AS market_id,pl.full_name AS athlete,t.abbr AS team,m.stat_key,sd.label AS stat,m.status,m.lock_at,
 lv.version AS current_line_version,lv.line_x10/10.0 AS current_line,r.value_x10/10.0 AS final_stat,r.source,r.revision AS result_revision,r.recorded_at,
 (SELECT count(*) FROM entry_legs el JOIN entries e ON e.id=el.entry_id JOIN users u ON u.id=e.user_id WHERE el.market_id=m.id AND NOT u.is_admin) AS user_picks,
 (SELECT count(*) FROM entry_legs el JOIN entries e ON e.id=el.entry_id JOIN users u ON u.id=e.user_id WHERE el.market_id=m.id AND el.side='over' AND NOT u.is_admin) AS user_over_picks,
 (SELECT count(*) FROM entry_legs el JOIN entries e ON e.id=el.entry_id JOIN users u ON u.id=e.user_id WHERE el.market_id=m.id AND el.side='under' AND NOT u.is_admin) AS user_under_picks
 FROM markets m JOIN players pl ON pl.id=m.player_id LEFT JOIN teams t ON t.id=pl.team_id JOIN stat_definitions sd ON sd.key=m.stat_key
 JOIN line_versions lv ON lv.market_id=m.id AND lv.version=m.current_version
 LEFT JOIN LATERAL(SELECT * FROM market_results WHERE market_id=m.id AND final ORDER BY revision DESC LIMIT 1)r ON true
 WHERE m.game_id=$1 ORDER BY pl.full_name,m.stat_key""",
 'player_stats': """SELECT DISTINCT ON(s.player_id,s.stat_key) p.full_name AS athlete,t.abbr AS team,s.stat_key,s.value_x10/10.0 AS actual_value,s.revision,s.source,s.recorded_at
 FROM player_game_stats s JOIN players p ON p.id=s.player_id LEFT JOIN teams t ON t.id=p.team_id WHERE s.game_id=$1 ORDER BY s.player_id,s.stat_key,s.revision DESC""",
 'mastery': f"""SELECT mt.user_id,p.display_name,u.is_admin,pl.full_name AS athlete,mt.correct_count FROM mastery_totals mt
 JOIN users u ON u.id=mt.user_id JOIN profiles p ON p.user_id=mt.user_id JOIN players pl ON pl.id=mt.player_id
 WHERE mt.user_id IN ({COHORT}) AND mt.player_id IN(SELECT player_id FROM markets WHERE game_id=$1) ORDER BY p.display_name,pl.full_name""",
 'pack_cards': """SELECT pp.id AS purchase_id,pp.user_id,p.display_name,u.is_admin,pp.pack_key,pp.price AS pack_price,pp.created_at,pp.status AS pack_status,pp.credited AS pack_credited,
 pc.position,pc.market_id,pc.entry_id,pc.picked_at FROM pack_cards pc JOIN pack_purchases pp ON pp.id=pc.purchase_id
 JOIN profiles p ON p.user_id=pp.user_id JOIN users u ON u.id=pp.user_id JOIN markets m ON m.id=pc.market_id WHERE m.game_id=$1 ORDER BY pp.created_at,pc.position""",
 'contest_picks': """SELECT ce.id AS contest_entry_id,ce.user_id,p.display_name,u.is_admin,cd.game_date,ca.question_id,q.market_id,ca.side,q.line_x10/10.0 AS submitted_line,q.result,
 ce.points,ce.tiebreak_x10/10.0 AS tiebreak,ce.submitted_at FROM contest_answers ca JOIN contest_entries ce ON ce.id=ca.entry_id JOIN profiles p ON p.user_id=ce.user_id JOIN users u ON u.id=ce.user_id
 JOIN contest_days cd ON cd.id=ce.contest_day_id JOIN contest_questions q ON q.id=ca.question_id JOIN markets m ON m.id=q.market_id WHERE m.game_id=$1 ORDER BY ce.submitted_at,q.q_no""",
 'head_to_head_picks': """SELECT h.id AS challenge_id,e.user_id,p.display_name,u.is_admin,q.position,q.market_id,e.answers->>(q.position-1) AS side,q.line_x10/10.0 AS submitted_line,e.tiebreak,e.submitted_at
 FROM head_to_head_entries e JOIN head_to_heads h ON h.id=e.challenge_id JOIN profiles p ON p.user_id=e.user_id JOIN users u ON u.id=e.user_id
 JOIN head_to_head_questions q ON q.challenge_id=e.challenge_id JOIN markets m ON m.id=q.market_id WHERE m.game_id=$1 ORDER BY e.submitted_at,q.position""",
 'jobs': """SELECT id,kind,payload,attempts,run_at,locked_until,last_error,done_at FROM jobs WHERE payload->>'gameId'=$1::bigint::text
 OR payload->>'marketId' IN(SELECT id::text FROM markets WHERE game_id=$1) ORDER BY id DESC LIMIT 200""",
 'kickoff_locks': """SELECT g.id AS game_id,h.abbr AS home_team,a.abbr AS away_team,g.start_at,g.status,
 min(m.lock_at) AS market_lock,count(m.id) AS markets,
 count(*) FILTER(WHERE m.status='open' AND m.lock_at>now()) AS available_markets
 FROM games g JOIN teams h ON h.id=g.home_team_id JOIN teams a ON a.id=g.away_team_id JOIN markets m ON m.game_id=g.id
 WHERE g.league='nfl' AND (g.start_at AT TIME ZONE 'America/New_York')::date=(SELECT (start_at AT TIME ZONE 'America/New_York')::date FROM games WHERE id=$1)
 GROUP BY g.id,h.abbr,a.abbr ORDER BY g.start_at,g.id""",
 'worker_health': """SELECT kind,max(done_at) AS last_completed_at,count(*) FILTER(WHERE done_at IS NULL AND attempts<8) AS outstanding,
 count(*) FILTER(WHERE done_at IS NULL AND attempts>=8) AS dead_letters FROM jobs GROUP BY kind ORDER BY kind""",
}

def fetch(app, game_id, machine, brief=False):
    queries = {'game': QUERIES['game']} if brief else QUERIES
    js = """const{Client}=require('/srv/collectibles/node_modules/pg');
const c=new Client({connectionString:process.env.DATABASE_URL});
(async()=>{await c.connect();await c.query('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
const out={};const queries=QUERIES;for(const[name,sql]of Object.entries(queries)){out[name]=(await c.query(sql,sql.includes('$1')?[GAME]:[])).rows;}
await c.query('COMMIT');await c.end();console.log('AUDIT_JSON:'+JSON.stringify(out));})().catch(e=>{console.error(e.message);process.exit(1);});""".replace('QUERIES',json.dumps(queries)).replace('GAME',str(int(game_id)))
    args=['fly','ssh','console','--app',app]
    if machine: args += ['--machine',machine]
    args += ['-C','node -e '+shlex.quote(js)]
    r=subprocess.run(args,capture_output=True,text=True,timeout=100)
    if r.returncode: raise RuntimeError(r.stderr[-1000:] or r.stdout[-1000:])
    line=next((s for s in r.stdout.splitlines() if s.startswith('AUDIT_JSON:')),None)
    if line is None: raise RuntimeError('No database snapshot returned: '+r.stdout[-500:])
    return json.loads(line.removeprefix('AUDIT_JSON:'))

def display(value):
    text = str(value) if value is not None else 'pending'
    return text.rstrip('0').rstrip('.') if re.fullmatch(r'-?\d+\.\d+', text) else text

def table(rows, columns):
    heads=''.join(f'<th>{html.escape(label)}</th>' for _,label in columns)
    body=''.join('<tr>'+''.join(f'<td>{html.escape(display(row.get(key)))}</td>' for key,_ in columns)+'</tr>' for row in rows)
    return f'<table><thead><tr>{heads}</tr></thead><tbody>{body or "<tr><td colspan=20>No rows yet</td></tr>"}</tbody></table>'

def render_png(report, screenshot, height=1800):
    chrome=pathlib.Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    if not chrome.exists(): return False
    profile=ROOT/'.local'/'audit-chrome';profile.mkdir(parents=True,exist_ok=True)
    r=subprocess.run([str(chrome),'--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check',f'--user-data-dir={profile}',
       '--hide-scrollbars',f'--window-size=1600,{height}','--force-device-scale-factor=1',f'--screenshot={screenshot}',report.as_uri()],capture_output=True,timeout=50)
    return r.returncode==0 and screenshot.exists()

def save(data, folder, label):
    folder.mkdir(parents=True,exist_ok=True)
    (folder/'snapshot.json').write_text(json.dumps(data,indent=2))
    for name, rows in data.items():
        fields=list(dict.fromkeys(k for row in rows for k in row))
        with (folder/f'{name}.csv').open('w',newline='') as f:
            w=csv.DictWriter(f,fieldnames=fields or ['no_rows_yet']);w.writeheader()
            for row in rows:w.writerow({k:json.dumps(v) if isinstance(v,(dict,list)) else v for k,v in row.items()})
    g=data['game'][0];users=[u for u in data.get('users',[]) if not u['is_admin']];picks=[p for p in data.get('picks',[]) if not p['is_admin']]
    entries={p['entry_id']:p for p in picks};over=sum(p['side']=='over' for p in picks)
    checks=[]
    for u in data.get('users',[]):checks.append({'check':'wallet equals ledger','subject':u['handle'],'ok':int(u['current_balance'])==int(u['ledger_balance']),'actual':u['current_balance'],'expected':u['ledger_balance']})
    for p in data.get('picks',[]):
        if p['leg_result'] is None or p['final_stat'] is None:continue
        actual=float(p['final_stat']);line=float(p['submitted_line'])
        expected='void' if p['result_source']=='dnp' else 'push' if actual==line else 'win' if (actual>line)==(p['side']=='over') else 'loss'
        checks.append({'check':'pick graded from submitted line','subject':p['leg_id'],'ok':p['leg_result']==expected,'actual':p['leg_result'],'expected':expected})
    with (folder/'verification.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=['check','subject','ok','actual','expected']);w.writeheader();w.writerows(checks)
    summary=[f"SPORTS SWIPE | {label.upper()} | DATABASE SNAPSHOT",f"Game {g['id']}: {g['away_team']} at {g['home_team']} | ESPN {g['espn_id']}",
       f"Captured {g['captured_at']} | kickoff {g['start_at']}",f"Status: {g['status']} | score {g['away_score']}–{g['home_score']} | final stats ingested: {g['stats_ingested_at'] or 'NO'}",
       f"Non-admin users: {len(users)} | Entries: {len(entries)} | Pick legs: {len(picks)} | Over: {over} | Under: {len(picks)-over}",
       f"Entry stakes: {sum(int(e['entry_stake']) for e in entries.values())} practice coins | credited: {sum(int(e['entry_credited']) for e in entries.values())}",
       f"Ungraded game legs (incl admin): {g['ungraded_pick_legs']} | unsettled markets: {g['unsettled_markets']}",
       f"Wallet/grading checks: {sum(c['ok'] for c in checks)}/{len(checks)} passed",'', 'USER | CURRENT COINS | GAME ENTRIES | FREE | PENDING | WON | LOST | STAKED | CREDITED']
    summary += [' | '.join(str(u.get(k,'')) for k in ['handle','current_balance','game_entries','free_entries','pending_entries','won_entries','lost_entries','game_entry_stakes','game_entry_credits']) for u in users]
    summary += ['', 'SUBMITTED PICKS (non-admin; full detail in picks.csv)']
    summary += [f"{p['handle']} | {p['athlete']} | {p['side']} {display(p['submitted_line'])} {p['stat']} | stake {p['entry_stake']} | {p['entry_status']} | result {p['leg_result'] or 'pending'} | coins now {p['current_wallet_balance']}" for p in picks]
    summary += ['', 'One CSV row per leg: parlay stakes/credits repeat across legs; aggregate by entry_id.', 'Ledger includes all wallet activity for game participants, not only this game.', 'Unsubmitted swipes/skips are not persisted. Admin activity is labeled and excluded from headline totals.']
    text='\n'.join(summary);(folder/'terminal.txt').write_text(text+'\n');print(text,flush=True)
    top=html.escape('\n'.join(summary[:8]));style="body{background:#091a16;color:#f0f4f2;font:17px ui-monospace,Menlo,monospace;margin:35px}h1{font-size:23px;color:#8bea97}h2{font-size:17px;margin-top:25px}pre{font-size:15px;line-height:1.6;white-space:pre-wrap}table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:9px 10px;border-bottom:1px solid #294037;text-align:left}th{color:#9bb8aa}small{color:#9bb8aa}"
    report=f"<html><meta charset=utf-8><style>{style}</style><h1>Sports Swipe / Live PostgreSQL / {html.escape(label)}</h1><pre>{top}</pre>"
    report+='<h2>Participant wallets — non-admin</h2>'+table(users,[('handle','Player'),('current_balance','Coins now'),('game_entries','Entries'),('pending_entries','Pending'),('won_entries','Won'),('lost_entries','Lost'),('game_entry_stakes','Entry stakes'),('game_entry_credits','Credits')])
    report+='<h2>Submitted predictions — non-admin</h2>'+table(picks[:22],[('handle','Player'),('athlete','Athlete'),('side','Call'),('submitted_line','Line'),('stat','Stat'),('entry_stake','Stake¹'),('leg_result','Result'),('entry_status','Entry'),('current_wallet_balance','Coins now')])
    report+='<p><small>¹ Parlay stakes belong to the entry, not each leg. Complete rows, ledger events, admin activity, box scores and verification are in the adjacent CSV files. This is a captured database report, not simulated data.</small></p></html>'
    path=folder/'report.html';path.write_text(report)
    if render_png(path.resolve(),folder.resolve()/'screenshot.png'):print('Screenshot:',folder/'screenshot.png',flush=True)
    all_picks=folder/'all_picks.html'
    all_picks.write_text(f'<html><meta charset=utf-8><style>{style}</style><h1>All submitted user picks / {html.escape(label)}</h1><pre>{top}</pre>'+table(picks,[('handle','Player'),('athlete','Athlete'),('side','Call'),('submitted_line','Line'),('stat','Stat'),('entry_stake','Entry stake'),('leg_result','Leg result'),('entry_status','Entry'),('current_wallet_balance','Coins now')])+'</html>')
    render_png(all_picks.resolve(),folder.resolve()/'all_picks_screenshot.png', min(6000,500+len(picks)*36))
    if data.get('kickoff_locks'):
        locks=folder/'kickoff_locks.html'
        locks.write_text(f'<html><meta charset=utf-8><style>{style}</style><h1>Each game locks at its own kickoff</h1><pre>Captured {html.escape(g["captured_at"])} / live PostgreSQL / times UTC</pre>'+table(data['kickoff_locks'],[('away_team','Away'),('home_team','Home'),('start_at','Kickoff'),('market_lock','Market lock'),('status','Game status'),('markets','Markets'),('available_markets','Still available')])+'</html>')
        render_png(locks.resolve(),folder.resolve()/'kickoff_locks_screenshot.png',1200)
    print('Saved CSVs and raw snapshot:',folder,flush=True)
    return all(c['ok'] for c in checks)

def final_ready(g):
    return g['status']=='final' and g['stats_ingested_at'] is not None and int(g['ungraded_pick_legs'])==0 and int(g['unsettled_markets'])==0

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--game-id',required=True,type=int);p.add_argument('--app',default='sportsswipe');p.add_argument('--machine',default='891e164c146198');p.add_argument('--out',type=pathlib.Path);p.add_argument('--watch-final',action='store_true');p.add_argument('--poll',type=int,default=120);p.add_argument('--deadline-hours',type=float,default=12);a=p.parse_args()
    out=(a.out or ROOT/'exports'/f'game-{a.game_id}-{dt.datetime.now(dt.timezone.utc):%Y%m%dT%H%M%SZ}').resolve()
    before=out/'before'
    if not (before/'snapshot.json').exists():
        data=fetch(a.app,a.game_id,a.machine)
        if not data['game']:sys.exit('Game not found')
        save(data,before,'Current / before final' if not final_ready(data['game'][0]) else 'Already final at first capture')
    if not a.watch_final:return
    until=time.monotonic()+a.deadline_hours*3600
    while time.monotonic()<until:
        try:
            g=fetch(a.app,a.game_id,a.machine,brief=True)['game'][0]
            print(f"WATCH {g['captured_at']} status={g['status']} stats={g['stats_ingested_at']} ungraded={g['ungraded_pick_legs']} unsettled={g['unsettled_markets']}",flush=True)
            kickoff=dt.datetime.fromisoformat(g['start_at'].replace('Z','+00:00'))
            captured=dt.datetime.fromisoformat(g['captured_at'].replace('Z','+00:00'))
            if captured>=kickoff and not (out/'kickoff'/'snapshot.json').exists():
                save(fetch(a.app,a.game_id,a.machine),out/'kickoff','Kickoff / per-game locks')
            if final_ready(g):
                data=fetch(a.app,a.game_id,a.machine)
                ok=save(data,out/'after','Post-game / graded')
                old=json.loads((before/'snapshot.json').read_text());prev={u['user_id']:u for u in old['users']}
                comparisons=[{'user_id':u['user_id'],'handle':u['handle'],'is_admin':u['is_admin'],'coins_before':prev.get(u['user_id'],{}).get('current_balance'),'coins_after':u['current_balance'],'credited_before':prev.get(u['user_id'],{}).get('game_entry_credits'),'credited_after':u['game_entry_credits'],'pending_before':prev.get(u['user_id'],{}).get('pending_entries'),'pending_after':u['pending_entries']}for u in data['users']]
                with (out/'before_after.csv').open('w',newline='') as f:
                    w=csv.DictWriter(f,fieldnames=list(comparisons[0]) if comparisons else ['no_participants']);w.writeheader();w.writerows(comparisons)
                (out/'COMPLETE.txt').write_text(f"Post-game captured {g['captured_at']}\nVerification checks {'PASS' if ok else 'NEED REVIEW'}\nWallet differences can include other games or purchases; use ledger.csv to attribute changes.\n")
                return
        except Exception as e:print('WATCH retry:',e,flush=True)
        time.sleep(max(a.poll,30))
    (out/'WATCH_EXPIRED.txt').write_text('No fully graded final snapshot within the watch window. Re-run --watch-final.\n')
if __name__=='__main__':main()
