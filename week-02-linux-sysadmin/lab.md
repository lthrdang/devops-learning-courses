# Week 02 — Lab

```bash
cd infra && make w02-up && multipass shell lab
```

---

## Part 1 — Build a real service (Day 1)

### 1.1 The application

```bash
sudo mkdir -p /opt/lab/app /var/lib/labapp
sudo tee /opt/lab/app/serve.py >/dev/null <<'EOF'
#!/usr/bin/env python3
"""Tiny HTTP service with a config file, a data dir, and honest logging."""
import http.server, json, os, signal, socketserver, sys, time, pathlib

PORT     = int(os.environ.get("PORT", "8080"))
GREETING = os.environ.get("GREETING", "hello")
DATA     = pathlib.Path(os.environ.get("DATA_DIR", "/var/lib/labapp"))
START    = time.time()

def log(level, msg):
    # stdout/stderr from a systemd service go straight to the journal.
    print(f"{level} {msg}", file=sys.stderr if level in ("ERROR","WARN") else sys.stdout, flush=True)

class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok", "uptime_s": round(time.time()-START, 1)})
        elif self.path == "/":
            self._send(200, {"greeting": GREETING, "pid": os.getpid()})
        elif self.path == "/write":
            try:
                (DATA / "counter").write_text(str(int(time.time())))
                self._send(200, {"wrote": str(DATA / "counter")})
            except OSError as e:
                log("ERROR", f"write failed: {e}")
                self._send(500, {"error": str(e)})
        else:
            self._send(404, {"error": "not found", "path": self.path})

    def log_message(self, fmt, *args):
        log("INFO", f'{self.address_string()} "{fmt % args}"')

def on_term(signum, frame):
    log("INFO", "SIGTERM received, shutting down cleanly")
    sys.exit(0)

signal.signal(signal.SIGTERM, on_term)
socketserver.TCPServer.allow_reuse_address = True
log("INFO", f"starting on :{PORT} greeting={GREETING} data={DATA}")
with socketserver.TCPServer(("0.0.0.0", PORT), H) as s:
    s.serve_forever()
EOF
sudo chmod 755 /opt/lab/app/serve.py
```

Run it by hand first — always prove the program works before blaming the supervisor:

```bash
python3 /opt/lab/app/serve.py &
curl -s localhost:8080/ | jq
curl -s localhost:8080/health | jq
kill %1
```

### 1.2 A service account

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin appuser
sudo chown -R appuser:appuser /var/lib/labapp
id appuser
sudo -u appuser -i        # what happens, and why? (nologin)
```

> **`-i`, not `-s` — and the difference is the entire point of the step.** `man sudo` is explicit: `-s` runs "the shell specified by the `SHELL` environment variable if it is set or the shell specified by the **invoking** user's password database entry". It never looks at the target account's shell, so `sudo -u appuser -s` hands you *your* bash or zsh running as `appuser`, prompt and all — and you would walk away believing `--shell /usr/sbin/nologin` does nothing. `-i` is the one that simulates an initial login *as the target user*, which means it runs the target user's shell, which means it runs `nologin`, which prints `This account is currently not available.` and exits non-zero.
>
> That is not a flaw in `-s`; it is what `-s` is for. `sudo -s` exists so an operator can get a root shell with their own familiar shell configuration. It is simply not a test of the target account's login policy — and `nologin` was never a security boundary against someone who already has `sudo`. What `nologin` actually stops is `ssh appuser@host`, `su - appuser`, and any daemon that tries to spawn a login shell for the account.

### 1.3 The unit

```bash
sudo tee /etc/systemd/system/labapp.service >/dev/null <<'EOF'
[Unit]
Description=Lab demo application
Documentation=https://example.invalid/labapp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=appuser
Group=appuser
Environment=PORT=8080
Environment=GREETING=hello
Environment=DATA_DIR=/var/lib/labapp
EnvironmentFile=-/etc/lab/labapp.env
ExecStart=/usr/bin/python3 /opt/lab/app/serve.py
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/labapp

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload        # ALWAYS after editing a unit
sudo systemctl enable --now labapp
systemctl status labapp
curl -s localhost:8080/health | jq
```

### 1.4 Prove `ProtectSystem=strict` works

```bash
curl -s localhost:8080/write | jq                    # /var/lib/labapp is in ReadWritePaths
sudo systemctl edit labapp --full                     # change DATA_DIR to /opt/lab
# ... set Environment=DATA_DIR=/opt/lab, save, then:
sudo systemctl restart labapp
curl -s localhost:8080/write | jq                     # predict the result
journalctl -u labapp -n 5 --no-pager
```

> You just watched systemd's sandboxing block a write your application was entitled to make at the filesystem level. That is the feature working. Revert `DATA_DIR` afterwards.

### 1.5 enabled vs active

```bash
systemctl is-active labapp ; systemctl is-enabled labapp
sudo systemctl disable labapp
systemctl is-active labapp ; systemctl is-enabled labapp    # note: STILL running
ls -l /etc/systemd/system/multi-user.target.wants/ | grep lab   # the symlink is gone
sudo systemctl enable labapp
```

### 1.6 Drop-ins and `systemctl cat`

```bash
sudo systemctl edit labapp        # opens a drop-in - read what it pre-fills
# type this into the EDITABLE REGION at the top:
#   [Service]
#   Environment=GREETING=from-a-dropin
sudo systemctl restart labapp
curl -s localhost:8080/ | jq -r .greeting

