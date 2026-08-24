# Week 06 — Lab

```bash
cd infra && make w06-up && multipass shell lab
sudo apt-get install -y python3-venv python3-pip
mkdir -p /opt/lab/w06 && cd /opt/lab/w06
```

---

## Part 1 — Environments (Day 1)

```bash
# 1.1 See the protection working
pip install httpx                    # read the error carefully
```

> `externally-managed-environment` is the system telling you that installing here could break `apt`. **Do not reach for `--break-system-packages`.** The flag is honestly named.

```bash
# 1.2 The right way
python3 -m venv .venv
source .venv/bin/activate
which python3 pip                    # note the paths changed
pip install --upgrade pip
pip install httpx
python3 -c "import httpx; print(httpx.__version__)"
deactivate
python3 -c "import httpx"            # fails outside the venv - as designed
```

```bash
# 1.3 A venv is just a directory
ls .venv/bin | head
.venv/bin/python3 -c "import httpx; print('works without activating')"
```

> That last line matters: in a systemd unit or a cron job there is no shell to run `activate` in. `ExecStart=/opt/lab/w06/.venv/bin/python3 ...` is how you actually deploy Python.

```bash
# 1.4 Pin it
source .venv/bin/activate
pip freeze > requirements.txt
cat requirements.txt
```

---

## Part 2 — Build `svcctl` (Days 2–4)

### 2.1 Get the skeleton

```bash
cp -r ~/course/week-06-python-for-platform/files/svcctl .
cd svcctl
tree
```

Read **all** of `src/svcctl/`, in this order: `checks.py`, `logparse.py`, `cli.py`. Then:

```bash
source ../.venv/bin/activate
pip install -e ".[dev]"
svcctl --help                     # the [project.scripts] entry point at work
```

### 2.2 Use it

```bash
svcctl check https://example.com https://ubuntu.com
svcctl check -t 2 -a 1 http://127.0.0.1:1/dead ; echo "rc=$?"
svcctl check -j https://example.com | jq
```

```bash
# generate a log and analyse it
bash ~/course/week-01-linux-foundations/files/gen-access-log.sh 5000 > /tmp/access.log
svcctl logs /tmp/access.log
svcctl logs /tmp/access.log -j | jq '.anomalous_clients'
cat /tmp/access.log | svcctl logs -            # reads stdin too
```

