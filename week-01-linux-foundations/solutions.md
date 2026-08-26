# Week 01 — Solutions & discussion

> Exact numbers depend on your generated log; the **pipelines** are the answer.

---

## C1.1 — The log interrogation

```bash
cd /opt/lab/w01
L=access.log
```

**1. Top 5 IPs**
```bash
awk '{print $1}' "$L" | sort | uniq -c | sort -rn | head -5
```

**2. Top 5 paths**
```bash
awk '{print $7}' "$L" | sort | uniq -c | sort -rn | head -5
```

**3. Status distribution**
```bash
awk '{print $9}' "$L" | sort | uniq -c | sort -rn
```

**4. 5xx percentage**
```bash
awk '$9 ~ /^5/ {e++} END {printf "%.1f%%\n", 100*e/NR}' "$L"
```
Note `$9 ~ /^5/` rather than `$9 >= 500` — string matching on the leading digit is exact, whereas numeric comparison would also catch a hypothetical `600`. Small point, right instinct.

**5. IPs with more than 40 5xx**
```bash
awk '$9 ~ /^5/ {print $1}' "$L" | sort | uniq -c | awk '$1 > 40 {print $2, $1}'
```

**6. Total megabytes**
```bash
awk '{b += $10} END {printf "%.2f MB\n", b/1048576}' "$L"
```

**7. Busiest hour** — the timestamp is field 4, shaped `[01/Mar/2026:14:23:11`:
```bash
awk '{split($4, t, ":"); print t[2]}' "$L" | sort | uniq -c | sort -rn | head -1
```

**8. Top paths among 5xx only**
```bash
awk '$9 ~ /^5/ {print $7}' "$L" | sort | uniq -c | sort -rn | head -3
```
This is the question that actually matters in an incident: *not* "what is broken" but "**what specifically** is broken". Total 5xx count tells you there is a fire; this tells you which room.

**9. Clients with >20% error rate** — two aggregations compared:
```bash
awk '{
  total[$1]++
  if ($9 >= 400) bad[$1]++
}
END {
  for (ip in total) {
    rate = 100 * (ip in bad ? bad[ip] : 0) / total[ip]
    if (rate > 20) printf "%-16s %6.1f%%  (%d/%d)\n", ip, rate, bad[ip], total[ip]
  }
}' "$L" | sort -k2 -rn
```

**Why this pattern matters:** associative arrays in `awk` let you compute a ratio per key in a single pass over the data. In a real incident you will do exactly this over gigabytes of logs where loading into a database is not an option and the answer is needed in two minutes. Also note the guard `(ip in bad ? ... : 0)` — referencing a missing key in awk creates it, which would silently corrupt a later loop over the same array.

---

## C1.2 — The permission puzzle

```bash
sudo mkdir -p /srv/app/uploads /srv/app/secrets
sudo sh -c 'echo "key: value" > /srv/app/config.yaml'
sudo sh -c 'echo "s3cr3t" > /srv/app/secrets/token'
```

| Requirement | Command | Bit doing the work |
|---|---|---|
| read but not modify config | `sudo chown root:root /srv/app/config.yaml; sudo chmod 644 /srv/app/config.yaml` | `w` absent for group/other |
| create in uploads | `sudo chmod 1777 /srv/app/uploads` | `w` **on the directory** |
| cannot delete others' files there | the leading `1` = **sticky bit** | sticky restricts deletion to the file's owner |
| cannot list secrets/ | `sudo chmod 711 /srv/app/secrets` | `r` absent on the directory |
| can read secrets/token if path known | `sudo chmod 644 /srv/app/secrets/token` | `x` present on the directory allows traversal |

Verification:

```bash
sudo -u deployer cat /srv/app/config.yaml                 # OK
sudo -u deployer sh -c 'echo x >> /srv/app/config.yaml'   # Permission denied
sudo -u deployer touch /srv/app/uploads/mine              # OK
sudo touch /srv/app/uploads/roots
sudo -u deployer rm /srv/app/uploads/roots                # Operation not permitted (sticky)
sudo -u deployer ls /srv/app/secrets                      # Permission denied
sudo -u deployer cat /srv/app/secrets/token               # OK
```

**The lesson:** "cannot list, but can read a known path" is genuinely useful — it is how home directories and some secret stores are protected. Security by obscurity of the *name*, backed by real permissions on the directory. Note it is not sufficient alone, but it is a real layer.

---

## C1.3 — Find the space

```bash
# the 200MB file under /var
sudo find /var -type f -size +100M -exec ls -lh {} \; 2>/dev/null

# 10 largest files on the system (-xdev stays on one filesystem - important,
# otherwise you walk /proc, /sys and every mount and waste minutes)
sudo find / -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -10 \
  | awk '{printf "%.1f MB\t%s\n", $1/1048576, $2}'

# directory with the most files
sudo find / -xdev -type f -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -5

# recently modified under /etc  ← the first thing to check when "nothing changed"
sudo find /etc -type f -mmin -10 -ls
```

That last one deserves emphasis. When a user insists "nothing changed", `find /etc -mmin -60` frequently disagrees, politely and with evidence.

---

## C1.4 — Process forensics via /proc

