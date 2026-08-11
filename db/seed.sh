#!/usr/bin/env bash
# Loads the demo dataset. Destructive: clears every transactional table first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

db_wait_for_ready 12
db_script seed/seed_demo.sql
