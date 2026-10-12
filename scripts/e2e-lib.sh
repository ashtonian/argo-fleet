#!/usr/bin/env bash
# Shared by the end-to-end tests: sourced, not run. Each test installs Argo CD,
# so every function here assumes require_kind_context has passed.

argo_cd_chart=${ARGO_CD_CHART_VERSION:-10.10.2}
argocd_apps_chart=${ARGOCD_APPS_CHART_VERSION:-2.0.6}
argo_helm=https://argoproj.github.io/argo-helm

# require_kind_context: refuses any kubectl context not named kind-*.
require_kind_context() {
  local context
  context=$(kubectl config current-context)
  if [[ $context != kind-* ]]; then
    echo "refusing to install into context '$context': the end-to-end tests only run against a kind cluster" >&2
    exit 1
  fi
}

# dump: diagnostics printed when a test fails.
dump() {
  echo "::group::diagnostics"
  kubectl get applications,applicationsets -n argocd -o yaml || true
  # Cluster Secrets' identity only: their data is never printed.
  kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}  labels: {.metadata.labels}{"\n"}  annotations: {.metadata.annotations}{"\n"}{end}' || true
  kubectl get pods -A -o wide || true
  kubectl logs -n argocd -l app.kubernetes.io/component=repo-server --all-containers --tail=200 || true
  kubectl logs -n argocd -l app.kubernetes.io/component=applicationset-controller --tail=100 || true
  echo "::endgroup::"
}

# prepare_namespace: creates argocd, enforcing the restricted Pod Security
# Standard, so installing anything that is not hardened fails.
prepare_namespace() {
  kubectl create namespace argocd
  kubectl label namespace argocd pod-security.kubernetes.io/enforce=restricted
}

# install_argocd VALUES: installs the argo-cd chart and waits for it.
install_argocd() {
  helm install argocd argo-cd --repo "$argo_helm" --version "$argo_cd_chart" \
    --namespace argocd --values "$1" --wait --timeout 10m
}

# install_bootstrap VALUES [HELM_ARGS...]: installs the argocd-apps chart.
install_bootstrap() {
  local values=$1
  shift
  helm install fleet-bootstrap argocd-apps --repo "$argo_helm" --version "$argocd_apps_chart" \
    --namespace argocd --values "$values" "$@"
}

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

# expect_apps NAME...: the Applications must be exactly these.
expect_apps() {
  local want got
  want=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  got=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | tr '\n' ' ')
  [[ $got == "$want" ]] || { echo "Applications: got '$got', want '$want'" >&2; return 1; }
  echo "ok   Applications are exactly: $want"
}

# eventually SECONDS DESCRIPTION COMMAND...: retries COMMAND until it succeeds.
eventually() {
  local seconds=$1 what=$2
  shift 2
  local deadline=$((SECONDS + seconds))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "timed out after ${seconds}s waiting for: $what" >&2
      return 1
    fi
    sleep 5
  done
  echo "ok   $what"
}
