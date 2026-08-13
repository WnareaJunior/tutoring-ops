#!/usr/bin/env bash
# =============================================================================
# Drive the Ubuntu server from a laptop.
#
# The working tree lives here; Oracle and .NET live there. This syncs the tree
# and runs things on the far end, so an agent (or a person) editing locally can
# execute remotely without thinking about it.
#
#   ./scripts/remote.sh sync                 push the working tree
#   ./scripts/remote.sh run '<command>'      sync, then run in the repo, blocking
#   ./scripts/remote.sh install              sync, then db/install.sh
#   ./scripts/remote.sh tests                sync, then db/run_tests.sh
#   ./scripts/remote.sh concurrency          sync, then db/run_concurrency.sh
#   ./scripts/remote.sh verify               sync, then verify.sh -- DETACHED
#   ./scripts/remote.sh log [name]           follow a detached run's output
#   ./scripts/remote.sh tail [name] [lines]  last N lines, does not block
#   ./scripts/remote.sh status [name]        is it still running
#   ./scripts/remote.sh shell                interactive session on the server
#
# Long jobs run detached in tmux and tee to a log, so a dropped connection --
# or a tool timeout on a 20 minute build -- cannot kill them. Start it, then
# poll with `tail`.
#
# Override the target:
#   export TUTORING_REMOTE=user@host
#   export TUTORING_REMOTE_DIR=tutoring-ops
#
# Worth setting up connection reuse first, or every call pays a fresh TCP and
# TLS handshake. In ~/.ssh/config on the laptop:
#
#   Host wilsserver
#       HostName <address>
#       User wnarea
#       ControlMaster auto
#       ControlPath ~/.ssh/cm-%r@%h:%p
#       ControlPersist 10m
#
# That turns each subsequent command from roughly a second into roughly nothing,
# which matters a lot when an agent is making hundreds of them.
# =============================================================================
set -euo pipefail

# devbox is the desktop dev server (WSL2 behind Tailscale; see the connection
# doc). wilsserver -- the Azure VM -- still exists but only to serve Oracle to
# the deployed API: export TUTORING_REMOTE=wnarea@wilsserver to target it.
REMOTE="${TUTORING_REMOTE:-wnarea@devbox}"
REMOTE_DIR="${TUTORING_REMOTE_DIR:-tutoring-ops}"

# The .NET SDK on devbox is a user-local install (WSL sudo wants a password,
# which a non-interactive session cannot give), and non-interactive ssh never
# reads .bashrc -- so put it on PATH here.
DOTNET_PATH='PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"'

HERE="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

sync_tree() {
    # --delete so a file removed locally is removed there too; without it a
    # renamed SQL file leaves its old copy behind and install.sh runs both.
    #
    # .git is excluded because the laptop is the source of truth and the server
    # copy is a build target, not a clone to commit from. bin/obj are excluded
    # so a local build does not fight the remote one over stale artifacts.
    rsync -az --delete \
        --exclude '.git/' \
        --exclude 'bin/' \
        --exclude 'obj/' \
        --exclude '**/local.settings.json' \
        --exclude '**/appsettings.Local.json' \
        "$HERE/" "$REMOTE:$REMOTE_DIR/"
}

remote_run() {
    # -t so colour and progress output survive the hop.
    ssh -t "$REMOTE" "cd '$REMOTE_DIR' && export $DOTNET_PATH && $1"
}

# Detached: survives this SSH session ending, and can be polled.
remote_bg() {
    local name="$1"
    local command="$2"
    local log="/tmp/tutoring-$name.log"

    ssh "$REMOTE" "tmux kill-session -t '$name' 2>/dev/null || true"
    ssh "$REMOTE" "cd '$REMOTE_DIR' && tmux new -d -s '$name' \
        \"export $DOTNET_PATH; ($command) 2>&1 | tee '$log'\""

    echo "Started '$name' on $REMOTE, logging to $log"
    echo
    echo "  ./scripts/remote.sh tail   $name      last lines, returns immediately"
    echo "  ./scripts/remote.sh log    $name      follow it"
    echo "  ./scripts/remote.sh status $name      still running?"
}

case "${1:-}" in
    sync)
        sync_tree
        echo "Synced to $REMOTE:$REMOTE_DIR"
        ;;

    run)
        [[ $# -ge 2 ]] || { echo "run needs a command" >&2; exit 2; }
        sync_tree
        remote_run "$2"
        ;;

    install)
        sync_tree
        remote_run "chmod +x db/*.sh scripts/*.sh && ./db/install.sh"
        ;;

    tests)
        sync_tree
        remote_run "./db/run_tests.sh"
        ;;

    concurrency)
        sync_tree
        remote_run "./db/run_concurrency.sh"
        ;;

    seed)
        sync_tree
        remote_run "./db/seed.sh"
        ;;

    # The full run can take 20+ minutes, so it is detached by default.
    verify)
        sync_tree
        remote_bg "verify" "chmod +x db/*.sh scripts/*.sh && ./scripts/verify.sh"
        ;;

    build)
        sync_tree
        remote_bg "build" "dotnet build src/TutoringOps.sln --configuration Release"
        ;;

    log)
        ssh -t "$REMOTE" "tail -f '/tmp/tutoring-${2:-verify}.log'"
        ;;

    tail)
        ssh "$REMOTE" "tail -n '${3:-60}' '/tmp/tutoring-${2:-verify}.log'"
        ;;

    status)
        name="${2:-verify}"
        if ssh "$REMOTE" "tmux has-session -t '$name' 2>/dev/null"; then
            echo "'$name' is still running"
        else
            echo "'$name' has finished (or never started)"
        fi
        ;;

    logs)
        ssh "$REMOTE" "docker logs --tail '${2:-50}' tutoring-oracle"
        ;;

    shell)
        ssh -t "$REMOTE" "cd '$REMOTE_DIR' && exec \$SHELL -l"
        ;;

    ""|-h|--help|help)
        usage 0
        ;;

    *)
        echo "Unknown command: $1" >&2
        usage 2
        ;;
esac
