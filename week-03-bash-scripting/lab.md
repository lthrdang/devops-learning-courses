# Week 03 — Lab

```bash
cd infra && make w03-up && multipass shell lab
mkdir -p /opt/lab/w03 && cd /opt/lab/w03
```

---

## Part 1 — Make the failures visible (Day 1)

### 1.1 Prove that `set -e` matters

```bash
cat > unsafe.sh <<'EOF'
#!/usr/bin/env bash
cd /nonexistent
echo "still here, in $(pwd)"
ls | head -3
EOF
chmod +x unsafe.sh
./unsafe.sh ; echo "exit=$?"
```

Now add `set -e` as the second line and run it again. **Write down both exit codes.** Then imagine line 2 was `rm -rf ./*`.

### 1.2 Prove that `set -u` matters

```bash
cat > unset.sh <<'EOF'
#!/usr/bin/env bash
echo "would remove: ${PREFIX}/data"
EOF
bash unset.sh
bash -u unset.sh ; echo "exit=$?"
```

### 1.3 Prove that `pipefail` matters

```bash
grep needle /nonexistent-file | wc -l ; echo "exit=$?"
set -o pipefail
grep needle /nonexistent-file | wc -l ; echo "exit=$?"
set +o pipefail
```

> This one is worth dwelling on: `curl https://api.example.com/data | jq .items` reports **success** when curl fails, because `jq` exited 0 after reading nothing. Any script that fetches and processes data is affected.

### 1.4 The arithmetic trap

```bash
cat > counter.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
for f in a b c; do
    (( count++ ))
    echo "processed $f"
done
echo "total: $count"
EOF
bash counter.sh ; echo "exit=$?"
```

Predict the output before running. Then fix it three different ways and confirm each.

### 1.5 The subshell that eats variables

```bash
printf 'a\nb\nc\n' > lines.txt

count=0
cat lines.txt | while read -r l; do count=$((count+1)); done
echo "piped: $count"

count=0
while read -r l; do count=$((count+1)); done < lines.txt
echo "redirected: $count"

count=0
while read -r l; do count=$((count+1)); done < <(cat lines.txt)
echo "process substitution: $count"
```

---

## Part 2 — Quoting and expansion (Day 2)

```bash
mkdir -p spaces && touch "spaces/my report.txt" "spaces/normal.txt"

# 2.1 The classic breakage
for f in $(ls spaces); do echo "[$f]"; done         # broken - watch it split
for f in spaces/*;      do echo "[$f]"; done        # correct
```

```bash
# 2.2 Parameter expansion drills - predict each result first
path=/var/log/nginx/access.log.1
echo "${path##*/}"      # basename
echo "${path%/*}"       # dirname
echo "${path%.*}"       # drop last extension
echo "${path##*.}"      # last extension only

name="Production-Web-01"
echo "${name,,}" ; echo "${name^^}"
echo "${name//-/_}"
echo "${#name}"

unset MAYBE
echo "${MAYBE:-fallback}"
echo "${MAYBE:+--flag=$MAYBE}"      # expands to NOTHING when unset - useful
MAYBE=x
echo "${MAYBE:+--flag=$MAYBE}"
```

```bash
# 2.3 Tests
f=/etc/hosts
[[ -f $f ]] && echo "file"
[[ -r $f && -s $f ]] && echo "readable and non-empty"
v="v1.22.3"
[[ $v =~ ^v([0-9]+)\.([0-9]+) ]] && echo "major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}"
host=prod-web-01
[[ $host == prod-* ]] && echo "production host - be careful"
```

```bash
# 2.4 Arrays
declare -a hosts=(web1 web2 "db server")
for h in "${hosts[@]}"; do echo "[$h]"; done     # correct
for h in ${hosts[@]};   do echo "[$h]"; done     # broken - see the difference
echo "count=${#hosts[@]}"

declare -A conf=([port]=8080 [env]=prod)
for k in "${!conf[@]}"; do echo "$k=${conf[$k]}"; done
```

---

## Part 3 — Build the reference scripts (Day 3–4)

### 3.1 Study, then rebuild

Read `files/backup.sh` line by line. Then **close it and write your own** from the spec:

> Archive a directory to a timestamped `.tar.gz`, verify the archive is readable and non-empty, write a checksum, keep only the N newest, support `--dry-run` and `--verbose`, use a lock so two copies cannot run at once, clean up temporary files on every exit path, and print only the artefact path on stdout.

Compare yours with the reference afterwards. Differences are interesting; identical is suspicious.

```bash
cp /home/ubuntu/course/week-03-bash-scripting/files/backup.sh . 2>/dev/null || true
mkdir -p data out && echo hello > data/one.txt && echo world > data/two.txt

./backup.sh -o ./out -v ./data
ls -l out/
tar -tzf out/backup-*.tar.gz
( cd out && sha256sum -c ./*.sha256 )
```

Exercise every path:

```bash
./backup.sh -n -o ./out ./data          # dry run
./backup.sh -o ./out /does/not/exist    # rc=1
./backup.sh -o ./out -k abc ./data      # rc=1
./backup.sh -Z ./data                   # rc=1
./backup.sh                             # usage, rc=1
```

