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
