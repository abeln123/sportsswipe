"""Local-only integration for admin presentation packs and reward-free head-to-heads."""
import json, os, subprocess, uuid
from urllib.parse import urlparse
from e2e_milestone import Session,check
DB=os.environ['TEST_DATABASE_URL']
assert urlparse(DB).hostname in ('localhost','127.0.0.1')
def sql(q):return subprocess.check_output(['psql',DB,'-X','-At','-v','ON_ERROR_STOP=1','-c',q],text=True).strip().splitlines()[0]
def main():
 stamp=uuid.uuid4().hex[:8];a,b,c=Session(),Session(),Session()
 ma=a.signup_or_login(f'admin-presentation-{stamp}@example.invalid','Admin Presentation DEMO')
 mb=b.signup_or_login(f'friend-{stamp}@example.invalid','Friend DEMO')
 mc=c.signup_or_login(f'outsider-{stamp}@example.invalid','New signup DEMO')
 sql(f"UPDATE users SET is_admin=true WHERE id='{ma['id']}'")
 status,_=b.call('POST','/admin/presentation-pack',{})
 check(status==403,'non-admin cannot open or grant presentation pack')
 _,store=b.call('GET','/packs');check(not store['presentationAvailable'],'presentation pack hidden from non-admin catalog')
 status,pack=a.call('POST','/admin/presentation-pack',{});check(status==200 and len(pack['cards'])==5,'admin opens five fixed cards')
 status,again=a.call('POST','/admin/presentation-pack',{});check([p['market']['marketId'] for p in pack['cards']]==[p['market']['marketId'] for p in again['cards']],'reopening presentation pack preserves five preselected cards')
 check(pack['cards'][0]['mastery']['count']==400 and pack['cards'][0]['mastery']['tier']=='diamond','first presentation card is already 400/400 Diamond')
 _,collection=a.call('GET','/me/collection')
 diamond=next(p for p in collection['cards'] if p['card']['playerId']==pack['cards'][0]['card']['playerId'])
 check(diamond['finish']=='diamond' and diamond['presentation'],'admin collection owns an equipped, marked presentation Diamond')
 _,deck=b.call('GET','/deck?limit=50')
 check(not ({p['market']['marketId'] for p in pack['cards']}&{p['market']['marketId'] for p in deck['cards']}),'presentation lines do not leak into regular decks')
 # Ordinary open slate: 12 lines so two exact 10-card matches can be frozen.
 team=int(sql(f"INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES ('nfl','duel-{stamp}','H2H','Head to Head Lab','Lab') RETURNING id"))
 away=int(sql(f"INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES ('nfl','duel-away-{stamp}','RIV','Rivals','Rivals') RETURNING id"))
 game=int(sql(f"INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at) VALUES ('nfl','duel-{stamp}',2026,{team},{away},now()+interval '1 day') RETURNING id"))
 mids=[];pids=[]
 for i in range(12):
  pid=int(sql(f"INSERT INTO players(league,espn_id,team_id,full_name,first_name,last_name,position) VALUES ('nfl','duel-{stamp}-{i}',{team},'Duel Athlete {i}','Duel','Athlete {i}','RB') RETURNING id"));pids.append(pid)
  mid=int(sql(f"INSERT INTO markets(game_id,player_id,stat_key,lock_at) VALUES ({game},{pid},'rush_yds',now()+interval '1 day') RETURNING id"));mids.append(mid)
  sql(f"INSERT INTO line_versions(market_id,version,line_x10) VALUES ({mid},1,100)")
 a.call('POST','/friend-requests',{'userId':mb['id']});_,req=b.call('GET','/friend-requests');b.call('POST',f"/friend-requests/{req['incoming'][0]['requestId']}/accept",{})
 command=str(uuid.uuid4());body={'commandId':command,'marketId':mids[0],'playerId':pids[0],'opponentId':mb['id']}
 status,challenge=a.call('POST','/head-to-heads',body);check(status==200,'share creates a head-to-head for a friend')
 _,retry=a.call('POST','/head-to-heads',body);check(retry['id']==challenge['id'],'retried share does not duplicate challenge or message')
 token=challenge['url'].split('/')[-1];ident=challenge['id']
 _,preview=c.call('GET',f'/head-to-head-invites/{token}');check(preview['questionCount']==10 and preview['open'],'signup/browser invite has a public preview')
 status,_=c.call('POST',f'/head-to-head-invites/{token}/accept',{});check(status==403,'another account cannot steal a friend-reserved invite')
 status,_=b.call('POST',f'/head-to-head-invites/{token}/accept',{});check(status==200,'designated friend accepts')
 _,detail=a.call('GET',f'/head-to-heads/{ident}')
 check(len(detail['cards'])==10 and detail['cards'][0]['market']['marketId']==mids[0],'match contains actual shared card plus nine others')
 _,threads=b.call('GET','/threads');thread=next(t for t in threads['threads'] if t['kind']=='dm')
 _,messages=b.call('GET',f"/threads/{thread['threadId']}/messages?afterSeq=0");check(messages['messages'][-1]['shared']['kind']=='head_to_head','friend receives challenge in Messages')
 # Freeze check even when current line changes.
 sql(f"INSERT INTO line_versions(market_id,version,line_x10) VALUES ({mids[0]},2,999)");sql(f"UPDATE markets SET current_version=2 WHERE id={mids[0]}")
 _,frozen=b.call('GET',f'/head-to-heads/{ident}');check(frozen['cards'][0]['market']['line']==10.0,'both players keep frozen line after market update')
 balances=[s.call('GET','/me/summary')[1]['balance'] for s in (a,b)]
 picks={'answers':['over']*10,'tiebreak':38}
 status,_=a.call('POST',f'/head-to-heads/{ident}/submit',picks);check(status==200,'creator submits ten answers and tiebreaker')
 _,hidden=b.call('GET',f'/head-to-heads/{ident}');check(hidden['people'][0]['answers'] is None and hidden['people'][0]['tiebreak'] is None,'opponent picks and tiebreaker stay private before lock')
 status,_=a.call('POST',f'/head-to-heads/{ident}/submit',{'answers':['under']*10,'tiebreak':38});check(status==400,'submitted answers cannot be edited')
 b.call('POST',f'/head-to-heads/{ident}/submit',{'answers':['over']*10,'tiebreak':60})
 # Open invitation can be accepted by a new user, once.
 _,open_invite=a.call('POST','/head-to-heads',{'commandId':str(uuid.uuid4()),'marketId':mids[1],'playerId':pids[1]})
 open_token=open_invite['url'].split('/')[-1]
 status,_=c.call('POST',f'/head-to-head-invites/{open_token}/accept',{});check(status==200,'browser signup recipient joins an open 1v1 invite')
 status,_=b.call('POST',f'/head-to-head-invites/{open_token}/accept',{});check(status==403,'open invite cannot gain a third player')
 # Result revision deliberately differs from current market line.
 qids=[p['market']['marketId'] for p in detail['cards']]
 for mid in qids:
  sql(f"INSERT INTO market_results(market_id,revision,value_x10,source) VALUES ({mid},1,110,'admin_demo') ON CONFLICT DO NOTHING")
 sql(f"UPDATE games SET status='final',home_score=21,away_score=17 WHERE id={game}")
 sql(f"UPDATE head_to_heads SET lock_at=now()-interval '1 minute' WHERE id='{ident}'")
 _,result=a.call('GET',f'/head-to-heads/{ident}');check(result['status']=='complete' and result['winnerId']==ma['id'],'equal correct scores resolve by closest total-points tiebreaker')
 check(result['people'][0]['points']==10 and result['people'][1]['points']==10,'all ten fixed-line picks graded consistently')
 check([s.call('GET','/me/summary')[1]['balance'] for s in (a,b)]==balances,'1v1 never credits or debits coins')
 status,_=b.call('POST',f'/head-to-heads/{ident}/submit',picks);check(status==400,'late submissions rejected')
 print(json.dumps({'adminEmail':f'admin-presentation-{stamp}@example.invalid','adminId':ma['id'],'diamondPlayerId':diamond['card']['playerId'],'challengeId':ident}))
if __name__=='__main__':main()