cat /etc/systemd/system/labapp.service | grep GREETING    # says "hello"
systemctl cat labapp | grep GREETING                       # says BOTH - last wins
systemctl show labapp -p Environment
```

> **The buffer is not empty, and reading it is half the value of the command.** Modern systemd pre-fills it with a header naming the file it is about to write (`/etc/systemd/system/labapp.service.d/override.conf`), a blank editable region, and then the *entire original unit reproduced as comments* below a `###` marker line, so you can see what you are overriding without leaving the editor. Only the region above that marker becomes the drop-in — the commented block is reference material, and anything you type into it is a comment. Two consequences worth internalising: the drop-in you create contains only your lines, never a copy of the original (so the original keeps receiving package updates), and per `man systemctl`, if you exit without adding anything the edit is cancelled outright rather than writing an empty override.
>
> `systemctl edit --full` is the other mode: it copies the whole unit for you to modify wholesale. Reach for it rarely — it severs the unit from its package, and the next `apt upgrade` will not touch it.

> **This is the entire lesson of drill 02.** The file you `cat` is not the configuration in effect.

### 1.7 Watch `Restart=on-failure`

```bash
sudo systemctl edit labapp
# add:  [Service]
#       Environment=PORT=99999      ← invalid port, the app will crash
sudo systemctl restart labapp
systemctl status labapp
journalctl -u labapp -n 20 --no-pager
systemctl show labapp -p NRestarts
```

Notice systemd gives up after a burst (`start-limit-hit`). Read `man systemd.unit` for `StartLimitBurst`/`StartLimitIntervalSec` and explain in your logbook **why a restart limit exists at all** — what would an unlimited restart loop do to the machine?

Then remove the bad drop-in: `sudo rm -r /etc/systemd/system/labapp.service.d && sudo systemctl daemon-reload && sudo systemctl restart labapp`.

---

## Part 2 — Logs (Day 2)

```bash
journalctl -u labapp -n 30 --no-pager
journalctl -u labapp -f &            # follow in the background
for i in $(seq 1 5); do curl -s localhost:8080/ >/dev/null; curl -s localhost:8080/nope >/dev/null; done
kill %1
```

```bash
journalctl -u labapp --since "5 min ago"
journalctl -u labapp -p err --no-pager
journalctl -u labapp -o json-pretty | head -40      # look at the structured fields
journalctl -u labapp -o cat | tail -5               # message text only
journalctl --disk-usage
journalctl --list-boots
```

### 2.2 Make the journal persistent

