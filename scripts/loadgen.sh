#!/usr/bin/env bash
# Mixed traffic against a running API so the Kibana dashboards have shape:
# cacheable content reads, the public leaderboard, unauthenticated calls to
# protected routes (401s), and unknown paths (404s).
#
#   scripts/loadgen.sh [base_url] [requests]
set -euo pipefail

BASE="${1:-http://localhost:8000}"
N="${2:-300}"

paths=(
  /v1/health
  /v1/content/version
  /v1/content/stages
  /v1/content/exam-dates
  /v1/leaderboards/public/xp
  /v1/leaderboards/public/weekly_xp
  /v1/leaderboards/public/zombies_slain
  /v1/me
  /v1/me/state
  /v1/does-not-exist
)

for ((i = 1; i <= N; i++)); do
  p="${paths[RANDOM % ${#paths[@]}]}"
  curl -s -o /dev/null -w "%{http_code} $p\n" "$BASE$p" &
  (( i % 20 == 0 )) && wait
done | sort | uniq -c | sort -rn
wait
