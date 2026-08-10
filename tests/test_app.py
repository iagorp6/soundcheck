"""Tests for the soundcheck service.

The original four tests are kept unchanged in intent. They pin the JSON
contract that soundcheck.sh parses, so breaking them means breaking the
monitor. Everything below `test_request_counter` is new and covers the
Prometheus endpoint and the deliberate-failure switch.

One thing was fixed rather than kept: the import path. It used to be
`sys.path.insert(0, '../app')`, which is relative to the CURRENT WORKING
DIRECTORY, so the suite only ran if you happened to be standing in tests/.
Resolving it from `__file__` instead makes `pytest` work from the repo root,
from tests/, and from CI without a `cd`.
"""

import sys
from pathlib import Path

import pytest

APP_DIR = Path(__file__).resolve().parent.parent / "app"
sys.path.insert(0, str(APP_DIR))

import app as app_module  # noqa: E402  (must follow the sys.path edit)
from app import app  # noqa: E402


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


# --- Original contract -----------------------------------------------------

def test_home_endpoint(client):
    """The root endpoint answers with a message and a version."""
    response = client.get("/")
    assert response.status_code == 200
    data = response.get_json()
    assert "message" in data
    assert "version" in data


def test_health_endpoint(client):
    """The health endpoint answers 200 and says it is healthy."""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.get_json()
    assert data["status"] == "healthy"
    assert "uptime_seconds" in data
    assert "timestamp" in data


def test_metrics_endpoint(client):
    """The JSON metrics keys soundcheck.sh depends on are all present."""
    response = client.get("/metrics")
    assert response.status_code == 200
    data = response.get_json()
    for key in (
        "total_requests",
        "successful_requests",
        "failed_requests",
        "success_rate_percent",
        "uptime_seconds",
        "uptime_minutes",
    ):
        assert key in data


def test_request_counter(client):
    """Serving a request moves the counter."""
    total_before = client.get("/metrics").get_json()["total_requests"]
    client.get("/")
    total_after = client.get("/metrics").get_json()["total_requests"]
    assert total_after > total_before


# --- Prometheus exposition -------------------------------------------------

def test_prometheus_endpoint_content_type(client):
    """Prometheus refuses anything that is not the text exposition format.

    The content type is part of the contract, not decoration. This is the
    check that would catch someone 'helpfully' making the endpoint return
    JSON like its neighbour.
    """
    response = client.get("/metrics/prometheus")
    assert response.status_code == 200
    assert response.mimetype == "text/plain"


def test_prometheus_endpoint_has_help_and_type(client):
    """Every metric carries HELP and TYPE metadata."""
    body = client.get("/metrics/prometheus").get_data(as_text=True)
    for name in (
        "soundcheck_app_info",
        "soundcheck_requests_total",
        "soundcheck_uptime_seconds",
        "soundcheck_start_time_seconds",
        "soundcheck_success_rate_percent",
    ):
        assert f"# HELP {name}" in body
        assert f"# TYPE {name}" in body


def test_prometheus_exposition_is_parseable(client):
    """Every non-comment line is `name[{labels}] <float>`.

    A malformed line does not throw at serve time; it silently poisons the
    scrape, so the format is worth asserting on rather than eyeballing.
    """
    body = client.get("/metrics/prometheus").get_data(as_text=True)
    assert body.endswith("\n")

    samples = 0
    for line in body.splitlines():
        if not line or line.startswith("#"):
            continue
        name_part, _, value = line.rpartition(" ")
        assert name_part, f"no metric name in: {line!r}"
        float(value)  # raises if the value is not a number
        samples += 1
    assert samples >= 5


def test_prometheus_counter_tracks_requests(client):
    """The per-route counters must sum to the JSON total.

    The two views have to agree, otherwise the shell fallback in
    soundcheck.sh and the Prometheus alert rule would be reasoning about
    different numbers while claiming to measure the same thing.
    """
    client.get("/")
    json_successes = client.get("/metrics").get_json()["successful_requests"]
    body = client.get("/metrics/prometheus").get_data(as_text=True)

    total = sum(
        float(ln.rsplit(" ", 1)[1])
        for ln in body.splitlines()
        if ln.startswith("soundcheck_requests_total{") and 'result="success"' in ln
    )
    assert total == pytest.approx(json_successes, abs=2)


