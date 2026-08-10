#!/usr/bin/env bash
#
# soundcheck: keep verifying that everything still sounds right
# ===========================================================================
# WHAT:  Asks the running service four questions: is it answering, is it
#        answering CORRECTLY, what do its counters say, and is the container
#        itself in the state it should be. Then it turns those answers into
#        an exit code a cron job or a CI step can act on.
#
# Named "soundcheck" because that is the continuous "test, one two" you do
# before and during a show, not a single yes/no at the door.
#
# ---------------------------------------------------------------------------
# THE BUG THIS SCRIPT WAS WRITTEN TO FIX
# ---------------------------------------------------------------------------
# The original monitor.sh did this:
#
#     HEALTH=$(curl -s http://localhost:8080/health)
#     if [ $? -eq 0 ]; then  echo "Application is healthy"
#
# and deploy.sh, in the same repo, did this:
#
#     if curl -sf http://localhost:8080/health
#
# One letter apart, and the difference is the whole point of a health check.
#
#   -s  = silent. Suppresses the progress meter. Says nothing about failure.
#   -f  = fail. Makes curl exit non-zero when the server answers 4xx or 5xx.
#
# WITHOUT -f, curl exits 0 for an HTTP 500. From curl's point of view that is
# a complete success: it opened a connection, sent a request, received a
# well-formed response. curl's job is transport, and transport worked. The
# fact that the body is a stack trace is an application-level concern curl has
# no opinion about unless you ask it to with -f.
#
# So the original monitor reported "healthy" for any service that was up
# enough to serve an error page, which is nearly every interesting outage.
# A crashed process it would catch (connection refused is a transport error).
# A broken dependency, a failing migration, an unhandled exception: green.
# The monitor was blind to exactly the failures you build a monitor for.
#
# This is also a good argument for shellcheck in CI, which is why the pipeline
# runs it: an inconsistency like this between two files is easy to write, easy
# to miss in review, and never announces itself at runtime.
# ---------------------------------------------------------------------------
#
# USAGE
#   ./soundcheck.sh [flags]
#     --watch [seconds]   loop instead of running once (default 10s)
#     --k8s               check Pod readiness/liveness instead of a container
#     --json-log          emit JSON lines on the terminal too
#     -h, --help
#
# EXIT CODES
#   0  healthy
#   1  usage error
#   2  not answering, or answering with an HTTP error
#   3  answering, but the success rate is below threshold
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

SC_TOOL="soundcheck"
SC_MODE="docker"

WATCH=0
WATCH_INTERVAL=10

usage() {
    cat <<'EOF'
soundcheck: continuously verify the live service

usage: ./soundcheck.sh [flags]

  --watch [seconds]   loop instead of running once (default 10s)
  --k8s               check Pod readiness/liveness instead of a container
  --json-log          emit JSON lines on the terminal too
  -h, --help          this text

exit codes: 0 healthy · 1 usage · 2 down or erroring · 3 success rate low
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --watch)
            WATCH=1
            # Optional numeric argument. Only consume the next token if it
            # actually looks like a number, so `--watch --k8s` still works.
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WATCH_INTERVAL="$2"; shift; fi
            ;;
        --k8s)      SC_MODE=k8s ;;
        --json-log) sc_override LOG_FORMAT json ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

sc_load_config
export LOG_FORMAT SC_TOOL SC_MODE

BASE_URL="http://localhost:${APP_PORT}"

# ---------------------------------------------------------------------------
# JSON reading, without making jq a hard requirement
#
# A monitoring script should have as few dependencies as the thing it
# monitors. jq is used when present because it is the right tool; python3 is
# the fallback because this app already needs Python; and the plain-sed path
# exists so that a box with neither still gets an answer instead of a
# confusing "command not found" that looks like the service is down.
# ---------------------------------------------------------------------------
json_field() {
    local json="$1" field="$2" value
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
        return
    fi

    # sc_python, not `python3` directly. See the long comment on it in
    # lib/common.sh: a bare `command -v python3` can find a Windows stub that
    # prints an advert to STDOUT, which would be returned here as the field's
    # value and then read as 0 by the threshold check, producing a false alert
    # about a service that is perfectly fine.
    if sc_has_python; then
        value="$(printf '%s' "$json" | sc_python -c \
            'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' \
            "$field" 2>/dev/null)" && { printf '%s' "$value"; return; }
    fi

    printf '%s' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" | head -n1
}

pretty_json() {
    if command -v jq >/dev/null 2>&1; then jq . 2>/dev/null || cat
    elif sc_has_python; then sc_python -m json.tool 2>/dev/null || cat
    else cat
    fi
}

