#!/usr/bin/env bash
# DRILL 05 - 502 Bad Gateway.  Week 05.  Run on the VM hosting nginx.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

command -v nginx >/dev/null || { apt-get update -qq && apt-get install -y -qq nginx; }

install -d -m 0755 /opt/lab/app
cat > /etc/systemd/system/labbackend.service <<'INNER'
[Unit]
Description=Lab backend
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 9000 --bind 127.0.0.1
Restart=always
[Install]
WantedBy=multi-user.target
INNER
systemctl daemon-reload && systemctl enable --now labbackend.service >/dev/null 2>&1 || true

cat > /etc/nginx/sites-available/lab.conf <<'INNER'
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:9001;   # backend actually listens on 9000
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_connect_timeout 2s;
        proxy_read_timeout 5s;
    }
}
INNER
ln -sf /etc/nginx/sites-available/lab.conf /etc/nginx/sites-enabled/lab.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx

base64 -w0 > /root/.drill-05-proxy <<'NOTE'
CAUSE: /etc/nginx/sites-available/lab.conf proxies to 127.0.0.1:9001 but the
backend listens on 127.0.0.1:9000. Nginx cannot connect upstream, so it returns
502 Bad Gateway - which means "I am fine, my upstream is not".
DETECT:
  tail -f /var/log/nginx/error.log
    -> "connect() failed (111: Connection refused) while connecting to upstream"
       errno 111 = ECONNREFUSED = something answered the SYN with a RST, i.e. the
       host is up but nothing is listening on that port. Contrast with 110
       (ETIMEDOUT), which would point at a firewall or a dead host.
  ss -tlnp | grep -E '9000|9001'   -> only 9000 is bound
  curl -sv http://127.0.0.1:9000/  -> backend is healthy
FIX: correct the proxy_pass port, nginx -t, systemctl reload nginx.
LESSON: learn the status-code triage. 502 = upstream unreachable or spoke
        garbage. 504 = upstream reachable but too slow (proxy_read_timeout).
        503 = no healthy upstream in the pool. 500 = the APPLICATION threw.
        Only 500 means the bug is in the app; the rest are infrastructure.
        And: nginx's error.log, not access.log, is where 502s explain themselves.
NOTE
chmod 0600 /root/.drill-05-proxy

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "The website returns '502 Bad Gateway'. Nginx is running - I checked with
   systemctl. I restarted it twice and it didn't help."

  Reproduce it:   curl -i http://localhost/

MSG