def test_app_info_carries_the_version(client):
    """The info-metric pattern: value 1, real content in the label."""
    body = client.get("/metrics/prometheus").get_data(as_text=True)
    line = next(
        ln for ln in body.splitlines() if ln.startswith("soundcheck_app_info{")
    )
    assert 'version="' in line
    assert line.endswith(" 1")


# --- The deliberate-failure switch -----------------------------------------

def test_health_fail_returns_http_error(client, monkeypatch):
    """HEALTH_FAIL makes /health answer 503 while the process stays up.

    This is the exact condition the original monitor.sh reported as healthy:
    a live process serving an error status. `curl -s` exits 0 here because the
    transfer succeeded; only `curl -sf` treats >= 400 as a failure.
    """
    monkeypatch.setattr(app_module, "HEALTH_FAIL", True)
    response = client.get("/health")
    assert response.status_code == 503
    assert response.get_json()["status"] == "unhealthy"


def test_health_fail_is_off_by_default(client):
    """The demo switch must never be on unless it was asked for."""
    assert app_module.HEALTH_FAIL is False
    assert client.get("/health").status_code == 200


# --- Regression tests for three bugs found in review -----------------------

def test_health_checks_are_counted(client):
    """Health probes must move the counters.

    They used to not, because only `/` incremented anything. On a service
    doing nothing but serving health checks that left the counters at zero,
    which gave the rate()-based alert rule a denominator of zero and made it
    permanently unfirable. An alert that cannot fire looks like coverage and
    is worse than no alert at all.
    """
    before = client.get("/metrics").get_json()["total_requests"]
    for _ in range(5):
        client.get("/health")
    after = client.get("/metrics").get_json()["total_requests"]
    assert after - before == 5


def test_metrics_endpoints_are_not_counted(client):
    """Scraping must not inflate the numbers being scraped.

    Prometheus polls every 10 seconds forever. Counting its own scrapes would
    bury real traffic under a constant background rate and make any error
    ratio meaningless.
    """
    before = client.get("/metrics").get_json()["total_requests"]
    for _ in range(5):
        client.get("/metrics/prometheus")
        client.get("/metrics")
    after = client.get("/metrics").get_json()["total_requests"]
    assert after == before


def test_unknown_route_returns_404_not_500(client):
    """A typo in a URL is not a server failure.

    `@app.errorhandler(Exception)` also catches werkzeug's HTTPException, so
    every 404 was being converted into a 500. Harmless while nothing read the
    numbers; not harmless once an alert rule was built on them, because a
    handful of bad URLs could take the success rate to zero and page someone.
    """
    response = client.get("/definitely-not-a-route")
    assert response.status_code == 404
    assert response.get_json()["status"] == 404


def test_error_is_counted_exactly_once(client):
    """The handlers must not double-count what after_request already counts."""
    before = client.get("/metrics").get_json()
    client.get("/still-not-a-route")
    after = client.get("/metrics").get_json()

    assert after["failed_requests"] - before["failed_requests"] == 1
    assert after["total_requests"] - before["total_requests"] == 1


def test_route_label_uses_the_rule_not_the_raw_path(client):
    """Cardinality guard: unmatched URLs collapse to one label value.

    Every distinct label combination is a separate Prometheus time series.
    Using the raw request path would create one series per URL a scanner ever
    tried, which is the standard way to take a Prometheus down by accident.
    """
    for i in range(10):
        client.get(f"/random-path-{i}")

    body = client.get("/metrics/prometheus").get_data(as_text=True)
    labels = [ln for ln in body.splitlines() if ln.startswith("soundcheck_requests_total")]

    assert any('route="<unmatched>"' in ln for ln in labels)
    assert not any("random-path" in ln for ln in labels)


def test_success_and_error_series_both_exist_at_zero(client):
    """A counter that only appears once non-zero leaves gaps in graphs.

    rate() over a series that does not exist returns nothing rather than 0, so
    a dashboard shows a hole where it should show a flat line.
    """
    body = client.get("/metrics/prometheus").get_data(as_text=True)
    assert 'route="/health",result="error"' in body
