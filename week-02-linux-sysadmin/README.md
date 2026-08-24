# Week 02 — Linux System Administration

**VM profile:** `make w02-up` → `lab`
**You will be able to:** make software start at boot and stay running, find any log on any Linux box, manage packages and storage, and schedule work reliably.

> Week 1 was about the machine as it is. Week 2 is about the machine as it **runs**: what starts it, what supervises it, and where it writes down what happened.

---

## Day 1 — systemd: the thing that starts everything

### 1.1 Boot, in one paragraph

Firmware → bootloader (GRUB) → kernel + initramfs → kernel mounts the real root filesystem → kernel starts **PID 1**, which on Ubuntu is `systemd`. From there, systemd brings up *units* according to their declared dependencies until it reaches the default target (`graphical.target` or, on a server, `multi-user.target`). Nothing else on the machine starts by magic; if something is running, some unit or some parent process started it, and you can find out which.

### 1.2 Units

A **unit** is anything systemd manages. The types you need:

| Type | Manages | Example |
|---|---|---|
| `.service` | a process | `nginx.service` |
| `.socket` | a listening socket, starting the service on demand | `docker.socket` |
| `.timer` | scheduled activation (the modern cron) | `logrotate.timer` |
| `.target` | a grouping / synchronisation point | `multi-user.target` |
| `.mount` | a mounted filesystem | `var-log.mount` |

### 1.3 Where unit files live — and the precedence that catches people

| Directory | Purpose | Precedence |
|---|---|---|
| `/lib/systemd/system/` | shipped by packages | lowest — **never edit these** |
| `/etc/systemd/system/` | your local units and overrides | highest |
| `/run/systemd/system/` | runtime-generated | middle |

Your changes belong in `/etc`. A package upgrade overwrites `/lib`, silently reverting anything you edited there.

**Drop-ins** are the correct way to modify a shipped unit. `/etc/systemd/system/nginx.service.d/10-limits.conf` adds to `nginx.service` without replacing it. This is powerful, and it is also *invisible* if you only `cat` the main unit file:

```bash
systemctl cat nginx            # unit + EVERY drop-in - always use this
systemctl show nginx -p ExecStart   # the single effective value
```

> **Learn `systemctl cat` now.** Chaos drill 02 is built on someone debugging a unit by reading the wrong file, which is a real and very common waste of an afternoon.

### 1.4 A minimal service unit, annotated

```ini
[Unit]
Description=Lab demo application
After=network-online.target          # ordering ONLY - not a guarantee it worked
Wants=network-online.target          # a weak dependency; Requires= is strict

[Service]
Type=simple                          # the process we start IS the service
User=appuser                         # never run as root without a reason
WorkingDirectory=/opt/lab/app
Environment=PORT=8080
EnvironmentFile=-/etc/lab/app.env    # the '-' means "ok if missing"
ExecStart=/usr/bin/python3 /opt/lab/app/serve.py
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure                   # restart if it exits non-zero
RestartSec=5s
TimeoutStopSec=30s                   # SIGTERM, wait 30s, then SIGKILL

# Hardening - cheap, and reviewers will ask for it
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/labapp

[Install]
WantedBy=multi-user.target           # ← what `systemctl enable` acts on
```

**`Type=` is the field people get wrong.** `simple` means "the process you exec is the service" — systemd considers it started the instant it forks. `notify` means the program tells systemd when it is genuinely ready (best, requires app support). `forking` is for old daemons that background themselves. `oneshot` is for a task that runs and exits. Choosing `simple` for a forking daemon makes systemd track the wrong PID, and the service then appears to die immediately.

### 1.5 `enabled` and `active` are independent

This trips up everyone exactly once, and Drill 02 makes sure it is you, today:

| | Meaning | Command |
|---|---|---|
| **active** | running *right now* | `systemctl is-active foo` |
| **enabled** | will start *at boot* | `systemctl is-enabled foo` |

`systemctl start` makes it active. `systemctl enable` creates a symlink under `multi-user.target.wants/` so it starts at boot. `systemctl enable --now` does both. A service that works perfectly and vanishes after every reboot is a service someone started but never enabled.

### 1.6 Reading failure

```bash
systemctl status labapp            # state, PID, recent log lines
systemctl --failed                 # everything currently broken - run this FIRST on a sick box
journalctl -u labapp -n 50 --no-pager
systemctl list-dependencies labapp
```

Exit-status codes you will actually meet:

