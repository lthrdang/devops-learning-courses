# Week 06 — Solutions & discussion

---

## C6.5 — Fail correctly (start here)

| # | Situation | As-shipped behaviour | Correct behaviour |
|---|---|---|---|
| 1 | `htp://x` | `URLError: unknown url type` — reported as a failed check | **Usage error, exit 2.** A malformed URL is the caller's mistake, not an unhealthy service. Reporting it as "DOWN" pages someone at 3am about a typo |
| 2 | missing target file | caught, `exit 2` ✓ | already correct |
| 3 | empty target file | falls through to "no targets", `exit 2` ✓ | correct — and note the alternative (exit 0, "nothing to check, all healthy!") would be a *silent monitoring outage*, the worst failure a monitoring tool has |
| 4 | `--timeout -5` | accepted; `urlopen` behaves unpredictably | validate: **exit 2** with a clear message |
| 5 | 4 GB response body | `resp.read(1024)` caps it ✓ — but only by luck | make it explicit and documented |
| 6 | `--workers 10000` | `min(workers, len(targets))` caps threads, but 10,000 targets still opens 10,000 sockets | cap workers at something sane (say 100) and **say so** |

```python
# 1 and 4: validate at the boundary, before any work starts.
from urllib.parse import urlparse

def validate_target(t: str) -> None:
    u = urlparse(t)
    if u.scheme not in ("http", "https"):
        raise ValueError(f"unsupported scheme {u.scheme!r} in {t!r} (want http/https)")
    if not u.netloc:
        raise ValueError(f"no host in {t!r}")

# in cmd_check, BEFORE probing anything:
try:
    for t in targets:
        validate_target(t)
    if args.timeout <= 0:
        raise ValueError("--timeout must be positive")
    if args.attempts < 1:
        raise ValueError("--attempts must be at least 1")
except ValueError as e:
    log.error("%s", e)
    return Exit.USAGE
```

**Why validating up front matters:** with 50 targets and one typo, validating inside the loop means you wait 50 probes to learn about a mistake you could have been told about instantly. **Validate everything at the boundary, then trust it inside.**

```python
# 5: bound the read explicitly, and say why.
MAX_BODY = 64 * 1024

with urllib.request.urlopen(req, timeout=timeout) as resp:
    status = resp.status
    # A health check must never be turned into a memory exhaustion vector by
    # the thing it is checking. We only need the status code.
    resp.read(MAX_BODY)
```

```python
# 6: cap concurrency, and tell the user you did.
MAX_WORKERS = 100
if workers > MAX_WORKERS:
    log.warning("capping --workers from %d to %d", workers, MAX_WORKERS)
    workers = MAX_WORKERS
```

**The general principle across all six:** distinguish *"the thing I am checking is broken"* (exit 1) from *"you asked me something impossible"* (exit 2) from *"I am broken"* (exit 3). A monitoring tool that returns 1 for all three trains its users to ignore it — and a tool nobody trusts is worse than no tool, because it occupies the space where a working one would be.

---

## C6.1 — `svcctl watch`

```python
# checks.py additions
from dataclasses import dataclass, field

@dataclass
class TargetState:
    """Hysteresis state for one target. This is HAProxy's fall/rise, in Python."""
    target: str
    up: bool = True
    consecutive_fail: int = 0
    consecutive_ok: int = 0
    polls: int = 0
    up_polls: int = 0
    transitions: list = field(default_factory=list)

    def observe(self, healthy: bool, fall: int, rise: int, now: float) -> str | None:
        """Record a poll; return "DOWN"/"UP" only on an actual transition."""
        self.polls += 1
        if healthy:
            self.up_polls += 1
            self.consecutive_ok += 1
            self.consecutive_fail = 0
            if not self.up and self.consecutive_ok >= rise:
                self.up = True
                self.transitions.append((now, "UP"))
                return "UP"
        else:
            self.consecutive_fail += 1
            self.consecutive_ok = 0
            if self.up and self.consecutive_fail >= fall:
                self.up = False
                self.transitions.append((now, "DOWN"))
                return "DOWN"
        return None

    @property
    def uptime_pct(self) -> float:
        return 100.0 * self.up_polls / self.polls if self.polls else 0.0
```

The test that justifies the whole feature:

```python
def test_a_single_blip_does_not_report_down():
    """This is the entire point of `fall`. Without it, every network hiccup
    pages a human, and after two weeks of that nobody reads the pages."""
    s = TargetState("http://x/")
    assert s.observe(False, fall=3, rise=2, now=1) is None    # blip
    assert s.observe(True,  fall=3, rise=2, now=2) is None    # recovered
    assert s.up is True
    assert s.transitions == []

def test_sustained_failure_does_report_down():
    s = TargetState("http://x/")
    assert s.observe(False, fall=3, rise=2, now=1) is None
    assert s.observe(False, fall=3, rise=2, now=2) is None
    assert s.observe(False, fall=3, rise=2, now=3) == "DOWN"   # third strike

def test_recovery_requires_rise_consecutive_successes():
    s = TargetState("http://x/", up=False, consecutive_fail=3)
    assert s.observe(True, fall=3, rise=2, now=1) is None
    assert s.observe(True, fall=3, rise=2, now=2) == "UP"

def test_a_failure_resets_the_recovery_counter():
    s = TargetState("http://x/", up=False, consecutive_fail=3)
    s.observe(True,  fall=3, rise=2, now=1)
    s.observe(False, fall=3, rise=2, now=2)      # back to zero
    assert s.observe(True, fall=3, rise=2, now=3) is None   # not up yet
```

