# One image, two Fly processes: `api` serves the HTTP API and the Flutter web
# build; `worker` runs ESPN ingestion, grading and contest jobs.

FROM node:22-bookworm-slim AS collectibles
WORKDIR /src/collectibles
COPY collectibles/package.json collectibles/package-lock.json ./
RUN npm ci
COPY collectibles/web ./web
RUN npm run build
RUN npm prune --omit=dev
COPY collectibles/src ./src

FROM debian:bookworm-slim AS web
ARG FLUTTER_VERSION=3.47.9
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /flutter
ENV PATH=/flutter/bin:$PATH
RUN flutter config --no-analytics && flutter precache --web
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
COPY --from=collectibles /src/app/web/collectibles/app.js ./web/collectibles/app.js
COPY --from=collectibles /src/app/web/collectibles/wallet.js ./web/collectibles/wallet.js
RUN flutter build web --release

FROM rust:1-bookworm AS server
WORKDIR /src/backend
COPY backend/ ./
RUN cargo build --release --locked --bin api --bin worker

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /srv
COPY --from=server /src/backend/target/release/api /usr/local/bin/api
COPY --from=server /src/backend/target/release/worker /usr/local/bin/worker
COPY --from=web /src/app/build/web /srv/web
COPY --from=collectibles /usr/local/bin/node /usr/local/bin/node
COPY --from=collectibles /src/collectibles/node_modules /srv/collectibles/node_modules
COPY --from=collectibles /src/collectibles/src /srv/collectibles/src
COPY collectibles/package.json /srv/collectibles/package.json
COPY --chmod=755 scripts/container-entrypoint.sh /usr/local/bin/sportsswipe-entrypoint
ENV STATIC_DIR=/srv/web \
    PORT=8080 \
    COOKIE_SECURE=true \
    RUST_LOG=info,sqlx=warn
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/sportsswipe-entrypoint"]
CMD ["api"]