**Ask the authoritative question first**, which is `Storage=` in journald's configuration — not the number of boots `--list-boots` happens to report:

```bash
# The setting that decides everything. Ubuntu ships it commented out at the
# default, `Storage=auto`, and the commented line IS the effective value.
grep -r '^ *Storage=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ 2>/dev/null
grep '^#Storage=' /etc/systemd/journald.conf          # the shipped default

# `auto` means: persist IF /var/log/journal exists, otherwise use /run (volatile).
# So under `auto`, the existence of this directory is the on/off switch.
ls -d /var/log/journal && echo "PERSISTENT" || echo "VOLATILE"

# And the ground truth - where is journald actually writing right now?
journalctl --header | grep -i 'file path' | head -3
journalctl --disk-usage
```

> **Why not "`--list-boots` shows one, therefore volatile"?** Because a single entry has at least three innocent explanations: the machine has genuinely only booted once, or `journalctl --vacuum-time`/`SystemMaxUse=` has already aged the older boots out, or the disk was persistent all along and simply has nothing older to show. A count is evidence; `Storage=` is the answer. Get into the habit of reading the setting rather than inferring it from a symptom — the same discipline saves you an hour every time you debug configuration.
>
> Note also that **Ubuntu Server ships `/var/log/journal` already present**, so on a stock image the journal is *already* persistent and the block below is a no-op. Run them anyway to see that they are idempotent, and understand that the interesting case is the opposite one: a minimal container or a Debian netinstall where the directory is absent and every log you need after a crash was in `/run`.

If `Storage=` is `auto` and the directory is missing, this is how you turn persistence on — and `systemd-tmpfiles` rather than a bare `mkdir` because it applies the ownership and `2755` mode journald expects:

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --header | grep -i 'file path' | head -3   # now under /var/log, not /run
sudo reboot            # from the host: multipass restart lab
# after it returns:
journalctl --list-boots            # now shows the previous boot too
journalctl -b -1 -u labapp --no-pager | tail
```

The alternative to `auto` is to be explicit — `Storage=persistent` creates the directory itself and never falls back, which is what you want in configuration management where you would rather the setting state the intent than depend on a directory existing.

### 2.3 Bound the journal's size

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/10-size.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=20M
MaxRetentionSec=2week
EOF
sudo systemctl restart systemd-journald
journalctl --disk-usage
sudo journalctl --vacuum-size=100M
```

### 2.4 File-based logs and rotation

```bash
sudo apt-get install -y nginx
sudo systemctl enable --now nginx
curl -s localhost >/dev/null
sudo tail -3 /var/log/nginx/access.log

cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx 2>&1 | head -30      # dry run, read it
```

Now demonstrate the reopen problem:

```bash
sudo mv /var/log/nginx/access.log /var/log/nginx/access.log.moved
curl -s localhost >/dev/null
ls -la /var/log/nginx/                          # is access.log recreated?
sudo tail -1 /var/log/nginx/access.log.moved    # where did the new line go?
sudo lsof -p "$(pgrep -f 'nginx: worker' | head -1)" | grep access

sudo systemctl reload nginx                      # tells nginx to reopen its files
curl -s localhost >/dev/null
ls -la /var/log/nginx/access.log
sudo rm /var/log/nginx/access.log.moved
```

> **Write in your logbook:** in one sentence, what does `postrotate ... systemctl reload nginx` in `/etc/logrotate.d/nginx` prevent?

---

## Part 3 — Packages, users, time (Day 3)

```bash
apt-cache policy nginx
dpkg -L nginx | head -20
dpkg -S /etc/nginx/nginx.conf
dpkg -S "$(which curl)"
apt list --installed 2>/dev/null | wc -l
```

```bash
# Which packages were installed most recently? (useful after "nothing changed")
grep -E ' install ' /var/log/dpkg.log | tail -20
zgrep -hE ' install ' /var/log/dpkg.log.* 2>/dev/null | tail -5
```

```bash
timedatectl
sudo timedatectl set-timezone UTC
timedatectl show -p NTPSynchronized
```

