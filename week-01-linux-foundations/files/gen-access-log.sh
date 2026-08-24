#!/usr/bin/env bash
# Generates a synthetic nginx-style access log for text-processing practice.
#   bash gen-access-log.sh [lines] > access.log
# Deterministic by default (fixed RANDOM seed) so that everyone in a cohort gets
# the same answers and can compare pipelines.
set -euo pipefail
N=${1:-5000}
RANDOM=42

IPS=(10.0.0.11 10.0.0.12 10.0.0.13 10.0.0.14 203.0.113.7 192.0.2.55)
PATHS=(/ /login /api/users /api/users/42 /api/orders /static/app.js /static/logo.png /health /api/search /admin)
METHODS=(GET GET GET GET GET POST POST PUT DELETE)
# Weighted so the error rate lands around 5%, like a real service. A log where
# 45% of requests fail teaches you nothing about finding a needle in a haystack.
CODES=(200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200
       200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200
       301 301 304 304 304 400 401 403 404 404 500 502 503)
AGENTS=("Mozilla/5.0 (X11; Linux x86_64)" "curl/8.5.0" "kube-probe/1.29" "Googlebot/2.1")

# One client behaves badly: a scanner probing paths that do not exist, plus a
# broken integration hammering a 500. It is a small fraction of total traffic -
# which is the point. Finding it is challenge C1.1 #9, and finding the one bad
# client inside mostly-healthy traffic is the actual skill.
SCANNER=198.51.100.23
SCAN_PATHS=(/admin /wp-login.php /.env /api/v1/internal /backup.zip)
SCAN_CODES=(404 404 404 404 403 403 401 500 200 200)   # ~70% errors, not 100%

for ((i=0; i<N; i++)); do
  ip=${IPS[$((RANDOM % ${#IPS[@]}))]}
  path=${PATHS[$((RANDOM % ${#PATHS[@]}))]}
  method=${METHODS[$((RANDOM % ${#METHODS[@]}))]}
  code=${CODES[$((RANDOM % ${#CODES[@]}))]}

  # every ~13th request comes from the scanner, with its own bad-status profile
  if (( i % 19 == 0 )); then
    ip=$SCANNER
    path=${SCAN_PATHS[$((RANDOM % ${#SCAN_PATHS[@]}))]}
    code=${SCAN_CODES[$((RANDOM % ${#SCAN_CODES[@]}))]}
  fi
  bytes=$((RANDOM % 20000 + 120))
  # spread timestamps over one day
  ts=$(date -u -d "2026-03-01 00:00:00 UTC + $((i * 17)) seconds" '+%d/%b/%Y:%H:%M:%S +0000')
  agent=${AGENTS[$((RANDOM % ${#AGENTS[@]}))]}
  printf '%s - - [%s] "%s %s HTTP/1.1" %s %s "-" "%s"\n' \
    "$ip" "$ts" "$method" "$path" "$code" "$bytes" "$agent"
done
