"""Health checking with retries, backoff and honest error reporting.

Deliberately built on the standard library only (`urllib.request`), so the tool
runs on any machine with Python 3.11+ and no pip install. In a real project you
would use httpx; the retry/timeout/classification logic below is identical
either way, and that logic is the part worth learning.
"""

from __future__ import annotations

import logging
import random
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict

log = logging.getLogger(__name__)

# Status codes worth retrying. Everything else is either success or a permanent
# client error - retrying a 404 or a 401 will never help and only adds latency.
RETRYABLE_STATUS = frozenset({408, 429, 500, 502, 503, 504})


@dataclass(frozen=True, slots=True)
class CheckResult:
    """One probe of one target. Immutable on purpose."""

    target: str
    healthy: bool
    status_code: int | None
    latency_ms: float
    attempts: int
    error: str | None = None

    def as_dict(self) -> dict:
        return asdict(self)


def classify(status: int) -> bool:
    """Is this HTTP status healthy?

    2xx and 3xx count as healthy: a redirect means the service is alive and
    answering. Everything from 400 up is a failure of some kind.
    """
    return 200 <= status < 400


def backoff_delay(attempt: int, base: float = 0.5, cap: float = 8.0) -> float:
    """Exponential backoff with FULL JITTER.

    attempt is 0-indexed. Without the jitter, every client that failed at the
    same moment retries at the same moment, and the service that was recovering
    gets knocked over again - the thundering herd. Randomising across the whole
    interval, rather than adding a small random nudge, spreads them best.
    """
    return random.uniform(0, min(cap, base * (2**attempt)))


def check_one(
    target: str,
    *,
    timeout: float = 5.0,
    attempts: int = 3,
    sleeper=time.sleep,
) -> CheckResult:
    """Probe one URL, retrying transient failures.

    Never raises for a network problem: a failure becomes a CheckResult with
    healthy=False. That is the whole point - one unreachable target must not
    abort a run of fifty, discarding the forty-nine results you already have.

    `sleeper` is injected so tests can run instantly instead of actually
    sleeping through the backoff.
    """
    last_error: str | None = None
    started = time.monotonic()

    for attempt in range(attempts):
        try:
            req = urllib.request.Request(target, method="GET",
                                         headers={"User-Agent": "svcctl/0.1"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.status
                resp.read(1024)  # drain a little so the connection closes cleanly

            elapsed = (time.monotonic() - started) * 1000

            if classify(status):
                return CheckResult(target, True, status, elapsed, attempt + 1)

            last_error = f"HTTP {status}"
            if status not in RETRYABLE_STATUS:
                # A permanent failure. Report it now rather than burning the
                # remaining attempts on something that cannot succeed.
                return CheckResult(target, False, status, elapsed, attempt + 1,
                                   last_error)

        except urllib.error.HTTPError as e:
            # urllib raises for >=400 rather than returning them.
            last_error = f"HTTP {e.code}"
            if e.code not in RETRYABLE_STATUS:
                elapsed = (time.monotonic() - started) * 1000
                return CheckResult(target, False, e.code, elapsed, attempt + 1,
                                   last_error)

        except (urllib.error.URLError, TimeoutError, OSError) as e:
            reason = getattr(e, "reason", e)
            last_error = f"{type(e).__name__}: {reason}"

        if attempt < attempts - 1:
            delay = backoff_delay(attempt)
            log.debug("%s: attempt %d/%d failed (%s), retrying in %.2fs",
                      target, attempt + 1, attempts, last_error, delay)
            sleeper(delay)

    elapsed = (time.monotonic() - started) * 1000
    return CheckResult(target, False, None, elapsed, attempts, last_error)


def check_all(
    targets: list[str],
    *,
    timeout: float = 5.0,
    attempts: int = 3,
    workers: int = 10,
) -> list[CheckResult]:
    """Probe every target concurrently, preserving input order in the output.

    Threads are correct here: the work is I/O-bound, waiting on sockets, so the
    GIL is released while waiting. ProcessPoolExecutor would be for CPU-bound
    work, and asyncio for thousands of connections rather than tens.
    """
    if not targets:
        return []

    results: dict[str, CheckResult] = {}

    with ThreadPoolExecutor(max_workers=min(workers, len(targets))) as pool:
        futures = {
            pool.submit(check_one, t, timeout=timeout, attempts=attempts): t
            for t in targets
        }
        for fut in as_completed(futures):
            target = futures[fut]
            try:
                results[target] = fut.result()
            except Exception as e:  # noqa: BLE001 - a worker must never kill the run
                # An exception inside a worker surfaces HERE, at .result().
                # If you never call .result(), it disappears silently - which is
                # one of the nastiest ways to lose errors in Python.
                log.exception("unexpected error checking %s", target)
                results[target] = CheckResult(
                    target, False, None, 0.0, 0, f"internal error: {e}"
                )

    # Output order follows input order, so runs are diffable across time.
    return [results[t] for t in targets]