Deliberately skew the clock and observe the damage. **Skew it backwards** — the direction matters, and getting it wrong is why this exercise is usually taught as a no-op:

```bash
sudo timedatectl set-ntp false

# --- 1. apt: a modest jump into the past ---
sudo date -s '-3 days'
date
sudo apt-get update            # expect apt to complain about the Release file's
                               # validity - it is dated in your "future"

# The knob behind that check, so you can see it is a real rule and not folklore:
# Acquire::Max-FutureTime is how many seconds ahead of "now" a Release file's Date
# header may be before apt rejects it. The default is TEN SECONDS. A three-day
# backwards skew is six orders of magnitude past that.
apt-config dump | grep -i FutureTime           # often empty: unset means the default
man apt.conf | grep -A4 Max-FutureTime

# --- 2. TLS: a jump into the deep past ---
sudo date -s '2019-01-01 00:00:00'
curl -sSI https://ubuntu.com | head -1     # now this genuinely fails. Why?

# --- put it back, and WAIT for it ---
sudo timedatectl set-ntp true
sleep 30 ; timedatectl                     # confirm "System clock synchronized: yes"
```

**Why backwards and not forwards.** Every apt repository's `Release` file carries a `Date:` header, and apt refuses an index whose `Date:` is in the *future* relative to your clock — `Release file ... is not valid yet`. That only happens when your clock is **behind** the repository. Push the clock two hours *forward* and apt sees a `Release` file dated slightly in the past, which is exactly what it expects every day of the week, so nothing at all is printed and the "lesson" teaches nothing. The tolerance is `Acquire::Max-FutureTime`, and `man apt.conf` puts its default at **ten seconds** — apt is not being approximate about this. (The precise wording apt prints for a backward skew varies between apt versions and mirrors, so read whatever it says about `Release` and validity rather than matching a fixed string. And if your mirror was refreshed within the last three days, jump further back.)

**Why a two-hour skew cannot break TLS either.** Certificate validation checks `notBefore <= now <= notAfter`. A public certificate is valid for months, so being two hours off lands you comfortably inside the window. To actually break it you have to leave the window — hence `2019-01-01`, which is before the certificate on essentially any site alive today was issued, and produces a real `certificate is not yet valid` error. That is the useful mental model: **TLS is not sensitive to small skew, it is sensitive to being on the wrong side of a validity boundary** — which is also why an expired certificate and a wrong clock produce indistinguishable symptoms from the client's chair.

> **Warning — a large backwards jump is genuinely disruptive, which is the point of doing it in a throwaway VM.** While the clock reads 2019, `apt` will reject most indexes, every `OnCalendar=` systemd timer recomputes its next run against the wrong year, and anything holding a cached token or lease sees times that make no sense. Recovery is `set-ntp true` plus the `sleep 30` above — do not move on until `timedatectl` reports `System clock synchronized: yes`, and re-run `systemctl list-timers` afterwards to confirm your timers came back to sane schedules.

---

## Part 4 — Storage and scheduling (Day 4)

```bash
lsblk -f ; findmnt ; df -h ; df -i
sudo blkid
```

### 4.1 Make a filesystem by hand

```bash
sudo dd if=/dev/zero of=/opt/lab/disk.img bs=1M count=128 status=progress
sudo mkfs.ext4 -q /opt/lab/disk.img
sudo mkdir -p /mnt/extra
sudo mount -o loop /opt/lab/disk.img /mnt/extra
df -h /mnt/extra ; df -i /mnt/extra
findmnt /mnt/extra
sudo umount /mnt/extra
```

### 4.2 Fill it two different ways

```bash
sudo mount -o loop /opt/lab/disk.img /mnt/extra
sudo chmod 777 /mnt/extra

# by blocks
dd if=/dev/zero of=/mnt/extra/big bs=1M count=200 2>&1 | tail -2
df -h /mnt/extra
rm /mnt/extra/big

# by inodes
sudo umount /mnt/extra
sudo mkfs.ext4 -q -N 256 -F /opt/lab/disk.img       # only 256 inodes
sudo mount -o loop /opt/lab/disk.img /mnt/extra
sudo chmod 777 /mnt/extra
for i in $(seq 1 400); do : > /mnt/extra/f$i 2>/dev/null || { echo "failed at $i"; break; }; done
df -h /mnt/extra          # plenty of space...
df -i /mnt/extra          # ...and zero inodes
```