> **Compare the "anomalous clients" answer with the awk pipeline you wrote in Week 1 (C1.1 #9).** They should agree exactly. Then compare how long each took you to write, and how you would extend each to also break down by hour.

### 2.3 Run the tests

```bash
pytest
pytest -v tests/test_checks.py
pytest -k "anomalous"
```

All 39 must pass.

### 2.4 Lint and type-check

```bash
ruff check src/
ruff format --check src/
mypy src/
```

Fix everything. Then deliberately introduce a type error and confirm `mypy` catches it before any test would:

```python
# in checks.py, temporarily:
def classify(status: int) -> bool:
    return status                      # returns int, declared bool
```

```bash
mypy src/          # catches it
pytest             # ...also catches it here, but only because a test exists.
                   # mypy would have caught it with NO test at all.
```

### 2.5 Extend it — the real exercise

Add a `svcctl watch` subcommand:

- polls a list of targets every N seconds;
- prints only **transitions** (healthy→unhealthy and back), not every poll;
- tracks consecutive failures and only reports "DOWN" after `--fall N` (you met this idea in Week 5's HAProxy config);
- exits cleanly on Ctrl-C, printing a summary of uptime per target.

Write the tests **first**. Specifically, write a test that proves a single blip does **not** produce a DOWN report when `--fall 3`. That test is the reason the feature is worth anything.

---

## Part 3 — Subprocess and the system (Day 2)

```bash
cd /opt/lab/w06 && source .venv/bin/activate
```

```python
# sysinfo.py
#!/usr/bin/env python3
"""Collect system facts by shelling out - carefully."""
import json, shutil, subprocess, sys
from pathlib import Path


def run(cmd: list[str], timeout: float = 10.0) -> tuple[int, str, str]:
    """Always a list. Always a timeout. Never shell=True."""
    if shutil.which(cmd[0]) is None:
        return 127, "", f"command not found: {cmd[0]}"
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, check=False)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        # A hung child would otherwise hang US forever - the classic way a
        # monitoring script silently stops monitoring.
        return 124, "", f"timed out after {timeout}s"


def service_state(unit: str) -> dict:
    rc_a, active, _ = run(["systemctl", "is-active", unit])
    rc_e, enabled, _ = run(["systemctl", "is-enabled", unit])
    return {
        "unit": unit,
        "active": active.strip(),
        "enabled": enabled.strip(),
        # enabled and active are INDEPENDENT - week 2.
        "will_survive_reboot": enabled.strip() == "enabled",
    }


def disk_usage() -> list[dict]:
    rc, out, _ = run(["df", "-B1", "--output=target,size,used,avail,pcent,ipcent", "-x", "tmpfs"])
    rows = []
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) >= 6:
            rows.append({"mount": f[0], "used_pct": f[4], "inode_pct": f[5]})
    return rows


if __name__ == "__main__":
    print(json.dumps({
        "services": [service_state(u) for u in sys.argv[1:] or ["ssh", "cron"]],
        "disks": disk_usage(),
        "load": Path("/proc/loadavg").read_text().split()[:3],
    }, indent=2))
```

```bash
python3 sysinfo.py ssh cron nginx
```

> Note `ipcent` in the `df` call — inode percentage alongside block percentage. That is Week 2's lesson encoded into a tool, and it is the difference between a disk check that finds the problem and one that reports "42% used" while writes fail.

### 3.1 Prove the injection risk

```python
# DANGEROUS - do not write code like this
import subprocess
filename = "notes.txt; echo PWNED"
subprocess.run(f"cat {filename}", shell=True)          # runs the echo

# SAFE
subprocess.run(["cat", filename])                       # cat gets ONE argument,
                                                        # which happens to be a
                                                        # silly filename
```

Run both. The first prints `PWNED`. Now imagine `filename` came from a web form.

---

## Part 4 — Networking, retries, concurrency (Day 3)

```bash
# 4.1 Timeouts matter
python3 - <<'EOF'
import time, urllib.request
start = time.monotonic()
try:
    urllib.request.urlopen("http://10.255.255.1/", timeout=2)
except Exception as e:
    print(f"failed in {time.monotonic()-start:.1f}s: {type(e).__name__}")
EOF
```

Now remove `timeout=2` and run it again. **Time how long you are prepared to wait before Ctrl-C.** That is how long an untimed request would block your monitoring loop.

```bash
# 4.2 Watch the backoff and jitter
python3 - <<'EOF'
import sys; sys.path.insert(0, "svcctl/src")
from svcctl.checks import backoff_delay
for attempt in range(6):
    samples = [round(backoff_delay(attempt), 2) for _ in range(5)]
    print(f"attempt {attempt}: {samples}")
EOF
```

> Two things to notice: the ceiling doubles each attempt, and **no two samples are the same**. Write down what would happen to a recovering service if the second property were absent and a thousand clients retried together.

```bash
# 4.3 Concurrency measured
python3 - <<'EOF'
import sys, time; sys.path.insert(0, "svcctl/src")
from svcctl.checks import check_all
targets = [f"http://127.0.0.1:{p}/" for p in range(9001, 9021)]

for workers in (1, 5, 20):
    t = time.monotonic()
    check_all(targets, timeout=1.0, attempts=1, workers=workers)
    print(f"workers={workers:>2}: {time.monotonic()-t:.2f}s")
EOF
```

> The speedup is close to linear because the work is **waiting**, not computing. Explain in your logbook why the same code would show almost no speedup if each "check" were computing a hash instead.

---

## Part 5 — Package and deploy (Day 4)

```bash
cd svcctl
pip install -e .
which svcctl
svcctl --version 2>/dev/null || python3 -c "import svcctl; print(svcctl.__version__)"
```

Deploy it as a real timer, without any shell activation:

```bash
sudo tee /etc/systemd/system/svcctl-check.service >/dev/null <<'EOF'
[Unit]
Description=Health check sweep
[Service]
Type=oneshot
User=ubuntu
ExecStart=/opt/lab/w06/.venv/bin/svcctl check -f /etc/lab/targets.txt
EOF

sudo mkdir -p /etc/lab
sudo tee /etc/lab/targets.txt >/dev/null <<'EOF'
# lab targets
https://example.com
http://127.0.0.1:9999/       # deliberately dead
EOF

sudo tee /etc/systemd/system/svcctl-check.timer >/dev/null <<'EOF'
[Unit]
Description=Run the health sweep every 2 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
RandomizedDelaySec=15
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now svcctl-check.timer
sudo systemctl start svcctl-check.service
journalctl -u svcctl-check.service -n 20 --no-pager
```

> The unit **fails** because one target is dead — `systemctl status` shows `status=1/FAILURE`. That is correct behaviour: the exit code carried the verdict all the way to systemd, and systemd will report it. Your Week 9 alerting will consume exactly this.

---

## Part 6 — The handover test

There is no chaos drill this week. Instead:

1. Write `svcctl`'s README as if for a colleague who has never seen it.
2. Give the tool and the README to someone else (or leave it a week and come back).
3. Have them accomplish a task with it **without asking you anything**.

Every question they have to ask is a defect in your interface or your documentation. Write those defects down and fix them. A tool that requires its author present is not a tool; it is a liability.
