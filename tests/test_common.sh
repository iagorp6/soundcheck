#!/usr/bin/env bash
#
# tests/test_common.sh: the shell test suite
# ===========================================================================
# This repo argues that shell bugs are invisible, that they fail by producing
# a plausible number rather than by throwing, and that the fix is machine
# checking rather than care. Leaving lib/common.sh untested while making that
# argument was the obvious hole, and one of the bugs found in review
# (`--json-log` silently losing to the config file) would have been caught
# here in three lines.
#
# WHY NOT bats-core, which is the standard choice: it is one more thing to
# install before the suite can run, and this file has to work on a machine
# where the only guaranteed tools are the ones the scripts themselves need.
# The harness below is about forty lines. That trade would go the other way in
# a bigger codebase; here the dependency costs more than it saves.
#
# USAGE
#   ./tests/test_common.sh            run everything
#   ./tests/test_common.sh -v         also print each passing assertion
#
# Exit code is the number of failed tests, capped at 125, so CI can just look
# at whether it is zero.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# --- Harness ---------------------------------------------------------------
TESTS_RUN=0
TESTS_FAILED=0
CURRENT=""

if [ -t 1 ]; then
    T_GREEN=$'\033[0;32m'; T_RED=$'\033[0;31m'; T_DIM=$'\033[2m'; T_OFF=$'\033[0m'
else
    T_GREEN=''; T_RED=''; T_DIM=''; T_OFF=''
fi

it() {
    CURRENT="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%sFAIL%s %s\n' "$T_RED" "$T_OFF" "$CURRENT"
    printf '     %s\n' "$1"
}

pass() {
    [ "$VERBOSE" = 1 ] && printf '%s  ok%s %s\n' "$T_GREEN" "$T_OFF" "$CURRENT"
    return 0
}

assert_eq() {
    if [ "$1" = "$2" ]; then pass; else
        fail "expected: $(printf '%q' "$2")
     actual:   $(printf '%q' "$1")"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass ;;
        *) fail "expected to contain: $2
     in: $1" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "expected NOT to contain: $2
     in: $1" ;;
        *) pass ;;
    esac
}

# assert_status <expected> <command...>
# Runs the command with errexit off so a non-zero exit is data, not a crash.
assert_status() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then pass; else
        fail "expected exit ${want}, got ${got}, from: $*"
    fi
}

# Each test that writes history gets its own file, so ordering between tests
# can never matter. Tests that depend on each other's leftovers are how a
# suite starts passing for the wrong reason.
new_history() { mktemp "${TMPDIR:-/tmp}/soundcheck-history-XXXXXX"; }

# --- Load the code under test ----------------------------------------------
# HISTORY_FILE is set before sourcing so the defaults do not point the suite at
# the developer's real deploy_history.log.
export HISTORY_FILE
HISTORY_FILE="$(new_history)"
# shellcheck source=../lib/common.sh
. "${REPO_ROOT}/lib/common.sh"

SC_TOOL="test"
SC_MODE="docker"

cleanup() { rm -f "${TMPDIR:-/tmp}"/soundcheck-history-* 2>/dev/null || true; }
trap cleanup EXIT

printf '%srunning shell tests against %s%s\n\n' "$T_DIM" "${REPO_ROOT}/lib/common.sh" "$T_OFF"

# ===========================================================================
# sc_json_escape
# ===========================================================================
# The ordering rule is the whole reason this function is worth testing:
# backslashes MUST be escaped before quotes, otherwise the backslash added
# while escaping a quote gets escaped a second time and the output is invalid
# JSON that still looks right at a glance.

it "sc_json_escape leaves plain text alone"
assert_eq "$(sc_json_escape 'plain text 1.2.0')" 'plain text 1.2.0'

it "sc_json_escape escapes double quotes"
assert_eq "$(sc_json_escape 'say "hi"')" 'say \"hi\"'

it "sc_json_escape escapes backslashes"
assert_eq "$(sc_json_escape 'C:\path')" 'C:\\path'

it "sc_json_escape escapes backslash before quote, not after"
# A naive implementation that escapes quotes first turns \" into \\\" here.
assert_eq "$(sc_json_escape '\"')" '\\\"'

