# Week 03 — Bash Scripting for Operators

**VM profile:** `make w03-up` → `lab`
**You will be able to:** write Bash that fails loudly instead of silently, handles arguments and errors properly, cleans up after itself, and passes `shellcheck` — and to know when Bash is the wrong tool.

> You already know how to program. This week is not "learn a language"; it is **learn where Bash's semantics differ from every language you already know**, because that gap is where operational bugs live. A Python bug throws. A Bash bug returns the empty string and carries on.

---

## Day 1 — The safety preamble, and why every line of it is necessary

Every script you write from now on starts like this:

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

### `set -e` — exit on error

Without it, a failing command is a suggestion. This script deletes your data:

```bash
cd /nonexistent          # fails, prints an error, and CONTINUES
rm -rf ./*               # now runs in whatever directory you were in
```

That is not hypothetical — it is a well-documented class of real incident.

**`set -e` has exceptions you must know**, or you will trust it where it does not apply. It does *not* trigger for a command that is:
- part of a condition: `if cmd; then`, `while cmd; do`
- to the left of `&&` or `||`: `cmd || true`
- negated: `! cmd`
- anywhere except the last command in a pipeline (that is what `pipefail` fixes)

### `set -u` — error on undefined variable

```bash
rm -rf "$PREFIX/data"    # if PREFIX is unset, this is `rm -rf /data`
```

`set -u` turns that into an immediate abort. This single flag prevents an entire genre of catastrophe. Where you legitimately want a default, be explicit:

```bash
: "${PREFIX:=/opt/lab}"        # set if unset
LEVEL="${LOG_LEVEL:-info}"     # use a default without assigning
FILE="${1:?usage: backup.sh <file>}"   # abort with a message if missing
```

### `set -o pipefail` — a pipeline fails if *any* stage fails

```bash
grep pattern missing.txt | wc -l     # exit status 0, because wc succeeded
```

By default a pipeline's status is its **last** command's. `pipefail` makes it the rightmost *failure*. Without it, `curl ... | jq ...` reports success when curl fails and jq happily processes nothing.

### `IFS=$'\n\t'` — remove the space from the word splitter

The default `IFS` is space, tab, newline, so unquoted expansions split on spaces — which is why filenames with spaces destroy naive scripts. Restricting `IFS` reduces the blast radius. It is a seatbelt, not a substitute for quoting.

### The `set -e` bug that will cost you an afternoon

This script exits after the first iteration, silently, with no error message:

```bash
set -euo pipefail
count=0
for f in a b c; do
    (( count++ ))          # ← kills the script
    echo "$f"
done
```

**Why:** an arithmetic command `(( expr ))` returns exit status **0 if the
expression evaluates to non-zero**, and **1 if it evaluates to zero** — it is
modelled on C's notion of truth, not on a command's notion of success.
Post-increment `count++` evaluates to the *old* value, which is `0` on the first
pass. So `(( count++ ))` returns 1, and `set -e` terminates the script.

Three correct forms:

```bash
count=$(( count + 1 ))     # plain assignment - always safe, always clearest
(( ++count ))              # pre-increment: evaluates to the NEW value (1) - safe until it wraps to 0
(( count++ )) || true      # explicit, but noisy if repeated
```

The same trap applies to `(( flag = 0 ))` and to any arithmetic that can
legitimately be zero. The reference implementation in `files/healthcheck.sh`
carries a comment at the exact line where this bit — it was a real bug found by
running the script, not a hypothetical.

### What the preamble does **not** save you from

`set -euo pipefail` is necessary and not sufficient. It does not fix unquoted variables, does not make `cd` safe, and does not detect logic errors. Drill 03 is a script that has none of these flags and reports success while doing nothing.

---

## Day 2 — Quoting, expansion, and the constructs that differ from other languages

### 2.1 Quote everything

```bash
"$var"        "${arr[@]}"        "$(cmd)"        "${1}"
```

The exceptions where you deliberately do not quote are rare and always intentional: when you *want* word splitting, or inside `[[ ]]` where splitting does not occur.

### 2.2 Parameter expansion — a small language of its own

```bash
${var:-default}     # value, or default if unset/empty  (does not assign)
${var:=default}     # value, or default AND assign
${var:?message}     # value, or abort with message
${var:+alt}         # alt if var IS set - useful for optional flags
${#var}             # length
${var#prefix}       ${var##longest_prefix}      # strip from the front
${var%suffix}       ${var%%longest_suffix}      # strip from the back
${var/old/new}      ${var//old/new}             # replace first / all
${var^^}  ${var,,}                              # upper / lower case
```

