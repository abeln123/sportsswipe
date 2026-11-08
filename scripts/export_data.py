#!/usr/bin/env python3
"""Download everything collected so far into exports/<timestamp>/.

Saves users.csv, picks.csv (one row per leg), contest_entries.csv,
contest_answers.csv and stats.json, then prints the headline numbers.

Usage:
  API=https://sportsswipe.fly.dev ADMIN_EMAIL=you@example.com ADMIN_PASSWORD=... python3 scripts/export_data.py
"""

import datetime
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

API = os.environ.get("API", "http://localhost:8080").rstrip("/")
EMAIL = os.environ.get("ADMIN_EMAIL", "")
PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
DATASETS = ["users", "picks", "contest_entries", "contest_answers"]


def request(path, token=None, body=None):
    req = urllib.request.Request(
        f"{API}/v1{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method="POST" if body is not None else "GET",
        headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def main():
    if not EMAIL or not PASSWORD:
        sys.exit("Set ADMIN_EMAIL and ADMIN_PASSWORD (an account listed in the API's ADMIN_EMAILS).")
    try:
        me = json.loads(request("/auth/login", body={"email": EMAIL, "password": PASSWORD}))
    except urllib.error.HTTPError as e:
        sys.exit(f"Login failed: {e.read().decode()}")
    if not me.get("isAdmin"):
        sys.exit(f"{EMAIL} is not an admin. Add it to ADMIN_EMAILS and log in again.")
    token = me["sessionToken"]

    out = pathlib.Path(__file__).resolve().parent.parent / "exports" / datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    out.mkdir(parents=True)
    for name in DATASETS:
        data = request(f"/admin/export/{name}.csv", token)
        (out / f"{name}.csv").write_bytes(data)
        rows = max(data.count(b"\n") - 1, 0)
        print(f"{name}.csv: {rows} rows")
    stats = json.loads(request("/admin/stats", token))
    (out / "stats.json").write_text(json.dumps(stats, indent=2))

    u, p, c = stats["users"], stats["picks"], stats["contests"]
    print(f"\nSaved to {out}\n")
    print(f"People: {u['total']} ({u['quickSignups']} quick sign-ups), {u['withAtLeastOnePick']} made a pick")
    print(f"Picks: {p['entries']} ({p['singles']} singles, {p['parlays']} parlays, {p['freePicks']} free)")
    print(f"Picks per active person: {p['picksPerActiveUser']}, average stake: {p['averageStake']} coins")
    print(f"Over chosen on {p['overPct']}% of {p['legs']} legs")
    print(f"Settled: {p['settled']}, won {p['won']}, lost {p['lost']} (win rate {p['winPct']}%)")
    print(f"Contests: {c['entries']} entries from {c['players']} people")
    for t in stats["topPlayers"][:5]:
        print(f"  {t['player']} ({t['league'].upper()}): {t['picks']} picks, {t['overPct']}% Over")


if __name__ == "__main__":
    main()
