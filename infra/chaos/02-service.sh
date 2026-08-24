#!/usr/bin/env bash
# DRILL 02 - systemd service that does not survive a reboot.  Week 02.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

install -d -m 0755 /opt/lab/app
cat > /opt/lab/app/serve.py <<'INNER'
#!/usr/bin/env python3
import http.server, socketserver, os
PORT = int(os.environ.get("PORT", "8080"))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","text/plain")
        self.end_headers(); self.wfile.write(b"lab app ok\n")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("0.0.0.0", PORT), H) as s:
    s.serve_forever()
INNER
chmod 0755 /opt/lab/app/serve.py

cat > /etc/systemd/system/labapp.service <<'INNER'
[Unit]
Description=Lab demo application
After=network.target

[Service]
Type=simple
User=ubuntu
Environment=PORT=8080
ExecStart=/usr/bin/python3 /opt/lab/app/serve.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
INNER

systemctl daemon-reload
systemctl start labapp.service   # running NOW ...

# --- the damage ---
# ... but never enabled, so it will not start at boot. The service is healthy
# right up until the machine restarts.
systemctl disable labapp.service >/dev/null 2>&1 || true

# A second, independent trap for whoever tries to just `systemctl enable` it:
# a drop-in overrides ExecStart with a path that does not exist. `systemctl cat`
# reveals it; `cat /etc/systemd/system/labapp.service` alone does not.
install -d -m 0755 /etc/systemd/system/labapp.service.d
cat > /etc/systemd/system/labapp.service.d/10-override.conf <<'INNER'
[Service]
ExecStart=
ExecStart=/usr/local/bin/python3 /opt/lab/app/serve.py
INNER
systemctl daemon-reload

base64 -w0 > /root/.drill-02-service <<'NOTE'
CAUSE 1: the unit was started but never enabled. `systemctl is-enabled labapp`
prints "disabled"; there is no symlink in multi-user.target.wants/, so nothing
starts it at boot. "Running" and "enabled" are independent states.
CAUSE 2: a drop-in at /etc/systemd/system/labapp.service.d/10-override.conf
resets ExecStart and points it at /usr/local/bin/python3, which does not exist.
The main unit file looks perfect - you must run `systemctl cat labapp` or
`systemctl show -p ExecStart labapp` to see the effective configuration.
FIX: rm the drop-in (or correct the path), systemctl daemon-reload,
     systemctl enable --now labapp
LESSON: `systemctl cat` shows unit + all drop-ins. Always prefer it to `cat`.
        status=203/EXEC means "the binary in ExecStart could not be executed".
NOTE
chmod 0600 /root/.drill-02-service

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "The lab app is fine right now, but after the nightly patch reboot it's always
   dead and I have to start it by hand. Also, when I tried to fix it myself this
   morning it wouldn't start at all any more."

  Reproduce it:   sudo systemctl restart labapp ; systemctl status labapp
  Then ask:       will this come back after `sudo reboot`?

MSG
