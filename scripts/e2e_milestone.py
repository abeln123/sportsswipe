#!/usr/bin/env python3
"""First production milestone, end to end over HTTP.

A zero-stake pick and a 100-coin pick are submitted; the response to the
100-coin pick is treated as lost after commit; the market locks; the same
command is retried; the market is settled twice; then receipt, wallet,
ledger-derived balance and profile record must all agree.

Usage: API=http://localhost:8080 ADMIN_EMAIL=admin@sportsswipe.test python3 scripts/e2e_milestone.py
The admin email must be listed in the API's ADMIN_EMAILS.
"""

import json
import os
import sys
import urllib.error
import urllib.request
import uuid

API = os.environ.get("API", "http://localhost:8080").rstrip("/")
ADMIN_EMAIL = os.environ.get("ADMIN_EMAIL", "admin@sportsswipe.test")
PASSWORD = "milestone-pass-123"


class Session:
    def __init__(self):
        self.token = None

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(API + "/v1" + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req) as res:
                return res.status, json.loads(res.read() or b"null")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"null")

    def signup_or_login(self, email, name):
        status, body = self.call("POST", "/auth/signup", {"email": email, "password": PASSWORD, "displayName": name})
        if status == 409:
            status, body = self.call("POST", "/auth/login", {"email": email, "password": PASSWORD})
        assert status == 200, (status, body)
        self.token = body["sessionToken"]
        return body


def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        sys.exit(1)


def main():
    admin = Session()
    admin.signup_or_login(ADMIN_EMAIL, "Admin")
    status, me = admin.call("GET", "/auth/me")
    check(me.get("isAdmin") is True, "admin account has admin role")

    player = Session()
    me = player.signup_or_login(f"milestone-{uuid.uuid4().hex[:8]}@sportsswipe.test", "Milestone")
    check(me["balance"] == 1000, "new account starts with 1,000 coins")

    status, deck = player.call("GET", "/deck?sport=all")
    check(status == 200 and len(deck["cards"]) >= 2, f"deck has playable cards ({len(deck['cards'])})")
    free_card, paid_card = deck["cards"][0]["market"], deck["cards"][1]["market"]

    free_cmd = str(uuid.uuid4())
    status, free = player.call("POST", "/picks", {
        "commandId": free_cmd, "marketId": free_card["marketId"], "lineVersion": free_card["lineVersion"],
        "side": "over", "stake": 0})
    check(status == 201 and free["potentialReturn"] == 25, "zero-stake pick accepted, returns 25 if right")

    paid_cmd = str(uuid.uuid4())
    body = {"commandId": paid_cmd, "marketId": paid_card["marketId"], "lineVersion": paid_card["lineVersion"],
            "side": "under", "stake": 100}
    status, first = player.call("POST", "/picks", body)
    check(status == 201 and first["potentialReturn"] == 225 and first["balance"] == 900,
          "100-coin pick accepted: debit 100, returns 225 if right")
    # The phone never saw `first`. It retries with the same command id.

    status, _ = admin.call("POST", "/admin/lock-market", {"marketId": paid_card["marketId"]})
    check(status == 200, "market locked")

    status, retry = player.call("POST", "/picks", body)
    check(status == 201 and retry["entryId"] == first["entryId"], "retry after lock returns the original receipt")
    status, by_status = player.call("GET", f"/commands/{paid_cmd}")
    check(by_status["entryId"] == first["entryId"], "command status endpoint returns the same receipt")

    status, conflict = player.call("POST", "/picks", {**body, "side": "over"})
    check(status == 409 and conflict["code"] == "command_conflict", "same command id with a different payload is a conflict")

    status, late = player.call("POST", "/picks", {**body, "commandId": str(uuid.uuid4())})
    check(status == 409 and late["code"] == "pick_closed", "a new pick on the locked market is rejected")

    status, summary = player.call("GET", "/me/summary")
    check(summary["balance"] == 900, "exactly one 100-coin debit exists")

    line = paid_card["line"]
    value = int(line) - 3 if line > 3 else 0
    status, s1 = admin.call("POST", "/admin/settle-market", {"marketId": paid_card["marketId"], "value": value})
    check(status == 200 and s1["summary"]["entriesSettled"] >= 1, f"settle 1: value {value} under line {line}")
    status, s2 = admin.call("POST", "/admin/settle-market", {"marketId": paid_card["marketId"], "value": value})
    check(status == 200 and s2["summary"]["coinsCredited"] == 0, "settle 2 with the same value credits nothing")
    status, _ = admin.call("POST", "/admin/settle-market", {"marketId": free_card["marketId"], "value": free_card["line"] + 0.5})
    check(status == 200, "free pick settled over the line")

    status, summary = player.call("GET", "/me/summary")
    check(summary["balance"] == 900 + 225 + 25, f"wallet is 1,150 after both wins ({summary['balance']})")

    status, picks = player.call("GET", "/me/picks?status=settled")
    entries = {e["entryId"]: e for e in picks["items"]}
    paid = entries.get(first["entryId"])
    check(paid and paid["status"] == "won" and paid["credited"] == 225 and paid["legs"][0]["line"] == line,
          "My picks shows the settled receipt with the accepted line")

    status, results = player.call("GET", "/me/results/unrevealed")
    check(results["won"] == 2 and results["coinsReturned"] == 250 and results["roundChange"] == 150,
          "results reveal: 2 won, 250 returned, +150 round change")
    check(len(results["newCards"]) == 2, "two new cards unlocked")

    status, stats = player.call("GET", f"/profiles/{me['id']}/stats")
    check(stats["won"] == 2 and stats["lost"] == 0 and stats["coinsReturned"] == 250, "profile record is 2-0 with 250 returned")

    status, coll = player.call("GET", "/me/collection")
    check(coll["collected"] == 2 and all(c["mastery"]["tier"] == "base" for c in coll["cards"]), "collection has two Base cards")

    race(admin)
    parlay_with_stale_leg(admin)
    print("\nMilestone verified.")