| Status | Means | Usually |
|---|---|---|
| `203/EXEC` | could not execute the binary | wrong path in `ExecStart`, or not executable |
| `200/CHDIR` | `WorkingDirectory` does not exist | |
| `217/USER` | the `User=` does not exist | |
| `1/FAILURE` | the program itself exited non-zero | **read the app's own logs** |
| `signal=KILL` | killed — often the OOM killer | check `journalctl -k \| grep -i oom` |

---

## Day 2 — Logs: journald, files, and rotation

### 2.1 Two logging worlds coexist

**journald** — binary, indexed, structured, queryable by unit/time/priority. Everything systemd starts writes here by default.
**Plain files in `/var/log/`** — what applications write themselves. Nginx, Postgres and most third-party software do this regardless of systemd.

You need both. A junior who only knows `journalctl` cannot debug nginx; one who only knows `tail` cannot debug a systemd unit.

### 2.2 journalctl, the flags that matter

```bash
journalctl -u nginx                  # one unit
journalctl -u nginx -f               # follow, like tail -f
journalctl -u nginx -n 100 --no-pager
journalctl --since "10 min ago"
journalctl --since "2026-03-01 09:00" --until "2026-03-01 10:00"
journalctl -p err                    # priority err and worse (emerg,alert,crit,err)
journalctl -k                        # kernel messages only (was dmesg)
journalctl -b                        # this boot;  -b -1 = the PREVIOUS boot
journalctl -u nginx -o json-pretty   # all structured fields
journalctl --disk-usage
journalctl _PID=1234                 # by any structured field
```

**`journalctl -b -1` is the one to remember.** After an unexplained reboot, the logs of the boot that *died* are the only ones that matter, and they are not in `-b`.

**Persistence:** by default on some systems the journal lives in `/run` and is **lost on reboot**. Check with `journalctl --list-boots`; if only one boot is listed, you have a volatile journal. Fix it by creating `/var/log/journal` and restarting `systemd-journald`. Discovering this *during* an incident, when you need yesterday's logs, is a bad day.

### 2.3 Log priorities

`0 emerg · 1 alert · 2 crit · 3 err · 4 warning · 5 notice · 6 info · 7 debug`

`-p warning` shows 0–4. Applications that log everything at `info` — or worse, everything at `err` — destroy the usefulness of this filter, which is a real code-review point when your team writes services.

### 2.4 Rotation, and the outage it prevents

An unrotated log grows until the filesystem is full, and a full `/` takes down everything on the machine. `logrotate` runs from a systemd timer and rotates, compresses and deletes old logs.

```bash
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx     # -d = DEBUG: show what it WOULD do
sudo logrotate -f /etc/logrotate.d/nginx     # force now
```

The subtlety: after renaming `access.log` to `access.log.1`, the running nginx still holds a file descriptor to the *renamed* file and keeps writing there. The new `access.log` stays empty and disk is never freed. That is what the `postrotate` script solves — it signals the process to reopen its files:

```
postrotate
    /usr/bin/systemctl reload nginx > /dev/null 2>&1 || true
endscript
```

Or `copytruncate`, which copies then truncates in place — simpler, but loses any lines written between the two operations. Knowing why both exist is the point.

---

## Day 3 — Packages, users, and time

### 3.1 apt

```bash
sudo apt-get update                       # refresh the index - NOT an upgrade
sudo apt-get install -y nginx
apt-cache policy nginx                    # installed version + candidate + source
apt list --installed | wc -l
dpkg -L nginx                             # every file this package installed
dpkg -S /etc/nginx/nginx.conf             # which package owns this file?  ← very useful
sudo apt-get remove nginx                 # binaries go, config stays
sudo apt-get purge nginx                  # config goes too
apt-mark hold docker-ce                   # pin: refuse to upgrade it
```

`dpkg -S` is the one juniors never learn and seniors use weekly: given a mystery file, find out what put it there.

**Repositories and keys.** A third-party repo is two things: a `.list`/`.sources` entry under `/etc/apt/`, and a GPG key that authenticates it. If either is wrong you get `NO_PUBKEY` or `Release file is not valid yet` — the latter usually meaning **your clock is wrong**, which is a wonderfully confusing failure mode and a fault in the Week 12 game day.

