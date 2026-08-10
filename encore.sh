#!/usr/bin/env bash
#
# encore: bring back a previous good performance
# ===========================================================================
# WHAT:  Puts a known-good earlier version back on the live port. With no
#        argument it picks the most recent successful deploy that is not the
#        one currently running; with a version argument it goes to exactly
#        that version.
#
# Named "encore" because that is what this is: the audience asks for a
# performance you already know went well, and you play it again. Kubernetes
# happens to agree. Its term for the same operation is `rollout undo`, which
# replays a previous revision rather than building anything new.
#
# WHY IT READS A HISTORY FILE INSTEAD OF GRABBING A TAG
# The original version did `docker run sre-app:previous` and hoped. That has
# two failure modes it cannot even detect: `:previous` might point at the same
# broken build (if two bad deploys happened in a row), and there is no way to
# reach anything older than one step. Reading deploy_history.log means encore
# can SHOW you what is actually available and let you choose, which is the
# difference between a rollback tool and a coin flip.
#
# USAGE
#   ./encore.sh                 roll back one good version
#   ./encore.sh 1.2.0           roll back to a specific version
#   ./encore.sh --list          show what is available, change nothing
#   ./encore.sh --k8s           `kubectl rollout undo` instead
#   ./encore.sh --k8s --to-revision 3
#
# EXIT CODES
#   0  a previous version is live and healthy
#   1  usage error / nothing to roll back to
#   2  the rolled-back version is also unhealthy (this is now an incident)
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

SC_TOOL="encore"
SC_MODE="docker"

TARGET_VERSION=""
LIST_ONLY=0
TO_REVISION=""

usage() {
    cat <<'EOF'
encore: bring back a previous good performance

usage: ./encore.sh [version] [flags]

  (no args)              roll back one good version
  <version>              roll back to exactly that version
  --list                 show available rollback targets, change nothing
  --k8s                  use `kubectl rollout undo`
  --to-revision <n>      with --k8s, target a specific revision
  --json-log             emit JSON lines on the terminal too
  -h, --help             this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)         LIST_ONLY=1 ;;
        --k8s)          SC_MODE=k8s ;;
        --to-revision)
            # Guard the shift: `--to-revision` as the final argument would
            # otherwise shift past the end and, under `set -e`, exit with no
            # explanation at all.
            [ $# -ge 2 ] || { echo "--to-revision needs a revision number" >&2; exit 1; }
            shift; TO_REVISION="$1"
            ;;
        --json-log)     sc_override LOG_FORMAT json ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
        *)
            [ -z "$TARGET_VERSION" ] || { echo "unexpected argument: $1" >&2; exit 1; }
            TARGET_VERSION="$1"
            ;;
    esac
    shift
done

sc_load_config
export LOG_FORMAT SC_TOOL SC_MODE

HEALTH_URL="http://localhost:${APP_PORT}${HEALTH_PATH}"

# --- What is running right now? -------------------------------------------
# Read from the container's own environment rather than from the history file.
# History records what we INTENDED; the container records what IS. When those
# two disagree, the container is right, and a rollback tool that trusts the
# wrong one will happily "roll back" to the version already running.
current_version() {
    docker inspect --format \
        '{{range .Config.Env}}{{println .}}{{end}}' "$APP_NAME" 2>/dev/null \
        | sed -n 's/^APP_VERSION=//p' | head -n1 || true
}

show_targets() {
    local current versions=() v idx=0 mark avail
    current="$(current_version)"

    sc_say "${C_BLUE}Rollback targets${C_RESET} (most recent successful deploys first)"
    sc_say ""

    while IFS= read -r v; do
        [ -n "$v" ] && versions+=("$v")
    done < <(sc_history_versions)

    if [ "${#versions[@]}" -eq 0 ]; then
        sc_say "  (deploy_history.log has no successful deploys recorded)"
    else
        for v in "${versions[@]}"; do
            idx=$((idx + 1))
            mark="  "
            [ "$v" = "$current" ] && mark="* "
            if docker image inspect "${IMAGE_REPO}:${v}" >/dev/null 2>&1; then
                avail="${C_GREEN}image present${C_RESET}"
            else
                avail="${C_RED}image pruned: cannot roll back to this${C_RESET}"
            fi
            sc_say "  ${mark}${idx}. ${v}   ${avail}"
        done
        sc_say ""
        sc_say "  ${C_DIM}* = currently live. Retention keeps ${RETENTION_COUNT} versions.${C_RESET}"
    fi

    sc_say ""
    sc_say "${C_BLUE}Recent history${C_RESET}"
    sc_history_tail 8 | sed 's/^/  /'
}

