#!/usr/bin/env bash
#
# audience: send traffic at the show
# ===========================================================================
# WHAT:  A small load generator with a dial for how much of the traffic
#        fails, so the alert rule, the Grafana dashboard and the
#        HorizontalPodAutoscaler have something real to react to.
#
# Named "audience" because that is what a show needs to be a show. Everything
# else in this repo is the crew: this is the only part that represents people
# actually arriving.
#
# WHY IT EXISTS, which is a point about monitoring rather than about load:
#
# Before this, the only traffic the service ever saw was its own health
# checks, about one request every two seconds. Every observability feature in
# the repo was therefore unfalsifiable. The success-rate alert could not fire,
# because the error ratio was pinned at zero. The dashboard drew flat lines.
# The HPA had no CPU to scale on. All of it was configuration that looked
# right and had never once been shown to work.
#
# A monitoring stack you have never seen fire is a monitoring stack you do not
# know works. This is the cheapest way to find out.
#
# USAGE
#   ./bin/audience.sh                          30s of clean traffic at 10 rps
#   ./bin/audience.sh --error-rate 0.2         20% of requests fail
#   ./bin/audience.sh --rps 25 --duration 300  louder, for longer
#   ./bin/audience.sh --url http://localhost:18080
#
#   --rps N           requests per second (default 10)
#   --duration N      seconds to run, 0 means until Ctrl-C (default 30)
#   --error-rate F    fraction of requests sent to /boom, 0.0 to 1.0
#   --url URL         base URL (default http://localhost:${APP_PORT})
#   -h, --help
#
# Exit code is 0 unless the target was unreachable for every request, because
# a load generator that fails when the service fails cannot report on the
# service failing.
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

SC_TOOL="audience"

RPS=10
DURATION=30
ERROR_RATE=0
BASE_URL=""

usage() {
    cat <<'EOF'
audience: send traffic at the show

usage: ./bin/audience.sh [flags]

  --rps N           requests per second (default 10)
  --duration N      seconds to run, 0 = until Ctrl-C (default 30)
  --error-rate F    fraction of requests sent to /boom, 0.0 to 1.0
  --url URL         base URL (default http://localhost:8080)
  -h, --help        this text

examples:
  ./bin/audience.sh --error-rate 0.2 --duration 300
      20% errors for five minutes, which is what it takes to drive
      SoundcheckLowSuccessRate from inactive through pending to firing.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rps)        shift; RPS="${1:-10}" ;;
        --duration)   shift; DURATION="${1:-30}" ;;
        --error-rate) shift; ERROR_RATE="${1:-0}" ;;
        --url)        shift; BASE_URL="${1:-}" ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

sc_load_config
: "${BASE_URL:=http://localhost:${APP_PORT}}"

sc_require curl awk

# Validate before sending anything. A typo in --error-rate that silently means
# zero would produce a run that looks fine and proves nothing.
awk -v r="$ERROR_RATE" 'BEGIN{exit !(r >= 0 && r <= 1)}' \
    || sc_die "--error-rate must be between 0.0 and 1.0 (got: ${ERROR_RATE})"
[ "$RPS" -gt 0 ] 2>/dev/null || sc_die "--rps must be a positive integer"

# (pacing is per-second now; see the batch loop below)

# ERROR_RATE is a float and $RANDOM is an integer, so the comparison happens
# in integer space: roll 0-9999 against the rate scaled by the same factor.
ERROR_THRESHOLD="$(awk -v r="$ERROR_RATE" 'BEGIN{printf "%d", r * 10000}')"

sent=0; ok=0; failed=0; unreachable=0
started="$(date +%s)"

# A summary on Ctrl-C as well as on completion. A generator you have to kill
# should still tell you what it did.
report() {
    local elapsed=$(( $(date +%s) - started ))
    [ "$elapsed" -gt 0 ] || elapsed=1
    sc_say ""
    sc_say "${C_BLUE}audience summary${C_RESET}"
    sc_say "  sent          ${sent} in ${elapsed}s  (~$((sent / elapsed))/s)"
    sc_say "  2xx           ${ok}"
    sc_say "  non-2xx       ${failed}"
    sc_say "  unreachable   ${unreachable}"
    if [ "$sent" -gt 0 ]; then
        sc_say "  measured error ratio $(awk -v f="$failed" -v s="$sent" 'BEGIN{printf "%.1f%%", 100*f/s}')"
    fi
    sc_event "load_finished" "sent=${sent}" "errors=${failed}" \
        "unreachable=${unreachable}" "error_rate=${ERROR_RATE}"
    exit 0
}
trap report INT TERM

