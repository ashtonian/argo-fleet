#!/usr/bin/env bash
# Installs Argo CD with lovely/argocd-values.yaml into the current kubectl
# context and checks the fleet comes up from REVISION for one example
# identity (us-east, cluster-001). The argocd namespace enforces the
# restricted Pod Security Standard, so the install itself fails if any
# container, the plugin sidecar included, is not hardened.
#
# Usage: scripts/e2e.sh CMP_IMAGE REVISION
# It installs Argo CD, so it refuses any kubectl context not named kind-*.
set -Eeuo pipefail

context=$(kubectl config current-context)
if [[ $context != kind-* ]]; then
  echo "refusing to install into context '$context': e2e.sh only runs against a kind cluster" >&2
  exit 1
fi

image=${1:?usage: e2e.sh CMP_IMAGE REVISION}
revision=${2:?usage: e2e.sh CMP_IMAGE REVISION}
chart_version=${ARGO_CD_CHART_VERSION:-10.10.2}
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

dump() {
  echo "::group::diagnostics"
  kubectl get applications,applicationsets -n argocd -o yaml || true
  kubectl get pods -A -o wide || true
  kubectl logs -n argocd -l app.kubernetes.io/component=repo-server -c lovely-charmap --tail=200 || true
  kubectl logs -n argocd -l app.kubernetes.io/component=applicationset-controller --tail=100 || true
  echo "::endgroup::"
}
trap 'dump; rm -rf "$work"' ERR

kubectl create namespace argocd
kubectl label namespace argocd pod-security.kubernetes.io/enforce=restricted
kubectl -n argocd create secret generic cluster-identity \
  --from-literal=group=us-east --from-literal=cluster-name=cluster-001

IMAGE=$image yq '.repoServer.extraContainers[0].image = strenv(IMAGE)' \
  "$repo/lovely/argocd-values.yaml" >"$work/values.yaml"
helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "$chart_version" \
  --namespace argocd --values "$work/values.yaml" --set "fleet.revision=$revision" \
  --wait --timeout 10m

# wait_app NAME: waits for an Application to exist, then to be synced and healthy.
wait_app() {
  local name=$1
  for _ in $(seq 60); do
    kubectl -n argocd get application "$name" >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl -n argocd wait application "$name" --for=jsonpath='{.status.sync.status}'=Synced --timeout=5m
  kubectl -n argocd wait application "$name" --for=jsonpath='{.status.health.status}'=Healthy --timeout=5m
  echo "ok   $name synced and healthy"
}

wait_app fleet-bootstrap
for app in base-ingress base-logging base-monitoring addon-gpu-operator; do
  wait_app "$app"
done

# us-east has no edge-cache addon, so nothing else may have been generated.
apps=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | tr '\n' ' ')
[[ $apps == "addon-gpu-operator base-ingress base-logging base-monitoring fleet-bootstrap " ]] ||
  { echo "unexpected Applications: $apps" >&2; exit 1; }

group=$(kubectl -n monitoring get deployment monitoring -o jsonpath='{.metadata.labels.group}')
cluster=$(kubectl -n monitoring get deployment monitoring -o jsonpath='{.metadata.labels.cluster}')
[[ $group == us-east && $cluster == cluster-001 ]] ||
  { echo "monitoring labels: group=$group cluster=$cluster" >&2; exit 1; }
revision_used=$(kubectl -n argocd get application base-monitoring -o jsonpath='{.spec.source.targetRevision}')
[[ $revision_used == "$revision" ]] || { echo "base-monitoring targets $revision_used, want $revision" >&2; exit 1; }
echo "ok   identity and revision reached the workloads"

echo "e2e: ok"
