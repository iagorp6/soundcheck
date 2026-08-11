#!/usr/bin/env bash
#
# showtime: put a version on air
# ===========================================================================
# WHAT:  Builds an image for a given version and makes it the one serving
#        real traffic on ${APP_PORT}, verifying it is healthy before and after
#        the cutover, keeping the last N versions available for encore.sh, and
#        writing one structured event per step to deploy_history.log.
#
# Named "showtime" because going live is the show starting. It is the deploy
# script; everything below is about making "deploy" mean "deploy AND it works",
# not "deploy and hope".
#
# TWO MODES, ONE DISCIPLINE
#   default   hand-rolled blue-green with Docker. Every step is visible.
#   --k8s     the same job handed to Kubernetes. `kubectl rollout status`
#             replaces the retry loop; the orchestrator owns the waiting.
#   The point of having both is to show what the orchestrator is doing for
#   you, having first done it by hand.
#
# USAGE
#   ./showtime.sh <version> [flags]
#
#   --auto-rollback   on a failed post-cutover health check, call encore.sh
#                     automatically instead of printing instructions
#   --json-log        make the terminal channel emit JSON lines too
#   --k8s             Kubernetes mode (Kind cluster, imperative kubectl)
#   --no-blue-green   old stop-then-start behaviour, for comparison
#   -h, --help
#
# EXIT CODES
#   0  the requested version is live and healthy
#   1  usage error / missing dependency
#   2  the new version never became healthy (previous version untouched)
#   3  cutover happened but the live port is unhealthy (rollback territory)
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

SC_TOOL="showtime"
SC_MODE="docker"

VERSION=""
AUTO_ROLLBACK=0
BLUE_GREEN=1

usage() {
    cat <<'EOF'
showtime: put a version on air

usage: ./showtime.sh <version> [flags]

  --auto-rollback   on a failed post-cutover health check, call encore.sh
                    automatically instead of printing instructions
  --json-log        make the terminal channel emit JSON lines too
  --k8s             Kubernetes mode (Kind cluster, imperative kubectl)
  --no-blue-green   old stop-then-start behaviour, for comparison
  -h, --help        this text

exit codes: 0 live and healthy · 1 usage · 2 candidate never healthy
            (previous version untouched) · 3 cut over but unhealthy
EOF
}

# --- Argument parsing ------------------------------------------------------
# Flags are parsed before config is loaded so that --json-log can influence
# LOG_FORMAT, and after nothing else, so an unknown flag fails fast rather
# than half-deploying.
while [ $# -gt 0 ]; do
    case "$1" in
        --auto-rollback) AUTO_ROLLBACK=1 ;;
        --json-log)      sc_override LOG_FORMAT json ;;
        --k8s)           SC_MODE=k8s ;;
        --no-blue-green) BLUE_GREEN=0 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
        *)
            [ -z "$VERSION" ] || { echo "unexpected argument: $1" >&2; exit 1; }
            VERSION="$1"
            ;;
    esac
    shift
done

[ -n "$VERSION" ] || { echo "usage: ./showtime.sh <version> [flags]" >&2; exit 1; }

sc_load_config
export LOG_FORMAT SC_TOOL SC_MODE

HEALTH_URL="http://localhost:${APP_PORT}${HEALTH_PATH}"
CANDIDATE_URL="http://localhost:${CANDIDATE_PORT}${HEALTH_PATH}"

