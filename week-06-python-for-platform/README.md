# Week 06 — Python for Platform Engineering

**VM profile:** `make w06-up` → `lab`
**You will be able to:** build a CLI tool other engineers depend on — argument parsing, structured logging, retries with backoff, real error handling, tests, and packaging — and know precisely when to reach for it instead of Bash.

> You can already program. This week is about the **operational** subset of Python: the standard library, the failure modes of talking to networks and processes, and the discipline that makes a tool trustworthy at 3am. Not web frameworks, not data science.

---

## Day 1 — Environments, and the problem they solve

### 1.1 Why virtual environments exist

The system Python on Ubuntu is a **dependency of the operating system**. `apt` tools are written against it. `sudo pip install` can upgrade a library that a system tool relies on and break your package manager — a genuinely unpleasant way to spend an afternoon.

Ubuntu 23.04+ enforces this with PEP 668: `pip install` outside a venv refuses with `externally-managed-environment`. **That error is the system protecting itself. Do not use `--break-system-packages`; the flag name is an accurate description.**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install httpx
deactivate
```

A venv is just a directory with its own `bin/python` and `lib/site-packages`. `activate` prepends its `bin` to `PATH`. Nothing magical, and worth knowing because it means **you do not need to activate it** — `.venv/bin/python script.py` works identically, which is what you use in a systemd unit or a cron job where there is no shell to activate anything.

### 1.2 Reproducible installs

```bash
pip freeze > requirements.txt          # exact versions of everything installed
pip install -r requirements.txt
```

`pip freeze` captures the whole transitive tree with exact pins. For an application, that is what you want — the same versions everywhere, every time. For a *library*, you want loose ranges in `pyproject.toml` instead.

Modern alternative worth knowing: **`uv`** (<https://github.com/astral-sh/uv>) is a drop-in, dramatically faster resolver and installer, and it is free and open source. `pipx` installs CLI tools into isolated environments so they are on your `PATH` without polluting anything.

### 1.3 Project layout

```
svcctl/
├── pyproject.toml
├── README.md
├── src/svcctl/
│   ├── __init__.py
│   ├── __main__.py      # python -m svcctl
│   ├── cli.py           # argument parsing only
│   ├── checks.py        # the logic - importable and testable
│   └── logs.py
└── tests/
    └── test_checks.py
```

**The `src/` layout is not decoration.** It makes it impossible to accidentally import your package from the working directory instead of from the installed copy — so your tests exercise what users will actually get. Without it, a missing file in your package still passes tests locally and fails on every other machine.

---

## Day 2 — The operational standard library

You need far less than you think. These modules cover almost everything a platform tool does:

| Module | For |
|---|---|
| `argparse` | CLI arguments — in the stdlib, no dependency |
| `logging` | structured, levelled output |
| `pathlib` | filesystem paths — never use string concatenation |
| `subprocess` | running other programs |
| `json` | structured data |
| `dataclasses` | typed records without boilerplate |
| `enum` | named constants |
| `concurrent.futures` | parallelism without touching threads directly |
| `urllib.request` | HTTP with **zero dependencies** |
| `tomllib` | reading TOML (3.11+, stdlib) |

External, and worth the dependency: **`httpx`** or `requests` for serious HTTP, **`pytest`** for tests, **`rich`** for terminal output, **`pyyaml`** for YAML.

### 2.1 `subprocess`, done correctly

```python
import subprocess

# THE form to use.
r = subprocess.run(
    ["systemctl", "is-active", "nginx"],   # a LIST, never a string
    capture_output=True,
    text=True,                              # str, not bytes
    timeout=10,                             # ALWAYS. A hung child hangs you forever.
    check=False,                            # inspect returncode yourself
)
if r.returncode != 0:
    log.error("systemctl failed rc=%s stderr=%s", r.returncode, r.stderr.strip())
