#!/usr/bin/env bash
#
# healthcheck.sh - probe a list of HTTP endpoints and report status.
#
# Demonstrates: arrays, associative arrays, process substitution instead of a
# pipeline-subshell, retry with backoff, machine-readable output, and an exit
# code that means something to a caller (a cron job, a monitor, a CI step).
#
# Usage:  healthcheck.sh [-t TIMEOUT] [-r RETRIES] [-j] URL [URL...]
#         healthcheck.sh -f targets.txt
#
set -euo pipefail

readonly PROG=${0##*/}
TIMEOUT=3
RETRIES=2
JSON=0
TARGET_FILE=''

log() { printf '%s %-5s %s\n' "$(date -Is)" "$1" "${*:2}" >&2; }
err() { log ERROR "$@"; }
die() { err "$@"; exit 2; }

usage() {
  cat >&2 <<EOF
Usage: ${PROG} [-t TIMEOUT] [-r RETRIES] [-j] URL [URL...]
       ${PROG} [-t TIMEOUT] [-r RETRIES] [-j] -f FILE

  -t TIMEOUT  per-attempt timeout in seconds (default: ${TIMEOUT})
  -r RETRIES  retries after the first attempt (default: ${RETRIES})
  -f FILE     read targets from FILE, one URL per line, # for comments
  -j          emit JSON instead of a table
  -h          this help

Exit: 0 all healthy | 1 at least one unhealthy | 2 usage error
EOF
  exit "${1:-0}"
}

while getopts ':t:r:f:jh' opt; do
  case ${opt} in
    t) TIMEOUT=${OPTARG} ;;
    r) RETRIES=${OPTARG} ;;
    f) TARGET_FILE=${OPTARG} ;;
    j) JSON=1 ;;
    h) usage 0 ;;
    :)  die "option -${OPTARG} requires an argument" ;;
    \?) die "unknown option -${OPTARG}" ;;
  esac
done
shift $(( OPTIND - 1 ))

[[ ${TIMEOUT} =~ ^[0-9]+$ ]] || die "-t must be an integer"
[[ ${RETRIES} =~ ^[0-9]+$ ]] || die "-r must be an integer"

# --- collect targets -----------------------------------------------------
declare -a targets=()

if [[ -n ${TARGET_FILE} ]]; then
  [[ -r ${TARGET_FILE} ]] || die "cannot read target file: ${TARGET_FILE}"
  # The canonical read loop: IFS= to keep whitespace, -r to keep backslashes,
  # and redirection rather than a pipe so no subshell eats our array.
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%%#*}                 # strip comments
    line=${line//[[:space:]]/}       # strip all whitespace
    [[ -n ${line} ]] && targets+=("${line}")
  done < "${TARGET_FILE}"
fi

targets+=("$@")

# ${arr[@]} on an EMPTY array is an unbound-variable error under `set -u` in
# older bash. Always guard on the length first.
(( ${#targets[@]} > 0 )) || usage 2

# --- probe ---------------------------------------------------------------
declare -A status_of=()
declare -A latency_of=()
failures=0

probe() {
  local url=$1 attempt=0 delay=1 code='' t=''

  while (( attempt <= RETRIES )); do
    # -o /dev/null   discard the body
    # -w             emit exactly the fields we want, in a parseable form
    # --max-time     hard cap on the whole request
    if out=$(curl -sS -o /dev/null \
                  -w '%{http_code} %{time_total}' \
                  --max-time "${TIMEOUT}" \
                  "${url}" 2>/dev/null); then
      code=${out%% *}
      t=${out##* }
      # 2xx and 3xx count as healthy; adjust if your service says otherwise.
      if [[ ${code} =~ ^[23] ]]; then
        printf '%s %s\n' "${code}" "${t}"
        return 0
      fi
    fi

    # NOT `(( attempt++ ))`. An arithmetic command's exit status is 1 when the
    # expression EVALUATES TO ZERO, and post-increment evaluates to the OLD
    # value - which is 0 on the first pass. Under `set -e` that silently kills
    # the script. This is one of the most infuriating bugs in bash; see
    # README.md Day 1. Plain assignment has no such surprise.
    attempt=$(( attempt + 1 ))
    if (( attempt <= RETRIES )); then
      # Exponential backoff. Retrying instantly just multiplies the load on a
      # service that is already struggling - which is how a blip becomes an
      # outage. This is the same reasoning behind RandomizedDelaySec in a timer.
      sleep "${delay}"
      delay=$(( delay * 2 ))
    fi
  done

  printf '%s %s\n' "${code:-000}" "${t:-0}"
  return 1
}

for url in "${targets[@]}"; do
  if result=$(probe "${url}"); then
    status_of[${url}]=${result%% *}
    latency_of[${url}]=${result##* }
  else
    status_of[${url}]=${result%% *}
    latency_of[${url}]=${result##* }
    failures=$(( failures + 1 ))    # see the note in probe() about (( x++ ))
  fi
done

# --- report --------------------------------------------------------------
if (( JSON )); then
  # Hand-rolled JSON is acceptable for this shape and this shape only. The
  # moment the output has nesting or user-controlled strings in it, use python
  # or jq -n - see week 6.
  printf '{"checked":%d,"failed":%d,"results":[' "${#targets[@]}" "${failures}"
  first=1
  for url in "${targets[@]}"; do
    (( first )) || printf ','
    first=0
    code=${status_of[${url}]}
    healthy=$([[ ${code} =~ ^[23] ]] && echo true || echo false)
    printf '{"url":"%s","code":"%s","seconds":%s,"healthy":%s}' \
      "${url}" "${code}" "${latency_of[${url}]}" "${healthy}"
  done
  printf ']}\n'
else
  printf '%-45s %-6s %-9s %s\n' URL CODE SECONDS STATUS
  for url in "${targets[@]}"; do
    code=${status_of[${url}]}
    if [[ ${code} =~ ^[23] ]]; then state=OK; else state=FAIL; fi
    printf '%-45s %-6s %-9s %s\n' "${url}" "${code}" "${latency_of[${url}]}" "${state}"
  done
fi

# The exit code is the API. A monitor, a cron job or a CI step reads this, not
# your pretty table.
(( failures == 0 )) || exit 1
