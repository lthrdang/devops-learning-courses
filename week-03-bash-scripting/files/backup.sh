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
  # WHY THE BRACES - a second trap, and a nastier one than show_cmd's. `exec`
  # with redirections and NO command applies those redirections to the current
  # shell, permanently. Written as `exec 9>"${LOCKFILE}" 2>/dev/null` the
  # 2>/dev/null is not a one-off silencer for this line: it rebinds fd 2 for the
  # whole rest of the run, and every log call after it - including the die()
  # below that explains why we are giving up - is thrown away. The script then
  # exits 1 with no output at all, which is the worst possible failure mode for
  # something you run unattended at 3am. Wrapping the exec in a group confines
  # the 2>/dev/null to the group, so it hides only the error message from THIS
  # redirection and leaves stderr intact afterwards.
  if ! { exec 9>"${LOCKFILE}"; } 2>/dev/null; then
    LOCKFILE=/tmp/${PROG%.sh}.lock      # fall back when not running as root
    exec 9>"${LOCKFILE}"
  fi
  flock -n 9 || die "another ${PROG} is already running (lock: ${LOCKFILE})"
  dbg "acquired lock ${LOCKFILE}"
fi

# --- do the work ---------------------------------------------------------
# WHY THE STAGING DIRECTORY LIVES UNDER ${DEST} AND NOT IN /tmp.
#
# The publish step below is a rename, and the reason it is a rename is that
# rename(2) is atomic: a consumer polling ${DEST} sees the archive either not at
# all or complete, never half-written. But that guarantee has a precondition -
# rename(2) only works WITHIN A SINGLE FILESYSTEM. Across filesystems the kernel
# returns EXDEV, and `mv` quietly falls back to open-create-copy-unlink: a
# streaming copy, during which the destination path exists and is short. Every
# property we wanted is gone, and nothing warns you, because `mv` still exits 0.
#
# A bare `mktemp -d` puts the staging area in ${TMPDIR:-/tmp}, and ${DEST} is
# caller-supplied via -o. Assuming those share a filesystem is a bet you lose
# routinely: TMPDIR set to a scratch volume; a tmpfs /tmp (the default on many
# images); systemd's PrivateTmp=true, which this course TEACHES in week 2 as
# baseline unit hardening and which gives the service a private /tmp on its own
# mount; an NFS or separate volume mounted at the backup target; /opt on its own
# LV. Any one of them silently downgrades the atomic publish to a visible copy.
#
# Worse, the failure is not merely non-atomic. If the process is killed mid-copy,
# the EXIT trap removes WORKDIR but the truncated file already sitting at ${FINAL}
# is not WORKDIR's - it survives, it matches the retention glob, and the next run
# counts that corpse as a good backup and prunes a real one to make room for it.
#
# Staging inside ${DEST} removes the whole class of problem by construction: the
# staging directory and the final path are on the same filesystem BECAUSE the
# staging directory is inside the final path's directory. The leading dot keeps it
# out of casual `ls`, and the name deliberately does not match the retention glob
# 'backup-*.tar.gz', so a concurrent run's retention pass can never see it.
#
# The cost is that ${DEST} must hold the archive twice for a moment. That is the
# correct trade: transient double space is a capacity problem you can measure,
# and a half-published backup is a correctness problem you discover during a
# restore.
STAMP=$(date +%Y%m%d-%H%M%S)
NAME="backup-${STAMP}.tar.gz"
FINAL="${DEST}/${NAME}"

if (( DRY_RUN )); then
  # Nothing is created in a dry run - not even the staging directory - so ${DEST}
  # may not exist yet (the mkdir above was itself dry-run'd). Name a plausible
  # path purely so the log lines below read like the real thing.
  WORKDIR="${DEST}/.backup-staging.XXXXXX"
else
  WORKDIR=$(mktemp -d -p "${DEST}" .backup-staging.XXXXXX)
fi
STAGING="${WORKDIR}/${NAME}"

info "archiving ${SOURCE} -> ${FINAL}"

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

  # A checksum next to the archive lets a future restore prove the file is intact
  # without unpacking it - so it is written BEFORE the archive is published, and
  # published first. Order matters: a consumer that spots backup-*.tar.gz appearing
  # and immediately reaches for the sidecar must never lose that race. The cd makes
  # sha256sum record a bare filename, which is what `sha256sum -c` wants when it is
  # run later from inside ${DEST}.
  ( cd "${WORKDIR}" && sha256sum "${NAME}" > "${NAME}.sha256" )

  mv -- "${STAGING}.sha256" "${FINAL}.sha256"
  mv -- "${STAGING}" "${FINAL}"        # the atomic publish - same filesystem, always
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
