#!/usr/bin/env bash
#
# lib/common.sh: shared plumbing for showtime / soundcheck / encore
# ---------------------------------------------------------------------------
# WHAT:  Config loading, the two output channels (human + machine), and the
#        append-only event log that encore.sh reads to know what it can roll
#        back to. Sourced by all three top-level scripts; not executable on
#        its own.
#
# WHY a shared file at all:  the three scripts have to agree on the container
#        name, the image repository, the ports and the history file. If each
#        one hard-coded its own copy of those, renaming anything would be a
#        three-file change with a silent failure mode (encore looking for a
#        container showtime no longer creates). One definition, three readers.
#
# THE TWO OUTPUT CHANNELS. This is the design idea worth understanding:
#
#   1. The TERMINAL channel is for a human standing at a keyboard during a
#      deploy. Colours, ticks, crosses, step numbers. Optimised for "can I
#      tell at a glance whether this went well".
#
#   2. The EVENT channel is for machines: one JSON object per line, appended
#      to deploy_history.log. Optimised for "can a log agent parse this
#      without a regex, and can I query it by version six weeks from now".
#
#   They are NOT alternatives. Every run writes both. Replacing the pretty
#      output with JSON would make the tool worse to operate; never writing
#      JSON would make it unqueryable. The only thing --json-log changes is
#      whether the TERMINAL channel also speaks JSON, which is what you want
#      when the script runs under a supervisor or in CI and the "terminal" is
#      really a log collector.
#
# JSON Lines (one object per line, no enclosing array) is used deliberately:
#      it is append-only friendly (no trailing comma to fix up), it survives a
#      truncated write (you lose one line, not the file), and it is the format
#      Loki, Promtail, Vector and friends expect natively.
# ---------------------------------------------------------------------------

# --- Where the repo lives --------------------------------------------------
# Resolved from this file's own location, so the scripts work no matter what
# directory they are invoked from. `cd ... && pwd` normalises symlinks and
# relative segments.
SOUNDCHECK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOUNDCHECK_ROOT="$(cd "${SOUNDCHECK_LIB_DIR}/.." && pwd)"
export SOUNDCHECK_ROOT

# --- Bash version guard ----------------------------------------------------
# These scripts expand possibly-empty arrays under `set -u`, which is only
# safe from bash 4.4. macOS still ships bash 3.2 as /bin/bash (it has been
# frozen there since 2007 over the GPLv3 licence change), so this is a real
# machine someone will run this on. Failing with a sentence beats failing with
# "unbound variable" on a line that looks fine.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] \
   || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "soundcheck needs bash >= 4.4 (found ${BASH_VERSION})." >&2
    echo "On macOS: brew install bash, then run with the newer bash." >&2
    exit 1
fi

# --- Defaults --------------------------------------------------------------
# Every one of these can be overridden by config/retention.env or by an
# environment variable, in that order of increasing precedence (see
# sc_load_config). Defaults are chosen so a fresh clone works with no config
# file at all.
#
# Before the defaults are applied, snapshot which keys the CALLER already set.
# This has to happen first: once `: "${X:=default}"` runs, X is set either way
# and there is no longer any way to tell "the user asked for this" apart from
# "nobody said anything". That distinction is the whole basis of the
# precedence rule in sc_load_config.
SC_CONFIG_KEYS="APP_NAME CANDIDATE_NAME IMAGE_REPO APP_PORT CANDIDATE_PORT
HEALTH_PATH RETENTION_COUNT DOCKER_NETWORK HISTORY_FILE LOG_FORMAT
HEALTH_RETRIES HEALTH_INTERVAL SUCCESS_RATE_THRESHOLD
K8S_NAMESPACE K8S_DEPLOYMENT K8S_CONTEXT"

for _sc_key in $SC_CONFIG_KEYS; do
    # ${!name+set} is indirect expansion: "is the variable NAMED by _sc_key set?"
    [ -n "${!_sc_key+set}" ] && eval "_SC_ENV_${_sc_key}=\${${_sc_key}}"
