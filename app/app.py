"""
soundcheck: the service under test.

A deliberately small Flask app. It exists so there is something real to
deploy, watch and roll back; it is not the point of the repo, but two things
about it are:

  1. It exposes its counters in TWO formats. `/metrics` is the original JSON,
     kept byte-compatible because soundcheck.sh and the test suite read it.
     `/metrics/prometheus` is the same numbers in Prometheus text exposition
     format, because Prometheus cannot scrape JSON: it speaks exactly one
     wire format and this is it. Adding a second endpoint rather than changing
     the first is the whole reason `metrics_path` is configurable in a scrape
     config.

  2. It has a switch to make /health fail on purpose (HEALTH_FAIL=1). That is
     not a hack left in by accident: it is what lets you demonstrate the bug
     this repo is about: a health endpoint returning HTTP 500 while the
     process is perfectly alive. `curl -s` calls that healthy; `curl -sf`
     does not.
"""

import json
import os
import time
from collections import defaultdict
from datetime import datetime, timezone

from flask import Flask, Response, jsonify, request
from werkzeug.exceptions import HTTPException

app = Flask(__name__)

# --- Configuration ---------------------------------------------------------
# Everything the app needs to know about the world arrives as an environment
# variable, never as an edit to this file. That is the same config/data split
# radio-kiosk makes with station.conf, and it is what allows k8s/configmap.yaml
# to change the app's behaviour without rebuilding the image. An image that has
# to be rebuilt to change a message is not a deployable artifact, it is a
# build output.
APP_VERSION = os.getenv("APP_VERSION", "0.0.0-dev")
APP_MESSAGE = os.getenv("APP_MESSAGE", "soundcheck. One, two, one two")
LOG_FORMAT = os.getenv("LOG_FORMAT", "text").lower()

# Demo switch, off unless explicitly enabled. See the module docstring.
HEALTH_FAIL = os.getenv("HEALTH_FAIL", "0") == "1"

# --- In-process counters ---------------------------------------------------
# In-memory and therefore reset by every restart, which is fine and in fact
# instructive: it is exactly why the Prometheus alert rule uses rate() over a
# counter instead of trusting a cumulative percentage the app computes itself.
metrics = {
    "total_requests": 0,
    "successful_requests": 0,
    "failed_requests": 0,
    "start_time": time.time(),
}

# Per-route breakdown, keyed by (route, result). Kept separate from the dict
# above so the JSON payload stays byte-compatible with what soundcheck.sh and
# the original test suite parse.
route_metrics = defaultdict(int)

# Endpoints that are excluded from the counters. A monitoring system must not
# dominate the numbers it is monitoring: Prometheus scrapes every 10 seconds
# forever, so counting its own scrapes would bury real traffic under a
# constant background rate and make any error ratio meaningless.
#
# Health checks ARE counted, deliberately. They are the one kind of traffic
# guaranteed to exist on an idle service, which is what keeps the denominator
# of the alert rule non-zero, and a health endpoint starting to fail is a real
# signal rather than noise to be filtered out.
UNCOUNTED_ROUTES = {"/metrics", "/metrics/prometheus"}


def _log_event(**fields):
    """One structured line per interesting event, on stdout.

    Stdout, not a file, on purpose: in a container the log stream IS stdout,
    and Docker, Promtail, and every orchestrator already know how to collect
    it. Writing to a file inside a container means inventing a way to get the
    file back out.
    """
    if LOG_FORMAT != "json":
        return
    payload = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "service": "soundcheck",
        "version": APP_VERSION,
    }
    payload.update(fields)
    # flush=True matters in a container: Python buffers stdout when it is a
    # pipe rather than a terminal, and a buffered log line is a log line that
    # arrives after the crash it was meant to explain.
    print(json.dumps(payload), flush=True)


def _success_rate():
    if metrics["total_requests"] == 0:
        return 100.0
    return (metrics["successful_requests"] / metrics["total_requests"]) * 100


def _route_label():
    """The matched ROUTE PATTERN, never the raw path.

    This is the difference between a label with five values and a label with
    one value per URL anyone has ever typed. `request.url_rule` is the rule
    the router matched, so `/users/42` and `/users/7` both report
    `/users/<id>`; a request that matched nothing reports a single constant.

    It matters because every distinct label combination is a separate time
    series in Prometheus, and a 404 scanner hitting random paths would
    otherwise create one series per attempt and take the database with it.
    Cardinality is the thing that kills Prometheus, and raw request paths are
    the most common way to do it by accident.
    """
    if request.url_rule is not None:
        return request.url_rule.rule
    return "<unmatched>"


@app.after_request
def count_request(response):
    """Count EVERY request, in one place.

    Previously each view incremented the counters itself, and only `/` did.
    The effect was that a service serving health checks and metrics scrapes
    all day reported one request in total, which meant the rate()-based alert
    rule had a denominator of zero and could never fire. An alert that cannot
    fire is worse than no alert, because it looks like coverage.

    after_request also runs for responses produced by error handlers, so this
    is the only place counting happens; the handlers below deliberately do not
    touch the counters.
    """
    route = _route_label()
    if route in UNCOUNTED_ROUTES:
        return response

    result = "success" if response.status_code < 400 else "error"
    metrics["total_requests"] += 1
    metrics["successful_requests" if result == "success" else "failed_requests"] += 1
    route_metrics[(route, result)] += 1

    _log_event(
        event="request",
        route=route,
        status=response.status_code,
        result=result,
    )
    return response


@app.route("/")
def home():
    return jsonify({
        "message": APP_MESSAGE,
        "version": APP_VERSION,
    })