**Why print only transitions:** a watcher that prints every poll produces 8,640 lines a day per target and is unreadable. One that prints only changes produces two lines on a bad day and zero on a good one. **The signal is the change, and hysteresis is what stops noise from looking like signal.** You met exactly this reasoning as `inter/fall/rise` in Week 5 — the same idea, now in your own code.

---

## C6.3 — The log tailer

The rotation handling is the whole exercise:

```python
import os, time
from pathlib import Path
from collections import deque

def follow(path: Path, poll: float = 0.5):
    """tail -f that survives rotation.

    The key insight: after logrotate renames the file, our open handle still
    points at the RENAMED inode and we would happily read an empty file
    forever, reporting "no errors" while errors pour into the new one. That is
    a silent monitoring outage, which is worse than a crash.

    So: remember the inode we opened, and re-stat the PATH periodically. If the
    inode behind the path has changed, the file was rotated - drain whatever is
    left in the old handle, then switch.
    """
    f = path.open("r", errors="replace")
    inode = os.fstat(f.fileno()).st_ino
    f.seek(0, os.SEEK_END)

    try:
        while True:
            line = f.readline()
            if line:
                yield line
                continue

            # No data. Has the path been replaced beneath us?
            try:
                if path.stat().st_ino != inode:
                    for remaining in f:      # drain the old file first
                        yield remaining
                    f.close()
                    f = path.open("r", errors="replace")
                    inode = os.fstat(f.fileno()).st_ino
                    continue
            except FileNotFoundError:
                pass                          # mid-rotation; try again shortly

            # Truncation (copytruncate) - the file got SHORTER.
            if f.tell() > path.stat().st_size:
                f.seek(0)

            time.sleep(poll)
    finally:
        f.close()
```

And the sliding window, in constant memory:

```python
def sliding_rate(window_s: float = 60.0, threshold_pct: float = 5.0):
    events = deque()       # (timestamp, is_5xx) - bounded by the window, not the file
    while True:
        ts, is_5xx = yield
        events.append((ts, is_5xx))
        cutoff = ts - window_s
        while events and events[0][0] < cutoff:
            events.popleft()          # ← this is why memory stays constant
        if len(events) >= 20:
            rate = 100 * sum(e[1] for e in events) / len(events)
            if rate > threshold_pct:
                yield f"ALERT: {rate:.1f}% 5xx over the last {window_s:.0f}s"
```

**Two details worth stealing:** the `len(events) >= 20` guard stops "1 request, 1 error = 100%" from alerting (the same trap as `min_requests` in `logparse.anomalous_clients`), and `deque.popleft()` bounds memory by the *window*, not by the file — a tailer whose memory grows with the log is a tailer that gets OOM-killed on the busiest day of the year.

---

## C6.4 — Structured logging

```python
import json, logging, datetime

class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.datetime.fromtimestamp(
                record.created, datetime.UTC).isoformat().replace("+00:00", "Z"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        # Anything passed as extra={...} becomes a first-class FIELD, which is
        # the entire point: you can then filter on it without regex.
        for k, v in record.__dict__.items():
            if k not in logging.LogRecord("", 0, "", 0, "", (), None).__dict__:
                payload[k] = v
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)

log.error("check failed", extra={"target": url, "attempt": n, "error": str(e)})
```

**What becomes possible:** querying. `{level="error"} | json | target=~"api.*" | attempt > 2` in Loki (Week 9) is a real query against real fields. With free-form text you are writing regexes against sentences that change whenever someone reworded a log message — and they do.

**What becomes harder:** reading it with your eyes. A wall of JSON in a terminal is genuinely worse than formatted text during interactive debugging.

**When to ship which:** JSON when logs are *ingested* (a container writing to stdout, collected by Promtail/Fluent Bit — Week 9); human-readable when logs are *read directly* (a CLI a person is watching). The mature answer is **both**: default to human-readable, switch to JSON with a flag or when stdout is not a TTY. `sys.stderr.isatty()` makes that automatic, and it is the same instinct as suppressing colour codes when output is redirected.

---

## C6.6 — Know when to stop

Existing tools that do this better: **Prometheus Blackbox Exporter** (probing plus alerting plus history), **Uptime Kuma** (self-hosted, a UI, notifications), **`hey`/`vegeta`** (load), **`goss`** (declarative server validation), **`monit`**.

**The case that `svcctl` was a waste of time:**

> Blackbox Exporter has been probing endpoints in production for a decade. It handles DNS, TCP, ICMP and gRPC as well as HTTP; it exposes metrics Prometheus already knows how to alert on; it has TLS expiry checks, redirect following and proxy support; and it has been hardened by thousands of operators finding edge cases I have not thought of. `svcctl` handles HTTP only, stores no history, alerts nobody, and has one user. Every hour spent on it is an hour not spent learning the tool the industry actually runs — and worse, if it ever reaches production, it becomes something a future colleague must maintain and cannot Google.

**The case that it was not:**

> I now know what a health check *is*, at the level of retries, jitter, timeouts, hysteresis, and the difference between an unhealthy target and a broken checker. When Blackbox Exporter reports a false positive, I will look at `probe_duration_seconds`, its retry semantics and its timeout configuration, because I have implemented all three and know where the bodies are. Configuring a tool you do not understand produces a system nobody can debug — which is precisely the failure mode of teams whose monitoring "just stopped working" and nobody knows why. Building it once, small, and throwing it away is the cheapest way to buy that understanding.

**The synthesis, which is the actual answer:** build it to learn, then delete it and adopt the real tool. The mistake is not building `svcctl` — it is *deploying* it.
