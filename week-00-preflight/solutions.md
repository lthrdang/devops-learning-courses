# Week 00 — Solutions & discussion

> Read only after your 45-minute timebox.

---

## C0.1 — One command, one machine

```bash
#!/usr/bin/env bash
set -euo pipefail

NAME=${1:?usage: newlab.sh <name>}
COURSE_DIR=$(cd "$(dirname "$0")" && pwd)
CI="${COURSE_DIR}/infra/cloud-init/base.yaml"
KEY="${HOME}/.ssh/lab_ed25519"

[[ -f "${KEY}.pub" ]] || ssh-keygen -t ed25519 -N '' -C "lab" -f "$KEY"

# Idempotency: only launch if it does not already exist.
if ! multipass info "$NAME" >/dev/null 2>&1; then
  multipass launch 24.04 --name "$NAME" --cpus 2 --memory 2G --disk 10G --cloud-init "$CI"
else
  echo "[newlab] ${NAME} exists; ensuring it is running"
  multipass start "$NAME"
fi

# Wait for readiness. Never assume; always verify.
multipass exec "$NAME" -- cloud-init status --wait >/dev/null

# Install the key (append only if absent - running twice must not duplicate it)
PUB=$(cat "${KEY}.pub")
multipass exec "$NAME" -- bash -s <<EOF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
grep -qxF '${PUB}' ~/.ssh/authorized_keys || echo '${PUB}' >> ~/.ssh/authorized_keys
EOF

IP=$(multipass info "$NAME" --format csv | awk -F, 'NR>1{print $3}')

# Rewrite the ssh config block idempotently
CFG="${HOME}/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
python3 - "$CFG" "$NAME" "$IP" "$KEY" <<'PY'
import re, sys
cfg, name, ip, key = sys.argv[1:5]
block = f"\n# >>> lab {name}\nHost {name}\n    HostName {ip}\n    User ubuntu\n    IdentityFile {key}\n    StrictHostKeyChecking accept-new\n# <<< lab {name}\n"
s = open(cfg).read()
s = re.sub(rf"\n?# >>> lab {name}\n.*?# <<< lab {name}\n", "", s, flags=re.S)
open(cfg, "w").write(s + block)
PY

echo "[newlab] ${NAME} ready at ${IP} -> ssh ${NAME}"
```

**What to notice:**
- `${1:?usage...}` fails immediately with a message when the argument is missing. Cheaper than an `if`.
- Idempotency is achieved by *checking before acting* and by using `grep -qxF ||` rather than blind appends. A provisioning script you cannot safely re-run is not automation.
- `cloud-init status --wait` is the difference between a script that works and one that works "usually", which is worse.

---

## C0.2 — Evidence that cloud-init ran

Any three of:

| Evidence | Command |
|---|---|
| Status subsystem | `cloud-init status --long` → `status: done` |
| The run transcript | `sudo less /var/log/cloud-init-output.log` (ends with `final_message`) |
| Structured logs | `sudo less /var/log/cloud-init.log` |
| systemd units | `systemctl status cloud-final.service` → `active (exited)` |
| Cached instance data | `sudo cat /var/lib/cloud/instance/user-data.txt` — the exact YAML this boot used |
| Per-boot markers | `ls /var/lib/cloud/instances/*/sem/` — one file per completed module |

**Partial failure** shows as `status: error` from `cloud-init status --long`, plus a populated `recoverable_errors` / `errors` list. Crucially, **the VM still boots and SSH still works** — which is exactly why you must check explicitly rather than infer success from "I can log in".

---

## C0.3 — The silent failure

- `multipass launch` **succeeds**. It waits for the machine to boot, not for provisioning to be correct.
- The VM boots normally and is reachable.
- `cloud-init status --long` reports `status: error`.
- The truth is in `/var/log/cloud-init-output.log`, at the `apt-get install` line: `E: Unable to locate package <name>`.

**Why this is dangerous:** a machine that is *reachable but incompletely configured* will be added to a load balancer, receive production traffic, and fail requests — while every health signal you casually look at (SSH works, the box pings) says it is fine. The general lesson is that **liveness is not readiness**, a distinction that reappears in Docker healthchecks (Week 7), Compose `depends_on` (Week 8) and Swarm task states (Week 10).

**What you would do about it:** make provisioning failure *loud* — have the last `runcmd` verify its own preconditions and, if they fail, prevent the node from ever advertising itself as ready. In cloud terms: never let an instance join the load balancer pool until an explicit readiness check passes.

---

## C0.4 — The cost of cattle

Typical figures (yours will differ; the ratios matter):

| Operation | Time |
|---|---|
| Launch + cloud-init | 60–120 s |
| Restore a snapshot | 5–15 s |
| Stop + start | 20–40 s |

**When to snapshot-restore:** iterating on a destructive experiment, where you want the *same* starting state repeatedly and quickly — every break/fix drill in this course.

**When rebuilding is safer despite being slower:** whenever you need to be certain there is no residue. A snapshot preserves whatever undocumented state existed when you took it, including mistakes you did not notice. A rebuild from cloud-init reconstructs the machine from a description you can read and review. If you cannot rebuild a machine from a file, you do not actually know what is on it — and that is the definition of a pet.

---

## C0.5 — Reading someone else's infrastructure

There is no single right answer, but a good review notes:

- **Ordering dependencies in `runcmd`.** It is a plain list executed top to bottom with no dependency graph. Adding a repository after `apt-get update` means the update was pointless.
- **Pinned versions or not.** `apt-get install docker-ce` installs whatever is current today, so two machines built a month apart differ. Reproducibility usually wants pinning; security patching usually wants floating. Real teams choose deliberately and write down why.
- **Secrets in plaintext.** If you find an API token or password in a `write_files` block, that is a finding: cloud-init user-data is readable from inside the instance and often via the cloud's metadata service.
- **Idempotency.** cloud-init runs once, so people write non-idempotent commands. That is fine until someone reuses the snippet somewhere it runs repeatedly.

---

## C0.6 — The forbidden question

A strong answer sounds roughly like:

> Nothing forces you to change it while it works. The problem is what happens when it stops. Nobody can tell you what is on that machine, so nobody can rebuild it, patch it confidently, or test a change against a copy of it — which means a hardware failure or a security advisory becomes an outage of unknown length rather than a scheduled task. Writing its configuration down as code costs a few days once and converts an unbounded risk into a bounded one. The benefit is not tidiness; it is that recovery time becomes something you can measure.

Note what it avoids: no jargon, no appeal to authority, and it is framed in terms of **risk and recovery time**, which is what the people who fund your work actually care about.
