#!/usr/bin/env bash
# Installs External Secrets, Argo CD with native/argocd-values.yaml and the
# fleet-bootstrap release with native/bootstrap-values.yaml into the current
# kubectl context, and checks the native fleet comes up from REVISION (a full
# commit SHA), with the cluster's identity delivered the way it is at scale:
#   - a provisioner writes only the seed of the registration Secret;
#   - External Secrets fills in the rest from a secrets manager, here its fake
#     provider, with identity/external-secret.example.yaml: the cluster's
#     entry, and the revision of its ring from the fleet's rings entry.
# It then checks the properties the native approach is chosen for:
#   - a changed value reaches the running workloads with no restart;
#   - an addon added to the cluster's entry is created;
#   - promoting a ring is one write, a bad revision breaks no workload, and a
#     cluster's own revision overrides its ring's;
#   - a missing value fails only the application that needs it;
#   - an incomplete entry, or an incomplete identity, changes nothing.
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
install_external_secrets
install_argocd "$repo/native/argocd-values.yaml"

# The provisioner's seed: what Argo CD needs to read the Secret, nothing more.
yq 'del(.metadata.annotations) | .metadata.labels = {"argocd.argoproj.io/secret-type": "cluster"}' \
  "$repo/identity/cluster-secret.example.yaml" | kubectl apply -f -

# The secrets manager's two entries. write_entries publishes them.
cluster_entry=$(jq -nc '{name: "cluster-001", group: "us-east", ring: "canary", addons: "gpu-operator", values: {REGION: "us-east-1"}}')
rings_entry=$(jq -nc --arg r "$revision" '{revisions: {canary: $r}}')
write_entries() {
  CLUSTER=$cluster_entry RINGS=$rings_entry yq -n '
    .apiVersion = "external-secrets.io/v1" | .kind = "ClusterSecretStore" | .metadata.name = "fleet" |
    .spec.provider.fake.data = [
      {"key": "fleet/cluster-001", "value": strenv(CLUSTER)},
      {"key": "fleet/rings", "value": strenv(RINGS)}]' | kubectl apply -f -
}
# Retried: External Secrets' webhook may still be getting its certificate.
eventually 120 "the secrets manager holds the cluster's and the rings' entries" write_entries
# Refreshed every 10 seconds instead of 5 minutes, to keep the test short.
yq '.spec.refreshInterval = "10s"' "$repo/identity/external-secret.example.yaml" | kubectl apply -f -

install_bootstrap "$repo/native/bootstrap-values.yaml"

# secret_field JSONPATH: a field of the registration Secret.
secret_field() {
  kubectl -n argocd get secret fleet-local -o jsonpath="$1"
}
secret_revision_is() { [[ $(secret_field '{.metadata.annotations.fleet\.ashtonian\.dev/revision}') == "$1" ]]; }
eventually 300 "External Secrets merged the identity and the ring's revision into the seed" secret_revision_is "$revision"
[[ $(secret_field '{.metadata.labels.fleet\.ashtonian\.dev/group}') == us-east ]] ||
  fail "the Secret's group label is '$(secret_field '{.metadata.labels.fleet\.ashtonian\.dev/group}')'"

wait_app fleet-bootstrap
for app in base-ingress base-logging base-monitoring addon-gpu-operator; do
  wait_app "$app"
done
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator

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

# Every Application targets, and is labelled with, the ring's revision, and
# Argo CD's metrics show it.
app_targets base-monitoring "$revision" || fail "base-monitoring does not target $revision"
revision_labelled "$revision" || fail "not every Application is labelled with revision $revision"
eventually 180 "argocd_app_labels shows Applications at the revision" metrics_count_revision "$revision"

# A changed value reaches the running workloads with no repo-server restart
# or hard refresh: fleet-identity's name changes with its content, which
# rolls the pods that use it. A value that looks like YAML or a patch
# operation must arrive as plain data.
pods_before=$(repo_server_pods)
configmap_before=$(identity_configmap)
note=$'a: "b" # c\n- op: remove\n  path: /data'
cluster_entry=$(jq -c --arg note "$note" '.values.REGION = "us-east-2" | .values.NOTE = $note' <<<"$cluster_entry")
write_entries
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

# An addon added to the cluster's entry is created.
cluster_entry=$(jq -c '.addons = "gpu-operator, edge-cache"' <<<"$cluster_entry")
write_entries
wait_app addon-edge-cache

# Promoting a ring is one write to the rings entry. A revision that does not
# exist reaches every Application that reads it and breaks no workload.
missing=0000000000000000000000000000000000000000
rings_entry=$(jq -nc --arg r "$missing" '{revisions: {canary: $r}}')
write_entries
eventually 300 "the ring's revision reached fleet-bootstrap" app_targets fleet-bootstrap "$missing"
eventually 300 "fleet-bootstrap reports the missing revision" app_error fleet-bootstrap
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator addon-edge-cache
[[ $(monitoring '{.status.readyReplicas}') == 2 ]] || fail "monitoring lost ready replicas"
echo "ok   a bad promotion broke no workload"

# A revision in the cluster's own entry overrides its ring's.
cluster_entry=$(jq -c --arg r "$revision" '.revision = $r' <<<"$cluster_entry")
write_entries
eventually 300 "the cluster's own revision overrides its ring's" app_targets fleet-bootstrap "$revision"
wait_app fleet-bootstrap
wait_app addon-gpu-operator

# A missing value fails only the application that wires it to a field, and
# that application keeps what it has.
cluster_entry=$(jq -c 'del(.values.REGION)' <<<"$cluster_entry")
write_entries
region_removed() { [[ $(identity GROUP) == us-east && -z $(identity REGION) ]]; }
eventually 300 "base-ingress reports the missing REGION" app_error base-ingress data.REGION
eventually 300 "monitoring synced without REGION" region_removed
[[ $(hostname) == ingress.us-east-2.example.com ]] || fail "the ingress Service changed: '$(hostname)'"
echo "ok   a missing value failed only base-ingress, which changed nothing"

# An entry without its group fails the ExternalSecret, which leaves the
# Secret as it was.
cluster_entry=$(jq -c 'del(.group)' <<<"$cluster_entry")
write_entries
external_secret_failed() {
  [[ $(kubectl -n argocd get externalsecret fleet-local -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}') == SecretSyncedError ]]
}
eventually 120 "External Secrets reports the entry without a group" external_secret_failed
[[ $(secret_field '{.metadata.labels.fleet\.ashtonian\.dev/group}') == us-east ]] || fail "the group label changed"
echo "ok   an incomplete entry changed nothing"

# Deleting the ExternalSecret leaves the Secret (creationPolicy Merge). An
# identity without a group fails generation and deletes nothing.
kubectl -n argocd delete externalsecret fleet-local
[[ $(secret_field '{.metadata.name}') == fleet-local ]] || fail "deleting the ExternalSecret deleted the Secret"
kubectl -n argocd label secret fleet-local fleet.ashtonian.dev/group-
eventually 300 "missing group label reported on fleet-base" \
  appset_error fleet-base 'error calling fail: cluster Secret has no fleet.ashtonian.dev/group label'
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator addon-edge-cache
[[ $(monitoring '{.metadata.name}') == monitoring ]] || fail "monitoring was deleted"
echo "ok   incomplete identity changed nothing"

echo "e2e-native: ok"
