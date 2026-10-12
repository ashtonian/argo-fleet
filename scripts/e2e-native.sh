#!/usr/bin/env bash
# Installs Argo CD with native/argocd-values.yaml and the fleet-bootstrap
# release with native/bootstrap-values.yaml into the current kubectl context,
# registers the cluster with the example identity
# (native/identity/cluster-secret.example.yaml: us-east, cluster-001), and
# checks the native fleet comes up from REVISION (a full commit SHA). It then
# checks the properties the native approach is chosen for:
#   - a changed value reaches the running workloads with no restart;
#   - an addon added to the cluster's annotation is created;
#   - a missing value fails only the application that needs it;
#   - an incomplete identity stops generation and changes nothing.
#
# Usage: scripts/e2e-native.sh REVISION
# It installs Argo CD, so it refuses any kubectl context not named kind-*.
set -Eeuo pipefail

repo=$(git rev-parse --show-toplevel)
# shellcheck source=scripts/e2e-lib.sh
source "$repo/scripts/e2e-lib.sh"
require_kind_context

revision=${1:?usage: e2e-native.sh REVISION}
trap dump ERR

prepare_namespace
install_argocd "$repo/native/argocd-values.yaml"
REVISION=$revision yq '.metadata.annotations."fleet.ashtonian.dev/revision" = strenv(REVISION)' \
  "$repo/native/identity/cluster-secret.example.yaml" | kubectl apply -f -
install_bootstrap "$repo/native/bootstrap-values.yaml"

wait_app fleet-bootstrap
for app in base-ingress base-logging base-monitoring addon-gpu-operator; do
  wait_app "$app"
done
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator

# fail MESSAGE
fail() {
  echo "$1" >&2
  exit 1
}
# monitoring JSONPATH: a field of the monitoring Deployment.
monitoring() {
  kubectl -n monitoring get deployment monitoring -o jsonpath="$1"
}
# identity_configmap: the fleet-identity ConfigMap monitoring's pods use.
identity_configmap() {
  monitoring '{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}'
}
# identity KEY: a key of that ConfigMap.
identity() {
  kubectl -n monitoring get configmap "$(identity_configmap)" -o jsonpath="{.data.$1}"
}
# pod_region: FLEET_REGION in a running monitoring pod.
pod_region() {
  kubectl -n monitoring exec deployment/monitoring -- printenv FLEET_REGION
}
# hostname: the ingress Service's hostname, which a replacement fills with REGION.
hostname() {
  kubectl -n ingress get service ingress -o jsonpath='{.metadata.annotations.external-dns\.alpha\.kubernetes\.io/hostname}'
}

# Identity labels on the Deployment and its pods, selector untouched.
[[ $(monitoring '{.metadata.labels.fleet\.ashtonian\.dev/group}') == us-east ]] ||
  fail "monitoring is not labelled with group us-east"
[[ $(monitoring '{.spec.template.metadata.labels.fleet\.ashtonian\.dev/cluster}') == cluster-001 ]] ||
  fail "monitoring's pods are not labelled with cluster cluster-001"
[[ $(monitoring '{.spec.selector.matchLabels}') == '{"app":"monitoring"}' ]] ||
  fail "monitoring's selector changed: $(monitoring '{.spec.selector.matchLabels}')"
echo "ok   identity labels on Deployments and pods; selectors unchanged"

# The us-east Component's structural override.
[[ $(monitoring '{.spec.replicas}') == 2 ]] || fail "the us-east Component did not set 2 replicas"
echo "ok   group Component applied (us-east: 2 replicas)"

# The identity and values, in fleet-identity, the pods' environment and a field.
[[ $(identity GROUP) == us-east && $(identity CLUSTER_NAME) == cluster-001 && $(identity REGION) == us-east-1 ]] ||
  fail "fleet-identity holds GROUP='$(identity GROUP)' CLUSTER_NAME='$(identity CLUSTER_NAME)' REGION='$(identity REGION)'"