### 3.2 Users and services

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin appuser
```

A **service account** should have no home, no shell and no password. If the service is compromised, the attacker gets a user who cannot log in. `--shell /usr/sbin/nologin` is the difference between an incident and a breach.

### 3.3 Time, and why it matters more than you think

```bash
timedatectl                    # is NTP synchronised? what timezone?
timedatectl set-timezone UTC
```

**Set servers to UTC.** Log correlation across machines in different timezones during an incident is miserable, and daylight-saving transitions create an hour that happens twice or not at all.

Clock skew breaks: TLS certificate validation (`certificate is not yet valid`), Kerberos, JWT expiry, APT repository metadata, and any distributed system using timestamps for ordering. It also makes logs from two hosts impossible to interleave — which is precisely when you need to.

---

## Day 4 — Storage and scheduled work

### 4.1 Block devices, filesystems, mounts

```bash
lsblk                          # the tree of disks and partitions
lsblk -f                       # + filesystem type and UUID
df -h                          # space per mounted filesystem
df -i                          # INODES - a separate exhaustible resource
findmnt                        # mount tree, much nicer than `mount`
sudo blkid                     # UUIDs
```

A device becomes usable in three steps: **partition** (`fdisk`/`parted`) → **filesystem** (`mkfs.ext4`) → **mount** (`mount`, or an entry in `/etc/fstab` for persistence).

**`/etc/fstab` uses UUIDs, not `/dev/sdb1`**, because device names are assigned in discovery order and can change between boots. A machine that boots into emergency mode after adding a disk is usually a `/dev/sdX` in fstab.

> **Danger:** a malformed `/etc/fstab` can prevent the system booting. Always test with `sudo mount -a` before rebooting, and add `nofail` to non-essential mounts.

### 4.2 The two ways a filesystem fills up

1. **Blocks** — the obvious one. `df -h` shows 100%.
2. **Inodes** — one per file. Millions of tiny files exhaust them while `df -h` shows plenty of space. `df -i` is the only way to see it. Classic causes: a mail spool, a session directory, a cache with no eviction.

And the classic "`df` says full but `du` says empty": a **deleted file still held open** by a running process. `du` walks directory entries; the file has none. The kernel frees the blocks only when the last descriptor closes.

```bash
sudo lsof +L1                   # files with link count < 1 = deleted but open
```

Both of these are Drill 02b. Do it.

### 4.3 Scheduled work: cron and timers

**cron:**
```bash
crontab -e ; crontab -l                    # per-user
ls /etc/cron.d/ /etc/cron.daily/           # system-wide
# m h dom mon dow  command
  0 3  *   *   *   /opt/lab/backup.sh
```

**The cron trap that catches every single beginner:** cron runs your job with a nearly empty environment — a minimal `PATH`, no `HOME` niceties, none of your `~/.bashrc`. A script that works in your shell fails in cron because it called `docker` without a full path, or relied on an exported variable. **Always use absolute paths in cron jobs, and always redirect output somewhere you will read.**

```bash
0 3 * * * /usr/bin/env bash /opt/lab/backup.sh >> /var/log/backup.log 2>&1
```

**systemd timers** are the modern replacement and are better in ways that matter:

```ini
# /etc/systemd/system/backup.timer
[Unit]
Description=Nightly backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true          # if the machine was off at 03:00, run it at next boot
RandomizedDelaySec=300   # jitter, so 500 machines do not stampede a server at once

[Install]
WantedBy=timers.target
```

```bash
systemctl list-timers --all
systemd-analyze calendar "*-*-* 03:00:00"    # verify a schedule before trusting it
```

Timers win because: the job's output goes to the journal automatically, it inherits all the `[Service]` hardening and resource limits, `Persistent=` handles missed runs, and `RandomizedDelaySec=` prevents thundering herds. Cron gives you none of that.

---

## Day 5 — Drills

```bash
cd infra
make snapshot VM=lab NAME=pre-w02
make break VM=lab DRILL=02-service
# ... 45 minutes ...
make restore VM=lab NAME=pre-w02
make break VM=lab DRILL=02-disk
```

> **LXD driver note:** if you are using the LXD Multipass driver, the loop-mounted filesystem in drill `02-disk` may not be permitted. In that case run the inode-exhaustion half against a directory on the existing filesystem and focus on the deleted-open-file half, which works everywhere.

## Recommended reading

- `man systemd.service`, `man systemd.exec`, `man systemd.timer` — dry, authoritative, and worth an hour each
- <https://www.freedesktop.org/software/systemd/man/> — the same, in a browser
- Digital Ocean's systemd essentials series — free and well written
- `man 5 crontab`, and <https://crontab.guru/> for schedule syntax
