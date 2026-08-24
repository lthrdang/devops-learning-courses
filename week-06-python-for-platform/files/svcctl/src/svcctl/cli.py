"""Command-line interface for svcctl.

This module does argument parsing and output formatting ONLY. All logic lives
in checks.py and logparse.py, which is what makes the logic testable without
constructing fake command lines.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from enum import IntEnum
from pathlib import Path

from . import checks, logparse

log = logging.getLogger("svcctl")


class Exit(IntEnum):
    """Exit codes are this tool's real API - a monitor reads these, not the table."""

    OK = 0
    UNHEALTHY = 1   # the check ran and found a problem
    USAGE = 2       # the caller invoked us wrongly
    INTERNAL = 3    # we broke


def setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
        stream=sys.stderr,          # stderr, so stdout stays pipeable data
    )


def read_targets(path: Path) -> list[str]:
    """One target per line; # starts a comment; blanks ignored."""
    targets = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            targets.append(line)
    return targets


# --------------------------------------------------------------------------
# `svcctl check`
# --------------------------------------------------------------------------
def cmd_check(args: argparse.Namespace) -> int:
    targets = list(args.targets)
    if args.file:
        try:
            targets = read_targets(args.file) + targets
        except OSError as e:
            log.error("cannot read %s: %s", args.file, e)
            return Exit.USAGE

    if not targets:
        log.error("no targets given (pass URLs, or -f FILE)")
        return Exit.USAGE

    results = checks.check_all(
        targets, timeout=args.timeout, attempts=args.attempts, workers=args.workers
    )

    if args.json:
        json.dump(
            {
                "checked": len(results),
                "unhealthy": sum(1 for r in results if not r.healthy),
                "results": [r.as_dict() for r in results],
            },
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")
    else:
        print(f"{'TARGET':<45} {'CODE':<6} {'MS':>8}  {'TRIES':<6} STATUS")
        for r in results:
            code = r.status_code if r.status_code is not None else "-"
            state = "OK" if r.healthy else "FAIL"
            print(f"{r.target:<45} {str(code):<6} {r.latency_ms:>8.1f}  "
                  f"{r.attempts:<6} {state}"
                  + (f"  ({r.error})" if r.error else ""))

    return Exit.OK if all(r.healthy for r in results) else Exit.UNHEALTHY


# --------------------------------------------------------------------------
# `svcctl logs`
# --------------------------------------------------------------------------
def cmd_logs(args: argparse.Namespace) -> int:
    if args.path and str(args.path) != "-":
        try:
            stream = args.path.open("r", errors="replace")
        except OSError as e:
            log.error("cannot read %s: %s", args.path, e)
            return Exit.USAGE
    else:
        stream = sys.stdin

    with stream:
        report = logparse.analyse(logparse.parse_lines(stream))

    if report.total == 0:
        log.error("no parseable log lines found")
        return Exit.USAGE     # NOT a division by zero further down

    if args.json:
        json.dump(
            {
                "total": report.total,
                "error_rate": round(report.error_rate, 2),
                "server_error_rate": round(report.server_error_rate, 2),
                "total_bytes": report.total_bytes,
                "top_paths": report.by_path.most_common(args.top),
                "top_clients": report.by_ip.most_common(args.top),
                "status_codes": sorted(report.by_status.items()),
                "error_paths": report.error_paths.most_common(args.top),
                "anomalous_clients": [
                    {"ip": ip, "error_rate": round(rate, 1), "errors": bad, "total": tot}
                    for ip, rate, bad, tot in report.anomalous_clients(args.threshold)
                ],
            },
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")
    else:
        print(f"Requests:        {report.total}")
        print(f"Error rate:      {report.error_rate:.1f}%  "
              f"({report.errors} of {report.total})")
        print(f"5xx rate:        {report.server_error_rate:.1f}%")
        print(f"Transferred:     {report.total_bytes / 1048576:.1f} MB")
        print()

        def section(title: str, rows) -> None:
            print(title)
            for key, count in rows:
                print(f"  {count:>7}  {key}")
            print()

        section(f"Top {args.top} paths", report.by_path.most_common(args.top))
        section(f"Top {args.top} clients", report.by_ip.most_common(args.top))
        section("Status codes", sorted(report.by_status.items()))
        section(f"Top {args.top} paths among errors",
                report.error_paths.most_common(args.top))

        anomalies = report.anomalous_clients(args.threshold)
        if anomalies:
            print(f"Clients above {args.threshold}% error rate:")
            for ip, rate, bad, total in anomalies:
                print(f"  {ip:<20} {rate:>6.1f}%   ({bad}/{total})")
            print()

    # The exit code carries the verdict, so this can be a CI or cron gate.
    return Exit.UNHEALTHY if report.server_error_rate > args.max_5xx else Exit.OK


# --------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="svcctl",
        description="Service health checks and access-log analysis.",
        epilog="Exit codes: 0 ok, 1 unhealthy, 2 usage error, 3 internal error.",
    )
    p.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    sub = p.add_subparsers(dest="command", required=True)

    c = sub.add_parser("check", help="probe HTTP endpoints")
    c.add_argument("targets", nargs="*", help="URLs to check")
    c.add_argument("-f", "--file", type=Path, help="file of targets, one per line")
    c.add_argument("-t", "--timeout", type=float, default=5.0)
    c.add_argument("-a", "--attempts", type=int, default=3)
    c.add_argument("-w", "--workers", type=int, default=10)
    c.add_argument("-j", "--json", action="store_true")
    c.set_defaults(func=cmd_check)

    l = sub.add_parser("logs", help="analyse an access log")
    l.add_argument("path", nargs="?", type=Path, help="log file, or - for stdin")
    l.add_argument("-n", "--top", type=int, default=5)
    l.add_argument("--threshold", type=float, default=20.0,
                   help="flag clients above this error rate (%%)")
    l.add_argument("--max-5xx", type=float, default=100.0,
                   help="exit 1 if the 5xx rate exceeds this (%%)")
    l.add_argument("-j", "--json", action="store_true")
    l.set_defaults(func=cmd_logs)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    setup_logging(args.verbose)
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        log.warning("interrupted")
        return 130
    except Exception:
        # Log the traceback, but exit with a code that means "the TOOL broke",
        # not "the thing you asked about is unhealthy". Conflating the two turns
        # a bug in your monitoring into a false page at 3am.
        log.exception("unexpected internal error")
        return Exit.INTERNAL


if __name__ == "__main__":
    sys.exit(main())