```

**`shell=True` is the thing to avoid.** With it, your arguments are parsed by a shell, so a filename containing `;` or `$( )` becomes command execution. It is the Python equivalent of an unquoted variable in Bash, with the same consequences. Pass a list and there is no shell to inject into.

**`timeout=` is not optional.** A subprocess that never returns is the most common way a monitoring script silently stops monitoring — it does not crash, it does not alert, it just stops, and nobody notices for weeks.

### 2.2 `pathlib`

```python
from pathlib import Path

log_dir = Path("/var/log/myapp")
today = log_dir / f"app-{date.today():%Y-%m-%d}.log"    # / is the join operator

today.parent.mkdir(parents=True, exist_ok=True)          # idempotent
if today.exists() and today.stat().st_size > 10_000_000:
    ...
for p in log_dir.glob("*.log"):
    print(p.name, p.stat().st_size)
text = today.read_text()
```

`os.path.join` still works; `pathlib` is clearer and carries the type. Use it.

### 2.3 `logging`, not `print`

```python
import logging, sys

def setup_logging(verbose: bool = False, json_output: bool = False) -> None:
    handler = logging.StreamHandler(sys.stderr)     # stderr, so stdout stays data
    if json_output:
        handler.setFormatter(JsonFormatter())
    else:
        handler.setFormatter(logging.Formatter(
            "%(asctime)s %(levelname)-8s %(name)s: %(message)s"))
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        handlers=[handler],
    )

log = logging.getLogger(__name__)
log.info("checking %d services", len(services))     # lazy %s formatting -
                                                    # the string is only built if
                                                    # this level is actually emitted
```

Three rules:
1. **Logs to stderr, data to stdout.** Then `mytool | jq` works, and `mytool 2>/dev/null` gives clean data.
2. **Use the levels honestly.** `DEBUG` for tracing, `INFO` for normal milestones, `WARNING` for "surprising but handled", `ERROR` for "this operation failed". An application that logs everything at `ERROR` makes `-p err` useless for everyone downstream.
3. **Never log a secret.** Tokens, passwords and full request bodies end up in a journal that a wide group can read.

### 2.4 Exit codes are your API

```python
import sys
from enum import IntEnum

class Exit(IntEnum):
    OK       = 0
    FAILED   = 1     # the thing we checked is unhealthy
    USAGE    = 2     # the caller invoked us wrongly
    INTERNAL = 3     # we broke

sys.exit(Exit.FAILED)
```

A monitoring system, a CI step or a shell `&&` reads the exit code, not your table. Distinguishing "the check ran and found a problem" from "the check itself could not run" is the difference between an actionable alert and a confusing one.

---

## Day 3 — Talking to the network without lying about it

### 3.1 Timeouts, again

```python
import httpx

r = httpx.get(url, timeout=httpx.Timeout(connect=3.0, read=10.0, write=5.0, pool=5.0))
```

A request with no timeout can hang **forever**. `requests` has no default timeout, which is a famous footgun. Set one on every call, always.

### 3.2 Retry with backoff and jitter

```python
import random, time

def with_retry(fn, attempts=3, base=0.5, cap=8.0):
    last = None
    for i in range(attempts):
        try:
            return fn()
        except (httpx.TransportError, httpx.HTTPStatusError) as e:
            last = e
            if i == attempts - 1:
                raise
            # Exponential backoff with FULL JITTER.
            delay = min(cap, base * (2 ** i))
            delay = random.uniform(0, delay)
            log.warning("attempt %d/%d failed (%s), retrying in %.2fs",
                        i + 1, attempts, e, delay)
            time.sleep(delay)
    raise last
```

**Why jitter, specifically.** Without it, a thousand clients that all failed at the same instant all retry at the same instant, and the service that was recovering is knocked down again. This is the **thundering herd**, and it is how a 30-second blip becomes a 30-minute outage. Randomising the delay spreads the retries out. (It is the same reasoning as `RandomizedDelaySec` in a systemd timer — Week 2.)

**What NOT to retry:** anything non-idempotent, and any 4xx. Retrying a `400` will never succeed and just wastes time; retrying a `POST /payments` may charge someone twice. Retry `429`, `502`, `503`, `504`, connection errors and timeouts. Nothing else, unless you know the operation is safe to repeat.

### 3.3 Parallelism, the easy way

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

with ThreadPoolExecutor(max_workers=10) as pool:
    futures = {pool.submit(check_one, t): t for t in targets}
    for fut in as_completed(futures):
        target = futures[fut]
        try:
            results[target] = fut.result()
        except Exception as e:                 # a worker exception is RAISED here,
            log.error("%s: %s", target, e)     # not where it was thrown - if you
            results[target] = None             # never call .result() it vanishes
```

