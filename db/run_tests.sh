#!/usr/bin/env bash
# Week 1 exit test: books, cancels and completes sessions purely through the
# package API and asserts the balances afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

db_wait_for_ready 12
db_script tests/run_all.sql
