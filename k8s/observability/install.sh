#!/usr/bin/env bash
#
# install.sh: the Kubernetes-mode observability stack
# ===========================================================================
# Installs Prometheus, Alertmanager, Grafana, Loki and Promtail into a Kind
# cluster via Helm, and (the part that matters) loads THE SAME dashboard and
# THE SAME alert rules the Docker Compose stack uses, rather than a second
# hand-maintained copy.
#
# HOW THE REUSE WORKS, since "reuse the config" is easy to claim and easy to
# fake:
#
#   Dashboard.  observability/grafana/dashboards/soundcheck.json is wrapped in
#     a ConfigMap labelled grafana_dashboard=1. Grafana's sidecar watches for
#     that label and loads whatever it finds. One JSON file, two stacks.
#
#   Alert rules.  observability/prometheus/alert_rules.yml is a top-level
#     `groups:` list, and a PrometheusRule's `spec` is ALSO a top-level
#     `groups:` list. So the conversion is a two-space indent under a CRD
#     header: no rewriting, no parser, no second copy to keep in sync. That
#     is not a coincidence; the CRD was designed to wrap the native format.
#
# USAGE
#   ./k8s/observability/install.sh            install or upgrade
#   ./k8s/observability/install.sh --uninstall
# ===========================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
NS_OBS="observability"
NS_APP="soundcheck"

DASHBOARD_JSON="${REPO_ROOT}/observability/grafana/dashboards/soundcheck.json"
ALERT_RULES="${REPO_ROOT}/observability/prometheus/alert_rules.yml"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

command -v helm    >/dev/null 2>&1 || die "helm is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

if [ "${1:-}" = "--uninstall" ]; then
    step "removing releases"
    helm uninstall soundcheck-obs -n "$NS_OBS" 2>/dev/null || true
    helm uninstall loki           -n "$NS_OBS" 2>/dev/null || true
    helm uninstall promtail       -n "$NS_OBS" 2>/dev/null || true
    kubectl delete namespace "$NS_OBS" --ignore-not-found
    echo "done."
    exit 0
fi

step "checking the cluster is reachable"
kubectl cluster-info >/dev/null || die "no reachable cluster. Create one with: kind create cluster --config k8s/kind-cluster.yaml"
echo "context: $(kubectl config current-context)"

step "adding Helm repositories"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null

kubectl create namespace "$NS_OBS" --dry-run=client -o yaml | kubectl apply -f -

# --- Prometheus + Alertmanager + Grafana -----------------------------------
step "installing kube-prometheus-stack (this pulls a lot of images the first time)"
helm upgrade --install soundcheck-obs prometheus-community/kube-prometheus-stack \
    --namespace "$NS_OBS" \
    --values "${HERE}/values-kube-prometheus-stack.yaml" \
    --wait --timeout 10m

# --- Loki + Promtail -------------------------------------------------------
step "installing Loki"
helm upgrade --install loki grafana/loki \
    --namespace "$NS_OBS" \
    --values "${HERE}/values-loki.yaml" \
    --wait --timeout 10m

step "installing Promtail"
helm upgrade --install promtail grafana/promtail \
    --namespace "$NS_OBS" \
    --values "${HERE}/values-promtail.yaml" \
    --wait --timeout 5m

# --- The shared dashboard --------------------------------------------------
step "loading the shared dashboard from ${DASHBOARD_JSON#"$REPO_ROOT"/}"
[ -f "$DASHBOARD_JSON" ] || die "dashboard file not found: ${DASHBOARD_JSON}"
kubectl create configmap grafana-dashboard-soundcheck \
    --namespace "$NS_OBS" \
    --from-file="soundcheck.json=${DASHBOARD_JSON}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl apply -f -

# --- The shared alert rules ------------------------------------------------
step "loading the shared alert rules from ${ALERT_RULES#"$REPO_ROOT"/}"
[ -f "$ALERT_RULES" ] || die "alert rules file not found: ${ALERT_RULES}"
{
    cat <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: soundcheck-rules
  namespace: ${NS_OBS}
  labels:
    app.kubernetes.io/part-of: soundcheck
spec:
EOF
    # Indent the native rules file by two spaces so it sits under `spec:`.
    # sed rather than a YAML library on purpose: this is a pure indent, and
    # round-tripping through a parser would reformat the comments away.
    sed 's/^/  /' "$ALERT_RULES"
} | kubectl apply -f -

# --- Done ------------------------------------------------------------------
cat <<EOF

Installed. Reach the UIs with port-forwards (nothing is exposed by default):

  Grafana       kubectl -n ${NS_OBS} port-forward svc/soundcheck-obs-grafana 3000:80
                http://localhost:3000  (admin / admin)
  Prometheus    kubectl -n ${NS_OBS} port-forward svc/soundcheck-obs-kube-prom-prometheus 9090:9090
  Alertmanager  kubectl -n ${NS_OBS} port-forward svc/soundcheck-obs-kube-prom-alertmanager 9093:9093
  The app       kubectl -n ${NS_APP} port-forward svc/soundcheck 8080:80

Then deploy something to look at:

  ./showtime.sh 1.0.0 --k8s
  ./soundcheck.sh --k8s
EOF