# Float comparison in shell. `[ ]` only does integers, so awk does the compare.
# awk is POSIX and present everywhere this script could plausibly run.
float_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

# ===========================================================================
# Docker-mode checks
# ===========================================================================
check_docker() {
    local rc=0 health metrics rate version state restarts

    # --- 1. Is it answering, and answering correctly? ----------------------
    sc_step "1/4 health endpoint"
    # THE FIX: -sf, not -s. See the header. -f is what makes an HTTP 500
    # register as a failure instead of as a successful transfer of bad news.
    if health="$(sc_http_body "${BASE_URL}${HEALTH_PATH}")"; then
        sc_ok "${BASE_URL}${HEALTH_PATH} responded 2xx"
        [ "$LOG_FORMAT" = json ] || printf '%s' "$health" | pretty_json | sed 's/^/     /'
        sc_event "health_check" "result=success" "endpoint=${HEALTH_PATH}"
    else
        sc_err "health check FAILED (no answer, or an HTTP error status)"
        sc_event "health_check" "result=failure" "endpoint=${HEALTH_PATH}"
        # Distinguishing the two cases is worth one extra call: "refused" and
        # "500" need completely different first moves from whoever is paged.
        #
        # intentional-plain-curl: this is the ONE place in the repo that must
        # NOT use -f. The whole question being asked here is "did the server
        # answer at all, even with an error?", and -f would collapse that back
        # into the same failure as a refused connection: destroying exactly
        # the distinction this branch exists to draw. CI enforces the marker.
        if curl -s --max-time 5 -o /dev/null "${BASE_URL}${HEALTH_PATH}" 2>/dev/null; then  # intentional-plain-curl
            sc_err "  the server IS reachable: it is returning an error status."
            sc_err "  this is precisely the case plain 'curl -s' reported as healthy."
        else
            sc_err "  nothing is listening on port ${APP_PORT} (connection level)."
        fi
        return 2
    fi

    # --- 2. Counters -------------------------------------------------------
    sc_step "2/4 metrics endpoint"
    if metrics="$(sc_http_body "${BASE_URL}/metrics")"; then
        [ "$LOG_FORMAT" = json ] || printf '%s' "$metrics" | pretty_json | sed 's/^/     /'
    else
        sc_warn "metrics endpoint did not answer: continuing, health is the gate"
        metrics=""
    fi

    # --- 3. Success rate (the standalone fallback for the Prometheus rule) --
    sc_step "3/4 success rate"
    if [ -n "$metrics" ]; then
        rate="$(json_field "$metrics" success_rate_percent)"
        if [ -n "$rate" ]; then
            if float_ge "$rate" "$SUCCESS_RATE_THRESHOLD"; then
                sc_ok "success rate ${rate}% (threshold ${SUCCESS_RATE_THRESHOLD}%)"
                sc_event "success_rate_check" "result=success" "rate=${rate}"
            else
                sc_err "success rate ${rate}% is BELOW ${SUCCESS_RATE_THRESHOLD}%"
                sc_event "success_rate_check" "result=failure" "rate=${rate}"
                rc=3
            fi
            # An honest caveat about this number, and the reason the
            # Prometheus rule in observability/prometheus/alert_rules.yml is
            # the version that should page you:
            #
            # success_rate_percent is cumulative since the process started.
            # After a week of uptime, an outage that fails every request for
            # ten minutes barely moves it: the denominator is a week of
            # successes. A threshold on a lifetime average is a smoke alarm
            # that averages the temperature since you moved in.
            #
            # Prometheus fixes it with rate() over a short window: the alert
            # rule asks "what fraction of the requests in the LAST FIVE
            # MINUTES failed", which actually tracks what is happening now.
            # This shell check is kept because it needs nothing but curl and
            # works when the stack is not running: a smoke alarm you can
            # carry, with a smoke alarm's precision.
            sc_dim "note: this is a lifetime average. observability/ has the rate()-based rule."
        else
            sc_warn "could not read success_rate_percent from the metrics payload"
        fi
    else
        sc_warn "skipped: no metrics payload"
    fi

    # --- 4. Container state ------------------------------------------------
    # "Answering on a port" and "in the state I deployed" are different
    # questions. A container in a crash loop can answer between restarts, so
    # a restart counter climbing is a signal the HTTP check cannot give you.
    sc_step "4/4 container state"
    if command -v docker >/dev/null 2>&1; then
        state="$(docker inspect --format='{{.State.Status}}' "$APP_NAME" 2>/dev/null || echo absent)"
        restarts="$(docker inspect --format='{{.RestartCount}}' "$APP_NAME" 2>/dev/null || echo 0)"
        version="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$APP_NAME" 2>/dev/null | sed -n 's/^APP_VERSION=//p' | head -n1)"
        # Docker's own HEALTHCHECK verdict, from the Dockerfile. Empty string
        # when the image declares none.
        local dhealth
        dhealth="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$APP_NAME" 2>/dev/null || true)"
        sc_ok "container ${APP_NAME}: ${state}, version ${version:-unknown}, restarts ${restarts}${dhealth:+, docker health ${dhealth}}"
        if [ "${restarts:-0}" -gt 0 ]; then
            sc_warn "restart count is ${restarts}: it has died at least once since deploy"
        fi
    else
        sc_dim "docker not available; skipping container inspection"
    fi

    return "$rc"
}