it "sc_json_escape escapes newlines and tabs"
assert_eq "$(sc_json_escape "$(printf 'a\tb')")" 'a\tb'

it "sc_json_escape output survives a real JSON parser"
if sc_has_python; then
    nasty='he said "\hello"	and left'
    parsed="$(printf '{"v":"%s"}' "$(sc_json_escape "$nasty")" \
        | sc_python -c 'import sys,json; print(json.load(sys.stdin)["v"])' 2>/dev/null)"
    assert_eq "$parsed" "$nasty"
else
    pass  # no working Python: the assertions above still cover the mechanics
fi

# ===========================================================================
# sc_reverse_lines
# ===========================================================================
it "sc_reverse_lines reverses"
assert_eq "$(printf 'a\nb\nc\n' | sc_reverse_lines)" "$(printf 'c\nb\na')"

it "sc_reverse_lines handles empty input"
assert_eq "$(printf '' | sc_reverse_lines)" ""

# ===========================================================================
# sc_event
# ===========================================================================
it "sc_event appends one line per call"
HISTORY_FILE="$(new_history)"
sc_event "deploy" "version=1.0.0" "result=success"
sc_event "deploy" "version=1.1.0" "result=success"
assert_eq "$(wc -l <"$HISTORY_FILE" | tr -d ' ')" "2"

it "sc_event writes parseable JSON with the standard fields"
HISTORY_FILE="$(new_history)"
SC_TOOL="showtime" SC_MODE="docker" sc_event "deploy" "version=1.0.0" "result=success"
line="$(cat "$HISTORY_FILE")"
assert_contains "$line" '"action":"deploy"'

it "sc_event carries the tool and mode"
assert_contains "$line" '"tool":"showtime"'

it "sc_event records the mode"
assert_contains "$line" '"mode":"docker"'

it "sc_event turns key=value pairs into fields"
assert_contains "$line" '"version":"1.0.0"'

it "sc_event timestamps in UTC RFC3339"
# Promtail parses this with format: RFC3339. A locale-dependent date format
# would make every shipped log line land at the wrong time, or be dropped.
assert_status 0 grep -qE '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$HISTORY_FILE"

it "sc_event escapes values containing quotes"
HISTORY_FILE="$(new_history)"
sc_event "aborted" 'reason=he said "no"'
if sc_has_python; then
    assert_eq "$(sc_python -c 'import sys,json; print(json.load(open(sys.argv[1]))["reason"])' "$HISTORY_FILE")" 'he said "no"'
else
    assert_contains "$(cat "$HISTORY_FILE")" '\"no\"'
fi

it "sc_event never fails the caller"
# It is called from sc_die and from error paths. An event write that returns
# non-zero under `set -e` would abort the very handler trying to report the
# problem, turning a clear failure into a silent one.
HISTORY_FILE="/nonexistent-dir-$$/deep/history.log"
assert_status 0 sc_event "deploy" "result=failure"

# ===========================================================================
# sc_history_versions
# ===========================================================================
seed_history() {
    HISTORY_FILE="$(new_history)"
    cat >"$HISTORY_FILE" <<'JSON'
{"ts":"2026-08-01T10:00:00Z","action":"deploy","tool":"showtime","mode":"docker","version":"1.0.0","result":"success"}
{"ts":"2026-08-02T10:00:00Z","action":"deploy","tool":"showtime","mode":"docker","version":"1.1.0","result":"success"}
{"ts":"2026-08-03T10:00:00Z","action":"deploy","tool":"showtime","mode":"docker","version":"1.2.0","result":"failure","stage":"candidate_health"}
{"ts":"2026-08-04T10:00:00Z","action":"rollback","tool":"encore","mode":"docker","target":"1.1.0","result":"success"}
{"ts":"2026-08-05T10:00:00Z","action":"deploy","tool":"showtime","mode":"docker","version":"1.1.0","result":"success"}
JSON
}

it "sc_history_versions returns newest first"
seed_history
assert_eq "$(sc_history_versions | head -n1)" "1.1.0"

it "sc_history_versions excludes failed deploys"
# The entire point of the rollback tool: never offer a version that is known
# not to work as somewhere safe to go back to.
assert_not_contains "$(sc_history_versions)" "1.2.0"