# --- Pick a target ---------------------------------------------------------
resolve_target() {
    local current versions=() v
    current="$(current_version)"

    if [ -n "$TARGET_VERSION" ]; then
        # An explicit request is honoured as-is, including "roll back to what
        # is already running": that is a legitimate way to restart a wedged
        # container, and second-guessing the operator here would be wrong.
        echo "$TARGET_VERSION"
        return 0
    fi

    while IFS= read -r v; do
        [ -n "$v" ] && versions+=("$v")
    done < <(sc_history_versions)

    for v in "${versions[@]}"; do
        [ "$v" = "$current" ] && continue
        echo "$v"
        return 0
    done

    # No usable history. Fall back to the `:previous` tag showtime maintains,
    # the original mechanism, kept alive precisely for this case: a box where
    # the history file was lost but the images are still there.
    if docker image inspect "${IMAGE_REPO}:previous" >/dev/null 2>&1; then
        echo "previous"
        return 0
    fi
    return 1
}

rollback_docker() {
    sc_require docker curl
    sc_ensure_network

    local target
    if ! target="$(resolve_target)"; then
        sc_err "nothing to roll back to."
        sc_say ""
        show_targets
        exit 1
    fi

    if ! docker image inspect "${IMAGE_REPO}:${target}" >/dev/null 2>&1; then
        sc_err "image ${IMAGE_REPO}:${target} is not on this host (pruned by retention?)"
        sc_say ""
        show_targets
        sc_event "rollback" "target=${target}" "result=failure" "reason=image_missing"
        exit 1
    fi

    sc_event "rollback_started" "target=${target}" "from=$(current_version)"
    sc_step "1/3 rolling back to ${target}"

    sc_step "2/3 replacing the live container"
    docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --name "$APP_NAME" \
        --network "$DOCKER_NETWORK" \
        --network-alias "$APP_NAME" \
        -p "${APP_PORT}:8080" \
        -e APP_VERSION="$target" \
        --restart unless-stopped \
        "${IMAGE_REPO}:${target}" >/dev/null

    sc_step "3/3 verifying ${HEALTH_URL}"
    if sc_wait_healthy "$HEALTH_URL"; then
        sc_event "rollback" "target=${target}" "result=success"
        sc_ok "encore complete: ${target} is back on air"
        exit 0
    fi

    # A failed rollback is a different severity of problem from a failed
    # deploy: the escape hatch itself did not work. Say so plainly rather
    # than looping into another automatic attempt.
    sc_event "rollback" "target=${target}" "result=failure" "stage=health"
    sc_err "the rolled-back version is ALSO unhealthy."
    sc_err "this is no longer a bad deploy: look outside the app:"
    sc_say "     port ${APP_PORT} taken? database down? disk full? DNS?"
    sc_say "     docker logs --tail 50 ${APP_NAME}"
    exit 2
}

# ===========================================================================
# Kubernetes mode
# ===========================================================================
# `kubectl rollout undo` is the whole implementation, because the Deployment
# controller already keeps the old ReplicaSet around (revisionHistoryLimit)
# with its full Pod template. Everything encore.sh does by hand in Docker mode
#. Find a previous good version, recreate it, wait for it to be healthy. Is
# already a built-in of the object model here.
#
# The catch worth knowing: rollout history is stored in the CLUSTER, not in
# Git and not in deploy_history.log. Delete the Deployment and the revisions
# go with it. So the local history file is still written in this mode too.
# ===========================================================================
rollback_k8s() {
    sc_require kubectl

    if [ "$LIST_ONLY" = 1 ]; then
        sc_say "${C_BLUE}Kubernetes rollout history${C_RESET}"
        kubectl -n "$K8S_NAMESPACE" rollout history "deployment/${K8S_DEPLOYMENT}"
        exit 0
    fi

    local args=(-n "$K8S_NAMESPACE" rollout undo "deployment/${K8S_DEPLOYMENT}")
    [ -n "$TO_REVISION" ] && args+=(--to-revision="$TO_REVISION")

    sc_event "rollback_started" "target=${TO_REVISION:-previous-revision}"
    sc_step "1/2 kubectl rollout undo"
    kubectl "${args[@]}"

    sc_step "2/2 waiting for the restored revision to become ready"
    if kubectl -n "$K8S_NAMESPACE" rollout status \
            "deployment/${K8S_DEPLOYMENT}" --timeout=120s; then
        sc_event "rollback" "target=${TO_REVISION:-previous-revision}" "result=success"
        sc_ok "encore complete"
        exit 0
    fi
    sc_event "rollback" "target=${TO_REVISION:-previous-revision}" "result=failure"
    sc_die "the restored revision is also not becoming ready"
}

# --- Go --------------------------------------------------------------------
if [ "$SC_MODE" = k8s ]; then
    rollback_k8s
fi

if [ "$LIST_ONLY" = 1 ]; then
    show_targets
    exit 0
fi

rollback_docker
