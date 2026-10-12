#!/usr/bin/env bash
# Installs Argo CD with lovely/argocd-values.yaml, using the plugin image
# CMP_IMAGE, and the fleet-bootstrap release with lovely/bootstrap-values.yaml
# into the current kubectl context. It registers the cluster with the example
# identity (identity/cluster-secret.example.yaml: us-east, cluster-001) at
# REVISION (a full commit SHA) and checks the fleet comes up with every token
# replaced. The argocd namespace enforces the restricted Pod Security
# Standard, so the install itself fails if any container, the plugin sidecar
# included, is not hardened. It then checks that:
#   - a changed value reaches the workloads with no restart;
#   - an addon added to the cluster's annotation is created;
#   - a missing value fails every render and changes nothing;
#   - an incomplete identity stops generation and changes nothing.
# scripts/e2e-native.sh also tests External Secrets, which writes the same
# identity for both approaches.
#
# Usage: scripts/e2e.sh CMP_IMAGE REVISION
# It installs Argo CD, so it refuses any kubectl context not named kind-*.
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
IMAGE=$image yq '.repoServer.extraContainers[0].image = strenv(IMAGE)' \
  "$repo/lovely/argocd-values.yaml" >"$work/values.yaml"
install_argocd "$work/values.yaml"
register_cluster "$revision"
install_bootstrap "$repo/lovely/bootstrap-values.yaml"

wait_app fleet-bootstrap
for app in base-ingress base-logging base-monitoring addon-gpu-operator; do
  wait_app "$app"
done
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator

# deployment NAMESPACE JSONPATH: a field of the Deployment named after its namespace.
deployment() {
  kubectl -n "$1" get deployment "$1" -o jsonpath="$2"
}
# public_url: the ingress container's PUBLIC_URL, a token inside a URL.
public_url() {
  deployment ingress '{.spec.template.spec.containers[0].env[?(@.name=="PUBLIC_URL")].value}'
}
# logging_config: the logging configuration file, tokens inside a file.
logging_config() {
  kubectl -n logging get configmap "$(deployment logging '{.spec.template.spec.volumes[0].configMap.name}')" \
    -o jsonpath='{.data.logging\.conf}'
}

# Identity tokens in labels, on the Deployment and its pods.
[[ $(deployment monitoring '{.metadata.labels.fleet\.ashtonian\.dev/group}') == us-east ]] ||
  fail "monitoring is not labelled with group us-east"
[[ $(deployment monitoring '{.spec.template.metadata.labels.fleet\.ashtonian\.dev/cluster}') == cluster-001 ]] ||
  fail "monitoring's pods are not labelled with cluster cluster-001"
[[ $(deployment monitoring '{.metadata.annotations.fleet\.ashtonian\.dev/rendered-from}') == "$revision" ]] ||
  fail "REVISION is not the commit Argo CD resolved"
echo "ok   identity and revision tokens replaced"

# The group's Component, chosen by a token in the application's kustomization.
[[ $(deployment monitoring '{.spec.replicas}') == 2 ]] || fail "the us-east Component did not set 2 replicas"
echo "ok   group Component applied (us-east: 2 replicas)"

# Values inside a URL and inside a configuration file.
[[ $(public_url) == https://ingress.us-east-1.example.com/healthz ]] || fail "PUBLIC_URL is '$(public_url)'"
grep -q 'Host  logs.us-east-1.example.com' <<<"$(logging_config)" || fail "the logging configuration has no REGION"
echo "ok   REGION inside a URL and a configuration file"

# The values travel in each Application's spec, and every Application is
# labelled with the revision for Argo CD's metrics.
env_value() {
  kubectl -n argocd get application "$1" -o jsonpath="{.spec.source.plugin.env[?(@.name==\"$2\")].value}"
}
[[ $(env_value base-monitoring FLEET_REGION) == us-east-1 ]] || fail "base-monitoring's spec has no FLEET_REGION"
app_targets base-monitoring "$revision" || fail "base-monitoring does not target $revision"
revision_labelled "$revision" || fail "not every Application is labelled with revision $revision"
eventually 180 "argocd_app_labels shows Applications at the revision" metrics_count_revision "$revision"

# A changed value reaches the workloads with no repo-server restart or hard
# refresh: the Applications' specs change, and Argo CD re-renders them.
pods_before=$(repo_server_pods)
kubectl -n argocd annotate secret fleet-local values.fleet.ashtonian.dev/REGION=us-east-2 --overwrite
public_url_is() { [[ $(public_url) == "$1" ]]; }
logging_region_is() { grep -q "Host  logs.$1.example.com" <<<"$(logging_config)"; }
eventually 300 "the changed REGION reached the URL" public_url_is https://ingress.us-east-2.example.com/healthz
eventually 300 "the changed REGION reached the configuration file" logging_region_is us-east-2
[[ $(repo_server_pods) == "$pods_before" ]] || fail "the repo-server restarted"
echo "ok   no restart was needed"

# An addon added to the annotation is created.
kubectl -n argocd annotate secret fleet-local fleet.ashtonian.dev/addons=gpu-operator,edge-cache --overwrite
wait_app addon-edge-cache

# A value the manifests use and the cluster lacks fails every render, since
# charmap renders every file under RENDER_ROOT, and changes nothing.
kubectl -n argocd annotate secret fleet-local values.fleet.ashtonian.dev/REGION-
eventually 300 "base-monitoring reports the missing REGION" app_error base-monitoring REGION
[[ $(public_url) == https://ingress.us-east-2.example.com/healthz ]] || fail "the ingress Deployment changed"
echo "ok   a missing value changed nothing"
kubectl -n argocd annotate secret fleet-local values.fleet.ashtonian.dev/REGION=us-east-2

# An incomplete identity fails generation and deletes nothing.
kubectl -n argocd label secret fleet-local fleet.ashtonian.dev/group-
eventually 300 "missing group label reported on fleet-base" \
  appset_error fleet-base 'error calling fail: cluster Secret has no fleet.ashtonian.dev/group label'
expect_apps fleet-bootstrap base-ingress base-logging base-monitoring addon-gpu-operator addon-edge-cache
[[ $(deployment monitoring '{.metadata.name}') == monitoring ]] || fail "monitoring was deleted"
echo "ok   incomplete identity changed nothing"

echo "e2e: ok"