@app.route("/health")
def health():
    """Liveness/readiness endpoint.

    Returns 200 with a body when things are fine, and 503 when HEALTH_FAIL is
    set. 503 (Service Unavailable) rather than 500 because it is the honest
    status for "I am running but not able to serve", and more to the point
    here, both are >= 400, which is the threshold `curl -f` reacts to and
    plain `curl -s` ignores.
    """
    uptime_seconds = time.time() - metrics["start_time"]

    if HEALTH_FAIL:
        _log_event(event="health", status=503, forced=True)
        return jsonify({
            "status": "unhealthy",
            "reason": "HEALTH_FAIL is set (deliberate demo failure)",
            "uptime_seconds": round(uptime_seconds, 2),
            "timestamp": datetime.now().isoformat(),
        }), 503

    return jsonify({
        "status": "healthy",
        "version": APP_VERSION,
        "uptime_seconds": round(uptime_seconds, 2),
        "timestamp": datetime.now().isoformat(),
    })


@app.route("/metrics")
def get_metrics():
    """Original JSON metrics. Shape is frozen. Soundcheck.sh parses it."""
    uptime_seconds = time.time() - metrics["start_time"]

    return jsonify({
        "total_requests": metrics["total_requests"],
        "successful_requests": metrics["successful_requests"],
        "failed_requests": metrics["failed_requests"],
        "success_rate_percent": round(_success_rate(), 2),
        "uptime_seconds": round(uptime_seconds, 2),
        "uptime_minutes": round(uptime_seconds / 60, 2),
    })


@app.route("/metrics/prometheus")
def get_metrics_prometheus():
    """The same numbers, in the only format Prometheus can read.

    Written by hand rather than with prometheus_client so the format is
    visible instead of hidden behind a library. The rules of it:

      # HELP <name> <description>     one per metric, for the UI
      # TYPE <name> <counter|gauge>   counters only go up; gauges go up/down
      <name>{label="value"} <number>  the sample itself

    Naming follows the convention: `<namespace>_<thing>_<unit>`, counters end
    in `_total`, and units are base units (seconds, bytes), never
    milliseconds, never percentages if a ratio will do.

    `soundcheck_app_info` is the standard "info metric" pattern: a gauge whose
    value is always 1, carrying the interesting data in its LABELS. It exists
    because a version is a string and Prometheus stores only floats. Joining
    against it is how a dashboard annotates a graph with "the version changed
    here", which is how deploy events become visible in Grafana without any
    deploy-specific plumbing.
    """
    uptime_seconds = time.time() - metrics["start_time"]
    lines = [
        "# HELP soundcheck_app_info Static app information; value is always 1.",
        "# TYPE soundcheck_app_info gauge",
        f'soundcheck_app_info{{version="{APP_VERSION}"}} 1',
        "",
        "# HELP soundcheck_requests_total Requests handled, by route and result.",
        "# TYPE soundcheck_requests_total counter",
    ]

    # Always emit both result values even at zero. A counter that only appears
    # once it is non-zero makes `rate()` return nothing instead of 0 for the
    # quiet period, which is how a dashboard ends up with a gap where it
    # should have a flat line at the bottom.
    seen_routes = {route for route, _ in route_metrics} or {"/"}
    for route in sorted(seen_routes):
        for result in ("success", "error"):
            count = route_metrics[(route, result)]
            lines.append(
                f'soundcheck_requests_total{{route="{route}",result="{result}"}} {count}'
            )

    lines += [
        "",
        "# HELP soundcheck_uptime_seconds Seconds since this process started.",
        "# TYPE soundcheck_uptime_seconds gauge",
        f"soundcheck_uptime_seconds {uptime_seconds:.2f}",
        "",
        "# HELP soundcheck_start_time_seconds Unix start time; a deploy is a step change here.",
        "# TYPE soundcheck_start_time_seconds gauge",
        f'soundcheck_start_time_seconds {metrics["start_time"]:.0f}',
        "",
        "# HELP soundcheck_success_rate_percent Lifetime success rate. Prefer rate() on the counter.",
        "# TYPE soundcheck_success_rate_percent gauge",
        f"soundcheck_success_rate_percent {_success_rate():.2f}",
        "",
    ]
    # The trailing newline is not optional: the text format is line-oriented
    # and a truncated final line is a parse error, not a warning.
    return Response(
        "\n".join(lines),
        mimetype="text/plain; version=0.0.4; charset=utf-8",
    )


@app.errorhandler(HTTPException)
def handle_http_exception(error):
    """Preserve the status the framework already decided on.

    This handler exists because of a real bug. The catch-all below is
    registered for `Exception`, and in Flask an HTTP error such as a 404 is
    raised as `NotFound`, which IS an Exception. So without this handler,
    every 404 and 405 was converted into a 500.

    That was harmless while nothing read the numbers. It stopped being
    harmless once an alert rule was built on them: one mistyped URL counted as
    a server failure, and a handful of them could take the success rate to
    zero and page someone. Registering a more specific handler fixes it,
    because Flask dispatches to the closest match in the exception hierarchy.
    """
    _log_event(
        event="http_error",
        route=_route_label(),
        status=error.code,
        error=error.name,
    )
    return jsonify({"error": error.name, "status": error.code}), error.code


@app.errorhandler(Exception)
def handle_error(error):
    """Catch-all for genuine application faults.

    Note that it does NOT touch the counters. `count_request` runs after this
    and sees the 500 response, so counting here as well would double-count
    every error. Errors are the one thing you least want to be wrong about.
    """
    _log_event(event="error", route=_route_label(), error=str(error), status=500)
    return jsonify({"error": str(error)}), 500


if __name__ == "__main__":
    _log_event(event="startup", port=8080)
    app.run(host="0.0.0.0", port=8080)