Prove the lock works:

```bash
( exec 9>/tmp/backup.lock; flock -n 9 && sleep 10 ) &
./backup.sh -o ./out ./data             # refused
wait
```

Prove retention works:

```bash
for d in 01 02 03 04 05; do touch "out/backup-202603${d}-000000.tar.gz"; done
./backup.sh -o ./out -k 3 ./data
ls -1 out/*.tar.gz                      # exactly 3, and the OLDEST are gone
```

### 3.2 shellcheck everything

```bash
shellcheck backup.sh healthcheck.sh unsafe.sh counter.sh
```

Fix every finding in your own scripts. For each warning code you suppress, add a comment saying why.

### 3.3 Test with bats

```bash
sudo apt-get install -y bats
cp /home/ubuntu/course/week-03-bash-scripting/files/backup.bats . 2>/dev/null || true
bats backup.bats
```

All 14 must pass. Then **write three more tests of your own**, at least one of which fails against a deliberately broken version of the script.

### 3.4 Traps

```bash
cat > trapdemo.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp=$(mktemp -d)
cleanup() { local rc=$?; echo "cleanup: removing $tmp (rc=$rc)"; rm -rf "$tmp"; exit "$rc"; }
trap cleanup EXIT
trap 'echo "interrupted"; exit 130' INT TERM

echo "working in $tmp"
touch "$tmp/artifact"
case "${1:-ok}" in
  ok)    echo "finishing normally" ;;
  fail)  false ;;
  hang)  sleep 300 ;;
esac
EOF
chmod +x trapdemo.sh

./trapdemo.sh ok    ; echo "rc=$?"
./trapdemo.sh fail  ; echo "rc=$?"
./trapdemo.sh hang &            # then Ctrl-C it, or: kill %1
sleep 1; kill %1; sleep 1
ls /tmp | grep -c tmp\\. || true   # no leftovers
```

### 3.5 healthcheck.sh

```bash
cp /home/ubuntu/course/week-03-bash-scripting/files/healthcheck.sh . 2>/dev/null || true
python3 -m http.server 8080 >/dev/null 2>&1 &

./healthcheck.sh -t 2 -r 0 http://localhost:8080/ http://localhost:9999/ ; echo "rc=$?"
./healthcheck.sh -t 2 -r 0 -j http://localhost:8080/ | jq

cat > targets.txt <<'EOF'
# lab targets
http://localhost:8080/
http://localhost:9999/     # deliberately dead
EOF
./healthcheck.sh -f targets.txt ; echo "rc=$?"
kill %1
```

> **Look closely at the retry timing.** Run with `-r 3` against a dead endpoint and time it. Explain in your logbook why the backoff doubles rather than staying constant, and what would happen to a struggling service if a hundred monitors all retried instantly.

---

## Part 4 — Wire it into the system

```bash
sudo cp backup.sh /usr/local/bin/backup.sh
sudo chmod 755 /usr/local/bin/backup.sh

sudo tee /etc/systemd/system/labbackup.service >/dev/null <<'EOF'
[Unit]
Description=Lab data backup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup.sh -o /opt/lab/backups -k 5 /opt/lab/w03/data
EOF

sudo tee /etc/systemd/system/labbackup.timer >/dev/null <<'EOF'
[Unit]
Description=Run the lab backup every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now labbackup.timer
sudo systemctl start labbackup.service
journalctl -u labbackup.service -n 20 --no-pager
ls -l /opt/lab/backups
```

> **No `Persistent=true` here, deliberately.** `man systemd.timer` says it "only has an effect on timers configured with `OnCalendar=`", and this timer has none. `Persistent=` catches up a run that a *wall-clock* schedule missed while the machine was off; `OnBootSec=`/`OnUnitActiveSec=` are monotonic — measured from boot and from the last activation — so there is no missed absolute time to catch up and the setting is silently inert. A real nightly backup would use `OnCalendar=*-*-* 03:00:00` **and** `Persistent=true`, so a laptop that was shut at 03:00 still gets its backup when it wakes. Copying `Persistent=` onto a monotonic timer is cargo cult: it costs nothing but it advertises a guarantee the unit does not provide.

> Notice also that the timer and the service share a stem — `labbackup.timer` activates `labbackup.service` — and that the script's stderr logging lands in the journal automatically, with timestamps and unit metadata. That is the payoff for logging to stderr rather than to a file of your own.

---

## Part 5 — Drill (Day 5)

```bash
# host
cd infra
make snapshot VM=lab NAME=pre-w03
make break VM=lab DRILL=03-script
```

Symptom: *"'backup OK' every night for three weeks. /opt/lab/backups is empty."*

Find **all three** bugs. Then:
1. Rewrite the script correctly.
2. Make it pass `shellcheck` with zero findings.
3. Write a `bats` test that fails against the original and passes against yours.

That third step is the real deliverable. A fix without a test that would have caught it is a fix that will be undone.
