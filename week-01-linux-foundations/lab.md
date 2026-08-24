# Week 01 — Lab

```bash
cd infra && make w01-up && multipass shell lab
```

Everything below runs **inside the VM** unless stated otherwise.

---

## Part 1 — Orientation (Day 1)

```bash
# 1.1 Where am I, who am I, what is this?
pwd ; whoami ; id ; hostname ; uname -a ; uptime

# 1.2 Walk the tree
ls / ; ls -la /etc | head -20 ; tree -L 1 /var
```

```bash
# 1.3 What IS a command?
type ls ; type cd ; type echo ; type -a echo
which python3 ; ls -l "$(which python3)"
```

> `type -a echo` shows both a builtin and `/usr/bin/echo`. Which one runs, and why? (Builtins win. This matters when their behaviour differs — `/usr/bin/echo -e` and bash's `echo -e` are not identical.)

```bash
# 1.4 Reading the manual - the skill that makes you self-sufficient
man ls          # q to quit, / to search, n for next match
man 5 hosts     # section 5 = file formats. `man hosts` alone may miss it.
man -k permission | head        # search by keyword
ls --help | head -30            # quicker for a flag reminder
```

### 1.5 Prove the expansion order

```bash
FILE="my report.txt"
touch "$FILE"
ls -l $FILE          # observe: two errors. Explain them.
ls -l "$FILE"        # correct
rm "$FILE"
```

```bash
echo {1..5}                 # brace expansion
echo ~                      # tilde
echo "$HOME"                # parameter
echo "today is $(date +%F)" # command substitution
echo $(( 7 * 6 ))           # arithmetic
touch a.txt b.txt ; echo *.txt ; rm a.txt b.txt   # glob
```

```bash
# 1.6 The glob that isn't
echo '*.txt'        # single quotes: no expansion at all
echo "*.txt"        # double quotes: no glob, but $ and ` still expand
echo "$USER: *.txt"
```

> **Logbook:** in one sentence each, when do you use single quotes, double quotes, and no quotes?

---

## Part 2 — Files and permissions (Day 2)

```bash
mkdir -p /opt/lab/w01 && cd /opt/lab/w01
echo "hello" > file.txt
ls -l file.txt
stat file.txt          # far more detail: inode, links, all three timestamps
```

```bash
# 2.1 Change and observe
chmod 600 file.txt ; ls -l file.txt
chmod u+x file.txt    ; ls -l file.txt
chmod 644 file.txt    ; ls -l file.txt
```

### 2.2 The directory-permission experiment — do this carefully

```bash
sudo mkdir -p /opt/lab/w01/vault
sudo sh -c 'echo secret > /opt/lab/w01/vault/data.txt'
sudo chmod 755 /opt/lab/w01/vault
sudo chmod 644 /opt/lab/w01/vault/data.txt

cat /opt/lab/w01/vault/data.txt        # works
touch /opt/lab/w01/vault/mine.txt      # ← predict, then run
```

Now remove *read* from the directory but keep *execute*:

```bash
sudo chmod 711 /opt/lab/w01/vault
ls /opt/lab/w01/vault                   # predict: ?
cat /opt/lab/w01/vault/data.txt         # predict: ?
```

And the reverse — read but no execute:

```bash
sudo chmod 744 /opt/lab/w01/vault
ls /opt/lab/w01/vault                   # predict: ?
cat /opt/lab/w01/vault/data.txt         # predict: ?
```

> **Write all six predictions in your logbook before running them.** Getting these wrong is the point; you will remember the corrected model far better than a table you read.

### 2.3 Deleting a file you cannot write

```bash
sudo chmod 755 /opt/lab/w01/vault
sudo chmod 400 /opt/lab/w01/vault/data.txt   # read-only, owned by root
sudo chown ubuntu /opt/lab/w01/vault
rm /opt/lab/w01/vault/data.txt               # you will be prompted; say yes
```

You just deleted a root-owned, read-only file as an ordinary user. Explain in your logbook exactly why that is not a bug.

### 2.4 Users and groups

```bash
sudo useradd -m -s /bin/bash deployer
sudo groupadd webops
sudo usermod -aG webops deployer
id deployer

sudo mkdir -p /srv/web && sudo chgrp webops /srv/web
sudo chmod 2775 /srv/web            # note the leading 2 - setgid
ls -ld /srv/web
sudo -u deployer touch /srv/web/index.html
ls -l /srv/web/index.html           # which GROUP owns the new file, and why?
```

> The setgid bit on a directory makes new files inherit the directory's group. This is how shared team directories are made to work.

### 2.5 Special bits in the wild

```bash
ls -l /usr/bin/passwd               # find the 's'
sudo find /usr/bin /usr/sbin -perm -4000 -type f 2>/dev/null
ls -ld /tmp                         # find the 't'
```

---

## Part 3 — Text processing (Day 3)

Generate a realistic log to work on:

```bash
cp /home/ubuntu/course/week-01-linux-foundations/files/gen-access-log.sh /opt/lab/w01/ 2>/dev/null || true
# If you have not mounted the course dir, write it yourself - see files/gen-access-log.sh
bash /opt/lab/w01/gen-access-log.sh > /opt/lab/w01/access.log
wc -l /opt/lab/w01/access.log
head -3 /opt/lab/w01/access.log
```

```bash
cd /opt/lab/w01

# 3.1 Selection
grep ' 500 ' access.log | head
grep -c ' 500 ' access.log            # count
grep -v ' 200 ' access.log | head     # invert
grep -n 'POST' access.log | head      # with line numbers
grep -i 'GET /API' access.log | head  # case-insensitive
```

```bash
# 3.2 Fields
head -1 access.log                    # count the fields; which is status? which is path?
awk '{print $9}' access.log | head
cut -d' ' -f1 access.log | head
```

```bash
# 3.3 THE pipeline - run it, then take it apart one stage at a time
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head

# Now build it up yourself and watch each stage:
awk '{print $1}' access.log | head
awk '{print $1}' access.log | sort | head
awk '{print $1}' access.log | sort | uniq -c | head
```

```bash
# 3.4 Questions to answer with one pipeline each. Write them yourself.
#   a) Which URL path is requested most often?
#   b) How many distinct client IPs are there?
#   c) What is the distribution of status codes?
#   d) Which IP produced the most 5xx responses?
#   e) What percentage of requests were errors (>=400)?
```

```bash
# 3.5 awk beyond field printing
awk '$9 >= 500 {print $1, $7}' access.log | head
awk '{sum += $10; n++} END {printf "avg bytes: %.1f over %d reqs\n", sum/n, n}' access.log
awk '{c[$9]++} END {for (s in c) printf "%s %d\n", s, c[s]}' access.log | sort -k2 -rn
```

```bash
# 3.6 sed
sed 's/GET/FETCH/' access.log | head -3       # first match per line
sed 's/GET/FETCH/g' access.log | head -3      # all matches
sed -n '10,15p' access.log                    # print a line range only
sed '/health/d' access.log | wc -l            # delete matching lines
```

```bash
# 3.7 JSON - do NOT use grep here
echo '{"service":"api","replicas":3,"ports":[8080,8443]}' > svc.json
jq '.' svc.json
jq -r '.service' svc.json
jq -r '.ports[]' svc.json
jq -r '.ports | length' svc.json
```

### 3.8 Redirection experiments

```bash
ls /etc /nonexistent > out.txt 2> err.txt
cat out.txt ; echo '---' ; cat err.txt

ls /etc /nonexistent > both.txt 2>&1 ; cat both.txt
ls /etc /nonexistent 2>&1 > wrong.txt ; cat wrong.txt   # explain the difference
```

---

## Part 4 — Processes (Day 4)

```bash
# 4.1 Look
ps aux | head
ps -eo pid,ppid,user,%cpu,%mem,stat,etime,cmd --sort=-%mem | head
pstree -p | head -20
cat /proc/1/comm ; cat /proc/1/cmdline | tr '\0' ' ' ; echo
```

```bash
# 4.2 Create one and control it
sleep 600 &
jobs
PID=$!
echo "pid=$PID"
ps -p "$PID" -o pid,ppid,stat,etime,cmd
ls -l /proc/$PID/          # cwd, exe, fd, environ ... all live
cat /proc/$PID/status | head -12
```

```bash
# 4.3 Signals
kill -STOP "$PID" ; ps -p "$PID" -o stat     # T = stopped
kill -CONT "$PID" ; ps -p "$PID" -o stat     # S = sleeping
kill "$PID"        ; ps -p "$PID" -o stat    # gone (SIGTERM)
```

### 4.4 SIGTERM vs SIGKILL — see the difference

```bash
cat > /opt/lab/w01/graceful.sh <<'EOF'
#!/usr/bin/env bash
cleanup() { echo "$(date -Is) caught SIGTERM, cleaning up" >> /tmp/graceful.log; exit 0; }
trap cleanup TERM
echo "$(date -Is) started pid=$$" >> /tmp/graceful.log
while true; do sleep 1; done
EOF
chmod +x /opt/lab/w01/graceful.sh

/opt/lab/w01/graceful.sh & P=$!
sleep 1; kill "$P"; sleep 1; cat /tmp/graceful.log

/opt/lab/w01/graceful.sh & P=$!
sleep 1; kill -9 "$P"; sleep 1; cat /tmp/graceful.log      # note what is MISSING
```

> This is the whole argument against reflexive `kill -9`, and it is also exactly what happens to a container that ignores `docker stop`.

### 4.5 Resources

```bash
uptime ; nproc                 # compare load average to core count
free -h                        # explain "available" vs "free" to yourself
df -h ; df -i
sudo du -xh --max-depth=1 /var | sort -h
```

Generate some load and watch:

```bash
sudo apt-get install -y stress-ng
stress-ng --cpu 2 --timeout 30s &
watch -n1 uptime               # Ctrl-C to stop
htop                           # q to quit
```

### 4.6 Which process owns that file?

```bash
sudo lsof /var/log/syslog | head
sudo lsof -p 1 | head
sudo fuser -v /var/log/syslog
```

---

## Part 5 — Drills (Day 5)

```bash
# On your HOST:
cd infra
make snapshot VM=lab NAME=pre-w01
make break VM=lab DRILL=01-permissions
```

Then, inside the VM, diagnose. **Timebox 45 minutes.** Record every hypothesis and test.

When done (or timed out):

```bash
multipass exec lab -- sudo cat /root/.drill-01-permissions | base64 -d
make restore VM=lab NAME=pre-w01
```

Repeat with `DRILL=02-disk` — yes, it is a Week 2 topic; attempting it now with only `df`, `du` and `lsof` is deliberate and instructive.
