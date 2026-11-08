# One image, two Fly processes: `api` serves the HTTP API and the Flutter web
# build; `worker` runs ESPN ingestion, grading and contest jobs.

FROM ghcr.io/cirruslabs/flutter:3.47.9 AS web
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release

FROM rust:1-bookworm AS server
WORKDIR /src/backend
COPY backend/ ./
RUN cargo build --release --locked --bin api --bin worker

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /srv
COPY --from=server /src/backend/target/release/api /usr/local/bin/api
COPY --from=server /src/backend/target/release/worker /usr/local/bin/worker
COPY --from=web /src/app/build/web /srv/web
ENV STATIC_DIR=/srv/web \
    PORT=8080 \
    COOKIE_SECURE=true \
    RUST_LOG=info,sqlx=warn
EXPOSE 8080
CMD ["api"]
