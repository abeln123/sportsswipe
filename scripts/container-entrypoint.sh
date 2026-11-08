#!/bin/sh
set -eu
if [ "${1:-api}" = "api" ] && [ "${COLLECTIBLES_ENABLED:-false}" = "true" ]; then
  : "${COLLECTIBLES_SERVICE_KEY:?Set the private collectibles service key}"
  export COLLECTIBLES_SERVICE_URL=http://127.0.0.1:8091
  node /srv/collectibles/src/server.mjs &
fi
exec "$@"