Threads are the right tool here because the work is **I/O-bound** — waiting on the network, not computing. Python's GIL only limits CPU-bound threads. For CPU-bound work use `ProcessPoolExecutor`; for thousands of concurrent connections, `asyncio`.

---

## Day 4 — Making it trustworthy

### 4.1 Type hints

```python
from dataclasses import dataclass

@dataclass(frozen=True, slots=True)
class CheckResult:
    target: str
    healthy: bool
    status_code: int | None
    latency_ms: float
    error: str | None = None
```

Hints do nothing at runtime; they let **`mypy`** find real bugs before you ship, and they document intent better than any comment. `frozen=True` makes the record immutable, which eliminates a category of "something modified this later" bugs.

```bash
pip install mypy ruff
mypy src/
ruff check src/          # linting
ruff format src/         # formatting
```

`ruff` replaces flake8, isort, black and more, and is fast enough to run on every save.

### 4.2 Testing with pytest

```python
import pytest
from svcctl.checks import parse_status, CheckResult

def test_parses_healthy_status():
    assert parse_status(200) is True

@pytest.mark.parametrize("code,expected", [
    (200, True), (204, True), (301, True),
    (400, False), (500, False), (503, False),
])
def test_status_classification(code, expected):
    assert parse_status(code) is expected

def test_timeout_is_reported_not_raised(httpx_mock):
    httpx_mock.add_exception(httpx.ConnectTimeout("timed out"))
    result = check_target("http://x/")
    assert result.healthy is False
    assert "timed out" in result.error       # ← the important assertion
```

**Test the failure paths.** The last test above is the valuable one: it asserts that a network timeout becomes a *reported result*, not an unhandled exception that kills the whole run and loses the other 49 results. That is the bug that actually happens.

### 4.3 Packaging

```toml
# pyproject.toml
[project]
name = "svcctl"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["httpx>=0.27"]

[project.scripts]
svcctl = "svcctl.cli:main"      # creates the `svcctl` command on install

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
```

```bash
pip install -e .        # editable install: your edits take effect immediately
svcctl --help
```

`[project.scripts]` is what turns your module into a real command. That single line is the difference between "run this script from that directory" and "a tool your team installs".

---

## Day 5 — When Python is the wrong answer

The boundary runs both ways, and juniors get it wrong in both directions.

**Use Bash when:** you are wiring together three commands and checking exit codes; the whole thing is under about 40 lines; you need it to run on a machine where you cannot install anything.

**Use Python when:** you are parsing structured data; you need retries, concurrency, or real error handling; the logic needs tests; it will be maintained by more than one person; it will outlive this quarter.

**Use neither when** a tool already exists. Writing a Python script to poll HTTP endpoints is a good exercise this week and a bad decision in production, where Prometheus Blackbox Exporter already does it, better, with alerting. **The most senior instinct is recognising that the code you were about to write already exists and is maintained by somebody else.**

## Drill

Week 6 has no chaos drill. Instead: take your `svcctl`, hand it to a colleague (or your past self via a week-old README), and have them use it without asking you a question. Every question they need to ask is a bug in the tool's interface, not in their understanding.

## Recommended reading

- *Automate the Boring Stuff with Python* — **free online** at <https://automatetheboringstuff.com/>
- *Python Cookbook* / the official docs `library` index — you want `logging`, `argparse`, `subprocess`, `pathlib`
- <https://docs.astral.sh/ruff/> and <https://docs.astral.sh/uv/>
- <https://calmcode.io/> — short, free, practical videos on exactly these tools
- AWS Architecture Blog, *Exponential Backoff and Jitter* — the canonical explanation