```bash
sleep 3600 & PID=$!

tr '\0' ' ' < /proc/$PID/cmdline; echo   # command line (NUL-separated!)
grep PPid /proc/$PID/status              # parent pid
ls -l /proc/$PID/cwd                     # symlink to working directory
ls -l /proc/$PID/exe                     # symlink to the binary
grep VmRSS /proc/$PID/status             # resident memory
grep -E '^(Uid|Gid):' /proc/$PID/status  # numeric ids; resolve with getent
stat -c '%U' /proc/$PID                  # owner, resolved
```

`/proc/<pid>/fd/` holds one symlink per open file descriptor: `0`, `1`, `2` for the standard streams, then sockets (`socket:[12345]`), pipes, and regular files. `lsof` is essentially a program that walks `/proc/*/fd/` for every process and resolves those links — which is why `lsof +L1` can find deleted-but-open files (the symlink still resolves, with ` (deleted)` appended, even though the name is gone from its directory). That is the mechanism behind Drill 02b.

---

## C1.5 — Reproduce `top`

```bash
ps -eo rss,user,comm --sort=-rss --no-headers \
  | head -5 \
  | awk '{printf "%8.1f MB  %-10s %s\n", $1/1024, $2, $3}'
```

---

## C1.6 — The signal experiment

```bash
#!/usr/bin/env bash
set -euo pipefail
PIDFILE=/tmp/myapp.pid
CONFIG=/tmp/myapp.conf
LOG=/tmp/myapp.log

log() { echo "$(date -Is) [$$] $*" >> "$LOG"; }

reload() { log "SIGHUP: re-reading ${CONFIG}"; SETTING=$(cat "$CONFIG" 2>/dev/null || echo default); log "  setting=${SETTING}"; }
shutdown() { log "SIGTERM: shutting down cleanly"; rm -f "$PIDFILE"; exit 0; }

trap reload HUP
trap shutdown TERM INT

echo $$ > "$PIDFILE"
log "started, pidfile=${PIDFILE}"
reload
# `sleep 1 & wait $!`, never a bare `sleep 1`. Bash defers a trap handler while it
# is waiting on a FOREGROUND child and only runs it once that child exits, so with
# a plain `sleep 1` the SIGTERM handler fires up to a second late - which is longer
# than the `sleep 1` the test below waits before checking, and the test becomes a
# coin flip that "proves" SIGTERM did nothing. `wait` is interruptible, so the
# signal breaks out of it immediately and the handler runs at once.
while true; do sleep 1 & wait $!; done
```

> **This is the single most common reason a shell-based service looks like it ignores SIGTERM.** The handler is correct, the trap is installed, and the process still dies to the SIGKILL that follows because the handler was queued behind a foreground `sleep`. If you want to watch it happen, swap in `sleep 30`: the same script now takes up to thirty seconds to acknowledge a signal that arrived instantly.

```bash
echo "verbose" > /tmp/myapp.conf
./myapp.sh & sleep 1
kill -HUP $(cat /tmp/myapp.pid); sleep 1     # reload
kill -TERM $(cat /tmp/myapp.pid); sleep 1    # clean stop
ls -l /tmp/myapp.pid                          # gone

./myapp.sh & sleep 1
kill -9 $(cat /tmp/myapp.pid); sleep 1
ls -l /tmp/myapp.pid                          # STILL THERE
```

**Why the leftover PID file matters:** the next start reads a stale PID file, concludes an instance is already running, and refuses to start — or worse, a *different* process has since been assigned that PID and the script kills an innocent bystander. The robust pattern is to verify that the PID in the file is actually your program (compare `/proc/<pid>/comm`), or to stop hand-rolling this entirely and let `systemd` track the process, which is exactly what Week 2 does.

---

## C1.7 — Explanations

**1. `cmd 2>&1 > file`.** Redirections are processed left to right. `2>&1` means "make fd 2 point wherever fd 1 currently points" — at that moment, the terminal. Only afterwards does `> file` move fd 1 to the file. Result: stdout goes to the file, stderr still goes to the terminal — the opposite of the intent. The correct order is `> file 2>&1`.

**2. `free -h` showing little "free".** Linux uses otherwise-idle RAM as page cache for disk contents. That memory is instantly reclaimable when a process needs it. Unused RAM is wasted RAM. The column that estimates what a new process could actually obtain is **`available`**, and that is the only one worth alerting on.

**3. Load average 4.0.** Load counts processes that are runnable *or* blocked in uninterruptible I/O, averaged over time. On 8 cores, 4.0 means half idle. On 1 core, it means three units of work are queued and waiting — users experience that as the site being slow. Load is only interpretable relative to `nproc`, and it deliberately includes I/O wait, which is why a disk problem raises load without raising CPU usage.

**4. `kill -9`.** SIGKILL is handled by the kernel and never delivered to the process, so no cleanup handler runs: buffers are not flushed, transactions are not rolled back or committed, lock files and PID files stay behind, and the process never deregisters from its load balancer or cluster. Send SIGTERM, give it a grace period, and escalate only if it does not exit. That escalation with a timeout is precisely what `systemd` and `docker stop` implement.

**5. `chmod 777`.** It makes the symptom vanish by granting every user on the system write access — so it works, which is what makes it dangerous. It does not answer *why* the intended user lacked permission, which is usually wrong ownership, a missing group membership, or a missing `x` bit on a parent directory. The correct fix is almost always `chown`/`chgrp` plus the narrowest mode that works. In a real environment, world-writable files under `/srv` or `/etc` are an audit finding and, for some file types, a privilege-escalation vector.
