#!/usr/bin/env bash
#
# smoke-test.sh - verify a deployment by doing what a USER does.
#
# A pipeline that goes green because `docker service update` returned 0 has
# verified nothing. This script is the difference between "the deploy command
# succeeded" and "the application works".
#
#   ./smoke-test.sh https://app.lab.local [expected_version]
#
set -euo pipefail

BASE=${1:?usage: smoke-test.sh <BASE_URL> [expected_version]}
EXPECT_VERSION=${2:-}
TIMEOUT=${TIMEOUT:-10}
SETTLE=${SETTLE:-30}          # allow a rolling update to finish before judging

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$(( fail + 1 )); }

echo "smoke test against ${BASE}"

# --- 1. wait for the deployment to settle ---------------------------------
# During a rolling update BOTH versions are live. Judging immediately gives a
# flaky pipeline that fails for reasons unrelated to the change.
printf 'waiting up to %ss for health...' "$SETTLE"
deadline=$(( SECONDS + SETTLE ))
until curl -sf -m "$TIMEOUT" -o /dev/null "${BASE}/health"; do
  (( SECONDS < deadline )) || { echo; bad "never became healthy within ${SETTLE}s"; exit 1; }
  printf '.'; sleep 2
done
echo ' up'

# --- 2. the endpoints a user actually hits --------------------------------
code=$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "${BASE}/") || code=000
[[ $code == 200 ]] && ok "GET / -> 200" || bad "GET / -> ${code}"

code=$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "${BASE}/items") || code=000
[[ $code == 200 ]] && ok "GET /items -> 200" || bad "GET /items -> ${code}"

# --- 3. is it the version we just shipped? --------------------------------
# Without this, a failed deploy that left the OLD version running looks like a
# successful deploy. This is the check that catches a silent no-op.
if [[ -n $EXPECT_VERSION ]]; then
  actual=$(curl -sf -m "$TIMEOUT" "${BASE}/" | grep -oP '"version"\s*:\s*"\K[^"]+' || echo unknown)
  [[ $actual == "$EXPECT_VERSION" ]] \
    && ok "version is ${actual}" \
    || bad "expected version ${EXPECT_VERSION}, got ${actual}"
fi

# --- 4. latency has not collapsed ------------------------------------------
total=$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{time_total}' "${BASE}/items" || echo 99)
if awk -v t="$total" 'BEGIN{exit !(t < 2.0)}'; then
  ok "latency ${total}s"
else
  bad "latency ${total}s exceeds 2s"
fi

# --- 5. errors are not being served ----------------------------------------
errors=0
for _ in $(seq 1 20); do
  c=$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "${BASE}/items") || c=000
  [[ $c == 200 ]] || errors=$(( errors + 1 ))
done
(( errors == 0 )) && ok "20/20 requests succeeded" || bad "${errors}/20 requests failed"

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
# The exit code is the API - the pipeline reads this, not the pretty output.
(( fail == 0 )) || exit 1
