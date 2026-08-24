# Week 02 — Solutions & discussion

---

## C2.1 — Hardening

```ini
[Service]
# --- identity ---
User=appuser
Group=appuser
NoNewPrivileges=true              # blocks setuid escalation from this process tree

# --- filesystem ---
ProtectSystem=strict              # entire filesystem read-only except...
ReadWritePaths=/var/lib/labapp    # ...this
ProtectHome=true                  # /home, /root, /run/user invisible
PrivateTmp=true                   # its own /tmp - blocks /tmp symlink attacks
ProtectProc=invisible             # cannot see other users' processes in /proc
ProcSubset=pid

# --- kernel & devices ---
ProtectKernelTunables=true        # /proc/sys read-only
ProtectKernelModules=true         # cannot load modules
ProtectKernelLogs=true
ProtectControlGroups=true
PrivateDevices=true               # only a minimal /dev
LockPersonality=true
MemoryDenyWriteExecute=true       # blocks a large class of exploit techniques
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictNamespaces=true           # cannot create namespaces (i.e. containers)

# --- network ---
RestrictAddressFamilies=AF_INET AF_INET6   # no unix sockets, no AF_PACKET
IPAddressDeny=any
IPAddressAllow=localhost 10.0.0.0/8

# --- syscalls ---
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native

# --- resources: a bug should not take the host down with it ---
MemoryMax=256M
TasksMax=64
LimitNOFILE=4096
```

```bash
systemd-analyze security labapp
```

**Directives you often cannot apply, and why:**
- `PrivateNetwork=true` — obviously not, it is a network service.
- `MemoryDenyWriteExecute=true` — breaks any JIT runtime (Java, Node, LuaJIT, some Python extensions). Fine for CPython here.
- `ProtectSystem=strict` — breaks anything expecting to write outside its declared paths, which includes many applications that write PID files or caches in surprising places. `strace -f -e trace=openat` finds them.

**The real lesson:** each of these is one line and costs nothing at runtime. `MemoryMax=` in particular converts "one buggy service takes down the whole host" into "one service gets OOM-killed and restarted", which is the difference between an incident and a blip.

---

## C2.2 — Socket activation

```ini
# /etc/systemd/system/labapp.socket
[Unit]
Description=Socket for labapp

[Socket]
ListenStream=8080
Accept=no

[Install]
WantedBy=sockets.target
```

```bash
sudo systemctl disable --now labapp.service
sudo systemctl enable --now labapp.socket
ss -tlnp | grep 8080          # systemd holds the socket; labapp is NOT running
curl -s localhost:8080/health # this triggers the start
systemctl is-active labapp.service
```

(A fully correct implementation also needs the app to accept a pre-opened fd via the `sd_listen_fds` protocol; for the lab, observing systemd holding the socket is the learning objective.)

**The observable difference:** before the first request, `ss -tlnp` shows the port bound to `systemd` (PID 1), not to your application.

**What it solves that `Restart=always` does not: the startup ordering problem.** Because systemd binds the socket before any service starts, a client connecting during a restart is not refused — the connection **queues in the kernel's accept backlog** and is served the moment the process is ready. `Restart=always` restarts a dead service, but every connection arriving in the gap gets `ECONNREFUSED`. This is also why services can be started in parallel at boot without dependency ordering: everyone's socket exists from the start.

---

## C2.3 — The reboot test

```bash
sudo systemctl enable labapp.service labreport.timer

# persistent mount, by UUID
UUID=$(sudo blkid -s UUID -o value /opt/lab/disk.img 2>/dev/null)
echo "/opt/lab/disk.img /mnt/extra ext4 loop,nofail 0 0" | sudo tee -a /etc/fstab
sudo mount -a          # ← TEST BEFORE REBOOTING. A bad fstab can block boot.
findmnt /mnt/extra

sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald
```

Verification after `multipass restart lab`:

```bash
systemctl is-active labapp && systemctl is-enabled labapp
findmnt /mnt/extra
systemctl list-timers labreport.timer
journalctl --list-boots        # more than one line
journalctl -b -1 -u labapp | tail
```

**`nofail` matters.** Without it, a mount that fails at boot drops the machine into emergency mode with no network — and on a remote server that means a trip to a console you may not have. Use `nofail` on everything that is not the root filesystem.

---

## C2.4 — Log triage

```bash
# 1. Is it broken NOW? Always establish the current state first.
systemctl --failed
systemctl status labapp

# 2. What did the service itself say in that window?
journalctl -u labapp --since "14:25" --until "14:40" --no-pager

# 3. Errors from anything, same window - the cause is often another unit
journalctl --since "14:25" --until "14:40" -p warning --no-pager

# 4. Did the kernel intervene? (OOM killer, disk errors, network flaps)
journalctl -k --since "14:25" --until "14:40" --no-pager | grep -iE 'oom|error|reset|link'

# 5. Did the service restart, and how many times?
systemctl show labapp -p NRestarts -p ExecMainStartTimestamp

# 6. What did the front end see? (a status-code timeline, per minute)
sudo awk '$4 ~ /14:3[0-9]/ {split($4,t,":"); print t[2]":"t[3], $9}' /var/log/nginx/access.log \
  | sort | uniq -c

# 7. Did anything change just before it broke?
grep -E ' install | upgrade ' /var/log/dpkg.log | tail
sudo find /etc -newermt '2026-03-01 14:00' -type f 2>/dev/null

# 8. Was the machine resource-starved?
sar -q -s 14:25:00 -e 14:40:00     # load;  -r memory, -u CPU, -b I/O
```

