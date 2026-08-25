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
  # bats' `run` merges stderr into $output, and this script logs to stderr on
  # purpose - so drop stderr here, or the assertion below is checking the log
  # lines and the path together rather than the stdout contract.
  run bash -c "'${SCRIPT}' -o '${DEST}' '${SRC}' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -s "$output" ]
  [[ "$output" == "${DEST}/backup-"*.tar.gz ]]
}

@test "the archive actually contains the source files" {
  archive="$("${SCRIPT}" -o "${DEST}" "${SRC}" 2>/dev/null)"
  run tar -tzf "${archive}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data/a.txt"* ]]
  [[ "$output" == *"data/b.txt"* ]]
}

@test "writes a matching sha256 sidecar" {
  archive="$("${SCRIPT}" -o "${DEST}" "${SRC}")"
  [ -f "${archive}.sha256" ]
  # The sidecar records a bare filename, so the check has to run inside DEST -
  # but `( cd ... && run ... )` would set $status inside a subshell and then
  # throw the subshell away, leaving nothing to assert on. Put the cd inside the
  # command that `run` executes instead, and assert on the status afterwards.
  run bash -c "cd '${DEST}' && sha256sum -c '$(basename "${archive}").sha256'"
  [ "$status" -eq 0 ]
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
  #
  # The path has to be the one the script actually uses. /var/lock is mode 1777
  # on Ubuntu, so an unprivileged run opens its lock there and never reaches the
  # /tmp fallback - a test holding /tmp/backup.lock contends with nobody, and
  # would pass just as happily with flock deleted from the script entirely.
  lock=/var/lock/backup.lock
  ( exec 9>"$lock"; flock -n 9 && sleep 2 ) &
  holder=$!
  sleep 0.3
  run "${SCRIPT}" -o "${DEST}" "${SRC}"
  # Wait the holder out instead of killing it. `sleep` is a child of that
  # subshell and inherits fd 9, so killing the subshell can orphan a sleep that
  # still holds the lock - and the leak then fails every test after this one.
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"already running"* ]]
}

@test "a successful run says so on stderr" {
  # The regression test for `exec 9>LOCK 2>/dev/null`: that form rebinds fd 2
  # for the whole remaining run, so every log line after the lock is taken -
  # "verified:", "done", and every error message - is silently discarded. The
  # archive still appears and the exit status is still 0, so nothing else in
  # this file notices. Capture stderr alone (2>&1 >/dev/null dups fd 2 to the
  # current stdout first, then sends stdout to /dev/null) and insist the
  # verification actually reported itself.
  run bash -c "'${SCRIPT}' -o '${DEST}' '${SRC}' 2>&1 >/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified:"* ]]
}

@test "a corrupt archive is rejected with status 3" {
  # Verification is only worth writing if it can fail, so make tar lie: a shim
  # earlier in PATH writes garbage where the archive should go and reports
  # success - which is exactly what a truncated write on a full disk looks like
  # from the caller's side. The shim delegates every other tar invocation to the
  # real one, so the integrity check itself runs unmodified.
  mkdir -p "${TMP}/bin"
  cat > "${TMP}/bin/tar" <<'SHIM'
#!/usr/bin/env bash
if [[ $1 == -czf ]]; then
  printf 'not a gzip stream at all' > "$2"
  exit 0
fi
exec /usr/bin/tar "$@"
SHIM
  chmod +x "${TMP}/bin/tar"
  PATH="${TMP}/bin:${PATH}"

  run "${SCRIPT}" -o "${DEST}" "${SRC}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"integrity check"* ]]
  # And - just as important - the junk must never have been published.
  [ "$(find "${DEST}" -name 'backup-*.tar.gz' | wc -l)" -eq 0 ]
}

@test "a destination that cannot be written to fails with status 1" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores the write bit, so this cannot fail as root"
  ro="${TMP}/readonly"
  mkdir -p "${ro}"
  chmod 0555 "${ro}"
  run "${SCRIPT}" -o "${ro}" "${SRC}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"destination not writable"* ]]
}
