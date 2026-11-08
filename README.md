# Sports Swipe

A web simulation of the Sports Swipe app: swipe Over or Under on real NFL and NBA
player lines with practice coins, build parlays, play free weekly contests, add
friends, create leagues and text invites from your own phone.

- `backend/`: Rust (Axum + SQLx) on Postgres. `api` serves `/v1/*`, invite
  landing pages (`/i/{token}`) and the web build; `worker` ingests ESPN data,
  creates lines, grades markets and runs contests.
- `app/`: Flutter app (web build runs inside a phone frame on desktop).
- `scripts/`: end-to-end checks over HTTP.

## Run locally

```sh
docker run -d --name ss-pg -p 5433:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=sportsswipe postgres:16
cp .env.example .env && set -a && source .env && set +a

# Load the NFL season and the last 21 NBA days, then create lines.
(cd backend && cargo run --release --bin worker -- backfill 21)

(cd app && flutter build web --release)
(cd backend && cargo run --release --bin api)      # http://localhost:8080
(cd backend && cargo run --release --bin worker)   # keep data, grading and contests current
```

Sign up with an email listed in `ADMIN_EMAILS` to get the admin screen
(Profile → Admin), where markets can be locked and settled with
`POST /v1/admin/settle-market`.

## Run in the iOS Simulator

Requires full Xcode (App Store) and CocoaPods (`brew install cocoapods`).

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS          # simulator runtime, if Xcode didn't install one
open -a Simulator                         # boots an iPhone
(cd app && flutter run -d iPhone)         # the API must be running on localhost:8080
```

The simulator reaches the Mac's `localhost`. For a real iPhone on the same
Wi-Fi, run the API with `PUBLIC_BASE_URL=http://<mac-ip>:8080` and the app with
`flutter run --dart-define=API_BASE=http://<mac-ip>:8080`.

## Export collected data

```sh
API=https://sportsswipe.fly.dev ADMIN_EMAIL=you@example.com ADMIN_PASSWORD=... python3 scripts/export_data.py
```

Writes `exports/<timestamp>/` with `users.csv`, `picks.csv` (one row per
leg), `contest_entries.csv`, `contest_answers.csv` and `stats.json`, and
prints the headline numbers. Admin accounts are left out of the stats.

## Tests

```sh
(cd backend && cargo test)
(cd app && flutter test)
python3 scripts/e2e_milestone.py
(cd scripts && python3 smoke_features.py)
```

## Deploy (Fly.io + Tiger Cloud)

See the header of `infra/fly.toml`. One image runs two processes: `app`
(the API and web build) and `worker`. Set `DATABASE_URL` to the Tiger Cloud
connection string with `sslmode=require`.