it "sc_history_versions deduplicates a redeployed version"
assert_eq "$(sc_history_versions | grep -c '^1\.1\.0$')" "1"

it "sc_history_versions ignores rollback events"
assert_eq "$(sc_history_versions | wc -l | tr -d ' ')" "2"

it "sc_history_versions is empty for a missing file"
HISTORY_FILE="/definitely/not/here.log"
assert_eq "$(sc_history_versions)" ""

it "sc_history_versions is empty for an empty file"
HISTORY_FILE="$(new_history)"
assert_eq "$(sc_history_versions)" ""

it "sc_history_versions agrees with itself with and without jq"
# The jq path and the grep/sed fallback must return the same answer, or a box
# without jq rolls back somewhere different from a box with it. That is the
# worst kind of bug: it only appears on the machine you are not testing on.
if command -v jq >/dev/null 2>&1; then
    seed_history
    with_jq="$(sc_history_versions)"
    # Force the fallback by hiding jq from PATH for one call.
    without_jq="$(PATH=/nonexistent bash -c "
        HISTORY_FILE='${HISTORY_FILE}'
        . '${REPO_ROOT}/lib/common.sh'
        sc_history_versions
    " 2>/dev/null)"
    assert_eq "$without_jq" "$with_jq"
else
    pass  # only the fallback exists here, and it is covered above
fi

# ===========================================================================
# sc_python
# ===========================================================================
# Found by this very suite failing on the machine it was written on. Windows
# puts an App Execution Alias named `python3` on PATH which is not Python: it
# prints "Python was not found; run without arguments to install from the
# Microsoft Store" to STDOUT and exits 49.
#
# `command -v python3` finds it happily. A caller that redirects stderr and
# reads stdout, which is exactly what pulling a field out of JSON looks like,
# gets the advert text back as the value. In soundcheck.sh that meant the
# success rate could be read as that sentence, which awk evaluates as 0, which
# is below any threshold. A missing interpreter would have produced a false
# ALERT rather than a clean skip.

it "sc_python either works or fails cleanly, never both"
if sc_has_python; then
    assert_eq "$(sc_python -c 'print(2 + 2)')" "4"
else
    assert_status 127 sc_python -c 'print(1)'
fi

it "sc_python refuses an interpreter that does not actually run"
# Simulate the alias: a `python3` on PATH that prints to stdout and exits
# non-zero. The probe must reject it and fall through to the next candidate.
stub_dir="$(mktemp -d)"
cat >"${stub_dir}/python3" <<'STUB'
#!/usr/bin/env bash
echo "Python was not found; run without arguments to install from the Microsoft Store"
exit 49
STUB
chmod +x "${stub_dir}/python3"
chosen="$(PATH="${stub_dir}:$PATH" bash -c "
    . '${REPO_ROOT}/lib/common.sh'
    sc_has_python && printf '%s' \"\$_SC_PYTHON\"
" 2>/dev/null)"
assert_not_contains "${chosen:-none}" "python3"

it "a stubbed python3 does not leak advert text into a value"
# The end-to-end version of the same bug, at the layer that matters.
leaked="$(PATH="${stub_dir}:$PATH" bash -c "
    . '${REPO_ROOT}/lib/common.sh'
    sc_has_python && sc_python -c 'print(\"clean\")'
" 2>/dev/null)"
assert_not_contains "${leaked:-}" "Microsoft Store"
rm -rf "$stub_dir"

# ===========================================================================
# Config precedence
# ===========================================================================
# defaults < config file < environment < command-line flag.
#
# Each case runs in its own bash process, because the layering happens partly
# at source time and cannot be re-tested in a shell that has already sourced
# the library.
config_probe() {
    # config_probe <env-assignments> <flag-lines> <var>
    local tmpdir; tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/config" "${tmpdir}/lib"
    cp "${REPO_ROOT}/lib/common.sh" "${tmpdir}/lib/"
    printf 'RETENTION_COUNT=3\nLOG_FORMAT=text\n' >"${tmpdir}/config/retention.env"
    env -i PATH="$PATH" HOME="$HOME" $1 bash -c "
        . '${tmpdir}/lib/common.sh'
        $2
        sc_load_config
        printf '%s' \"\$$3\"
    " 2>/dev/null
    rm -rf "$tmpdir"
}

