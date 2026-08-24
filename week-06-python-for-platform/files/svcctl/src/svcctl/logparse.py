"""Parse nginx/combined access logs and answer operational questions.

This is the Python counterpart to the awk pipelines from week 1. Compare the
two: awk wins for a single aggregation over a huge file; Python wins the moment
you need several aggregations at once, or a ratio between them.
"""

from __future__ import annotations

import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Iterable, Iterator

# Combined log format:
# 10.0.0.1 - - [01/Mar/2026:09:15:00 +0000] "GET /path HTTP/1.1" 200 1234 "-" "curl/8"
LINE_RE = re.compile(
    r'^(?P<ip>\S+) \S+ \S+ \[(?P<ts>[^\]]+)\] '
    r'"(?P<method>[A-Z]+) (?P<path>\S+) [^"]*" '
    r'(?P<status>\d{3}) (?P<bytes>\d+|-)'
)


@dataclass(frozen=True, slots=True)
class Entry:
    ip: str
    timestamp: str
    method: str
    path: str
    status: int
    size: int

    @property
    def hour(self) -> str:
        # "01/Mar/2026:09:15:00 +0000" -> "09"
        parts = self.timestamp.split(":")
        return parts[1] if len(parts) > 1 else "??"


def parse_lines(lines: Iterable[str]) -> Iterator[Entry]:
    """Yield an Entry per parseable line, skipping the rest.

    Malformed lines are SKIPPED, not fatal. A single truncated line at the end
    of a file being written to must not abort the analysis of the other million.
    """
    for line in lines:
        m = LINE_RE.match(line)
        if not m:
            continue
        raw_size = m.group("bytes")
        yield Entry(
            ip=m.group("ip"),
            timestamp=m.group("ts"),
            method=m.group("method"),
            path=m.group("path"),
            status=int(m.group("status")),
            size=0 if raw_size == "-" else int(raw_size),
        )


@dataclass
class Report:
    total: int = 0
    errors: int = 0
    server_errors: int = 0
    total_bytes: int = 0
    by_path: Counter = None
    by_ip: Counter = None
    by_status: Counter = None
    by_hour: Counter = None
    errors_by_ip: Counter = None
    error_paths: Counter = None

    def __post_init__(self):
        for f in ("by_path", "by_ip", "by_status", "by_hour",
                  "errors_by_ip", "error_paths"):
            if getattr(self, f) is None:
                setattr(self, f, Counter())

    @property
    def error_rate(self) -> float:
        return 100.0 * self.errors / self.total if self.total else 0.0

    @property
    def server_error_rate(self) -> float:
        return 100.0 * self.server_errors / self.total if self.total else 0.0

    def anomalous_clients(self, threshold_pct: float = 20.0,
                          min_requests: int = 20) -> list[tuple[str, float, int, int]]:
        """Clients whose error rate is far above normal.

        This is the question awk makes awkward and Python makes trivial: it
        needs TWO aggregations of the same data compared against each other.
        `min_requests` guards against a client with 1 request and 1 error
        appearing as a 100% offender - a real trap in this kind of analysis.
        """
        out = []
        for ip, total in self.by_ip.items():
            if total < min_requests:
                continue
            bad = self.errors_by_ip.get(ip, 0)
            rate = 100.0 * bad / total
            if rate > threshold_pct:
                out.append((ip, rate, bad, total))
        return sorted(out, key=lambda r: r[1], reverse=True)


def analyse(entries: Iterable[Entry]) -> Report:
    """Build the whole report in ONE pass over the data.

    The awk equivalent needs a separate pass (and a separate sort|uniq pipeline)
    per section. On a multi-gigabyte log that difference is minutes.
    """
    r = Report()
    for e in entries:
        r.total += 1
        r.total_bytes += e.size
        r.by_path[e.path] += 1
        r.by_ip[e.ip] += 1
        r.by_status[e.status] += 1
        r.by_hour[e.hour] += 1
        if e.status >= 400:
            r.errors += 1
            r.errors_by_ip[e.ip] += 1
            r.error_paths[e.path] += 1
        if e.status >= 500:
            r.server_errors += 1
    return r