def race(admin):
    """Two devices stake the whole balance at the same moment."""
    import threading

    p = Session()
    p.signup_or_login(f"race-{uuid.uuid4().hex[:8]}@sportsswipe.test", "Racer")
    _, deck = p.call("GET", "/deck?sport=all")
    cards = [c["market"] for c in deck["cards"][:2]]
    results = []

    def go(card):
        results.append(p.call("POST", "/picks", {
            "commandId": str(uuid.uuid4()), "marketId": card["marketId"], "lineVersion": card["lineVersion"],
            "side": "over", "stake": 1000}))

    threads = [threading.Thread(target=go, args=(c,)) for c in cards]
    [t.start() for t in threads]
    [t.join() for t in threads]
    ok = [r for r in results if r[0] == 201]
    rejected = [r for r in results if r[0] == 409 and r[1]["code"] == "insufficient_coins"]
    _, summary = p.call("GET", "/me/summary")
    check(len(ok) == 1 and len(rejected) == 1 and summary["balance"] == 0,
          "two simultaneous 1,000-coin picks: exactly one debit succeeds")
    check(rejected[0][1]["balance"] == 0, "the loser receives the authoritative balance")


def parlay_with_stale_leg(admin):
    p = Session()
    p.signup_or_login(f"parlay-{uuid.uuid4().hex[:8]}@sportsswipe.test", "Parlay")
    _, deck = p.call("GET", "/deck?sport=all&limit=12")
    legs = [c["market"] for c in deck["cards"][-3:]]
    body = {"commandId": str(uuid.uuid4()), "stake": 100,
            "legs": [{"marketId": l["marketId"], "lineVersion": l["lineVersion"], "side": "over"} for l in legs]}
    admin.call("POST", "/admin/lock-market", {"marketId": legs[-1]["marketId"]})
    status, res = p.call("POST", "/parlays", body)
    _, summary = p.call("GET", "/me/summary")
    check(status == 409 and res["staleLegs"][0]["marketId"] == legs[-1]["marketId"] and summary["balance"] == 1000,
          "parlay with a locked leg is rejected whole, names the leg, debits zero")
    body2 = {**body, "commandId": str(uuid.uuid4()), "legs": body["legs"][:2]}
    status, res = p.call("POST", "/parlays", body2)
    check(status == 201 and res["potentialReturn"] == 3 * 100 + 50, "two-leg parlay accepted, returns 350 if both hit")


if __name__ == "__main__":
    main()