`${file%.*}` (drop the extension) and `${path##*/}` (basename) avoid forking `basename`/`dirname` in a loop — which matters when the loop runs ten thousand times.

### 2.3 Tests: `[[ ]]`, not `[ ]`

`[` is a *command*; `[[` is shell syntax. Use `[[ ]]` in Bash always:

```bash
[[ -f $file ]]              # no quoting needed inside [[ ]]
[[ $name == prod-* ]]       # glob matching
[[ $name =~ ^v[0-9]+$ ]]    # regex, captures in ${BASH_REMATCH[@]}
[[ -n $a && -z $b ]]        # && works; inside [ ] you need -a and it is fragile
(( count > 5 ))             # arithmetic context - no $ needed
```

| Test | True when |
|---|---|
| `-f` | regular file exists |
| `-d` | directory exists |
| `-e` | exists (any type) |
| `-s` | exists and is non-empty |
| `-r` `-w` `-x` | readable / writable / executable **by you** |
| `-z` `-n` | string empty / non-empty |

### 2.4 Arrays

```bash
declare -a hosts=(web1 web2 web3)
declare -A conf=([port]=8080 [env]=prod)      # associative

echo "${hosts[@]}"      # ALL elements, each a separate word  ← almost always what you want
echo "${hosts[*]}"      # all elements as ONE word, joined by IFS
echo "${#hosts[@]}"     # count
for h in "${hosts[@]}"; do echo "$h"; done
```

**`"${arr[@]}"` on an empty array errors under `set -u` in Bash < 4.4.** Guard with `if (( ${#arr[@]} )); then`. This bites in real scripts and cost the game-day drill a patch.

### 2.5 Reading input correctly

The canonical file-reading loop, with every part load-bearing:

```bash
while IFS= read -r line; do
    printf '%s\n' "$line"
done < "$file"
```

- `IFS=` — do not strip leading/trailing whitespace
- `-r` — do not interpret backslashes
- `"$line"` quoted — no splitting
- `printf` not `echo` — `echo` mangles anything starting with `-` or containing `\`

**Never `for line in $(cat file)`.** It splits on whitespace, not newlines, and globs the result.

### 2.6 The subshell trap that eats your variables

```bash
count=0
cat file | while read -r line; do (( count++ )); done
echo "$count"      # prints 0
```

Each side of a pipeline runs in a **subshell**; the increment happens in a child process and is lost. Use redirection or process substitution instead:

```bash
while read -r line; do (( count++ )); done < file
while read -r line; do (( count++ )); done < <(some_command)
```

`< <(cmd)` — **process substitution** — is the tool for "feed a command's output into a loop without a subshell". Remember it; it solves this permanently.

---

## Day 3 — Structure: functions, arguments, errors, cleanup

### 3.1 Functions

```bash
log()  { printf '%s [%s] %s\n' "$(date -Is)" "${1}" "${*:2}" >&2; }
info() { log INFO "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }
```

Logs go to **stderr** so that a function's stdout stays usable as data:

```bash
get_version() { echo "1.2.3"; }        # stdout is the return VALUE
v=$(get_version)
```

A Bash function "returns" an exit status (0–255), not a value. Data comes back on stdout. Mixing the two — printing progress messages to stdout in a function whose output you capture — is a bug you will write once.

`local` for every variable inside a function. Without it, everything is global and functions silently clobber each other.

### 3.2 Argument parsing

For a few flags, `getopts` is built in and sufficient:

```bash
usage() { cat >&2 <<EOF
Usage: ${0##*/} [-v] [-o OUTPUT] SOURCE
  -v          verbose
  -o OUTPUT   output directory (default: /tmp)
  -h          this help
EOF
exit "${1:-0}"; }

verbose=0; output=/tmp
while getopts ':vo:h' opt; do
  case $opt in
    v) verbose=1 ;;
    o) output=$OPTARG ;;
    h) usage 0 ;;
    :) die "option -$OPTARG requires an argument" ;;
    \?) die "unknown option: -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
