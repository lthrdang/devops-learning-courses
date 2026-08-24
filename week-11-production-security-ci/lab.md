# Week 11 — Lab

```bash
cd infra && make w11-up        # reuses the week-10 cluster
```

---

## Part 1 — Harden a host (Day 1)

> **Open a second SSH session before you touch sshd, and do not close it until the new config is proven.** This is not a suggestion.

```bash
# terminal 1 - your safety line. Leave it open.
ssh ubuntu@node1

# terminal 2 - do the work here
ssh ubuntu@node1
```

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF

sudo sshd -t && echo "config VALID"      # if this fails, STOP
sudo systemctl reload ssh
```

Now, from your **host**, open a *third* session before closing anything:

```bash
ssh node1 'echo "new session works"'
```

Only when that succeeds may you close terminal 2.

```bash
# 1.1 Prove password auth is gone
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no ubuntu@node1
# expect: Permission denied (publickey)
```

```bash
# 1.2 See who has been trying
sudo journalctl -u ssh --since "1 day ago" | grep -ci 'failed\|invalid' || echo 0
sudo lastb 2>/dev/null | head    # failed logins, if btmp exists
```

### 1.3 The exposure audit — the only test that counts

```bash
# on node1
sudo ss -tlnp
sudo nft list ruleset | grep -c DOCKER
```

From **another machine**:

```bash
sudo apt-get install -y nmap
nmap -Pn -p- --min-rate 1000 <NODE1_IP>
```

For every open port, write down: what it is, why it is open, and who should reach it. Then close everything you cannot justify.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow from 10.0.0.0/8 to any port 2377 proto tcp
sudo ufw allow from 10.0.0.0/8 to any port 7946
sudo ufw allow from 10.0.0.0/8 to any port 4789 proto udp
sudo ufw --force enable
```

Re-run `nmap` from outside. **Any published Docker port is still open** — that is Week 7 §3.3, and it is the point of this exercise. Confirm it, then fix it properly by not publishing what should not be published.

### 1.4 Prove the docker-group escalation

```bash
docker run --rm -v /:/host alpine sh -c 'head -2 /host/etc/shadow'
```

Write the one-sentence policy you would put in your team's onboarding document about who gets added to the `docker` group.

---

## Part 2 — Supply chain (Day 2)

```bash
docker pull python:3.12-slim
trivy image --severity HIGH,CRITICAL python:3.12-slim | tail -20
trivy image --severity HIGH,CRITICAL --ignore-unfixed python:3.12-slim | tail -5
```

> Note the difference `--ignore-unfixed` makes. Findings with **no available fix** are not actionable — gating CI on them means blocking every build for something you cannot do anything about, which is how teams end up disabling the scanner entirely.

```bash
# 2.1 Compare a fat image with a lean one
cd ~/course/week-07-docker-fundamentals/files/app
docker build -q -t lab/app:1.0 .
docker build -q -f Dockerfile.bad -t lab/app:bad .

for t in 1.0 bad; do
  echo "=== lab/app:$t ==="
  docker images lab/app:$t --format '  size: {{.Size}}'
  trivy image --severity HIGH,CRITICAL --ignore-unfixed -q lab/app:$t 2>/dev/null | grep -c 'HIGH\|CRITICAL' || true
done
```

> **The strongest security control here is not the scanner — it is removing software.** Fewer packages, fewer findings, and a smaller *real* attack surface. Record both numbers.

```bash
# 2.2 Pin by digest
docker inspect python:3.12-slim --format '{{index .RepoDigests 0}}'
# put that digest in your FROM line and rebuild
```

```bash
# 2.3 Find secrets that should not be there
trivy fs --scanners secret,misconfig ~/course
```

---

## Part 3 — Registry and CI (Day 4)

```bash
# 3.1 A registry the cluster can pull from
docker run -d --name registry --restart always -p 5000:5000 \
  -v regdata:/var/lib/registry registry:2

# every node must trust it (plain HTTP - lab only)
for n in node1 node2 node3; do
  ssh "$n" 'sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{ "insecure-registries": ["node1:5000"],
  "log-driver": "json-file", "log-opts": {"max-size":"10m","max-file":"3"} }
EOF
sudo systemctl restart docker'
done
```

```bash
# 3.2 Build, push, deploy
cd ~/course/week-08-docker-compose/files/stack/api
TAG="sha-$(git rev-parse --short HEAD 2>/dev/null || echo manual)"
docker build -t node1:5000/swarm-api:$TAG .
docker push node1:5000/swarm-api:$TAG
docker service update --image node1:5000/swarm-api:$TAG --detach=false lab_api
```

> **`build:` is ignored by Swarm** (Week 10 §3.1). This is the workflow that replaces it, and every node must be able to pull — which is why the registry and the `insecure-registries` change come first.

### 3.3 Gitea and a real pipeline

```bash
docker run -d --name gitea -p 3001:3000 -p 2222:22 \
  -v giteadata:/data --restart always gitea/gitea:latest
```

