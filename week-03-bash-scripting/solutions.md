# Week 03 — Solutions & discussion

---

## C3.4 — Find the bug (do this one first; it is the highest-value exercise)

### A — parsing `ls`, unquoted expansion, no error handling

```bash
files=$(ls /var/log/*.log)      # 1. output of ls is not a safe list
for f in $files; do             # 2. splits on whitespace -> breaks on spaces in names
    lines=$(wc -l < $f)         # 3. unquoted $f
    echo "$f has $lines lines"
done
```
Also: if no `.log` files exist, the glob stays literal and `wc` fails on a file named `*.log`.

```bash
shopt -s nullglob               # an unmatched glob expands to NOTHING, not to itself
for f in /var/log/*.log; do
    lines=$(wc -l < "$f")
    printf '%s has %s lines\n' "$f" "$lines"
done
```

**Bites when:** any filename contains a space, a tab or a glob character; or when the directory is empty.

### B — unquoted variable in `[ ]`

```bash
if [ $USER = "root" ]; then
```
If `USER` is unset or empty, this becomes `[ = "root" ]` — a syntax error. If it somehow contained a space, `[` receives too many arguments.

```bash
if [[ $USER == root ]]; then
```
`[[ ]]` does not word-split, so it is safe even unquoted. Better still, do not test the *name*: `if (( EUID == 0 ))` tests the actual privilege, which is what you care about — a user named `root` is not necessarily uid 0, and uid 0 is not necessarily named `root`.

### C — no error handling, no cleanup on failure, predictable temp name

```bash
tmp=/tmp/work.$$        # PIDs are reused and predictable -> symlink attack surface
mkdir $tmp              # unquoted; not checked
process_data > $tmp/out # if this fails, we continue anyway
mv $tmp/out /final/location   # ...and move a truncated or empty file into place
rm -rf $tmp             # never runs if any line above exited
```

```bash
set -euo pipefail
tmp=$(mktemp -d)                       # unpredictable name, mode 0700
trap 'rm -rf "$tmp"' EXIT              # runs on EVERY exit path
process_data > "$tmp/out"
[[ -s "$tmp/out" ]] || { echo "no output produced" >&2; exit 1; }
mv "$tmp/out" /final/location
```

**Bites when:** `process_data` fails — you publish an empty file to a location other systems read, which is worse than failing.

### D — the pipeline subshell

`count` is incremented inside a subshell created by the pipe, so the parent still sees `0` and the alert never fires. Also `$count` is unquoted in `[ ]`, and `read line` should be `read -r line`.

```bash
count=0
while IFS= read -r line; do
    count=$(( count + 1 ))
done < <(grep ERROR app.log)
(( count > 10 )) && alert
```
Or simply `count=$(grep -c ERROR app.log || true)` — note the `|| true`, because `grep` exits 1 when it finds nothing, which `set -e` would treat as fatal.

**Bites when:** always. And silently — the alert simply never fires, which you discover during the incident it was supposed to catch.

### E — unvalidated remote input used to build a command

```bash
VERSION=$(curl -s https://api.example.com/version)
docker run myapp:$VERSION
```
`curl -s` hides errors; on failure `VERSION` is empty and you run `myapp:` — which resolves to `myapp:latest` and deploys something you did not intend. If the endpoint returns a trailing newline or an HTML error page, the tag is garbage. And the value is interpolated into a command unquoted.

```bash
VERSION=$(curl -fsS --max-time 10 https://api.example.com/version) \
  || { echo "could not fetch version" >&2; exit 1; }
VERSION=${VERSION//[$'\n\r']/}
[[ $VERSION =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
docker run "myapp:$VERSION"
```

`curl -f` (fail on HTTP errors) and `-S` (show errors even with `-s`) are the two flags to always pair with `-s`. **Validate anything that crosses a trust boundary before it becomes part of a command.**

---

## C3.1 — The log analyser

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly PROG=${0##*/}
TOP=5
THRESHOLD=100

usage() { echo "Usage: ${PROG} [-n TOP] [-t 5XX_THRESHOLD_PCT] [FILE]" >&2; exit "${1:-0}"; }

while getopts ':n:t:h' o; do
  case $o in
    n) TOP=$OPTARG ;;
    t) THRESHOLD=$OPTARG ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $(( OPTIND - 1 ))

