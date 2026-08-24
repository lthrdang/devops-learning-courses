# Week 11 — Solutions & discussion

---

## C11.3 — Rotate everything

### 1. The database password — and the Week 8 trap

```bash
# WRONG: this does nothing to an existing database.
echo -n 'newpass' > secrets/db_password.txt && docker stack deploy -c stack.yml lab
```

`POSTGRES_PASSWORD` is read **only when the data directory is empty**. The database still expects the old password; the app now sends the new one; every request fails authentication. You have caused an outage with a security improvement.

```bash
# RIGHT, and zero-downtime:
NEW=$(openssl rand -base64 32)

# 1. change it IN the database first. The app is still using the old one and
#    keeps working, because postgres accepts the change immediately but
#    existing connections are unaffected.
docker exec -i "$(docker ps -qf name=lab_db)" \
  psql -U postgres -c "ALTER USER postgres PASSWORD '$NEW';"

# 2. create a NEW swarm secret - secrets are immutable, so you never edit one
echo -n "$NEW" | docker secret create db_password_v2 -

# 3. swap it in as a rolling update, keeping the in-container path identical
docker service update \
  --secret-rm db_password \
  --secret-add source=db_password_v2,target=db_password \
  --update-order start-first \
  --detach=false \
  lab_api

# 4. only now remove the old secret
docker secret rm db_password
```

**Where a mistake causes an outage:** doing steps 1 and 3 in the reverse order. If you roll the app to the new secret first, every replica fails to authenticate until step 1 lands — and because they fail their healthcheck, Swarm rolls back to a version that also cannot authenticate. **Change the accepting side before the sending side.** That ordering rule generalises to every credential rotation you will ever do.

### 2. TLS certificate

```bash
docker config create tls_cert_v2 ./new.crt
docker config create tls_key_v2 ./new.key
docker service update \
  --config-rm tls_cert --config-add source=tls_cert_v2,target=/etc/nginx/tls/app.crt \
  --config-rm tls_key  --config-add source=tls_key_v2,target=/etc/nginx/tls/app.key \
  --update-order start-first --detach=false lab_web
```

Overlap the validity windows: issue the new certificate **before** the old expires, so there is no moment where neither is valid. Automate with a timer that renews at 2/3 of the lifetime, and **alert on expiry-minus-14-days** — the number of outages caused by expired certificates is a standing embarrassment of the industry.

### 3. SSH key for the deploy user

```bash
ssh-keygen -t ed25519 -f ~/.ssh/deploy_v2 -N ''
# ADD the new key first - both now work
cat ~/.ssh/deploy_v2.pub | ssh deployer@node1 'cat >> ~/.ssh/authorized_keys'
# verify the new key independently
ssh -i ~/.ssh/deploy_v2 deployer@node1 'echo ok'
# update CI to the new key, confirm a pipeline run succeeds
# ONLY THEN remove the old one
ssh -i ~/.ssh/deploy_v2 deployer@node1 "sed -i '/old-key-comment/d' ~/.ssh/authorized_keys"
```

**Add, verify, switch, remove.** Removing before verifying locks out your own automation, and the tool you would use to fix it is the one you just broke.

**The pattern across all four:** *add the new, verify it independently, switch traffic, then remove the old.* It is the same shape as the zero-downtime deploy from Week 5 (C5.1) and Swarm's `start-first`. Once you see that all of these are the same procedure, rotation stops being frightening.

---

## C11.2 — Recover from total loss

**The runbook, in the order it must happen:**

```bash
# 0. What do you actually have?  If any answer is "I don't know", stop and
#    find out BEFORE you need this.
#      - the backup files, and their checksums          -> off-site?
#      - the git repo with stack.yml and configs        -> cloned where?
#      - the secrets                                    -> NOT in the same place
#      - the images                                     -> registry, or rebuildable?

# 1. New host, base config
multipass launch 24.04 --name node1b --cloud-init infra/cloud-init/docker-node.yaml

# 2. Restore configuration FROM GIT - not from memory, not from a backup
git clone <repo> stack && cd stack

# 3. Recreate the secrets (from your secret store, which is separate)
echo -n "$DB_PASSWORD" | docker secret create db_password -

# 4. Bring up the data layer FIRST and restore into it
docker stack deploy -c stack.yml lab
./backup-verify.sh verify /backups/appdb-latest.sql.gz     # verify BEFORE restoring
./backup-verify.sh restore /backups/appdb-latest.sql.gz --yes

# 5. Then the application
docker service update --image "$REGISTRY/api:$KNOWN_GOOD" --detach=false lab_api

# 6. Verify like a user
./scripts/smoke-test.sh http://node1b:8080
```

**Typical measured times:**

| Step | Time |
|---|---|
| VM provision + cloud-init | 2–3 min |
| Restore configuration from git | 1 min |
| Recreate secrets | 2 min (longer if you have to find them) |
| Restore the database | **depends entirely on size** — this dominates |
| Redeploy services | 2 min |
| **Total for a small stack** | **15–30 min** |

**The step that takes longest is almost always the database restore**, and the one that goes wrong most often is *finding the secrets*, because they are deliberately not in git and people forget where they put them.

**One change that halves it:** keep a warm standby with streaming replication, so recovery is a promotion rather than a restore. That trades ongoing cost for RTO — and being able to state that trade-off in those terms is the actual deliverable.

**The most valuable part of this exercise is running the runbook a second time.** The first run is full of steps you did from memory without writing down. The second run finds them.