# ===========================================================================
# Kubernetes-mode checks
# ===========================================================================
# The interesting difference from Docker mode: the cluster is ALREADY running
# these probes for you, on a schedule, and acting on the results. So the job
# here is not to probe. It is to read the verdict the cluster already reached
# and the actions it already took (restarts, evictions, not-Ready Pods).
#
# READY vs LIVE: the distinction the probes encode, and the one people get
# wrong most often:
#   readinessProbe  "should this Pod receive traffic right now?"  Fail it, and
#                   the Pod is removed from the Service's endpoints. Nothing
#                   is killed. This is the correct probe for warm-up, or for a
#                   dependency being briefly unavailable.
#   livenessProbe   "is this process beyond saving?"  Fail it, and the
#                   kubelet KILLS the container and starts a new one. Getting
#                   this too aggressive is how a slow-but-recovering service
#                   gets restart-looped into a real outage.
# ===========================================================================
check_k8s() {
    local rc=0 not_ready
    sc_require kubectl

    sc_step "1/3 pods"
    kubectl -n "$K8S_NAMESPACE" get pods \
        -l "app.kubernetes.io/name=${K8S_DEPLOYMENT}" -o wide 2>&1 | sed 's/^/     /'

    sc_step "2/3 readiness"
    # A Pod's Ready condition is the aggregate of its containers' readiness
    # probes; this is the exact signal the Service uses to route traffic.
    not_ready="$(kubectl -n "$K8S_NAMESPACE" get pods \
        -l "app.kubernetes.io/name=${K8S_DEPLOYMENT}" \
        -o 'jsonpath={range .items[*]}{.metadata.name}{"="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | grep -v '=True$' || true)"

    if [ -z "$not_ready" ]; then
        sc_ok "all pods report Ready"
        sc_event "health_check" "result=success" "check=pod_readiness"
    else
        sc_err "pods not Ready:"
        printf '%s\n' "$not_ready" | sed 's/^/     /'
        sc_event "health_check" "result=failure" "check=pod_readiness"
        rc=2
    fi

    sc_step "3/3 restarts (livenessProbe verdicts the kubelet already acted on)"
    kubectl -n "$K8S_NAMESPACE" get pods \
        -l "app.kubernetes.io/name=${K8S_DEPLOYMENT}" \
        -o 'jsonpath={range .items[*]}{.metadata.name}{" restarts="}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
        2>/dev/null | sed 's/^/     /'

    sc_dim "metrics: Prometheus scrapes these Pods exactly as it scrapes the container"
    sc_dim "  kubectl -n ${K8S_NAMESPACE} port-forward svc/${K8S_DEPLOYMENT} ${APP_PORT}:80"

    return "$rc"
}

run_once() {
    sc_say ""
    sc_say "${C_BLUE}=== soundcheck @ $(sc_now_iso) (${SC_MODE} mode) ===${C_RESET}"
    if [ "$SC_MODE" = k8s ]; then check_k8s; else check_docker; fi
}

# --- Go --------------------------------------------------------------------
# Note: `set -e` is deliberately NOT enabled in this script (see the `set -uo
# pipefail` at the top). A monitor whose job is to observe failures must not
# abort on the first one: it has to finish the sweep and report everything it
# found. This is one of the few places where turning `set -e` off is the
# correct call rather than sloppiness.
if [ "$WATCH" = 1 ]; then
    sc_say "watching every ${WATCH_INTERVAL}s: Ctrl-C to stop"
    while true; do
        run_once || true
        sleep "$WATCH_INTERVAL"
    done
fi

run_once
exit $?
