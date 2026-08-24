#!/usr/bin/env bash
#
# backup.sh - create a verified, timestamped archive of a directory.
#
# This is the reference implementation for week 3. Every construct in it is
# taught in README.md, and it is the answer to "what does a script you would
# actually run as root at 3am look like?".
#
# Usage:  backup.sh [-o DEST] [-k KEEP] [-n] [-v] SOURCE
#
set -euo pipefail
IFS=$'\n\t'

readonly PROG=${0##*/}
LOCKFILE=/var/lock/${PROG%.sh}.lock

DEST=/opt/lab/backups
KEEP=7
DRY_RUN=0
VERBOSE=0

# --- logging -------------------------------------------------------------
# Everything goes to stderr so that stdout stays clean for actual output -
# a caller doing `ARCHIVE=$(backup.sh ...)` must not receive log lines.
log()  { printf '%s %-5s %s\n' "$(date -Is)" "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
dbg()  { (( VERBOSE )) && log DEBUG "$@" || true; }
die()  { err "$@"; exit 1; }

# show_cmd: render a command for logging.
#
# WHY THIS EXISTS - a genuine trap worth understanding. "$*" joins the
# positional parameters with the FIRST CHARACTER OF IFS. We set IFS=$'\n\t' at
# the top of this script, so "$*" would join the words with NEWLINES and every
# log line would explode into several. Setting IFS locally to a space fixes it,
# and `local` keeps the change scoped to this function.
show_cmd() {
  local IFS=' '
  printf '%s' "$*"
}

# run: execute, or merely describe the execution, when --dry-run is active.
run() {
  if (( DRY_RUN )); then
    info "DRY-RUN: $(show_cmd "$@")"
  else
    dbg "exec: $(show_cmd "$@")"
    "$@"
  fi
}

usage() {
  cat >&2 <<EOF
Usage: ${PROG} [options] SOURCE

Create a gzipped tar archive of SOURCE, verify it, and prune old copies.

Options:
  -o DEST   destination directory        (default: ${DEST})
  -k KEEP   number of archives to retain (default: ${KEEP})
  -n        dry run - show what would happen, change nothing
  -v        verbose
  -h        this help

Exit codes:
  0  success
  1  usage or precondition error
  2  archive creation failed
  3  archive verification failed
EOF
  exit "${1:-0}"
}

# --- cleanup -------------------------------------------------------------
# WORKDIR is created lazily, so the trap must cope with it not existing yet.
WORKDIR=''
cleanup() {
  local rc=$?                       # capture BEFORE anything else changes it
  if [[ -n ${WORKDIR} && -d ${WORKDIR} ]]; then
    rm -rf -- "${WORKDIR}"
  fi
  (( rc != 0 )) && err "${PROG} exited with status ${rc}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'err "interrupted"; exit 130' INT TERM

# --- argument parsing ----------------------------------------------------
while getopts ':o:k:nvh' opt; do
  case ${opt} in
    o) DEST=${OPTARG} ;;
    k) KEEP=${OPTARG} ;;
    n) DRY_RUN=1 ;;
    v) VERBOSE=1 ;;
    h) usage 0 ;;
    :)  die "option -${OPTARG} requires an argument (try -h)" ;;
    \?) die "unknown option -${OPTARG} (try -h)" ;;
  esac
done
shift $(( OPTIND - 1 ))

(( $# == 1 )) || usage 1
SOURCE=$1

# --- preconditions: fail early, fail loudly ------------------------------
[[ -d ${SOURCE} ]]        || die "source not found or not a directory: ${SOURCE}"
[[ -r ${SOURCE} ]]        || die "source not readable: ${SOURCE}"
[[ ${KEEP} =~ ^[0-9]+$ ]] || die "-k must be a non-negative integer, got: ${KEEP}"
(( KEEP >= 1 ))           || die "-k must be at least 1"

run mkdir -p "${DEST}"
if (( DRY_RUN == 0 )) && [[ ! -w ${DEST} ]]; then
  die "destination not writable: ${DEST}"
fi

# --- mutual exclusion ----------------------------------------------------
# flock releases automatically when the process dies, however it dies. A
# hand-rolled lockfile races between test and create, and leaves a stale lock
# behind after a crash - which then blocks every future run.
if (( DRY_RUN == 0 )); then
  if ! exec 9>"${LOCKFILE}" 2>/dev/null; then
    LOCKFILE=/tmp/${PROG%.sh}.lock      # fall back when not running as root
    exec 9>"${LOCKFILE}"
  fi
  flock -n 9 || die "another ${PROG} is already running (lock: ${LOCKFILE})"
  dbg "acquired lock ${LOCKFILE}"
fi

# --- do the work ---------------------------------------------------------
WORKDIR=$(mktemp -d)
STAMP=$(date +%Y%m%d-%H%M%S)
NAME="backup-${STAMP}.tar.gz"
STAGING="${WORKDIR}/${NAME}"
FINAL="${DEST}/${NAME}"

info "archiving ${SOURCE} -> ${FINAL}"

# Build into a temporary file, then move into place. A consumer must never see
# a half-written archive, and mv within one filesystem is atomic.
# -C makes the stored paths relative, so a restore does not try to recreate
# /opt/lab/data/... from the filesystem root.
src_parent=$(dirname -- "${SOURCE}")
src_base=$(basename -- "${SOURCE}")

if (( DRY_RUN )); then
  info "DRY-RUN: tar -czf ${STAGING} -C ${src_parent} ${src_base}"
else
  if ! tar -czf "${STAGING}" -C "${src_parent}" "${src_base}"; then
    err "tar failed"
    exit 2
  fi
fi

# --- verify: the step that separates a backup from a hope ----------------
if (( DRY_RUN == 0 )); then
  [[ -s ${STAGING} ]] || { err "archive is empty"; exit 3; }

  if ! tar -tzf "${STAGING}" >/dev/null 2>&1; then
    err "archive failed its integrity check"
    exit 3
  fi

  entries=$(tar -tzf "${STAGING}" | wc -l)
  (( entries > 0 )) || { err "archive contains no entries"; exit 3; }

  size=$(stat -c%s "${STAGING}")
  info "verified: ${entries} entries, ${size} bytes"

  mv -- "${STAGING}" "${FINAL}"
  # A checksum next to the archive lets a future restore prove the file is
  # intact without unpacking it.
  ( cd "${DEST}" && sha256sum "${NAME}" > "${NAME}.sha256" )
fi

# --- retention -----------------------------------------------------------
# Sorting by name is also sorting by time, because the timestamp format is
# lexicographically ordered. That is precisely why that format was chosen.
mapfile -t archives < <(
  find "${DEST}" -maxdepth 1 -name 'backup-*.tar.gz' -printf '%f\n' 2>/dev/null | sort
)
total=${#archives[@]}

if (( total > KEEP )); then
  prune=$(( total - KEEP ))
  info "retaining ${KEEP} of ${total}; pruning ${prune}"
  for (( i = 0; i < prune; i++ )); do
    run rm -f -- "${DEST}/${archives[i]}" "${DEST}/${archives[i]}.sha256"
  done
else
  dbg "retention: ${total} archive(s), keep=${KEEP}, nothing to prune"
fi

info "done"
# stdout receives exactly one thing: the artefact path, so callers can use it.
(( DRY_RUN )) || printf '%s\n' "${FINAL}"