source=${1:?$(usage 1)}
```

`getopts` handles short flags only. If you need `--long-options`, that is a signal to consider Python (Week 6).

### 3.3 `trap` — cleanup that actually happens

```bash
tmpdir=$(mktemp -d)
cleanup() {
    local rc=$?
    rm -rf "$tmpdir"
    (( rc != 0 )) && err "failed with status ${rc}"
    exit "$rc"
}
trap cleanup EXIT
```

`trap ... EXIT` runs on **every** exit path — success, error, `set -e` abort, and `SIGTERM`. It is the only reliable way to guarantee cleanup. Note the first line captures `$?` *before* anything in the handler overwrites it.

Traps you will use:

| Trap | Fires on |
|---|---|
| `EXIT` | any exit — put cleanup here |
| `ERR` | any command failing (with `set -E` to inherit into functions) |
| `INT TERM` | Ctrl-C / `kill` — for graceful shutdown |

### 3.4 The lock file, done right

Two copies of a backup script running at once will corrupt each other. `flock` solves it correctly, atomically, with no stale-lock problem:

```bash
exec 9>/var/lock/mybackup.lock
flock -n 9 || die "another instance is already running"
# ... work ...
# the lock is released automatically when the process exits, even on kill -9
```

Hand-rolled `if [[ -f lockfile ]]` checks have a race between the test and the create, and leave stale locks after a crash. This is the case study for "use the primitive the OS gives you".

### 3.5 Idempotency

An operational script should be safe to run twice. Check before acting; use `mkdir -p`, `ln -sf`, `grep -q || append`; make destructive steps conditional. A script that cannot be re-run is a script nobody dares run during an incident — which is exactly when you need it.

---

## Day 4 — Verification: shellcheck, bats, and dry-run

### 4.1 shellcheck is not optional

```bash
shellcheck myscript.sh
```

It finds unquoted expansions, useless `cat`, the `$?` bug, subshell variable loss, and more. **Every script in this course must pass `shellcheck` cleanly.** Where you genuinely need to override, do it narrowly and say why:

```bash
# shellcheck disable=SC2086  # word splitting is intended: $FLAGS holds several args
cmd $FLAGS
```

### 4.2 Testing Bash with `bats`

```bash
sudo apt-get install -y bats
```

```bash
#!/usr/bin/env bats

setup() { TMP=$(mktemp -d); }
teardown() { rm -rf "$TMP"; }

@test "creates an archive" {
  run ./backup.sh -o "$TMP" ./testdata
  [ "$status" -eq 0 ]
  [ -s "$TMP"/backup-*.tar.gz ]
}

@test "fails cleanly when the source is missing" {
  run ./backup.sh -o "$TMP" /does/not/exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
```

Testing the **failure** paths matters more than the success path. Anyone can make the happy path work; drill 03 is a script whose happy path "works" and whose failure path lies.

### 4.3 `--dry-run` as a first-class feature

Any script that deletes, deploys or modifies should support a dry run:

```bash
run() {
    if (( DRY_RUN )); then info "DRY-RUN: $*"; else "$@"; fi
}
run rm -rf "$olddir"
```

This turns "I think this will do the right thing" into "here is exactly what it will do", which is what you want before running something as root at 3am.

### 4.4 When to stop using Bash

Bash is excellent glue: launching processes, wiring pipes, handling files, reacting to exit codes. It is a poor **programming language**: no real data structures, no exceptions, no types, arithmetic that is integer-only, and error handling that must be bolted on.

**Switch to Python when you hit any of these:**

- more than ~150 lines, or more than about three levels of nesting;
- parsing JSON, YAML or XML seriously;
- floating-point arithmetic;
- retry logic with backoff, or concurrency;
- anything that needs unit tests with mocks;
- more than two data structures being juggled at once.

Recognising this boundary *early* is a senior trait. Week 6 picks it up on the Python side.

---

## Day 5 — Drills

```bash
cd infra
make snapshot VM=lab NAME=pre-w03
make break VM=lab DRILL=03-script
```

Symptom: *"The nightly backup has logged 'backup OK' every night for three weeks. There are no backups."*

Then: rewrite the broken script properly, make it pass `shellcheck`, and write `bats` tests that would have caught the original bug.

## Recommended reading

- Google Shell Style Guide — <https://google.github.io/styleguide/shellguide.html>
- BashFAQ / BashPitfalls — <https://mywiki.wooledge.org/BashPitfalls> — read all 60, they are all real
- `man bash`, the sections on EXPANSION and Compound Commands
- <https://www.shellcheck.net/wiki/> — every warning code explained