# ===========================================================================
# Retention
# ===========================================================================
# WHY retention is a real requirement and not busywork:
#
# The original exercise kept exactly one previous image (`:previous`). That
# answers "the deploy I just did is bad, undo it" and nothing else. The
# question it cannot answer is the one that actually happens in incidents:
# "the last TWO deploys were both bad, get me back to Friday's build."
#
# So: every version keeps its own immutable tag (soundcheck-app:1.2.0), and we
# delete the oldest ones once there are more than RETENTION_COUNT. Cleanup is
# necessary because images are not free: without it a busy week fills a disk,
# and a disk-full box is a worse outage than the one you were rolling back.
#
# RETENTION_COUNT includes the version running right now, so the default of 3
# keeps the live one plus two older ones: two steps of rollback, not three.
#
# We prune by walking deploy_history.log rather than by image creation time,
# because history order is DEPLOY order. An image built weeks ago and
# redeployed yesterday is recent in the only sense that matters here.
#
# SCOPE, and this is a real limitation rather than a detail: this prunes the
# LOCAL Docker image store. In --k8s mode the images the cluster actually runs
# live in the Kind node's own store, put there by `kind load docker-image`, and
# nothing here removes them. Rollback depth in Kubernetes is governed by
# `revisionHistoryLimit` in k8s/deployment.yaml instead, which is set to 5.
# Two different mechanisms with two different numbers; pretending one config
# key controlled both would be tidier and untrue.
# ===========================================================================
prune_old_versions() {
    local keep="$RETENTION_COUNT" versions=() v idx=0 in_use
    while IFS= read -r v; do
        [ -n "$v" ] && versions+=("$v")
    done < <(sc_history_versions)

    [ "${#versions[@]}" -gt "$keep" ] || { sc_dim "retention: ${#versions[@]}/${keep} versions kept, nothing to prune"; return 0; }

    # Every image any container references, running or stopped.
    #
    # Checking only "is this the version I am deploying" is not enough, and
    # this bit me for real: deploying repeatedly in --k8s mode pruned the
    # image that the Docker-mode container was still running on. The container
    # survives, because Docker pins it by image ID, but the TAG disappears,
    # and the next Docker-mode deploy then fell over trying to tag an image
    # name that no longer resolved.
    #
    # Retention is allowed to delete old images. It is not allowed to delete
    # one that something is currently using.
    in_use="$(docker ps -a --format '{{.Image}}' 2>/dev/null || true)"

    for v in "${versions[@]}"; do
        idx=$((idx + 1))
        [ "$idx" -le "$keep" ] && continue
        # Never delete what is being deployed right now, whatever history says.
        [ "$v" = "$VERSION" ] && continue
        if printf '%s\n' "$in_use" | grep -qxF "${IMAGE_REPO}:${v}"; then
            sc_dim "retention: keeping ${IMAGE_REPO}:${v}, a container still references it"
            continue
        fi
        if docker image inspect "${IMAGE_REPO}:${v}" >/dev/null 2>&1; then
            sc_dim "retention: removing ${IMAGE_REPO}:${v}"
            docker image rm "${IMAGE_REPO}:${v}" >/dev/null 2>&1 \
                || sc_warn "could not remove ${IMAGE_REPO}:${v} (still in use?)"
            sc_event "retention_prune" "version=${v}" "result=success"
        fi
    done
}

# ===========================================================================
# Docker mode
# ===========================================================================
deploy_docker() {
    sc_require docker curl
    sc_ensure_network

    local strategy=recreate
    [ "$BLUE_GREEN" = 1 ] && strategy=blue-green
    sc_event "deploy_started" "version=${VERSION}" "strategy=${strategy}" \
        "auto_rollback=${AUTO_ROLLBACK}"

    # --- 1. Build ----------------------------------------------------------
    sc_step "1/6 building ${IMAGE_REPO}:${VERSION}"
    if ! docker build -t "${IMAGE_REPO}:${VERSION}" "${SOUNDCHECK_ROOT}/app"; then
        sc_event "deploy" "version=${VERSION}" "result=failure" "stage=build"
        sc_die "build failed; nothing was touched"
    fi
    sc_ok "image built"

    # --- 2. Remember what is live now --------------------------------------
    # Captured BEFORE anything is stopped. If the box dies mid-deploy, the
    # `:previous` tag and the history line are already correct.
    sc_step "2/6 recording the currently live version"
    local old_image=""
    old_image="$(docker inspect --format='{{.Config.Image}}' "$APP_NAME" 2>/dev/null || true)"
    if [ -n "$old_image" ]; then
        sc_ok "currently live: ${old_image}"
        # A running container can outlive the tag it was started from: the
        # image is pinned by ID inside Docker, but the NAME can be deleted,
        # and retention in the other mode is perfectly capable of deleting it.
        # `docker tag` then fails with a bare daemon error, and under `set -e`
        # that killed the whole deploy at step 2 over a bookkeeping alias.
        #
        # Losing the :previous shortcut is not a reason to refuse to deploy.
        # encore.sh reads deploy_history.log first and only falls back to that
        # tag, so the rollback path survives this.
        if docker image inspect "$old_image" >/dev/null 2>&1; then
            docker tag "$old_image" "${IMAGE_REPO}:previous"
        else
            sc_warn "live container references ${old_image}, which is no longer on this host"
            sc_dim "leaving the :previous alias alone; encore.sh uses the history file"
        fi
    else
        sc_dim "nothing live yet: treating this as a first deploy"
    fi

    if [ "$BLUE_GREEN" = 1 ]; then
        deploy_blue_green
    else
        deploy_recreate
    fi
}

