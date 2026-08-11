#!/usr/bin/env bash
# Shared connection plumbing for the db scripts.
#
# Works two ways, in this order:
#   1. sqlplus on PATH  -> talks to $ORACLE_HOST_DSN directly
#   2. otherwise        -> runs sqlplus inside the compose container
#
# Override any of these with environment variables; the defaults match
# docker-compose.yml.
set -euo pipefail

ORACLE_CONTAINER="${ORACLE_CONTAINER:-tutoring-oracle}"
ORACLE_APP_USER="${ORACLE_APP_USER:-tutoring}"
ORACLE_APP_PASSWORD="${ORACLE_APP_PASSWORD:-TutorPw1}"
ORACLE_SERVICE="${ORACLE_SERVICE:-XEPDB1}"
ORACLE_HOST="${ORACLE_HOST:-localhost}"
ORACLE_PORT="${ORACLE_PORT:-1521}"

# Inside the container the listener is always on localhost:1521.
ORACLE_HOST_DSN="${ORACLE_APP_USER}/${ORACLE_APP_PASSWORD}@${ORACLE_HOST}:${ORACLE_PORT}/${ORACLE_SERVICE}"
ORACLE_IN_DSN="${ORACLE_APP_USER}/${ORACLE_APP_PASSWORD}@localhost:1521/${ORACLE_SERVICE}"

if command -v sqlplus >/dev/null 2>&1; then
  DB_MODE="native"
else
  DB_MODE="docker"
fi

# Pipe SQL in on stdin. Note that @@ relative includes do not work this way --
# use db_script for anything that includes another file.
db_exec() {
  if [[ "$DB_MODE" == "native" ]]; then
    sqlplus -S "$ORACLE_HOST_DSN"
  else
    docker exec -i "$ORACLE_CONTAINER" sqlplus -S "$ORACLE_IN_DSN"
  fi
}

# Run a script by path. Argument is repo-relative from the db/ directory,
# e.g. db_script migrations/01_schema.sql
db_script() {
  local rel="$1"
  if [[ "$DB_MODE" == "native" ]]; then
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '@%s/%s\nexit\n' "$here" "$rel" | sqlplus -S "$ORACLE_HOST_DSN"
  else
    # ./ is mounted at /db by docker-compose.
    printf '@/db/%s\nexit\n' "$rel" | docker exec -i "$ORACLE_CONTAINER" \
      sqlplus -S "$ORACLE_IN_DSN"
  fi
}

db_wait_for_ready() {
  local attempts="${1:-60}"
  echo "Waiting for Oracle to accept connections..."
  for ((i = 1; i <= attempts; i++)); do
    if printf 'SELECT 1 FROM DUAL;\nexit\n' | db_exec >/dev/null 2>&1; then
      echo "Oracle is ready (mode: $DB_MODE)."
      return 0
    fi
    sleep 5
  done
  echo "Oracle did not become ready after $((attempts * 5))s." >&2
  return 1
}
