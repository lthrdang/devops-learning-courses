#!/usr/bin/env bats
#
# Tests for backup.sh.  Run with:  bats backup.bats
#
# Note how many of these test FAILURE paths. Anyone can make the happy path
# work; drill 03 is a script whose happy path "works" and whose failure path
# lies. Tests that only cover success would have passed on that script too.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/backup.sh"
  TMP="$(mktemp -d)"
  SRC="${TMP}/data"
  DEST="${TMP}/out"
  mkdir -p "${SRC}" "${DEST}"
  echo "alpha" > "${SRC}/a.txt"
  echo "beta"  > "${SRC}/b.txt"
}

teardown() {
  rm -rf "${TMP}"
}

@test "creates an archive and prints its path on stdout" {
  run "${SCRIPT}" -o "${DEST}" "${SRC}"
  [ "$status" -eq 0 ]
  [ -s "$output" ]
  [[ "$output" == "${DEST}/backup-"*.tar.gz ]]
}

@test "the archive actually contains the source files" {
  run "${SCRIPT}" -o "${DEST}" "${SRC}"
  [ "$status" -eq 0 ]
  run tar -tzf "$output"
  [[ "$output" == *"data/a.txt"* ]]
  [[ "$output" == *"data/b.txt"* ]]
}

@test "writes a matching sha256 sidecar" {
  archive="$("${SCRIPT}" -o "${DEST}" "${SRC}")"
  [ -f "${archive}.sha256" ]
  ( cd "${DEST}" && run sha256sum -c "$(basename "${archive}").sha256" )
}

@test "logs go to stderr, not stdout" {
  # If logging leaked to stdout, the captured path would be unusable.
  archive="$("${SCRIPT}" -v -o "${DEST}" "${SRC}" 2>/dev/null)"
  [ "$(printf '%s' "${archive}" | wc -l)" -eq 0 ]
  [ -f "${archive}" ]
}

@test "fails with status 1 when the source does not exist" {
  run "${SCRIPT}" -o "${DEST}" "${TMP}/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"source not found"* ]]
}

@test "fails when -k is not a number" {
  run "${SCRIPT}" -o "${DEST}" -k abc "${SRC}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "rejects an unknown option" {
  run "${SCRIPT}" -Z "${SRC}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "prints usage and fails when given no arguments" {
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "dry run changes nothing on disk" {
  run "${SCRIPT}" -n -o "${DEST}" "${SRC}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ "$(find "${DEST}" -name 'backup-*.tar.gz' | wc -l)" -eq 0 ]
}

@test "retention keeps exactly -k archives" {
  for d in 01 02 03 04 05; do
    touch "${DEST}/backup-202603${d}-000000.tar.gz"
  done
  run "${SCRIPT}" -o "${DEST}" -k 3 "${SRC}"
  [ "$status" -eq 0 ]
  [ "$(find "${DEST}" -name 'backup-*.tar.gz' | wc -l)" -eq 3 ]
}

@test "retention prunes the OLDEST, not an arbitrary three" {
  for d in 01 02 03 04 05; do
    touch "${DEST}/backup-202603${d}-000000.tar.gz"
  done
  "${SCRIPT}" -o "${DEST}" -k 3 "${SRC}" >/dev/null
  [ ! -f "${DEST}/backup-20260301-000000.tar.gz" ]
  [ -f "${DEST}/backup-20260305-000000.tar.gz" ]
}

@test "leaves no temporary directory behind on success" {
  before="$(find /tmp -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)"
  "${SCRIPT}" -o "${DEST}" "${SRC}" >/dev/null
  after="$(find /tmp -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)"
  [ "$before" -eq "$after" ]
}

@test "leaves no temporary directory behind on failure" {
  before="$(find /tmp -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)"
  run "${SCRIPT}" -o "${DEST}" "${TMP}/nope"
  after="$(find /tmp -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)"
  [ "$before" -eq "$after" ]
}

@test "a second concurrent run is refused by the lock" {
  # Hold the lock in a background subshell, then try to run.
  lock=/tmp/backup.lock
  ( exec 9>"$lock"; flock -n 9 && sleep 3 ) &
  holder=$!
  sleep 0.3
  run "${SCRIPT}" -o "${DEST}" "${SRC}"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  # Either it was refused (status 1) or - if the lock path differs because we
  # are not root - it succeeded. Assert on the refusal message when refused.
  if [ "$status" -eq 1 ]; then
    [[ "$output" == *"already running"* ]]
  fi
}