# Read from a file argument or from stdin. Buffer to a temp file so we can make
# several passes without requiring the input to be seekable.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if (( $# )); then
  [[ -r $1 ]] || { echo "cannot read: $1" >&2; exit 1; }
  cat -- "$1" > "$tmp"
else
  cat > "$tmp"
fi

total=$(wc -l < "$tmp")
if (( total == 0 )); then
  echo "input is empty - nothing to analyse" >&2
  exit 1                       # ← the guard the challenge was really about
fi

errors=$(awk '$9 >= 400' "$tmp" | wc -l)
sxx=$(awk '$9 ~ /^5/' "$tmp" | wc -l)
first=$(head -1 "$tmp" | awk '{print substr($4,2)}')
last=$(tail -1 "$tmp" | awk '{print substr($4,2)}')

# bash has no floating point. Use awk for the arithmetic, not bc - awk is
# already a dependency here and bc is not installed by default on Ubuntu.
err_pct=$(awk -v e="$errors" -v t="$total" 'BEGIN{printf "%.1f", 100*e/t}')
sxx_pct=$(awk -v e="$sxx"   -v t="$total" 'BEGIN{printf "%.1f", 100*e/t}')

printf 'Requests:      %s\n'          "$total"
printf 'Time range:    %s .. %s\n'    "$first" "$last"
printf 'Error rate:    %s%%  (%s of %s)\n' "$err_pct" "$errors" "$total"
printf '5xx rate:      %s%%\n\n'      "$sxx_pct"

section() {
  local title=$1 field=$2
  printf '%s\n' "$title"
  awk -v f="$field" '{print $f}' "$tmp" | sort | uniq -c | sort -rn | head -"$TOP" \
    | awk '{printf "  %6s  %s\n", $1, $2}'
  echo
}

section "Top paths"     7
section "Top clients"   1
section "Status codes"  9

# The exit code is the API: this is what a monitoring system consumes.
awk -v s="$sxx_pct" -v t="$THRESHOLD" 'BEGIN { exit !(s > t) }' \
  && { echo "FAIL: 5xx rate ${sxx_pct}% exceeds threshold ${THRESHOLD}%" >&2; exit 1; }
