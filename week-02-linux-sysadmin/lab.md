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
sudo -u appuser -s        # what happens, and why? (nologin)
```

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
sudo systemctl edit labapp        # opens an EMPTY drop-in editor
# add:
#   [Service]
#   Environment=GREETING=from-a-dropin
sudo systemctl restart labapp
curl -s localhost:8080/ | jq -r .greeting

cat /etc/systemd/system/labapp.service | grep GREETING    # says "hello"
systemctl cat labapp | grep GREETING                       # says BOTH - last wins
systemctl show labapp -p Environment
```

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

```bash
journalctl --list-boots            # only one? then it is volatile
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
sudo reboot            # from the host: multipass restart lab
# after it returns:
journalctl --list-boots            # now shows the previous boot too
journalctl -b -1 -u labapp --no-pager | tail
```

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

Deliberately skew the clock and observe the damage:

```bash
sudo timedatectl set-ntp false
sudo date -s '+2 hours'
sudo apt-get update            # read any warning about the Release file
curl -sI https://ubuntu.com | head -1    # TLS may now fail. Why?
sudo timedatectl set-ntp true
sleep 30 ; timedatectl
```

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
Persistent=true
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

```bash
systemd-analyze calendar "*-*-* 03:00:00"
systemd-analyze calendar "Mon *-*-* 09:00:00" --iterations 3
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
