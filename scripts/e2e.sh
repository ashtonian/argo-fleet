#!/usr/bin/env bash
# Installs Argo CD with lovely/argocd-values.yaml and the fleet-bootstrap
# release with lovely/bootstrap-values.yaml into the current kubectl context,
# and checks the fleet comes up from REVISION (a full commit SHA) for one
# example identity (us-east, cluster-001). The argocd namespace enforces the
# restricted Pod Security Standard, so the install itself fails if any
# container, the plugin sidecar included, is not hardened.
#
# Usage: scripts/e2e.sh CMP_IMAGE REVISION
# It installs Argo CD, so it refuses any kubectl context not named kind-*.
# scripts/e2e-native.sh tests the native approach the same way.
set -Eeuo pipefail

repo=$(git rev-parse --show-toplevel)
# shellcheck source=scripts/e2e-lib.sh
source "$repo/scripts/e2e-lib.sh"
require_kind_context

image=${1:?usage: e2e.sh CMP_IMAGE REVISION}
revision=${2:?usage: e2e.sh CMP_IMAGE REVISION}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'dump; rm -rf "$work"' ERR

prepare_namespace
kubectl -n argocd create secret generic cluster-identity \
  --from-literal=GROUP=us-east --from-literal=CLUSTER_NAME=cluster-001

IMAGE=$image yq '.repoServer.extraContainers[0].image = strenv(IMAGE)' \
  "$repo/lovely/argocd-values.yaml" >"$work/values.yaml"
install_argocd "$work/values.yaml"
install_bootstrap "$repo/lovely/bootstrap-values.yaml" \
  --set "applications.fleet-bootstrap.source.targetRevision=$revision"

wait_app fleet-bootstrap
for app in base-ingress base-logging base-monitoring addon-gpu-operator; do
  wait_app "$app"
done

# us-east has no edge-cache addon, so nothing else may have been generated.
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator

group=$(kubectl -n monitoring get deployment monitoring -o jsonpath='{.metadata.labels.group}')
cluster=$(kubectl -n monitoring get deployment monitoring -o jsonpath='{.metadata.labels.cluster}')
[[ $group == us-east && $cluster == cluster-001 ]] ||
  { echo "monitoring labels: group=$group cluster=$cluster" >&2; exit 1; }
revision_used=$(kubectl -n argocd get application base-monitoring -o jsonpath='{.spec.source.targetRevision}')
[[ $revision_used == "$revision" ]] || { echo "base-monitoring targets $revision_used, want $revision" >&2; exit 1; }
echo "ok   identity and revision reached the workloads"

echo "e2e: ok"