**The shape of this list is the point.** It goes: *current state → the suspect → everything else → the layer below → what changed → what the user saw*. Notice how much of it is about **what changed** — in real incidents, "nothing changed" is false roughly as often as it is true, and `dpkg.log` plus `find -newermt` settles the argument with evidence rather than opinion.

---

## C2.5 — Rotation that works

```
# /etc/logrotate.d/labapp
/var/log/labapp/*.log {
    daily
    size 10M          # rotate on EITHER condition
    rotate 7
    compress
    delaycompress     # keep .1 uncompressed - it may still be being written
    missingok
    notifempty
    create 0640 appuser adm
    sharedscripts
    postrotate
        systemctl reload labapp.service >/dev/null 2>&1 || true
    endscript
}
```

```bash
sudo logrotate -d /etc/logrotate.d/labapp     # dry run first, always
sudo logrotate -f /etc/logrotate.d/labapp
ls -l /var/log/labapp/
```

**Proving "does not lose lines"** — the interesting part, and the part most people skip:

```bash
# Write a numbered line every 10ms into the log, in the background
sudo -u appuser bash -c 'for i in $(seq 1 5000); do echo "line $i" >> /var/log/labapp/app.log; sleep 0.01; done' &
sleep 5
sudo logrotate -f /etc/logrotate.d/labapp
wait

# Reassemble every generation and check for gaps in the sequence
sudo bash -c 'zcat -f /var/log/labapp/app.log.*.gz 2>/dev/null; cat /var/log/labapp/app.log.1 2>/dev/null; cat /var/log/labapp/app.log' \
  | awk '{print $2}' | sort -n | awk 'NR>1 && $1 != prev+1 {print "GAP after", prev} {prev=$1}'
```

Empty output means no lines were lost. **This is what testing a claim looks like** — you construct a situation where the failure would be detectable, then look for it. With `copytruncate` instead of `postrotate`, this test finds gaps, which is exactly the trade-off `copytruncate` makes.

---

## C2.6 — Every scheduled job

```bash
# systemd
systemctl list-timers --all

# cron: six locations, and people forget at least three
crontab -l                          # current user
for u in $(cut -f1 -d: /etc/passwd); do echo "== $u"; sudo crontab -l -u "$u" 2>/dev/null; done
cat /etc/crontab
ls -la /etc/cron.d/
ls -la /etc/cron.{hourly,daily,weekly,monthly}/

# at / batch
atq

# anacron
cat /etc/anacrontab 2>/dev/null

# and the ones that are not "scheduling" but behave like it:
systemctl list-units --type=path      # .path units trigger on filesystem events
ls -la /etc/systemd/system/*.timer
```

Keep this list. "Find every scheduled job" is a real task during audits and during incidents where something runs at 03:00 and nobody knows what.

---

## C2.7 — Reply to the developer

> Four things differ between your terminal and a systemd service, in the order I'd check them:
>
> **1. Working directory.** Your shell is in the project folder; the service starts in `/`. A relative path like `config.yaml` resolves somewhere else entirely. → `systemctl show labapp -p WorkingDirectory` — set `WorkingDirectory=` or use absolute paths.
>
> **2. User.** You are `you`; the service is `appuser`, which may not own the config or the log directory. → `sudo -u appuser cat /path/to/config.yaml` — if that fails, it is permissions, and `ls -ld` on every parent directory will show which one.
>
> **3. Environment.** Your shell has `~/.bashrc`, `PATH` additions, and exported variables; the service has almost nothing. → `systemctl show labapp -p Environment` and compare with `env`. Use `Environment=` or `EnvironmentFile=`.
>
> **4. Sandboxing.** If the unit has `ProtectSystem=strict` or `PrivateTmp=true`, writes are blocked *even though the filesystem permissions allow them* — which makes it look like a permissions bug that `chmod` cannot fix. → `systemctl cat labapp` and check for `Protect*`/`ReadWritePaths`. `PrivateTmp` in particular means the service's `/tmp` is not your `/tmp`, so "the file I wrote isn't there" has a very confusing surface.
>
> Fastest way to see the truth for all four at once: `sudo systemd-run --uid=appuser --property=WorkingDirectory=/ -t /path/to/your/app` — that runs it interactively under the same constraints and prints the real error.

That last command is worth memorising. `systemd-run -t` gives you a transient unit with whatever properties you specify, attached to your terminal — it collapses the "works in my shell / fails as a service" debugging loop from twenty minutes to one command.
