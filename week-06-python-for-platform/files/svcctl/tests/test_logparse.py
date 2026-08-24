"""Tests for svcctl.logparse."""

import pytest

from svcctl.logparse import Entry, analyse, parse_lines

SAMPLE = [
    '10.0.0.1 - - [01/Mar/2026:09:15:00 +0000] "GET /api/users HTTP/1.1" 200 1234 "-" "curl/8"',
    '10.0.0.1 - - [01/Mar/2026:09:16:00 +0000] "GET /api/users HTTP/1.1" 200 1000 "-" "curl/8"',
    '10.0.0.2 - - [01/Mar/2026:10:00:00 +0000] "POST /api/orders HTTP/1.1" 500 89 "-" "curl/8"',
    '10.0.0.2 - - [01/Mar/2026:10:01:00 +0000] "GET /admin HTTP/1.1" 404 12 "-" "nmap"',
    '10.0.0.3 - - [01/Mar/2026:10:02:00 +0000] "GET /health HTTP/1.1" 200 - "-" "kube-probe"',
]


def test_parses_all_well_formed_lines():
    assert len(list(parse_lines(SAMPLE))) == 5


def test_extracts_every_field():
    e = next(parse_lines(SAMPLE))
    assert e == Entry("10.0.0.1", "01/Mar/2026:09:15:00 +0000",
                      "GET", "/api/users", 200, 1234)


def test_dash_byte_count_becomes_zero_not_a_crash():
    """nginx writes '-' when it sent no body. int('-') would explode."""
    entries = list(parse_lines(SAMPLE))
    assert entries[4].size == 0


def test_malformed_lines_are_skipped_not_fatal():
    """A truncated final line in a file still being written must not abort the
    analysis of the million lines before it."""
    bad = SAMPLE + ["this is not a log line", "", '10.0.0.9 - - [trunc']
    assert len(list(parse_lines(bad))) == 5


def test_hour_extraction():
    entries = list(parse_lines(SAMPLE))
    assert entries[0].hour == "09"
    assert entries[2].hour == "10"


# --- analysis --------------------------------------------------------------
def test_totals_and_rates():
    r = analyse(parse_lines(SAMPLE))
    assert r.total == 5
    assert r.errors == 2                 # the 500 and the 404
    assert r.server_errors == 1          # only the 500
    assert r.error_rate == pytest.approx(40.0)
    assert r.server_error_rate == pytest.approx(20.0)


def test_empty_input_does_not_divide_by_zero():
    """The bug this guards against reports 'healthy' instead of crashing, which
    is strictly worse than crashing."""
    r = analyse(parse_lines([]))
    assert r.total == 0
    assert r.error_rate == 0.0
    assert r.server_error_rate == 0.0


def test_aggregations():
    r = analyse(parse_lines(SAMPLE))
    assert r.by_path["/api/users"] == 2
    assert r.by_ip["10.0.0.1"] == 2
    assert r.by_status[200] == 3
    assert r.by_hour["10"] == 3
    assert r.total_bytes == 1234 + 1000 + 89 + 12


def test_error_paths_only_counts_errors():
    r = analyse(parse_lines(SAMPLE))
    assert r.error_paths["/admin"] == 1
    assert "/health" not in r.error_paths


def test_anomalous_clients_ignores_low_volume_clients():
    """A client with 1 request and 1 error is 100% - and meaningless. Without
    the min_requests guard this analysis is dominated by noise."""
    r = analyse(parse_lines(SAMPLE))
    assert r.anomalous_clients(threshold_pct=20.0, min_requests=20) == []


def test_anomalous_clients_finds_a_real_offender():
    lines = []
    # 100 healthy requests from a normal client
    for i in range(100):
        lines.append(f'10.0.0.1 - - [01/Mar/2026:09:00:{i:02d} +0000] '
                     f'"GET / HTTP/1.1" 200 100 "-" "curl"')
    # 50 requests from a scanner, 45 of them 404
    for i in range(50):
        code = 404 if i < 45 else 200
        lines.append(f'198.51.100.9 - - [01/Mar/2026:09:01:{i:02d} +0000] '
                     f'"GET /.env HTTP/1.1" {code} 10 "-" "scanner"')

    r = analyse(parse_lines(lines))
    found = r.anomalous_clients(threshold_pct=20.0, min_requests=20)
    assert len(found) == 1
    ip, rate, bad, total = found[0]
    assert ip == "198.51.100.9"
    assert rate == pytest.approx(90.0)
    assert (bad, total) == (45, 50)
