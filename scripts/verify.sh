#!/usr/bin/env bash
# =============================================================================
# Runs everything that can be run without an Azure subscription, in order, and
# says plainly what passed.
#
#   ./scripts/verify.sh                 the whole thing
#   ./scripts/verify.sh --db-only       schema, packages and the SQL suites
#   ./scripts/verify.sh --skip-build    skip the .NET build and tests
#
# This is the command that turns "written" into "runs". Until it passes end to
# end, docs/build-status.md should keep saying nothing has been executed.
#
# Fail-fast on purpose: the later stages are meaningless if the schema did not
# install, and a wall of cascading failures hides the one that matters.
# =============================================================================
# -E so the ERR trap is inherited by functions and subshells; without it a
# failure inside one of them skips the summary and exits bare.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

DB_ONLY=0
SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --db-only)    DB_ONLY=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

PASSED=()
START_TIME="$SECONDS"

stage() {
    printf '\n\033[1m==> %s\033[0m\n' "$1"
}

record() {
    PASSED+=("$1")
}

summary_and_exit() {
    local status="$1"
    local failed_stage="${2:-}"
    local elapsed=$((SECONDS - START_TIME))

    printf '\n\033[1m%s\033[0m\n' "-----------------------------------------------"
    for p in "${PASSED[@]:-}"; do
        [[ -n "$p" ]] && printf '  \033[32mpassed\033[0m  %s\n' "$p"
    done

    if [[ -n "$failed_stage" ]]; then
        printf '  \033[31mFAILED\033[0m  %s\n' "$failed_stage"
    fi
    printf '  %ds elapsed\n' "$elapsed"
    printf '\033[1m%s\033[0m\n' "-----------------------------------------------"

    if [[ "$status" -eq 0 ]]; then
        cat <<'EOF'

  Everything green. Two things worth doing now:

    * update docs/build-status.md -- the "Has it been run?" section is
      currently written on the assumption that nothing has
    * cd db && ./seed.sh, then start the API and UI to see it with data
EOF
    fi

    exit "$status"
}

trap 'summary_and_exit 1 "${CURRENT_STAGE:-unknown}"' ERR

# -----------------------------------------------------------------------------
CURRENT_STAGE="docker availability"
stage "Checking Docker"
if ! docker info >/dev/null 2>&1; then
    echo "Docker is not usable by this user." >&2
    echo "Run ./scripts/bootstrap-ubuntu.sh, then log out and back in." >&2
    summary_and_exit 1 "$CURRENT_STAGE"
fi
record "docker is usable"

# -----------------------------------------------------------------------------
CURRENT_STAGE="oracle container"
stage "Starting Oracle"
cd "$HERE/db"

ORACLE_IMAGE="gvenzl/oracle-xe:21-slim"

# Pull as its own step, with retries. The image is around 2GB and a single
# reset partway through fails the whole `up`. Docker keeps the layers it has
# already completed, so a retry resumes rather than starting over -- which makes
# retrying much cheaper than it looks.
if ! docker image inspect "$ORACLE_IMAGE" >/dev/null 2>&1; then
    echo "Pulling $ORACLE_IMAGE (~2GB). Completed layers are kept between attempts."
    PULL_OK=0
    for attempt in 1 2 3 4 5; do
        if docker compose pull; then
            PULL_OK=1
            break
        fi
        echo "  attempt $attempt failed; retrying in $((attempt * 10))s"
        sleep $((attempt * 10))
    done

    if (( PULL_OK == 0 )); then
        cat >&2 <<'EOF'

Could not pull the image after 5 attempts.

If the errors showed IPv6 addresses and "connection reset by peer", the pull is
going out over a broken or MTU-limited IPv6 path. Preferring IPv4 usually fixes
it outright:

    echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf
    sudo systemctl restart docker

See docs/running-on-ubuntu-server.md for the rest.
EOF
        summary_and_exit 1 "$CURRENT_STAGE"
    fi
fi

if [[ "$(docker inspect -f '{{.State.Running}}' tutoring-oracle 2>/dev/null)" == "true" ]]; then
    echo "Container already running."
else
    docker compose up -d
    echo "First boot creates the database and takes a few minutes."
fi

# The compose healthcheck is the authority on readiness; polling it beats
# guessing with sleep. The ceiling is 40 minutes because first boot on a
# spinning disk genuinely can take that long -- see the note in
# docker-compose.yml.
WAIT_MINUTES="${ORACLE_WAIT_MINUTES:-40}"
echo "Waiting for the healthcheck (up to ${WAIT_MINUTES}m; first boot on a spinning disk is slow)."
WAITED=0
for i in $(seq 1 $((WAIT_MINUTES * 6))); do
    health="$(docker inspect -f '{{.State.Health.Status}}' tutoring-oracle 2>/dev/null || echo unknown)"
    if [[ "$health" == "healthy" ]]; then
        echo "  healthy after ${WAITED}m."
        break
    fi
    # Bail early on a container that has actually died, rather than waiting out
    # the full 40 minutes for something that is never coming back.
    if [[ "$(docker inspect -f '{{.State.Running}}' tutoring-oracle 2>/dev/null)" != "true" ]]; then
        echo
        echo "The container stopped. Last logs:" >&2
        docker logs --tail 40 tutoring-oracle >&2 || true
        summary_and_exit 1 "$CURRENT_STAGE"
    fi
    if (( i % 6 == 0 )); then
        WAITED=$((i / 6))
        echo "  ${WAITED}m elapsed, status: $health"
    fi
    sleep 10
done

if [[ "$(docker inspect -f '{{.State.Health.Status}}' tutoring-oracle 2>/dev/null)" != "healthy" ]]; then
    echo
    echo "Oracle did not become healthy. Recent logs:" >&2
    docker logs --tail 40 tutoring-oracle >&2 || true
    summary_and_exit 1 "$CURRENT_STAGE"
fi
record "oracle is healthy"

# -----------------------------------------------------------------------------
CURRENT_STAGE="schema and packages"
stage "Installing the schema and packages"
chmod +x ./*.sh
./install.sh
record "schema and packages installed, every package VALID"

# -----------------------------------------------------------------------------
CURRENT_STAGE="business rule suite"
stage "Business rule suite"
./run_tests.sh
record "business rule suite"

# -----------------------------------------------------------------------------
CURRENT_STAGE="concurrency suite"
stage "Concurrency suite"
./run_concurrency.sh
record "concurrency suite"

if (( DB_ONLY == 1 )); then
    summary_and_exit 0
fi

# -----------------------------------------------------------------------------
cd "$HERE"

if (( SKIP_BUILD == 1 )); then
    summary_and_exit 0
fi

CURRENT_STAGE="dotnet sdk"
stage "Checking the .NET SDK"
if ! command -v dotnet >/dev/null 2>&1; then
    echo "dotnet is not on PATH. Run ./scripts/bootstrap-ubuntu.sh." >&2
    summary_and_exit 1 "$CURRENT_STAGE"
fi
dotnet --version
record "dotnet sdk present"

CURRENT_STAGE="dotnet build"
stage "Building the solution"
dotnet build src/TutoringOps.sln --configuration Release
record "solution builds"

CURRENT_STAGE="dotnet test"
stage "Integration tests"
# These talk to the Oracle started above. They skip themselves when it is
# unreachable, so watch for skips rather than assuming green means covered.
dotnet test src/TutoringOps.sln --configuration Release --no-build --verbosity normal
record "integration tests"

summary_and_exit 0
