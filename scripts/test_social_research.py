"""Exercise the social/research flow against an isolated local API and database.
API=http://localhost:8089 TEST_DATABASE_URL=postgres://... python3 scripts/test_social_research.py
Never point this fixture at a live database.
"""
import json
import os
import subprocess
import uuid
from e2e_milestone import Session, check

def sql(query):
    db = os.environ['TEST_DATABASE_URL']
    assert '@127.0.0.1:' in db or '@localhost:' in db, 'Use an isolated localhost database'
    return subprocess.check_output(['psql', db, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip().splitlines()[0]

def main():
    a,b,c = Session(),Session(),Session()
    stamp=uuid.uuid4().hex[:8]
    me=a.signup_or_login(f'alex-{stamp}@test.invalid','Alex Rivera')
    friend=b.signup_or_login(f'jordan-{stamp}@test.invalid','Jordan Lee')
    c.signup_or_login(f'casey-{stamp}@test.invalid','Casey Park')
    _,inv=a.call('POST','/invites',{})
    _,preview=c.call('GET',f"/invites/{inv['token']}")
    check(preview['kind']=='friend' and preview['valid'], 'personal invitation previews without accepting')
    _,friends=a.call('GET','/friends')
    check(not friends['friends'],'preview does not create friendship')
    status,accepted=b.call('POST',f"/invites/{inv['token']}/accept",{})
    check(status==200 and 'threadId' in accepted,'accept creates friendship and opens conversation')
    thread=accepted['threadId']
    _,again=b.call('POST',f"/invites/{inv['token']}/accept",{})
    check(again['threadId']==thread,'accept retry reuses conversation')
    status,_=a.call('POST',f"/invites/{inv['token']}/accept",{})
    check(status==400,'self invitation cannot be accepted')
    status,_=c.call('GET',f'/threads/{thread}/messages')
    check(status==404,'nonmember cannot read conversation')
    own=int(sql(f"INSERT INTO teams(league,espn_id,abbr,name,short_name,color_primary) VALUES ('nfl','atl-{stamp}','ATL','Atlanta Falcons','Falcons','A71930') RETURNING id"))
    player=int(sql(f"INSERT INTO players(league,espn_id,team_id,full_name,first_name,last_name,position,jersey) VALUES ('nfl','bijan-{stamp}',{own},'Bijan Robinson','Bijan','Robinson','RB','7') RETURNING id"))
    for i,(opp,value) in enumerate(zip(['NO','BAL','CHI','SF','TB'],[145,86,63,61,76])):
        away=int(sql(f"INSERT INTO teams(league,espn_id,abbr,name,short_name) VALUES ('nfl','{opp}-{stamp}','{opp}','{opp}','{opp}') RETURNING id"))
        game=int(sql(f"INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at,status) VALUES ('nfl','{stamp}-{i}',2026,{own},{away},now()-interval '{5-i} weeks','final') RETURNING id"))
        sql(f"INSERT INTO player_game_stats(game_id,player_id,stat_key,value_x10,source) VALUES ({game},{player},'rush_yds',{value*10},'espn')")
    game=int(sql(f"INSERT INTO games(league,espn_id,season,home_team_id,away_team_id,start_at) VALUES ('nfl','{stamp}-next',2026,{own},{away},now()+interval '1 day') RETURNING id"))
    market=int(sql(f"INSERT INTO markets(game_id,player_id,stat_key,lock_at) VALUES ({game},{player},'rush_yds',now()+interval '1 day') RETURNING id"))
    sql(f"INSERT INTO line_versions(market_id,version,line_x10) VALUES ({market},1,865)")
    _,report=a.call('POST','/analyst/form',{'playerId':player,'statKey':'rush_yds','n':5})
    check(report['metric']['average']==86.2 and report['metric']['aboveLine']==1,'research computes 86.2 average and one game above 86.5')
    _,focused=a.call('POST','/analyst/ask',{'question':'How often did Bijan Robinson clear 86.5 rushing yards over his last 5 games?'})
    check(focused['focus']=='line' and focused['metric']['games']==5,'decimal line does not become sample size')
    _,threshold=a.call('POST','/analyst/ask',{'question':'How often did Bijan Robinson clear 80 rushing yards in his last 5 games?'})
    check(threshold['metric']['requestedLine']==80 and threshold['metric']['aboveRequestedLine']==2,'explicit question threshold overrides the headline comparison')
    cmd=str(uuid.uuid4())
    body={'clientMsgId':cmd,'body':'Would you take this line?','shareId':report['shareId']}
    status, sent=a.call('POST',f'/threads/{thread}/messages',body)
    check(status==200,'research and comment send together')
    _,retry=a.call('POST',f'/threads/{thread}/messages',body)
    check(retry['duplicate'] and retry['seq']==sent['seq'],'share retry does not duplicate message')
    _,messages=b.call('GET',f'/threads/{thread}/messages')
    shared=messages['messages'][0]['shared']
    check(shared['payload']['games']==report['games'] and 'alreadyPickedEntryId' not in shared['payload'],'recipient receives exact chart snapshot without private pick data')
    check(messages['firstUnreadSeq']==1,'first unread sequence is supplied')
    status,_=b.call('POST',f'/threads/{thread}/messages',{'clientMsgId':str(uuid.uuid4()),'body':'forged','shareId':report['shareId']})
    check(status==404,'cannot send another user’s share as your own')
    status,_=a.call('POST','/shares',{'kind':'card','playerId':player})
    check(status==404,'unearned cards cannot be shared')
    sql(f"INSERT INTO mastery_totals(user_id,player_id,correct_count) VALUES ('{me['id']}',{player},1)")
    _,card=a.call('POST','/shares',{'kind':'card','playerId':player})
    a.call('POST',f'/threads/{thread}/messages',{'clientMsgId':str(uuid.uuid4()),'body':'First card','shareId':card['shareId']})
    a.call('PATCH','/me/profile',{'visibility':'private'})
    _,messages=b.call('GET',f'/threads/{thread}/messages?afterSeq=0')
    check(messages['messages'][-1]['shared']['kind']=='unavailable','private card access is checked at read time')
    _,threads=b.call('GET','/threads')
    check(threads['threads'][0]['shared']['kind']=='unavailable','thread previews also honor item privacy')
    _,league=a.call('POST','/leagues',{'name':'Sunday Crew'})
    _,leagues=a.call('GET','/leagues')
    check(leagues['leagues'][0]['rank']==1,'league roster includes actual current place')
    pending=sql(f"INSERT INTO entries(user_id,kind,command_id,stake,rule_version,potential_return) VALUES ('{me['id']}','single','{uuid.uuid4()}',0,1,25) RETURNING id")
    status,_=a.call('POST','/shares',{'kind':'pick','entryId':pending})
    check(status==404,'pending picks cannot be shared')
    print(json.dumps({'playerId':player,'marketId':market,'email':me['email'] if 'email' in me else f'alex-{stamp}@test.invalid','threadId':thread}))

if __name__=='__main__':main()