# --- Blue-green ------------------------------------------------------------
# WHAT: start the new version on a spare port ALONGSIDE the running one, prove
#       it is healthy there, and only then take the old one out of the way.
#
# WHY it beats stop-then-start: with stop-then-start, the moment you discover
#       the new version is broken is the moment you already have no working
#       version running. The outage starts before the information arrives.
#       Here, a broken candidate is found while the old version is still
#       serving every request, so the failure costs nothing but a build.
#
# THE HONEST TRADEOFFS:
#   - For a window of a few seconds both versions are running, so the box
#     needs headroom for two copies. On a memory-tight host that is a real
#     constraint, not a footnote.
#   - If both versions write to the same database, both are writing during
#     that window. This app is stateless, so it does not apply here. But it
#     is the thing that makes blue-green hard in real systems, and pretending
#     otherwise would be the wrong lesson.
#   - Docker cannot re-map a running container's published port. So the
#     cutover is: verify candidate on 8081, remove it, start the SAME IMAGE
#     as a fresh container on 8080. The verification still did its job: it
#     proved the image boots and answers, but be clear-eyed that this is
#     "verified image, new container", not a zero-downtime port handover.
#     Doing that properly needs a reverse proxy in front, which is a load
#     balancer, which is ensemble's problem, not this repo's.
deploy_blue_green() {
    sc_step "3/6 starting candidate on port ${CANDIDATE_PORT} (old version still serving)"
    docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --name "$CANDIDATE_NAME" \
        --network "$DOCKER_NETWORK" \
        -p "${CANDIDATE_PORT}:8080" \
        -e APP_VERSION="$VERSION" \
        "${IMAGE_REPO}:${VERSION}" >/dev/null
    sc_ok "candidate up"

    sc_step "4/6 verifying candidate at ${CANDIDATE_URL}"
    if ! sc_wait_healthy "$CANDIDATE_URL"; then
        docker logs --tail 20 "$CANDIDATE_NAME" 2>&1 | sed 's/^/     | /' || true
        docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
        sc_event "deploy" "version=${VERSION}" "result=failure" "stage=candidate_health"
        sc_err "candidate never became healthy: removed it"
        sc_ok "the previous version is STILL LIVE on port ${APP_PORT}; no rollback needed"
        exit 2
    fi

    sc_step "5/6 cutting over to port ${APP_PORT}"
    docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
    docker rm -f "$APP_NAME"       >/dev/null 2>&1 || true
    docker run -d \
        --name "$APP_NAME" \
        --network "$DOCKER_NETWORK" \
        --network-alias "$APP_NAME" \
        -p "${APP_PORT}:8080" \
        -e APP_VERSION="$VERSION" \
        --restart unless-stopped \
        "${IMAGE_REPO}:${VERSION}" >/dev/null

    finish_docker
}

# --- Recreate --------------------------------------------------------------
# The original strategy, kept behind --no-blue-green so the difference can be
# demonstrated rather than just described. Watch the health check fail here
# with nothing serving, then watch it fail in blue-green mode with the old
# version still up. That contrast is the argument.
deploy_recreate() {
    sc_step "3/6 stopping the live container (downtime starts here)"
    docker rm -f "$APP_NAME" >/dev/null 2>&1 || true

    sc_step "4/6 starting ${VERSION} directly on port ${APP_PORT}"
    docker run -d \
        --name "$APP_NAME" \
        --network "$DOCKER_NETWORK" \
        --network-alias "$APP_NAME" \
        -p "${APP_PORT}:8080" \
        -e APP_VERSION="$VERSION" \
        --restart unless-stopped \
        "${IMAGE_REPO}:${VERSION}" >/dev/null

    sc_step "5/6 (no candidate stage in recreate mode)"
    finish_docker
}