done
unset _sc_key

: "${APP_NAME:=soundcheck-app}"          # name of the live container
: "${CANDIDATE_NAME:=soundcheck-candidate}" # name of the blue-green candidate
: "${IMAGE_REPO:=soundcheck-app}"        # local image repository (no registry)
: "${APP_PORT:=8080}"                    # the port real traffic uses
: "${CANDIDATE_PORT:=8081}"              # temporary port for the new version
: "${HEALTH_PATH:=/health}"
: "${RETENTION_COUNT:=3}"                # how many old versions to keep
: "${DOCKER_NETWORK:=soundcheck-net}"    # shared net so Prometheus can scrape
: "${HISTORY_FILE:=${SOUNDCHECK_ROOT}/deploy_history.log}"
: "${LOG_FORMAT:=text}"                  # text | json  (terminal channel)
: "${HEALTH_RETRIES:=10}"
: "${HEALTH_INTERVAL:=2}"                # seconds between health attempts
: "${SUCCESS_RATE_THRESHOLD:=95.0}"      # soundcheck.sh's standalone check
: "${K8S_NAMESPACE:=soundcheck}"
: "${K8S_DEPLOYMENT:=soundcheck}"
: "${K8S_CONTEXT:=kind-soundcheck}"

# --- Colours ---------------------------------------------------------------
# Only emit escape codes when stdout is a terminal AND the caller has not set
# NO_COLOR (https://no-color.org). Piping the output into a file or a log
# shipper should not fill it with \033[0;32m noise.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_GREEN='' C_RED='' C_YELLOW='' C_BLUE='' C_DIM='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# sc_override KEY VALUE: register a command-line flag as a hard override
#
# Flags are parsed AFTER this file is sourced but BEFORE sc_load_config runs,
# so a flag that simply assigns to a config key gets silently overwritten when
# the config file is sourced. That was a real bug: `--json-log` did nothing at
# all as soon as config/retention.env existed and set LOG_FORMAT, and the
# committed .example sets it, so copying the example broke the flag.
#
# The fix is to write the value into the same snapshot slot the environment
# uses, which sc_load_config re-applies on top of the file. `printf -v` sets a
# variable by name without eval.
# ---------------------------------------------------------------------------
sc_override() {
    printf -v "$1" '%s' "$2"
    printf -v "_SC_ENV_$1" '%s' "$2"
}