it "a default applies when nothing else sets the value"
assert_eq "$(config_probe '' '' APP_PORT)" "8080"

it "the config file beats the default"
assert_eq "$(config_probe '' '' LOG_FORMAT)" "text"

it "the environment beats the config file"
assert_eq "$(config_probe 'RETENTION_COUNT=9' '' RETENTION_COUNT)" "9"

it "a flag beats the config file"
# This is the regression test for a real bug: --json-log did nothing whenever
# config/retention.env existed, because flags are parsed before the config
# file is sourced and the file simply overwrote the flag's value. Silently.
assert_eq "$(config_probe '' 'sc_override LOG_FORMAT json' LOG_FORMAT)" "json"

it "a flag beats the environment too"
assert_eq "$(config_probe 'LOG_FORMAT=text' 'sc_override LOG_FORMAT json' LOG_FORMAT)" "json"

# ===========================================================================
# sc_http_ok: the bug this whole repo is named after
# ===========================================================================
# Everything else here tests plumbing. This tests the claim on the front page:
# that a health check must fail on an HTTP error status, and that the original
# `curl -s` did not.
#
# A real server is started rather than mocking curl, because the behaviour
# under test IS curl's, and a mock would only prove that I understand the bug,
# not that the code avoids it.
PORT=18099
SERVER_PID=""

start_server() {
    sc_has_python || return 1
    sc_python -c '
import http.server, sys

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 503 if self.path.startswith("/bad") else 200
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"status\":\"whatever\"}")
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$PORT" >/dev/null 2>&1 &
    SERVER_PID=$!
    local i
    for i in $(seq 1 40); do
        # intentional-plain-curl: "is anything listening yet", where a 503
        # would still mean yes. -f would make the readiness probe for the
        # test server itself depend on the status code it returns.
        curl -s -o /dev/null "http://127.0.0.1:${PORT}/ok" 2>/dev/null && return 0  # intentional-plain-curl
        sleep 0.25
    done
    return 1
}

if command -v curl >/dev/null 2>&1 && start_server; then
    it "sc_http_ok succeeds on 200"
    assert_status 0 sc_http_ok "http://127.0.0.1:${PORT}/ok"

    it "sc_http_ok FAILS on 503 (this is the fix)"
    assert_status 22 sc_http_ok "http://127.0.0.1:${PORT}/bad"

    it "plain 'curl -s' SUCCEEDS on 503 (this was the bug)"
    # If this assertion ever flips, curl changed its behaviour and the premise
    # of this repo needs revisiting rather than the code.
    # intentional-plain-curl: demonstrating the defect is the point here.
    assert_status 0 curl -s -o /dev/null "http://127.0.0.1:${PORT}/bad"  # intentional-plain-curl

    it "sc_http_ok fails when nothing is listening"
    assert_status 7 sc_http_ok "http://127.0.0.1:1/health"

    it "sc_wait_healthy gives up rather than looping forever"
    HEALTH_RETRIES=2 HEALTH_INTERVAL=0 assert_status 1 \
        sc_wait_healthy "http://127.0.0.1:${PORT}/bad"

    it "sc_http_body returns the payload on 200"
    assert_contains "$(sc_http_body "http://127.0.0.1:${PORT}/ok")" '"status"'

    it "sc_http_body returns nothing on 503"
    assert_eq "$(sc_http_body "http://127.0.0.1:${PORT}/bad")" ""

    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
else
    printf '%sskipping HTTP tests: need curl and a working Python 3%s\n' "$T_DIM" "$T_OFF"
fi

# ===========================================================================
# Report
# ===========================================================================
printf '\n'
if [ "$TESTS_FAILED" -eq 0 ]; then
    printf '%s%d passed%s\n' "$T_GREEN" "$TESTS_RUN" "$T_OFF"
    exit 0
fi
printf '%s%d of %d failed%s\n' "$T_RED" "$TESTS_FAILED" "$TESTS_RUN" "$T_OFF"
[ "$TESTS_FAILED" -gt 125 ] && exit 125
exit "$TESTS_FAILED"