[[ $(pod_region) == us-east-1 ]] || fail "FLEET_REGION in the monitoring pod is '$(pod_region)', want us-east-1"
[[ $(hostname) == ingress.us-east-1.example.com ]] || fail "the ingress hostname is '$(hostname)'"
echo "ok   identity and values in fleet-identity, the pods' environment and the ingress hostname"

[[ $(kubectl -n argocd get application base-monitoring -o jsonpath='{.spec.source.targetRevision}') == "$revision" ]] ||
  fail "base-monitoring does not target $revision"
echo "ok   Applications pinned to the cluster's revision"

# A changed value reaches the running workloads with no repo-server restart
# or hard refresh: fleet-identity's name changes with its content, which
# rolls the pods that use it. A value that looks like YAML or a patch
# operation must arrive as plain data.
repo_server_pods() {
  kubectl -n argocd get pods -l app.kubernetes.io/component=repo-server -o jsonpath='{.items[*].metadata.uid}'
}
pods_before=$(repo_server_pods)
configmap_before=$(identity_configmap)
note=$'a: "b" # c\n- op: remove\n  path: /data'
kubectl -n argocd annotate secret fleet-local --overwrite \
  values.fleet.ashtonian.dev/REGION=us-east-2 "values.fleet.ashtonian.dev/NOTE=$note"
hostname_is() { [[ $(hostname) == "$1" ]]; }
configmap_replaced() { [[ $(identity_configmap) != "$configmap_before" ]]; }
eventually 300 "the changed REGION reached the ingress hostname" hostname_is ingress.us-east-2.example.com
eventually 300 "monitoring uses a new fleet-identity ConfigMap" configmap_replaced
kubectl -n monitoring rollout status deployment/monitoring --timeout=5m
# Retried, since the old pods may still be terminating.
pod_region_is() { [[ $(pod_region) == "$1" ]]; }
eventually 120 "the running monitoring pods have REGION us-east-2" pod_region_is us-east-2
[[ $(repo_server_pods) == "$pods_before" ]] || fail "the repo-server restarted"
echo "ok   no restart was needed"
[[ $(identity NOTE) == "$note" ]] || fail "NOTE arrived as '$(identity NOTE)'"
echo "ok   a value with quotes, '#' and newlines arrived unchanged"

# An addon added to the annotation is created.
kubectl -n argocd annotate secret fleet-local fleet.ashtonian.dev/addons=gpu-operator,edge-cache --overwrite
wait_app addon-edge-cache

# A missing value fails only the application that wires it to a field, and
# that application keeps what it has.
kubectl -n argocd annotate secret fleet-local values.fleet.ashtonian.dev/REGION-
ingress_failed() {
  kubectl -n argocd get application base-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="ComparisonError")].message}' | grep -q 'data.REGION'
}
region_removed() { [[ $(identity GROUP) == us-east && -z $(identity REGION) ]]; }
eventually 300 "base-ingress reports the missing REGION" ingress_failed
eventually 300 "monitoring synced without REGION" region_removed
[[ $(hostname) == ingress.us-east-2.example.com ]] || fail "the ingress Service changed: '$(hostname)'"
echo "ok   a missing value failed only base-ingress, which changed nothing"

# An incomplete identity fails generation and deletes nothing.
kubectl -n argocd label secret fleet-local fleet.ashtonian.dev/group-
generation_failed() {
  kubectl -n argocd get applicationset fleet-base \
    -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].message}' |
    grep -q 'error calling fail: cluster Secret has no fleet.ashtonian.dev/group label'
}
eventually 300 "missing group label reported on fleet-base" generation_failed
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator addon-edge-cache
[[ $(monitoring '{.metadata.name}') == monitoring ]] || fail "monitoring was deleted"
echo "ok   incomplete identity changed nothing"

echo "e2e-native: ok"