Open `http://<NODE1_IP>:3001`, complete setup, create a repository, push your app, and add `.gitea/workflows/ci.yml` from `files/workflows/`. Register a runner following the Gitea Actions docs, then push a commit and watch the pipeline.

**Then deliberately break each gate and confirm the pipeline stops:**

| Break | Expected |
|---|---|
| a shellcheck error in a script | `lint` fails, nothing is built |
| a failing unit test | `test` fails, nothing is built |
| a CRITICAL CVE (use an old base image) | `scan` fails, nothing is pushed |
| an app that fails its healthcheck | `deploy` fails, Swarm auto-rolls-back |
| an app that starts but returns 500 | **`smoke-test` fails**, and the job rolls back |

> That last row is the one that justifies the verify stage. Swarm's healthcheck said the container was fine; only a test that does what a *user* does caught it.

---

## Part 4 — Backups (Day 3)

```bash
cp ~/course/week-11-production-security-ci/files/backup-verify.sh ~/
chmod +x ~/backup-verify.sh
```

```bash
# 4.1 Put known data in
docker exec -i stack-db-1 psql -U postgres -d appdb <<'EOF'
CREATE TABLE IF NOT EXISTS canary(id int primary key, note text);
INSERT INTO canary VALUES (1,'before backup') ON CONFLICT DO NOTHING;
EOF

# 4.2 Back up
BACKUP=$(./backup-verify.sh backup)
echo "artefact: $BACKUP"
ls -lh "$BACKUP"*
```

```bash
# 4.3 VERIFY - restores into a throwaway container and asserts content
./backup-verify.sh verify "$BACKUP"
```

> Read the output. The gzip check and the checksum only prove the file is well-formed. **The line that matters is `VERIFIED: restores cleanly, N table(s)`** — everything before it would also pass for a backup of the wrong database.

```bash
# 4.4 The real drill: destroy and recover, against a stopwatch
docker exec -i stack-db-1 psql -U postgres -d appdb -c 'DROP TABLE canary;'
./backup-verify.sh restore "$BACKUP" --yes
docker exec -i stack-db-1 psql -U postgres -d appdb -c 'SELECT * FROM canary;'
```

**Write the reported restore time in your logbook. That number is your RTO.**

```bash
# 4.5 Prove a corrupt backup is caught
cp "$BACKUP" /tmp/corrupt.sql.gz
printf 'garbage' | dd of=/tmp/corrupt.sql.gz bs=1 seek=100 conv=notrunc 2>/dev/null
./backup-verify.sh verify /tmp/corrupt.sql.gz ; echo "exit=$?"
```

```bash
# 4.6 Automate it, with verification
sudo tee /etc/systemd/system/pgbackup.service >/dev/null <<'EOF'
[Unit]
Description=Verified Postgres backup
[Service]
Type=oneshot
ExecStart=/home/ubuntu/backup-verify.sh backup
# The SECOND ExecStart runs only if the first succeeded. A backup job that
# does not verify is the week-3 drill waiting to happen.
ExecStart=/bin/bash -c '/home/ubuntu/backup-verify.sh verify "$(ls -t /var/backups/pg/*.sql.gz | head -1)"'
EOF

sudo tee /etc/systemd/system/pgbackup.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly verified backup
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=600
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable --now pgbackup.timer
sudo systemctl start pgbackup.service
journalctl -u pgbackup.service -n 30 --no-pager
```

---

## Part 5 — Deploy safety (Day 4)

### 5.1 The backward-compatible migration

Simulate the mixed-version problem:

```sql
-- WRONG: breaks every request served by an old replica during the rollout
ALTER TABLE users RENAME COLUMN email TO email_address;
```

```sql
-- RIGHT, in four deploys:
-- 1. ALTER TABLE users ADD COLUMN email_address text;
-- 2. deploy code that WRITES both columns and READS the old one
-- 3. backfill:  UPDATE users SET email_address = email WHERE email_address IS NULL;
-- 4. deploy code that reads the new one; a later release drops the old column
```

> **During any rolling update, both versions run against the same database.** Every migration must be backward-compatible with the previous release. This is the most common way a "zero downtime" deploy causes an outage, and it has nothing to do with the orchestrator.

### 5.2 Rollback drill

```bash
# with automatic rollback
docker service update --image node1:5000/swarm-api:broken --detach=false lab_api
docker service inspect lab_api --format '{{.UpdateStatus.State}} {{.UpdateStatus.Message}}'

# now WITHOUT it - do it by hand, and time yourself
docker service update --update-failure-action pause --image node1:5000/swarm-api:broken --detach lab_api
# ... recover manually ...
docker service rollback --detach=false lab_api
```

Write down both elapsed times. The difference is what `failure_action: rollback` is worth.

---

## Part 6 — Consolidation (Day 5)

Produce three artefacts and keep them:

1. **An exposure report** — every open port on every node, justified.
2. **A measured RTO** — the real restore time, plus what you would need to change to halve it.
3. **A deploy runbook** — how to ship, how to verify, how to roll back, and who to tell.