exit 0
```

**Points worth absorbing:**
- The empty-input guard is checked *before* any division. Silent `nan`/divide-by-zero in a monitoring script is worse than a crash, because it reports "healthy".
- `awk` does the floating-point maths. Bash arithmetic is integer-only, and `bc` is not installed by default on Ubuntu server — a dependency you did not declare is a script that fails on a fresh host.
- Buffering stdin to a temp file makes multiple passes possible. The alternative — a single `awk` program computing everything at once — is faster and is the right answer above about 100 MB.

---

## C3.2 — Restore mode

The essential structure:

```bash
restore() {
  local archive=$1 dest=$2
  [[ -f $archive ]] || die "archive not found: $archive"

  # 1. VERIFY BEFORE TOUCHING ANYTHING
  if [[ -f "${archive}.sha256" ]]; then
    ( cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256" ) \
      || die "checksum mismatch - archive is corrupt, refusing to restore"
  else
    warn "no checksum sidecar; integrity cannot be verified"
  fi
  tar -tzf "$archive" >/dev/null || die "archive is unreadable"

  # 2. REFUSE TO CLOBBER
  if [[ -d $dest && -n $(ls -A "$dest" 2>/dev/null) ]] && (( ! FORCE )); then
    die "destination ${dest} is not empty; use -f to overwrite"
  fi

  # 3. DRY RUN LISTS, IT DOES NOT EXTRACT
  if (( DRY_RUN )); then
    info "would extract into ${dest}:"
    tar -tzf "$archive" | head -50
    return 0
  fi

  run mkdir -p "$dest"
  run tar -xzf "$archive" -C "$dest"
  info "restored ${archive} -> ${dest}"
}
```

**The drill matters more than the code.** Verifying byte-for-byte:

```bash
find data -type f -exec sha256sum {} + | sort > /tmp/before.txt
rm -rf data
./backup.sh restore -a out/backup-XXXX.tar.gz -d ./restored
( cd restored && find data -type f -exec sha256sum {} + | sort ) > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt && echo "IDENTICAL"
```

Record the elapsed time. That number is your **RTO** — recovery time objective — and it is the only honest answer to "how long would it take to get the data back?".

---

## C3.3 — The rollout script

The critical design decisions, more than the code:

```bash
deploy_one() {
  local host=$1
  info "[$host] copying"
  run scp -q "$ARTIFACT" "${host}:/tmp/artifact" || return 1
  run ssh "$host" "sudo install -m 0644 /tmp/artifact ${TARGET} && sudo systemctl restart ${SERVICE}" || return 1

  # Wait for READY, not merely for the restart command to return. A restart
  # that returns 0 means systemd forked the process, not that it can serve.
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if ssh "$host" "curl -fsS --max-time 2 http://localhost:8080/health" >/dev/null 2>&1; then
      info "[$host] healthy"
      return 0
    fi
    sleep 2
  done
  err "[$host] did not become healthy within ${HEALTH_TIMEOUT}s"
  return 1
}

completed=()
for host in "${hosts[@]}"; do
  if deploy_one "$host"; then
    completed+=("$host")
  else
    err "ROLLOUT HALTED at ${host}"
    err "already updated: ${completed[*]:-none}"
    err "not touched:     $(printf '%s ' "${hosts[@]:${#completed[@]}+1}")"
    exit 1
  fi
done
```

**Why halt rather than continue:** if host 2 is unhealthy after the change, hosts 3–20 will almost certainly be unhealthy too. Continuing converts a one-host problem into a total outage. This is exactly what Swarm's `--update-failure-action pause` does by default in Week 10 — you are hand-rolling the primitive you will later get for free, which is the best way to understand why it exists.

**Why report which hosts were completed:** the person cleaning up needs to know the fleet is now in a *mixed* state. A rollout script that fails without telling you where it stopped has made the incident worse.

---

## C3.5 — The Bash-to-Python boundary

A defensible answer:

> The analyser should have moved to Python at the point where it needed **more than one aggregation of the same data at once** — top paths, top clients, status distribution, and a per-client error ratio. In Bash each of those is a separate pass, spawning `sort` and `uniq` per section; the data is re-read four times and the intermediate results cannot be combined without writing them to temporary files. In Python it is one pass, one `collections.Counter` per dimension, and the cross-cutting question ("which clients have an anomalous error rate?") becomes three lines instead of an `awk` program embedded in a string.
>
> The second signal is the **threshold check with a float comparison**. Bash cannot compare `5.9 > 5.0` without shelling out to `awk`, and once your control flow depends on a subprocess's exit status to do arithmetic, the language has run out. The rule I would give a junior: if you are calling `awk` to do maths, or `python -c` for anything, you have already crossed the line — you just have not admitted it yet.

Speed: on a 1 GB log, a single `awk` pass typically beats naive Python by 2–4×, while multi-pass Bash with four `sort` invocations loses badly to both. That is a useful nuance: `awk` is not "slow Bash", it is a fast stream processor, and "rewrite it in Python" is not automatically faster. Measure.

---

## C3.6 — The 3am script

The paragraph at the top is the deliverable. Something like:

```
# reclaim.sh - free disk space on a full filesystem, safely, under pressure.
#
# WHAT IT DOES:
#   Reports the largest directories and files on the target filesystem, finds
#   deleted-but-still-open files holding space, and - only with --yes or an
#   interactive confirmation - truncates rotated logs older than N days and
#   vacuums the systemd journal.
#
# WHAT IT WILL NEVER DO:
#   Delete anything not matching an explicit allowlist of patterns.
#   Touch a database directory, /home, or anything under /etc.
#   Run against / unless --force-root is given.
#   Kill a process. It will TELL you which process holds a deleted file and
#   let you decide.
#
# EVERY action is appended to /var/log/reclaim.log with a timestamp and the
# invoking user, BEFORE it is performed - so if the machine dies mid-run, the
# log still says what was in progress.
```

**Why the "will never do" list is the important half:** at 3am, under pressure, your colleague needs to know the blast radius in five seconds, not to audit 200 lines of Bash. A script that is *safe* but does not *say* it is safe will not be run — and an unrun script is worth nothing.

The other detail worth stealing: **log the intent before performing the action.** A log written after the fact tells you nothing about the operation that was underway when the machine went down.