### 4.3 The deleted-but-open file

```bash
sudo bash -c 'exec 9>/var/log/ghost.log; rm /var/log/ghost.log; dd if=/dev/zero of=/proc/self/fd/9 bs=1M count=100 status=none; sleep 300' &
sleep 3
df -h /
sudo du -xsh /var/log            # does NOT account for it
sudo lsof +L1 | head             # THERE it is
```

Reclaim without killing the process:

```bash
PID=$(sudo lsof +L1 2>/dev/null | awk '/ghost/ {print $2; exit}')
sudo truncate -s 0 /proc/$PID/fd/9
df -h /
sudo kill "$PID"
```

### 4.4 A systemd timer

```bash
sudo tee /etc/systemd/system/labreport.service >/dev/null <<'EOF'
[Unit]
Description=Collect a disk report
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'df -h > /var/log/labreport-$(date +%%F-%%H%%M).txt'
EOF

sudo tee /etc/systemd/system/labreport.timer >/dev/null <<'EOF'
[Unit]
Description=Run the disk report every 2 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
RandomizedDelaySec=10
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now labreport.timer
systemctl list-timers labreport.timer
sleep 130
ls -l /var/log/labreport-*
journalctl -u labreport.service -n 20 --no-pager
```

> **Note the `%%F` double percent.** In a systemd unit, `%` is a specifier escape; `%%` produces a literal `%`. Getting this wrong is a classic, and the error is baffling until you know.

> **Note what is *not* in that `[Timer]` section: `Persistent=true`.** You will see it copied onto timers like this one constantly, and on this one it does nothing at all. `man systemd.timer` is unambiguous — "this setting only has an effect on timers configured with `OnCalendar=`". `Persistent=` works by recording the last trigger time on disk and comparing it against the *wall-clock* schedule at boot, so that a run missed while the machine was off gets fired immediately. `OnBootSec=`/`OnUnitActiveSec=` are **monotonic**: they are relative to boot and to the last activation, so there is no absolute time that could have been missed and nothing for `Persistent=` to catch up. A monotonic timer's schedule *restarts* at every boot by definition. Put `Persistent=true` on a calendar timer — the nightly `03:00` backup in this week's README is the worked example — where it is load-bearing; leave it off a monotonic one, where it is decoration that implies a guarantee you are not getting.

```bash
systemd-analyze calendar "*-*-* 03:00:00"
systemd-analyze calendar "Mon *-*-* 09:00:00" --iterations 3
# `verify` catches what systemd would otherwise ignore in silence: unknown key
# names, and (for a .service) an ExecStart= that is missing or not executable.
# Point it at the SERVICE - run against a .timer it will not tell you the service
# is missing, because it does not follow the activation link. `list-timers` does:
# its ACTIVATES column is what proves the two halves are wired to each other.
systemd-analyze verify /etc/systemd/system/labreport.service
systemctl list-timers labreport.timer --all
```

### 4.5 Compare with cron

```bash
( crontab -l 2>/dev/null; echo '* * * * * /usr/bin/env > /tmp/cron-env.txt' ) | crontab -
sleep 70
cat /tmp/cron-env.txt          # compare with `env` in your shell
crontab -r
```

> **Logbook:** list three variables present in your interactive shell but absent from cron's environment, and name one command that would therefore fail in a cron job but work when you type it.

---

## Part 5 — Drills (Day 5)

```bash
# host
cd infra
make snapshot VM=lab NAME=pre-w02
make break VM=lab DRILL=02-service
```

Symptom: *"The app doesn't come back after a reboot, and now it won't start at all."*
45 minutes. Then reveal, restore, and run `DRILL=02-disk`.
