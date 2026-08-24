# Week 11 — Production Concerns: Security, Backup, CI/CD

**VM profile:** `make w11-up` → `node1`, `node2`, `node3` (the Week 10 cluster)
**You will be able to:** harden a host, run your own registry and CI, ship a change from commit to cluster automatically, and get it back when it breaks.

> Weeks 1–10 built a system. This week is about the things that decide whether you still have it next month: someone breaking in, a disk dying, and a deploy going wrong at the worst possible moment.

---

## Day 1 — Hardening the host

### 1.1 SSH

The single most-attacked service on any internet-facing Linux box.

```bash
# /etc/ssh/sshd_config.d/99-hardening.conf
PermitRootLogin no
PasswordAuthentication no          # keys only - the highest-value line here
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers deployer ubuntu
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
```

```bash
sudo sshd -t                       # VALIDATE FIRST. A broken config locks you out.
sudo systemctl reload ssh
```

> **Never restart sshd without an open session to fall back on**, and never before `sshd -t` passes. Test the new configuration from a *second* terminal before closing the first. People lock themselves out of remote servers this way regularly, and on a cloud VM without console access that means rebuilding it.

`PasswordAuthentication no` eliminates brute-force entirely. Tools like `fail2ban` are then largely redundant for SSH — worth understanding, because "install fail2ban" is often cargo-culted onto systems that already accept only keys.

### 1.2 The firewall, and Docker

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow from 10.0.0.0/8 to any port 2377 proto tcp
sudo ufw --force enable
```

**Remember Week 7 §3.3: Docker bypasses ufw.** A published container port is reachable regardless of your rules. The defences:

- publish to a specific interface (`-p 127.0.0.1:8080:80`);
- never publish database ports at all — put them on an internal network;
- in Swarm, prefer `mode: host` publishing behind an external LB when you need per-node control.

Verifying what is *actually* exposed, rather than what you believe is exposed:

```bash
sudo ss -tlnp                              # what is listening, and as whom
sudo nft list ruleset | grep -A5 DOCKER    # what Docker inserted
# and from ANOTHER machine - the only test that counts:
nmap -Pn -p- <NODE_IP>
```

### 1.3 Unattended upgrades

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
cat /etc/apt/apt.conf.d/50unattended-upgrades
```

Enable **security** updates automatically. The trade-off is real: automatic patching occasionally breaks something, and not patching reliably gets you compromised. For security updates specifically, automatic wins — but set `Unattended-Upgrade::Automatic-Reboot "false"` and reboot on your own schedule, so a kernel update does not restart a node during business hours.

### 1.4 Least privilege, stated plainly

- One **service account** per service: no shell, no home, no password (Week 2).
- `sudo` policies narrow enough to be meaningful — `deployer ALL=(root) NOPASSWD: /usr/bin/docker service update *` beats blanket `ALL`.
- **The `docker` group is root.** `docker run -v /:/host` reads `/etc/shadow`. Treat membership as equivalent to a root grant, and say so when someone requests it.

---

## Day 2 — Supply chain and secrets

### 2.1 Scanning, and what it is worth

```bash
trivy image --severity HIGH,CRITICAL myapp:1.0
trivy image --exit-code 1 --severity CRITICAL myapp:1.0     # a CI gate
trivy fs --scanners vuln,secret,misconfig .
```

**Be honest about what a scanner tells you.** It reports *known CVEs in packages present in the image*. It does not know whether the vulnerable code path is reachable, and a large fraction of findings in a base image are in packages your application never calls.

The useful policy is therefore **not** "zero CVEs" — that is unachievable and trains people to add ignore-rules. It is:

1. **Reduce what is in the image** (multi-stage, distroless, no shell, no compiler). Fewer packages, fewer findings, smaller real attack surface. This is the highest-leverage move and it is free.
2. **Fail CI on CRITICAL only**, and review HIGH.
3. **Rebuild regularly.** Most fixes arrive by rebuilding on a newer base, not by changing your code. A pipeline that rebuilds weekly fixes more than any triage process.

### 2.2 Pinning and provenance

```dockerfile
FROM python:3.12-slim@sha256:2a2a1...     # a digest is immutable; a tag is not
```

A tag is a *pointer* and can be moved. `python:3.12-slim` today and tomorrow may be different images. Pin by digest where reproducibility matters, and use Dependabot/Renovate to raise the pin regularly — pinning without a bump process is how you end up two years behind.

### 2.3 Secrets, ranked

| Method | Verdict |
|---|---|
| Hardcoded in the image | never. Extractable from a layer forever (Week 7 C7.6) |
| `ENV` in a Dockerfile | never. Visible in `docker inspect` and `docker history` |
| `environment:` in compose | acceptable only for non-secrets |
| A mounted file, mode 0600 | acceptable on a single host (Week 8) |
| **Docker/Swarm secrets** | good: encrypted at rest and in transit, tmpfs-mounted (Week 10) |
| Vault / SOPS / age | best: audited access, real rotation, and secrets can live in git *encrypted* |

**Rotation is the part everyone skips.** A secret you cannot rotate in under an hour is a secret you will not rotate when it leaks. Write the runbook before you need it — and remember from Week 8 that changing `POSTGRES_PASSWORD` does not change an initialised database's password.

---

## Day 3 — Backups that are actually restores

### 3.1 The only definition that matters

> **A backup is not a backup until you have restored it.** Everything else is a file you hope is useful.

**3-2-1:** three copies, two media types, one off-site. And the numbers that turn it into engineering:

- **RPO** (Recovery Point Objective) — how much data may you lose? This sets backup *frequency*.
- **RTO** (Recovery Time Objective) — how long may recovery take? This sets backup *method*.

You do not know your RTO until you have timed a real restore. Week 3 and Week 8 both made you do this; this week you automate it.

### 3.2 What to back up

| Thing | How | Note |
|---|---|---|
| Databases | `pg_dump` / `mysqldump`, or a filesystem snapshot with the DB quiesced | **never** copy a live data directory — you get a torn, unrestorable file |
| Volumes | `tar` from a helper container mounting the volume | stop the writer, or accept inconsistency |
| Configuration | **git** | if config is not in git, you are backing up a mystery |
| Secrets | a separate encrypted store | do **not** put them in the same backup as the data they protect |
| The images themselves | a registry, replicated | a backup you cannot deploy is not a recovery plan |

### 3.3 Automating the verification

```bash
# The bit that makes it real: restore into a scratch database and check.
gzip -dc backup.sql.gz | docker exec -i verify-db psql -U postgres -d scratch
docker exec verify-db psql -U postgres -d scratch -c 'SELECT count(*) FROM users;'
```

A weekly job that restores the latest backup into a throwaway container and asserts a row count is worth more than any amount of backup monitoring. **Monitoring tells you the backup job exited 0; only a restore tells you the backup is usable** — and Week 3's drill was exactly a job that exited 0 for three weeks while producing nothing.

---

## Day 4 — CI/CD

### 4.1 The pipeline

```
commit → lint → test → build image → scan → push to registry → deploy → verify → (rollback)
```

Every stage is a gate. The two that people omit and then regret: **scan** and **verify**.

### 4.2 A registry of your own

```bash
docker run -d --name registry -p 5000:5000 -v regdata:/var/lib/registry registry:2
docker tag myapp:1.0 node1:5000/myapp:1.0
docker push node1:5000/myapp:1.0
```

Swarm needs this: `build:` is ignored, so **every node must be able to pull the image** (Week 10 §3.1). A plain HTTP registry requires configuring `insecure-registries` in `/etc/docker/daemon.json` on every node — acceptable in a lab, and worth doing with TLS in anything real.

### 4.3 Tagging

**Never deploy `:latest`.** It is a mutable pointer, so you cannot tell what is running, cannot roll back deterministically, and `docker service update --image app:latest` may not even pull a new image because the tag has not changed.

```
myapp:1.4.2                    a release
myapp:1.4.2-a3f9c2d            release + commit — my preference
myapp:sha-a3f9c2d              immutable, traceable to one commit
```

The rule: **the running version must be traceable to exactly one commit.** Everything else follows from that.

### 4.4 Gitea Actions — free, self-hosted, GitHub-compatible

Gitea is a lightweight open-source Git service whose Actions are compatible with GitHub Actions workflow syntax. That means you learn one syntax and can run it on your own hardware or on GitHub.

```yaml
name: build-and-deploy
on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: shellcheck scripts/*.sh
      - run: python -m pytest -q

  build:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: docker build -t $REGISTRY/myapp:sha-${GITHUB_SHA::7} .
      - name: Scan
        run: trivy image --exit-code 1 --severity CRITICAL $REGISTRY/myapp:sha-${GITHUB_SHA::7}
      - name: Push
        run: docker push $REGISTRY/myapp:sha-${GITHUB_SHA::7}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Rolling update
        run: |
          docker -H ssh://deployer@node1 service update \
            --image $REGISTRY/myapp:sha-${GITHUB_SHA::7} \
            --update-order start-first \
            --update-failure-action rollback \
            --detach=false \
            lab_api
      - name: Verify
        run: ./scripts/smoke-test.sh https://app.lab.local
```

Two details worth copying: `--detach=false` makes the deploy step **wait** and fail the pipeline if the update fails, and the separate **verify** step tests the thing a user does. A pipeline that goes green when the deploy command returns has verified nothing.

### 4.5 Deploy safety

| Strategy | How | Cost |
|---|---|---|
| **Rolling** | replace tasks in batches | the default; brief mixed-version state |
| **Blue/green** | run both, switch the LB, keep blue warm | double the resources; instant rollback |
| **Canary** | send 5% of traffic to the new version first | needs traffic splitting and per-version metrics |

**Mixed-version state is the constraint people forget.** During any rolling update, v1 and v2 run simultaneously against the same database. Therefore: **every schema migration must be backward-compatible with the previous release.** Add a column, deploy code that writes both, backfill, deploy code that reads the new one, *then* drop the old. Renaming a column in one step breaks every request served by the old replicas — and it is the most common way a "zero downtime" deploy causes an outage.

---

## Day 5 — Drill and consolidation

No new chaos script. Instead:

1. **A restore drill against a stopwatch.** Destroy the database, restore it, and write down the elapsed time. That number is your RTO.
2. **A rollback drill.** Deploy a deliberately broken image and recover — first with automatic rollback, then by hand with automatic rollback disabled.
3. **An exposure audit.** From another machine, `nmap` every node and justify each open port. Anything you cannot justify, close.

## Recommended reading

- CIS Benchmarks for Ubuntu and Docker — free, and the basis for most audits
- *Google SRE Book*, release-engineering chapter — <https://sre.google/books/>
- OWASP Docker Security Cheat Sheet — <https://cheatsheetseries.owasp.org/>
- Trivy — <https://trivy.dev/> · Gitea — <https://docs.gitea.com/usage/actions/overview>
- *Continuous Delivery*, Humble & Farley — the definitive book on pipeline design