# --- Post-cutover verification + the rollback decision ---------------------
finish_docker() {
    sc_step "6/6 verifying live traffic port ${HEALTH_URL}"
    if sc_wait_healthy "$HEALTH_URL"; then
        sc_event "deploy" "version=${VERSION}" "result=success" "port=${APP_PORT}"
        prune_old_versions
        sc_ok "version ${VERSION} is on air at http://localhost:${APP_PORT}"
        exit 0
    fi

    sc_event "deploy" "version=${VERSION}" "result=failure" "stage=post_cutover_health"
    sc_err "version ${VERSION} is live but NOT healthy"
    handle_failure
}

# ===========================================================================
# The automatic-vs-manual rollback decision
# ===========================================================================
# This is deliberately a FLAG and not a default, because both answers are
# defensible and the right one depends on the situation:
#
#   AUTOMATIC (--auto-rollback) recovers in seconds with nobody awake. That is
#   the right call for a well-understood service where the cost of being down
#   is high. The danger is that it is also very good at hiding a problem: a
#   deploy that fails, auto-reverts, and reports success looks like nothing
#   happened. Run that in a loop and you get a service that is quietly
#   permanently stuck on an old version while the pipeline claims to be green.
#   Automatic rollback must therefore always be LOUD. Hence the event line.
#
#   MANUAL keeps a human in the loop for the judgement call. Sometimes rolling
#   back is wrong: if the new version is failing because of a schema migration
#   that already ran, or a dependency that is itself down, reverting makes it
#   worse. A person can tell those apart; a health check cannot.
#
# The genuinely bad option is having no opinion: failing and leaving the
# operator to work out on their own what state the system is in.
# ===========================================================================
handle_failure() {
    if [ "$AUTO_ROLLBACK" = 1 ]; then
        sc_warn "--auto-rollback set: calling encore.sh"
        sc_event "auto_rollback_triggered" "failed_version=${VERSION}"
        local passthru=()
        [ "$LOG_FORMAT" = json ] && passthru+=(--json-log)
        exec "${SOUNDCHECK_ROOT}/encore.sh" "${passthru[@]+"${passthru[@]}"}"
    fi

    sc_err "manual mode: the system is left exactly as it is, on purpose."
    sc_say ""
    sc_say "  Inspect first:   docker logs --tail 50 ${APP_NAME}"
    sc_say "  Then roll back:  ./encore.sh              # previous good version"
    sc_say "                   ./encore.sh <version>    # a specific one"
    sc_say "  Available:       ./encore.sh --list"
    sc_say ""
    sc_say "  Next time, to have this happen automatically:"
    sc_say "                   ./showtime.sh ${VERSION} --auto-rollback"
    exit 3
}

