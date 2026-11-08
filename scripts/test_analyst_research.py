#!/usr/bin/env python3
"""Opt-in integration test: real Gemini + ESPN; isolated localhost API only.
Run after adding a real Josh Allen / BUF / BAL / DAL test catalog. Never uses production accounts.
"""
import concurrent.futures
import json
import os
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlparse
BASE = os.environ.get('ANALYST_TEST_BASE', 'http://127.0.0.1:8096')
if urlparse(BASE).hostname not in ('localhost', '127.0.0.1'):
    raise SystemExit('This test may only create accounts on a local API.')

def request(path, body, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + '/v1' + path, data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=90) as response:
        return json.load(response)

user = request('/auth/quick', {'displayName': 'Analyst research test'})
token = user['sessionToken']
questions = [
    'how often does josh allen throw interceptions againts the ravens',
    "I'm noticing that the Cowboys typically lose when having a short rest period. Assess the recent years.",
]

def ask(question):
    before = time.monotonic()
    a = request('/analyst/ask', {'question': question}, token)
    assert a['kind'] == 'analysis', json.dumps(a)
    return a, round(time.monotonic() - before, 2)

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    results = list(executor.map(ask, questions))

allen, cowboys = results[0][0], results[1][0]
assert allen['researchPlan']['stat'] == 'pass_int'
assert allen['researchPlan']['measure'] == 'frequency'
assert allen['researchPlan']['threshold'] == 0
assert all(g['opponent'] == 'BAL' for g in allen['games'])
assert allen['metric']['hits'] == sum(g['value'] > 0 for g in allen['games'])
assert len(set(g['eventId'] for g in allen['games'])) == len(allen['games'])
assert allen['provenance']['databaseGames'] >= 1, 'A verified local box score must merge with ESPN history.'
assert allen.get('shareId'), 'Computed research must remain shareable.'
assert cowboys['researchPlan']['restMax'] == 6
assert cowboys['researchPlan']['measure'] == 'loss_rate'
assert cowboys['metric']['hits'] == sum(g['result'] == 'L' for g in cowboys['games'])
assert all(g['restDays'] is not None and g['restDays'] <= 6 for g in cowboys['games'])
assert cowboys['comparison']['games'] > 0
# Independently reconstruct the Cowboys cohort from the cached raw ESPN schedule.
# This catches a wrong date join, dropped games, or incorrect short-rest denominator.
raw = subprocess.run(['docker', 'exec', 'sportsswipe-diamond-tests', 'psql', '-U', 'postgres', '-Atc',
    "SELECT coalesce(jsonb_agg(jsonb_build_object('resource',resource,'body',body)),'[]'::jsonb) FROM analyst_source_cache WHERE resource LIKE 'schedule/football/nfl/teams/6/schedule%seasontype=2'"], capture_output=True, text=True, check=True)
records = []
plan = cowboys['researchPlan']
for source in json.loads(raw.stdout):
    season = int(source['resource'].split('season=')[1].split('&')[0])
    if not plan['startSeason'] <= season <= plan['endSeason']:
        continue
    for event in source['body'].get('events', []):
        comp = event['competitions'][0]
        if not comp.get('status', {}).get('type', {}).get('completed'):
            continue
        own = next(c for c in comp['competitors'] if c['team']['id'] == '6')
        opponent = next(c for c in comp['competitors'] if c['team']['id'] != '6')
        points = lambda c: float(c['score']['value'] if isinstance(c['score'], dict) else c['score'])
        date = datetime.fromisoformat(event['date'].replace('Z', '+00:00')).astimezone(ZoneInfo('America/New_York')).date()
        records.append((season, date, event['id'], points(own) < points(opponent)))
records = sorted({row[2]: row for row in records}.values())
previous = {}
expected = []
other = []
for season, date, event, lost in records:
    before = previous.get(season)
    previous[season] = date
    if before is None:
        continue
    rest = (date - before).days
    (expected if rest <= plan['restMax'] else other).append((event, lost))
assert {g['eventId'] for g in cowboys['games']} == {event for event, _ in expected}
assert cowboys['metric']['hits'] == sum(lost for _, lost in expected)
assert cowboys['comparison']['games'] == len(other)
assert cowboys['comparison']['hits'] == sum(lost for _, lost in other)

assert all(g['source'] in ('espn', 'database') for a, _ in results for g in a['games'])
followup = request('/analyst/ask', {'question': 'What about including the playoffs?', 'context': [{'question': questions[0], 'plan': allen['researchPlan']}]}, token)
assert followup['kind'] == 'analysis', json.dumps(followup)
assert followup['researchPlan']['seasonType'] == 'all'
assert followup['researchPlan']['stat'] == 'pass_int'
assert followup['metric']['games'] >= allen['metric']['games']
# The next identical question should reuse persisted source snapshots.
repeat = request('/analyst/ask', {'question': questions[0]}, token)
assert repeat['kind'] == 'analysis'
assert repeat['metric'] == allen['metric']
assert repeat['provenance']['cachedSources'] > 0
assert repeat['provenance']['fetchedSources'] == 0
# Exact slate shortcuts also enrich a database history that is too small.
player_id = int(subprocess.run(['docker', 'exec', 'sportsswipe-diamond-tests', 'psql', '-U', 'postgres', '-Atc', "SELECT id FROM players WHERE league='nfl' AND espn_id='3918298'"], capture_output=True, text=True, check=True).stdout.strip())
form = request('/analyst/form', {'playerId': player_id, 'statKey': 'pass_int', 'n': 5}, token)
assert form['kind'] == 'analysis', json.dumps(form)
assert form['metric']['games'] == 5
assert form['card']['fullName'] == 'Josh Allen'
proof = {'questions': questions, 'results': [r for r, _ in results], 'seconds': [s for _, s in results], 'playoffFollowup': followup, 'cacheVerified': True}
Path('/tmp/ss-analyst-proof.json').write_text(json.dumps(proof, indent=2))
print(json.dumps({'passed': True, 'answers': [r['answer'] for r, _ in results], 'seconds': proof['seconds'], 'playoffGames': followup['metric']['games'], 'cacheVerified': True}))