# ---------------------------------------------------------------------------
# sc_load_config: layers config sources in the right order
#
# Precedence, weakest to strongest:
#   1. the defaults above
#   2. config/retention.env  (committed as .example, real file is gitignored)
#   3. the process environment  (RETENTION_COUNT=5 ./showtime.sh 1.2.0)
#   4. command-line flags, via sc_override
#
# Getting that order right matters: a one-off override on the command line
# must beat the file, otherwise you cannot experiment without editing config.
# ---------------------------------------------------------------------------
sc_load_config() {
    local config_file="${SOUNDCHECK_ROOT}/config/retention.env"
    local key snap
    if [ -f "$config_file" ]; then
        # `set -a` marks everything assigned while it is active for export, so
        # values reach the `docker run -e` calls and any child process too.
        # shellcheck source=/dev/null
        set -a; . "$config_file"; set +a
    fi

    # Put the caller's environment back on top of whatever the file said.
    for key in $SC_CONFIG_KEYS; do
        snap="_SC_ENV_${key}"
        [ -n "${!snap+set}" ] && eval "${key}=\${${snap}}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Terminal channel
# ---------------------------------------------------------------------------
sc_say()  { [ "$LOG_FORMAT" = json ] || printf '%b\n' "$*"; }
sc_step() { sc_say "${C_BLUE}==>${C_RESET} $*"; }
sc_ok()   { sc_say "${C_GREEN}  OK${C_RESET} $*"; }
sc_warn() { sc_say "${C_YELLOW}  !!${C_RESET} $*" >&2; }
sc_err()  { sc_say "${C_RED} ERR${C_RESET} $*" >&2; }
sc_dim()  { sc_say "${C_DIM}     $*${C_RESET}"; }

# sc_die: complain and stop. Always writes a failure event first, so an
# aborted run is as visible in the history file as a successful one. A history
# that only records successes is worse than no history: it looks clean.
sc_die() {
    sc_err "$*"
    sc_event "aborted" "result=failure" "reason=$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Event channel
# ---------------------------------------------------------------------------

# sc_json_escape: minimal but correct JSON string escaping.
#
# Only backslash, double quote and control characters are legal problems in a
# JSON string. Order matters: backslash MUST be escaped first, otherwise the
# backslashes introduced while escaping quotes get escaped a second time.
sc_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

sc_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# sc_event <action> [key=value ...]
#
# Appends one JSON object to deploy_history.log, and. When LOG_FORMAT=json,
# prints the same object to stdout so a supervisor sees it live.
#
# Every event carries the same four fields (ts, action, tool, result) plus
# whatever key=value pairs the caller adds. Consistent field NAMES across
# every event are what make the file queryable; if showtime writes "version"
# and encore writes "target_version" you can no longer ask a single question
# about a release across both tools.
#
# `>>` on a single short line is atomic enough for this: POSIX guarantees
# writes under PIPE_BUF to a file opened O_APPEND will not interleave, and
# these lines are a few hundred bytes.
# ---------------------------------------------------------------------------
sc_event() {
    local action="$1"; shift
    local line pair key value
    line="{\"ts\":\"$(sc_now_iso)\",\"action\":\"$(sc_json_escape "$action")\""
    line="${line},\"tool\":\"$(sc_json_escape "${SC_TOOL:-unknown}")\""
    line="${line},\"mode\":\"$(sc_json_escape "${SC_MODE:-docker}")\""

    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        line="${line},\"$(sc_json_escape "$key")\":\"$(sc_json_escape "$value")\""
    done
    line="${line}}"

    mkdir -p "$(dirname "$HISTORY_FILE")"
    printf '%s\n' "$line" >>"$HISTORY_FILE"
    [ "$LOG_FORMAT" = json ] && printf '%s\n' "$line"
    return 0
}

# ---------------------------------------------------------------------------
# History reading
# ---------------------------------------------------------------------------

# sc_history_versions: versions of successful deploys, newest first, deduped.
#
# Parsing JSON with grep/sed is normally a bad idea. It is acceptable here for
# one specific reason: this script is the only writer of the file, the shape
# is fixed, and the alternative is making jq a hard dependency of a rollback
# tool: the one tool you want to work on a broken box at 3am with nothing
# installed. If jq IS available we use it, because it is correct; the grep
# path is the fallback, not the plan.
sc_history_versions() {
    [ -f "$HISTORY_FILE" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r 'select(.action=="deploy" and .result=="success") | .version' \
            "$HISTORY_FILE" 2>/dev/null | sc_reverse_lines | awk '!seen[$0]++'
    else
        grep '"action":"deploy"' "$HISTORY_FILE" \
            | grep '"result":"success"' \
            | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' \
            | sc_reverse_lines | awk '!seen[$0]++'
    fi
}

# sc_reverse_lines: newest first.
#
# `tac` would be the obvious tool and is one character long, but it is a GNU
# coreutils program: it does not exist on macOS, which ships `tail -r`
# instead. awk is POSIX and present on both. A rollback script that only works
# on Linux is a rollback script that does not work when you need it.
sc_reverse_lines() {
    awk '{ lines[NR] = $0 } END { for (i = NR; i > 0; i--) print lines[i] }'
}

# sc_history_tail: the last N lines, for showing a human what happened.
sc_history_tail() {
    local n="${1:-10}"
    [ -f "$HISTORY_FILE" ] || { echo "(no history yet)"; return 0; }
    tail -n "$n" "$HISTORY_FILE"
}

# ---------------------------------------------------------------------------
# sc_python: run a Python 3 that actually works
#
# `command -v python3` is not enough to know Python 3 exists, and this is not
# a hypothetical. Windows ships an "App Execution Alias" at
# AppData/Local/Microsoft/WindowsApps/python3 which is a stub advertising the
# Microsoft Store. It is on PATH, so `command -v` finds it, and running it
# prints an install advert TO STDOUT and exits 49.
#
# That combination is nastier than a plain missing command. A caller that
# redirects stderr and reads stdout, which is exactly what parsing a metric
# out of JSON looks like, gets the advert text back as its value. In
# soundcheck.sh that meant the success rate could be read as the string
# "Python was not found; ...", which awk evaluates as 0, which is below any
# threshold. A missing interpreter would have produced a false ALERT.
#
# So the probe runs the interpreter and checks what comes back, rather than
# trusting either PATH or the exit code alone. The result is cached because
# this is called per metric field.
# ---------------------------------------------------------------------------
sc_python() {
    if [ -z "${_SC_PYTHON+set}" ]; then
        local candidate
        _SC_PYTHON=""
        for candidate in python3 python; do
            command -v "$candidate" >/dev/null 2>&1 || continue
            if [ "$("$candidate" -c 'print("sc-ok")' 2>/dev/null)" = "sc-ok" ]; then
                _SC_PYTHON="$candidate"
                break
            fi
        done
    fi
    [ -n "$_SC_PYTHON" ] || return 127
    "$_SC_PYTHON" "$@"
}

sc_has_python() { sc_python -c 'pass' >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Small guards
# ---------------------------------------------------------------------------
sc_require() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 \
            || sc_die "required command not found: ${cmd}"
    done
}

# sc_ensure_network: create the shared Docker network if it is missing.
#
# WHY a user-defined network instead of the default bridge: containers on a
# user-defined network can resolve each other BY NAME through Docker's
# embedded DNS. That is what lets observability/prometheus.yml say
# `soundcheck-app:8080` instead of chasing a container IP that changes on
# every deploy. It is also what connects a container started by showtime.sh
# to a Prometheus started by docker compose: two separate lifecycles, one
# network.
sc_ensure_network() {
    docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 && return 0
    sc_dim "creating docker network ${DOCKER_NETWORK}"
    docker network create "$DOCKER_NETWORK" >/dev/null
}

# sc_http_ok: the health probe, and the reason this repo exists.
#
#   -s  silent: no progress meter polluting the output
#   -f  FAIL on HTTP >= 400. Without this, curl exits 0 for a 500 error page,
#       because from curl's point of view the transfer succeeded perfectly:
#       it asked for bytes and got bytes. "The server answered" and "the
#       server is healthy" are different questions, and only -f asks the
#       second one. This is the bug that was in the original monitor.sh.
#   --max-time  a hung server must fail the check, not hang the check.
sc_http_ok() {
    curl -sf --max-time 5 "$1" >/dev/null 2>&1
}

sc_http_body() {
    curl -sf --max-time 5 "$1" 2>/dev/null
}

# sc_wait_healthy <url>: retry loop around sc_http_ok.
#
# Retries exist because a container that has just started is not yet a server
# that has just started: Python has to boot, Flask has to bind. Failing on the
# first probe would make every deploy flaky. Retrying forever would make a
# genuinely broken deploy hang instead of failing. Hence a bounded count.
sc_wait_healthy() {
    local url="$1" i
    for (( i = 1; i <= HEALTH_RETRIES; i++ )); do
        if sc_http_ok "$url"; then
            sc_ok "healthy after ${i} attempt(s): ${url}"
            return 0
        fi
        sc_dim "attempt ${i}/${HEALTH_RETRIES} failed, retrying in ${HEALTH_INTERVAL}s"
        sleep "$HEALTH_INTERVAL"
    done
    return 1
}
