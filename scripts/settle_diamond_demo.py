"""Settle only the last pending free pick of a local fictional Diamond demo.
DATABASE_URL=... python3 scripts/settle_diamond_demo.py FINAL_MARKET_ID
Uses the existing Rust grading worker via a queued grade_market job.
"""
import os, subprocess, sys
from urllib.parse import urlparse
url=os.environ['DATABASE_URL']
assert urlparse(url).hostname in ('localhost','127.0.0.1'), 'Local isolated demo DB only'
market=int(sys.argv[1])
query=f"""DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM markets m JOIN players p ON p.id=m.player_id JOIN entries e ON e.single_market_id=m.id JOIN users u ON u.id=e.user_id WHERE m.id={market} AND p.collectible_demo AND e.stake=0 AND e.status='pending' AND u.email LIKE '%-demo-%@example.invalid') THEN RAISE EXCEPTION 'Not a pending local demo pick'; END IF;
 UPDATE markets SET status='locked' WHERE id={market};
 INSERT INTO market_results(market_id,revision,value_x10,source) VALUES ({market},1,600,'admin_demo') ON CONFLICT DO NOTHING;
 INSERT INTO jobs(kind,dedupe_key,payload) VALUES ('grade_market','diamond-demo:{market}',jsonb_build_object('marketId',{market})) ON CONFLICT DO NOTHING;
 END $$;"""
subprocess.run(['psql',url,'-X','-v','ON_ERROR_STOP=1','-c',query],check=True)
print('Result recorded. Run the normal worker to grade it; the collectible claim stays blocked until grading records the 400th win.')