# ===========================================================================
# Kubernetes mode
# ===========================================================================
# The same three beats. Apply, wait for healthy, decide. Expressed in the
# orchestrator's own vocabulary.
#
# The thing to notice: the curl retry loop DISAPPEARS. `kubectl rollout status`
# blocks until the new ReplicaSet reports Ready, and "Ready" means the
# readinessProbe in deployment.yaml passed. That is the identical check, moved
# from my shell script into the control loop that owns the Pods. Kubernetes
# also gives blue-green for free here: a RollingUpdate with maxUnavailable=0
# will not remove an old Pod until a new one is Ready, which is exactly what
# the candidate-on-8081 dance was emulating by hand.
# ===========================================================================
deploy_k8s() {
    sc_require kubectl docker
    # `kind` is only needed when the target really is a Kind cluster, so it is
    # checked where that is known rather than demanded up front.
    if kubectl config current-context 2>/dev/null | grep -q '^kind-'; then
        sc_require kind
    fi
    sc_event "deploy_started" "version=${VERSION}" "strategy=rolling-update" \
        "auto_rollback=${AUTO_ROLLBACK}"

    sc_step "1/5 building ${IMAGE_REPO}:${VERSION}"
    docker build -t "${IMAGE_REPO}:${VERSION}" "${SOUNDCHECK_ROOT}/app"

    # Kind runs its nodes as containers with their own image store, so a local
    # image is invisible to the cluster until it is loaded in. This is the
    # single most common "ImagePullBackOff on a local image" cause, and the
    # reason this step exists instead of a registry push.
    if kubectl config current-context 2>/dev/null | grep -q '^kind-'; then
        sc_step "2/5 loading image into the Kind node"
        kind load docker-image "${IMAGE_REPO}:${VERSION}" \
            --name "${K8S_CONTEXT#kind-}"
    else
        sc_dim "2/5 not a Kind context: assuming the image is pullable"
    fi

    sc_step "3/5 applying manifests"
    kubectl apply -f "${SOUNDCHECK_ROOT}/k8s/namespace.yaml"
    kubectl -n "$K8S_NAMESPACE" apply -f "${SOUNDCHECK_ROOT}/k8s/configmap.yaml"
    kubectl -n "$K8S_NAMESPACE" apply -f "${SOUNDCHECK_ROOT}/k8s/service.yaml"

    # -----------------------------------------------------------------------
    # The Deployment is applied with the version substituted in, rather than
    # applied verbatim and then corrected with `kubectl set image`.
    #
    # The obvious ordering, apply-then-set-image, is wrong, and it fails in a
    # way that still reports success. deployment.yaml carries a placeholder
    # tag, so `apply` first reconciles the Deployment TO that placeholder:
    # Kubernetes creates a ReplicaSet for an image that does not exist, the
    # pods go ErrImagePull, and only then does `set image` create a second
    # ReplicaSet with the real tag. The rollout succeeds, so nothing complains.
    #
    # Two things break quietly as a result. Every deploy burns two revisions,
    # so revisionHistoryLimit: 5 buys two rollbacks rather than five, which is
    # exactly the depth this repo added retention to guarantee. And every
    # deploy emits genuine ImagePullBackOff events, which is precisely the
    # noise that trains you to ignore a real pull failure.
    #
    # sed rather than a templating tool: it is one field, and adding
    # Kustomize or Helm here would import a dependency to solve a problem
    # that is one substitution wide. `kubectl apply -f -` reads the rendered
    # manifest from stdin, so nothing is written to disk.
    # -----------------------------------------------------------------------
    # Two substitutions, one pass: the image tag and APP_VERSION. They have to
    # move together, because APP_VERSION is what the app reports in
    # soundcheck_app_info, and a deploy where the image says 1.2.0 while the
    # metric says something else is worse than either being wrong alone.
    sc_step "4/5 applying the Deployment at ${IMAGE_REPO}:${VERSION}"
    sed -e "s|image: ${IMAGE_REPO}:latest|image: ${IMAGE_REPO}:${VERSION}|" \
        -e "s|value: \"0.0.0-dev\"|value: \"${VERSION}\"|" \
        "${SOUNDCHECK_ROOT}/k8s/deployment.yaml" \
        | kubectl -n "$K8S_NAMESPACE" apply -f -

    # Recording the change-cause makes `kubectl rollout history` readable
    # instead of a column of <none>, which is what encore.sh --k8s reads.
    kubectl -n "$K8S_NAMESPACE" annotate "deployment/${K8S_DEPLOYMENT}" \
        kubernetes.io/change-cause="showtime.sh ${VERSION}" --overwrite >/dev/null

    sc_step "5/5 waiting for the rollout (readinessProbe is the health check now)"
    if kubectl -n "$K8S_NAMESPACE" rollout status \
            "deployment/${K8S_DEPLOYMENT}" --timeout=120s; then
        sc_event "deploy" "version=${VERSION}" "result=success" "namespace=${K8S_NAMESPACE}"
        prune_old_versions
        sc_ok "version ${VERSION} rolled out"
        sc_dim "reach it with: kubectl -n ${K8S_NAMESPACE} port-forward svc/${K8S_DEPLOYMENT} ${APP_PORT}:80"
        exit 0
    fi

    sc_event "deploy" "version=${VERSION}" "result=failure" "stage=rollout_status"
    sc_err "rollout did not become ready in time"
    if [ "$AUTO_ROLLBACK" = 1 ]; then
        sc_warn "--auto-rollback set: calling encore.sh --k8s"
        sc_event "auto_rollback_triggered" "failed_version=${VERSION}"
        exec "${SOUNDCHECK_ROOT}/encore.sh" --k8s
    fi
    sc_say ""
    sc_say "  Inspect:    kubectl -n ${K8S_NAMESPACE} describe deploy/${K8S_DEPLOYMENT}"
    sc_say "  Roll back:  ./encore.sh --k8s"
    exit 3
}

# --- Go --------------------------------------------------------------------
if [ "$SC_MODE" = k8s ]; then
    deploy_k8s
else
    deploy_docker
fi
