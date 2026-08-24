#!/usr/bin/env bash
#
# backup-verify.sh - back up a Postgres database AND prove the backup restores.
#
# The verification is the point. A backup job that exits 0 for three weeks while
# producing nothing is exactly the week-3 drill, and it is a real thing that
# happens to real teams. Monitoring tells you the job ran; only a restore tells
# you the backup is usable.
#
#   ./backup-verify.sh backup   [-o DIR]
#   ./backup-verify.sh verify   <FILE>
#   ./backup-verify.sh restore  <FILE> [--yes]
#
set -euo pipefail

readonly PROG=${0##*/}
DEST=${BACKUP_DIR:-/var/backups/pg}
DB_CONTAINER=${DB_CONTAINER:-stack-db-1}
DB_USER=${DB_USER:-postgres}
DB_NAME=${DB_NAME:-appdb}
KEEP=${KEEP:-14}

log()  { printf '%s %-5s %s\n' "$(date -Is)" "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }

need() { command -v "$1" >/dev/null || die "missing command: $1"; }

# ---------------------------------------------------------------------------
cmd_backup() {
  mkdir -p "$DEST"
  local stamp out
  stamp=$(date +%Y%m%d-%H%M%S)
  out="${DEST}/${DB_NAME}-${stamp}.sql.gz"

  info "dumping ${DB_NAME} from ${DB_CONTAINER}"

  # pg_dump, NOT a copy of the data directory. A file-level copy of a running
  # database is torn: it captures pages mid-write and is usually unrestorable.
  # --clean --if-exists makes the dump idempotent on restore.
  if ! docker exec -i "$DB_CONTAINER" \
        pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists 2>/tmp/pgdump.err \
        | gzip > "$out"; then
    err "pg_dump failed: $(tail -3 /tmp/pgdump.err)"
    rm -f "$out"
    exit 2
  fi

  # --- verify the ARTEFACT, not the absence of complaints (week 3) ---------
  [[ -s $out ]]        || { err "backup is empty"; rm -f "$out"; exit 3; }
  gzip -t "$out"       || { err "backup is not valid gzip"; rm -f "$out"; exit 3; }

  local lines
  lines=$(gzip -dc "$out" | wc -l)
  (( lines > 10 ))     || { err "backup has only ${lines} lines - suspicious"; exit 3; }

  # A dump that contains no CREATE TABLE almost certainly dumped an empty or
  # wrong database. Check for content, not just for size.
  gzip -dc "$out" | grep -q 'CREATE TABLE' \
    || err "WARNING: no CREATE TABLE in the dump - is ${DB_NAME} the right database?"

  sha256sum "$out" > "$out.sha256"
  info "wrote $(du -h "$out" | cut -f1) to ${out} (${lines} lines)"

  prune
  printf '%s\n' "$out"          # stdout = the artefact path, for the caller
}

prune() {
  local -a files
  mapfile -t files < <(find "$DEST" -maxdepth 1 -name "${DB_NAME}-*.sql.gz" -printf '%f\n' | sort)
  local total=${#files[@]}
  if (( total > KEEP )); then
    local n=$(( total - KEEP ))
    info "retaining ${KEEP} of ${total}, pruning ${n}"
    for (( i = 0; i < n; i++ )); do
      rm -f "${DEST}/${files[i]}" "${DEST}/${files[i]}.sha256"
    done
  fi
}

# ---------------------------------------------------------------------------
cmd_verify() {
  local file=${1:?usage: ${PROG} verify <FILE>}
  [[ -f $file ]] || die "no such file: ${file}"

  info "checking integrity"
  [[ -f "${file}.sha256" ]] && { sha256sum -c "${file}.sha256" >/dev/null || die "checksum MISMATCH"; }
  gzip -t "$file" || die "not valid gzip"

  # THE REAL TEST: restore into a scratch database inside a throwaway container
  # and assert that something is actually in it. Everything above this line
  # only proves the file is well-formed.
  info "restoring into a scratch container - this is the part that counts"
  local cid
  cid=$(docker run -d --rm -e POSTGRES_PASSWORD=verify postgres:16-alpine)
  # shellcheck disable=SC2064  # we WANT $cid expanded now, not at trap time
  trap "docker rm -f '$cid' >/dev/null 2>&1 || true" EXIT

  local ready=0
  for _ in $(seq 1 30); do
    if docker exec "$cid" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  (( ready )) || die "scratch postgres never became ready"

  docker exec "$cid" psql -U postgres -c 'CREATE DATABASE scratch;' >/dev/null

  if ! gzip -dc "$file" | docker exec -i "$cid" psql -U postgres -d scratch -v ON_ERROR_STOP=1 >/tmp/restore.log 2>&1; then
    err "RESTORE FAILED - this backup is not usable:"
    tail -10 /tmp/restore.log >&2
    exit 4
  fi

  local tables
  tables=$(docker exec "$cid" psql -U postgres -d scratch -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")
  (( tables > 0 )) || die "restored successfully but the database is EMPTY (${tables} tables)"

  info "VERIFIED: restores cleanly, ${tables} table(s)"
}

# ---------------------------------------------------------------------------
cmd_restore() {
  local file=${1:?usage: ${PROG} restore <FILE> [--yes]}
  local confirm=${2:-}

  [[ -f $file ]] || die "no such file: ${file}"
  [[ -f "${file}.sha256" ]] && { sha256sum -c "${file}.sha256" >/dev/null || die "checksum MISMATCH - refusing"; }

  if [[ $confirm != "--yes" ]]; then
    err "This OVERWRITES ${DB_NAME} in ${DB_CONTAINER}."
    err "Re-run with --yes if you are sure."
    exit 1
  fi

  info "restoring ${file} -> ${DB_CONTAINER}/${DB_NAME}"
  local started=$SECONDS
  gzip -dc "$file" | docker exec -i "$DB_CONTAINER" \
    psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 >/dev/null \
    || die "restore failed"

  # THIS NUMBER IS YOUR RTO. Not the one in the plan - the one you measured.
  info "restore completed in $(( SECONDS - started ))s  <-- this is your measured RTO"
}

need docker
case "${1:-}" in
  backup)  shift; cmd_backup "$@" ;;
  verify)  shift; cmd_verify "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) die "usage: ${PROG} {backup|verify|restore} [args]" ;;
esac
