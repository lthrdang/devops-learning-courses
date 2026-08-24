"""Tests for svcctl.checks.

Note how many of these test FAILURE behaviour. The happy path is easy; the
value of a monitoring tool is entirely in what it does when things go wrong.
"""

import pytest

from svcctl.checks import (
    CheckResult,
    RETRYABLE_STATUS,
    backoff_delay,
    check_all,
    check_one,
    classify,
)


# --- classification --------------------------------------------------------
@pytest.mark.parametrize(
    "code,expected",
    [
        (200, True), (201, True), (204, True),
        (301, True), (302, True), (304, True),
        (400, False), (401, False), (403, False), (404, False), (429, False),
        (500, False), (502, False), (503, False), (504, False),
    ],
)
def test_classify(code, expected):
    assert classify(code) is expected


def test_redirects_count_as_healthy():
    """A 301 means the service is alive and answering. That is what we asked."""
    assert classify(301) is True


# --- backoff ---------------------------------------------------------------
def test_backoff_is_bounded_by_the_cap():
    for attempt in range(12):
        assert 0 <= backoff_delay(attempt, base=0.5, cap=8.0) <= 8.0


def test_backoff_grows_with_attempt_number():
    """With full jitter each value is random, so compare the MAXIMA over many
    samples rather than single draws - a test that compares one sample to
    another is a flaky test."""
    early = max(backoff_delay(0, base=0.5, cap=64.0) for _ in range(400))
    late = max(backoff_delay(5, base=0.5, cap=64.0) for _ in range(400))
    assert late > early


def test_backoff_is_jittered_not_constant():
    """The whole point is that two clients do not retry at the same instant."""
    samples = {round(backoff_delay(3), 6) for _ in range(50)}
    assert len(samples) > 1


# --- check_one -------------------------------------------------------------
def test_connection_refused_is_reported_not_raised():
    """THE important test: a network failure must become a result, not an
    exception that aborts the whole run and discards other results."""
    r = check_one("http://127.0.0.1:1/", timeout=1.0, attempts=1, sleeper=lambda _: None)
    assert isinstance(r, CheckResult)
    assert r.healthy is False
    assert r.status_code is None
    assert r.error is not None
    assert "refused" in r.error.lower() or "URLError" in r.error


def test_retries_are_attempted_and_counted():
    calls = []
    r = check_one("http://127.0.0.1:1/", timeout=1.0, attempts=3,
                  sleeper=lambda d: calls.append(d))
    assert r.attempts == 3
    assert len(calls) == 2          # sleeps BETWEEN attempts, not after the last


def test_no_sleep_after_the_final_attempt():
    """Sleeping after the last attempt just adds latency to a failure."""
    calls = []
    check_one("http://127.0.0.1:1/", timeout=1.0, attempts=1,
              sleeper=lambda d: calls.append(d))
    assert calls == []


def test_latency_is_recorded_even_on_failure():
    r = check_one("http://127.0.0.1:1/", timeout=1.0, attempts=1, sleeper=lambda _: None)
    assert r.latency_ms > 0


def test_result_is_immutable():
    r = check_one("http://127.0.0.1:1/", timeout=1.0, attempts=1, sleeper=lambda _: None)
    with pytest.raises(Exception):
        r.healthy = True        # frozen dataclass


# --- check_all -------------------------------------------------------------
def test_empty_target_list_returns_empty_not_error():
    assert check_all([]) == []


def test_one_bad_target_does_not_lose_the_others():
    """The core reliability property of the whole tool."""
    targets = ["http://127.0.0.1:1/", "http://127.0.0.1:2/", "http://127.0.0.1:3/"]
    results = check_all(targets, timeout=1.0, attempts=1)
    assert len(results) == 3
    assert all(isinstance(r, CheckResult) for r in results)


def test_output_order_matches_input_order():
    """Concurrent execution completes out of order; the OUTPUT must not, or
    two runs cannot be diffed against each other."""
    targets = ["http://127.0.0.1:3/", "http://127.0.0.1:1/", "http://127.0.0.1:2/"]
    results = check_all(targets, timeout=1.0, attempts=1)
    assert [r.target for r in results] == targets


def test_retryable_set_excludes_permanent_client_errors():
    """Retrying a 404 or a 401 will never succeed - it only adds latency."""
    for code in (400, 401, 403, 404, 405, 410):
        assert code not in RETRYABLE_STATUS
    for code in (429, 500, 502, 503, 504):
        assert code in RETRYABLE_STATUS
