#!/usr/bin/env python3
"""Smoke test for social, invites, contests, the analyst and the store.

Usage: API=http://localhost:8080 ADMIN_EMAIL=admin@sportsswipe.test python3 scripts/smoke_features.py
"""

import os
import urllib.request
import uuid

from e2e_milestone import API, ADMIN_EMAIL, Session, check


def main():
    admin = Session()
    admin.signup_or_login(ADMIN_EMAIL, "Admin")
    a, b = Session(), Session()
    me_a = a.signup_or_login(f"maya-{uuid.uuid4().hex[:6]}@sportsswipe.test", "Maya K")
    me_b = b.signup_or_login(f"court-{uuid.uuid4().hex[:6]}@sportsswipe.test", "Court")

    # Friends and DMs
    _, found = a.call("GET", f"/users/search?q={me_b['handleTag'].replace('#', '%23')}")
    check(found["users"] and found["users"][0]["userId"] == me_b["id"], "search by HANDLE#tag finds the user")
    status, _ = a.call("POST", "/threads/dm", {"userId": me_b["id"]})
    check(status == 403, "DMs require an accepted friendship")
    a.call("POST", "/friend-requests", {"userId": me_b["id"]})
    _, reqs = b.call("GET", "/friend-requests")
    check(len(reqs["incoming"]) == 1, "friend request arrives")
    b.call("POST", f"/friend-requests/{reqs['incoming'][0]['requestId']}/accept")
    _, dm = a.call("POST", "/threads/dm", {"userId": me_b["id"]})
    cid = str(uuid.uuid4())
    a.call("POST", f"/threads/{dm['threadId']}/messages", {"clientMsgId": cid, "body": "Taking the over on Brunson"})
    _, dup = a.call("POST", f"/threads/{dm['threadId']}/messages", {"clientMsgId": cid, "body": "Taking the over on Brunson"})
    check(dup["duplicate"] is True, "resent message is deduplicated")
    _, msgs = b.call("GET", f"/threads/{dm['threadId']}/messages?after_seq=0")
    check(len(msgs["messages"]) == 1, "friend reads exactly one message")

    # Leagues and invites
    _, league = a.call("POST", "/leagues", {"name": "Sunday Crew"})
    _, inv = a.call("POST", "/invites", {"leagueId": league["leagueId"]})
    check(inv["url"].startswith(API) or "/i/" in inv["url"], "invite link minted")
    token = inv["url"].rsplit("/", 1)[1]
    html = urllib.request.urlopen(f"{API}/i/{token}").read().decode()
    check('og:title" content="Join Sunday Crew on Sports Swipe"' in html, "landing page has Open Graph title")
    c = Session()
    c.signup_or_login(f"newbie-{uuid.uuid4().hex[:6]}@sportsswipe.test", "Newbie")
    _, l_before = c.call("GET", f"/leagues/{league['leagueId']}")
    check(l_before.get("code") == "not_found", "previewing the link did not create membership")
    status, _ = c.call("POST", f"/invites/{token}/accept")
    check(status == 200, "authenticated accept joins the league")
    _, detail = c.call("GET", f"/leagues/{league['leagueId']}")
    check(len(detail["members"]) == 2, "league has two members")
    status, _ = c.call("POST", "/leagues/join", {"code": league["joinCode"]})
    check(status == 200, "join with a code is idempotent")
    c.call("POST", f"/threads/{league['threadId']}/messages", {"clientMsgId": str(uuid.uuid4()), "body": "hi league"})
    _, threads = a.call("GET", "/threads")
    check(any(t["kind"] == "league" and t["unread"] == 1 for t in threads["threads"]), "league thread shows unread")

    # Contest
    _, week = a.call("GET", "/contests/current")
    open_days = [d for d in week["days"] if d["status"] == "open"]
    check(len(week["days"]) == 7, f"contest week has 7 days ({len(open_days)} open)")
    if open_days:
        day = open_days[0]
        _, slate = a.call("GET", f"/contest-days/{day['dayId']}/slate")
        answers = [{"questionId": q["questionId"], "side": "over"} for q in slate["questions"]]
        body = {"commandId": str(uuid.uuid4()), "slateVersion": slate["slateVersion"], "tiebreak": 55, "answers": answers[:-1]}
        status, res = a.call("POST", f"/contest-days/{day['dayId']}/entries", body)
        check(status == 422, "incomplete contest entry rejected")
        body["answers"] = answers
        status, res = a.call("POST", f"/contest-days/{day['dayId']}/entries", body)
        check(status == 201 and len(res["answers"]) == len(answers), "complete contest entry accepted with receipt")
        status, again = a.call("POST", f"/contest-days/{day['dayId']}/entries", body)
        check(status == 201 and again["entryId"] == res["entryId"], "contest retry returns the same receipt")
        status, settled = admin.call("POST", "/admin/settle-contest-day", {"dayId": day["dayId"]})
        check(status == 200 and len(settled["settled"]) == len(answers), "admin demo settles the contest day")
        _, standings = a.call("GET", f"/contests/{week['contestId']}/standings")
        mine = [r for r in standings["rows"] if r["isMe"]]
        check(mine and mine[0]["daysCounted"] == 1, f"standings include the entry ({mine[0]['points']} pts)")

    # Analyst
    _, ans = a.call("POST", "/analyst/ask", {"question": "Josh Allen passing yards last 5 games"})
    check(ans["kind"] == "form" and ans["metric"]["games"] >= 3, f"analyst: {ans.get('answer')}")
    _, ans = a.call("POST", "/analyst/ask", {"question": "How often does Josh Allen throw an interception against Baltimore?"})
    check(ans["kind"] == "insufficient_data", "unsupported stat gets an explicit insufficient-data answer")

    # Store
    _, skus = a.call("GET", "/store/skus")
    check([s["price"] for s in skus["skus"]] == [250, 1250, 6250, 31250], "store prices match")
    cmd = str(uuid.uuid4())
    _, p1 = a.call("POST", "/store/purchases", {"commandId": cmd, "finish": "bronze"})
    _, p2 = a.call("POST", "/store/purchases", {"commandId": cmd, "finish": "bronze"})
    check(p1["purchaseId"] == p2["purchaseId"] and p2["balance"] == 750, "purchase is idempotent and debits once")
    print("\nFeature smoke passed.")


if __name__ == "__main__":
    main()