sc_step "sending ~${RPS}/s at ${BASE_URL} for ${DURATION}s, error rate ${ERROR_RATE}"
sc_event "load_started" "rps=${RPS}" "duration=${DURATION}" "error_rate=${ERROR_RATE}"

# ---------------------------------------------------------------------------
# One curl process per SECOND, not per request.
#
# The obvious loop is one curl per request with a sleep between them. It
# produced 4 requests per second when asked for 20, and the service was not
# the reason: each iteration spawned curl, then awk, then sleep, and process
# creation on Windows costs tens of milliseconds each. The generator was
# measuring its own overhead.
#
# curl accepts many URLs in one invocation and performs them in sequence,
# writing one -w line per response. So a whole second's worth of traffic
# becomes a single process, and the per-request cost drops to what the request
# actually costs. `-o /dev/null` has to be repeated once per URL, because curl
# pairs output flags with URLs positionally and would otherwise let the later
# bodies fall through to stdout and corrupt the status lines.
#
# This is still a traffic generator and not a benchmark. It makes graphs move.
# ---------------------------------------------------------------------------
deadline=$(( started + DURATION ))
while [ "$DURATION" -eq 0 ] || [ "$(date +%s)" -lt "$deadline" ]; do
    args=()
    for (( i = 0; i < RPS; i++ )); do
        # Unbiased roll, which the obvious `$RANDOM % 10000` is not.
        #
        # $RANDOM yields 0..32767, and 32768 is not a multiple of 10000, so
        # the values 0..2767 come up four times per cycle while 2768..9999
        # come up three. Asking for a 25% error rate that way produces 30.5%.
        # Measured, not theorised: a 25% run came back at 36% and the excess
        # was this, not sampling noise.
        #
        # Discarding draws at or above 30000, the largest multiple of 10000
        # that fits, makes the remainder exactly uniform. It costs about 8% of
        # draws and buys a dial whose number means what it says, which matters
        # when the whole point is to land the success rate near a threshold.
        while :; do roll=$RANDOM; [ "$roll" -lt 30000 ] && break; done
        if [ "$ERROR_THRESHOLD" -gt 0 ] && [ $(( roll % 10000 )) -lt "$ERROR_THRESHOLD" ]; then
            args+=(-o /dev/null "${BASE_URL}/boom")
        else
            args+=(-o /dev/null "${BASE_URL}/")
        fi
    done

    # -w rather than -f, because here the status code IS the measurement. -f
    # would collapse every failure into exit 22 and lose the distinction
    # between "the service returned 500", which is what was asked for, and
    # "nothing answered", which means the run is meaningless.
    # intentional-plain-curl: reading the status is the entire purpose.
    # Kept on one line because the CI guard is line-based: a marker on a
    # continuation line does not count, which is the right call for a check
    # whose whole job is to be hard to satisfy by accident.
    batch="$(curl -s -w '%{http_code} %{time_total}\n' --max-time 5 "${args[@]}" 2>/dev/null)"  # intentional-plain-curl

    # One awk for the whole batch: tally the codes and total the time spent,
    # so the pacing below can sleep for whatever is left of the second.
    #
    # `read` rather than `eval` on a generated assignment string. eval would
    # work and is how this was first written, but it hides the assignment from
    # static analysis (shellcheck reported all four counters as referenced but
    # never assigned) and it hands awk's output to the shell as code. read
    # does the same job as data.
    read -r b_n b_ok b_fail b_unreach b_time <<<"$(printf '%s\n' "$batch" | awk '
        /^[0-9]/ {
            n++; t += $2
            if ($1 ~ /^2/)            o++
            else if ($1 == "000")     u++
            else                      f++
        }
        END { printf "%d %d %d %d %.3f", n+0, o+0, f+0, u+0, t+0 }')"

    sent=$((sent + b_n))
    ok=$((ok + b_ok))
    failed=$((failed + b_fail))
    unreachable=$((unreachable + b_unreach))

    sc_dim "sent ${sent}, 2xx ${ok}, non-2xx ${failed}, unreachable ${unreachable}"

    # Sleep whatever is left of this second. When the service is slower than
    # the requested rate there is nothing left and the loop simply runs flat
    # out, which is the honest behaviour: the tool cannot manufacture a rate
    # the service will not serve.
    sleep "$(awk -v t="${b_time:-0}" 'BEGIN{d=1-t; print (d>0)?d:0}')"
done

if [ "$sent" -gt 0 ] && [ "$unreachable" -eq "$sent" ]; then
    sc_err "every request was unreachable: is ${BASE_URL} actually up?"
fi
report