---

## C11.4 — Make the pipeline refuse

```yaml
- name: Reject root
  run: |
    user=$(docker inspect "$IMG" --format '{{.Config.User}}')
    [ -n "$user" ] && [ "$user" != "root" ] && [ "$user" != "0" ] \
      || { echo "::error::image runs as root"; exit 1; }

- name: Size budget
  run: |
    bytes=$(docker inspect "$IMG" --format '{{.Size}}')
    mb=$(( bytes / 1024 / 1024 ))
    echo "image is ${mb}MB"
    [ "$mb" -le 200 ] || { echo "::error::image ${mb}MB exceeds the 200MB budget"; exit 1; }

- name: Secret scan
  run: docker run --rm -v "$PWD:/src" aquasec/trivy fs --scanners secret --exit-code 1 /src

- name: CVE gate
  run: trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed "$IMG"
```

**Hard failure versus warning, for a team shipping ten times a day:**

| Gate | Verdict | Why |
|---|---|---|
| test failure | **hard** | non-negotiable; this is what tests are for |
| secret detected | **hard** | a leaked credential cannot be un-leaked. Highest cost, lowest false-positive rate |
| smoke test after deploy | **hard**, with automatic rollback | it is already in production; failing loudly and reverting is the whole point |
| runs as root | **hard** | trivially fixable, one line, no legitimate reason to skip |
| CRITICAL CVE | **hard, with `--ignore-unfixed`** | without that flag it blocks builds for things you cannot fix, and someone will disable the gate entirely |
| image size | **warning** | a legitimate new dependency can exceed the budget, and blocking a release over 12 MB is how gates lose credibility |

**The principle: a gate that fires often and cannot be acted on will be disabled, and then it protects nothing.** Every hard gate must be *fixable by the person who tripped it, today*. That test — not severity — is what decides hard versus warning. A team that ships ten times a day cannot afford a gate with a 20% false-positive rate; they will route around it within a week, and you will have made things worse than having no gate at all.

---

## C11.6 — Threat model

**What an attacker wants:** the customer database, credentials that reach further, or your compute for cryptomining. In practice, most attacks are opportunistic and want the third.

| Way in | What they reach | Cheapest control |
|---|---|---|
| SSH brute force | full host, then the `docker` group, then everything | `PasswordAuthentication no`. **One line, eliminates the entire class** |
| A published database port | all customer data directly | do not publish it — internal network only. Zero cost |
| A vulnerable dependency in the app image | the app container; then the overlay network, and the database credentials in `/run/secrets` | non-root user, `--cap-drop=ALL`, `--read-only`, and rebuild weekly |
| A compromised CI token | push a malicious image that deploys automatically | short-lived tokens, and a deploy that requires a signed tag |
| A stolen laptop with an unencrypted SSH key | whatever that key reaches | passphrase on the key, plus per-user keys so one can be revoked |

**Cheapest control with the largest risk reduction: `PasswordAuthentication no`, plus not publishing the database port.** Both are one line, both are free, and between them they remove the two ways almost every small deployment is actually breached. Everything else on the list is real but secondary.

**What I am explicitly not defending against, and why:** a targeted attacker with a zero-day in the Linux kernel, or a supply-chain compromise of an upstream base image. Defending against those requires resources a five-person team does not have — runtime security monitoring, reproducible builds, an SBOM pipeline with attestation. **The right posture is to make opportunistic attacks fail and to ensure a determined one leaves evidence** (centralised logs the attacker cannot edit — which is what shipping to Loki on a different host buys you). Stating this explicitly is not defeatism; a threat model that claims to cover everything is one nobody has thought about carefully.

---

## C11.7 — The disaster you have not planned for

A model answer, for a stack with backups but a single database:

> **The gap: our database has no replica, and our backups are on the same host as the database.** If that host's disk fails, we lose both.
>
> **Cost if it happened tomorrow:** the last off-host copy is whatever was synced to the office NAS, which is up to 24 hours old. So we lose up to a day of customer orders — data we cannot reconstruct and would have to ask customers about individually. Recovery is roughly 30 minutes once we have a host, but the reputational cost of "we lost your order" is the real number, and it is much larger than the 30 minutes. Call it two days of engineering time, a week of support load, and an unknown number of customers who do not come back.
>
> **Cost to be ready:** a streaming replica on a second host is about two days of work and one more machine — roughly €30/month. It reduces RPO from 24 hours to seconds and RTO from 30 minutes to a promotion of a few minutes. Shipping backups off-site to object storage is another half day and a few euros a month, and it independently removes the "backups died with the database" failure.
>
> **Recommendation: do the off-site backups this week, and the replica this quarter.** The off-site copy is a half day and removes the *catastrophic* version of this failure — losing everything. The replica removes the *painful* version — losing a day. Doing the cheap one first is not a compromise; it is the correct order, because it buys the larger risk reduction per hour spent.
>
> **What I am accepting in the meantime:** up to 24 hours of data loss for the next few weeks, knowingly, with the team informed. That is a decision, not an oversight, and it is written down here so that if it happens nobody has to reconstruct whether we knew.

**Why this is the right shape of answer:** it names a real gap rather than a generic one, prices both sides in units a manager can act on, sequences the work by risk-reduction-per-effort rather than by completeness, and — most importantly — **explicitly records the accepted risk**. An engineer who says "we accept 24 hours of data loss until March, and here is why" is doing risk management. One who silently hopes is not, and the difference only becomes visible on the worst day.
