#!/usr/bin/env bash
# Renders every lovely application the way the CMP sidecar does: the exact
# generate script from lovely/cmp/plugin.yaml, run inside the plugin image on
# a fresh copy of the repository, with the identity and values an Application
# passes in its spec (ARGOCD_ENV_FLEET_*). Checks that each example identity
# renders with no token left and its group's Component applied, and that a
# missing or invalid value, or an unknown token, stops the render with
# nothing on stdout.
#
# Usage: scripts/render-test.sh CMP_IMAGE [OUT_DIR]
# OUT_DIR, when given, receives the rendered manifests for later validation.
set -euo pipefail

image=${1:?usage: render-test.sh CMP_IMAGE [OUT_DIR]}
out=${2:-}
repo=$(git rev-parse --show-toplevel)
script=$(yq '.spec.generate.args[0]' "$repo/lovely/cmp/plugin.yaml")
# The sidecar's own settings, from the values every cluster installs.
sidecar_env() { yq ".repoServer.extraContainers[0].env[] | select(.name == \"$1\") | .value" "$repo/lovely/argocd-values.yaml"; }
render_root=$(sidecar_env RENDER_ROOT)
render_include=$(sidecar_env RENDER_INCLUDE)
# The commit Argo CD would have resolved for the Application being rendered.
revision=0123456789abcdef0123456789abcdef01234567
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# fresh_copy: copies the working tree, as the CMP server receives the
# repository, to $work/repo.
fresh_copy() {
  rm -rf "$work/repo"
  rsync -a --exclude .git "$repo/" "$work/repo/"
}

# run_plugin APP_PATH [DOCKER_ARGS...]: runs the generate script in the plugin
# image against $work/repo with a read-only root filesystem, as the sidecar
# runs. Identity and values are DOCKER_ARGS (-e ARGOCD_ENV_FLEET_<KEY>=...).
# The files belong to the calling user, so the container runs as that user.
run_plugin() {
  local path=$1
  shift
  docker run --rm --read-only --tmpfs /tmp --user "$(id -u):$(id -g)" "$@" \
    -v "$work/repo:/repo" -w "/repo/$path" \
    -e RENDER_ROOT="$render_root" -e RENDER_INCLUDE="$render_include" \
    -e ARGOCD_APP_SOURCE_PATH="$path" -e ARGOCD_APP_REVISION="$revision" \
    -e KUBE_VERSION=1.36.0 -e KUBE_API_VERSIONS=v1,apps/v1 \
    --entrypoint bash "$image" -c "$script"
}

# identity GROUP CLUSTER_NAME REGION: the plugin environment an Application
# for that cluster carries.
identity() {
  echo "-e ARGOCD_ENV_FLEET_GROUP=$1 -e ARGOCD_ENV_FLEET_CLUSTER_NAME=$2 -e ARGOCD_ENV_FLEET_REGION=$3"
}

# expect_rejected DESCRIPTION APP_PATH [DOCKER_ARGS...]: the render must fail
# and print nothing.
expect_rejected() {
  local what=$1 stdout
  shift
  if stdout=$(run_plugin "$@" 2>/dev/null); then
    fail "render succeeded with $what"
  fi
  [[ -z $stdout ]] || fail "render with $what printed manifests"
  echo "ok   $what is rejected"
}

for cluster in us-east:cluster-001:us-east-1 eu-west:cluster-003:eu-west-1; do
  IFS=: read -r group name region <<<"$cluster"
  # shellcheck disable=SC2207 # the identity is three -e KEY=VALUE words
  env=($(identity "$group" "$name" "$region"))
  for dir in "$repo"/lovely/apps/base/*/ "$repo"/lovely/apps/addons/*/; do
    path=${dir#"$repo"/}
    path=${path%/}
    fresh_copy
    manifests=$(run_plugin "$path" "${env[@]}") || fail "$group/$name $path: render failed"
    [[ -n $manifests ]] || fail "$group/$name $path: rendered nothing"
    if grep -q '<::' <<<"$manifests"; then
      fail "$group/$name $path: token left in output: $(grep -m1 '<::' <<<"$manifests")"
    fi
    grep -q "fleet.ashtonian.dev/group: \"\?$group\"\?" <<<"$manifests" || fail "$group/$name $path: no group label"
    grep -q "fleet.ashtonian.dev/cluster: \"\?$name\"\?" <<<"$manifests" || fail "$group/$name $path: no cluster label"
    if [[ -n $out ]]; then
      mkdir -p "$out/$name"
      printf '%s\n' "$manifests" >"$out/$name/${path//\//_}.yaml"
    fi
    echo "ok   $group/$name $path"
  done

  fresh_copy
  ingress=$(run_plugin lovely/apps/base/ingress "${env[@]}")
  grep -q "value: https://ingress.$region.example.com/healthz" <<<"$ingress" || fail "$group: REGION did not fill the URL"
  fresh_copy
  logging=$(run_plugin lovely/apps/base/logging "${env[@]}")
  grep -q "Host  logs.$region.example.com" <<<"$logging" || fail "$group: REGION did not fill the configuration file"
  fresh_copy
  monitoring=$(run_plugin lovely/apps/base/monitoring "${env[@]}")
  grep -q "fleet.ashtonian.dev/rendered-from: $revision" <<<"$monitoring" || fail "$group: REVISION is not the resolved commit"
  case $group in
    us-east) grep -q 'replicas: 2' <<<"$monitoring" || fail "the us-east Component did not set 2 replicas" ;;
    eu-west) grep -q 'fleet.ashtonian.dev/data-residency: eu' <<<"$monitoring" || fail "the eu-west Component was not applied" ;;
  esac
  echo "ok   $group: tokens inside a URL and a configuration file, REVISION, and the group's Component"
done

# shellcheck disable=SC2207
env=($(identity us-east cluster-001 us-east-1))

fresh_copy
expect_rejected "an empty GROUP" lovely/apps/base/monitoring \
  -e ARGOCD_ENV_FLEET_GROUP= -e ARGOCD_ENV_FLEET_CLUSTER_NAME=cluster-001 -e ARGOCD_ENV_FLEET_REGION=us-east-1

# A value a manifest uses and the cluster lacks fails every render, since
# every file under RENDER_ROOT is rendered.
fresh_copy
expect_rejected "a missing REGION" lovely/apps/base/monitoring \
  -e ARGOCD_ENV_FLEET_GROUP=us-east -e ARGOCD_ENV_FLEET_CLUSTER_NAME=cluster-001

fresh_copy
expect_rejected "a group without a Component" lovely/apps/base/monitoring \
  -e ARGOCD_ENV_FLEET_GROUP=nowhere -e ARGOCD_ENV_FLEET_CLUSTER_NAME=cluster-001 -e ARGOCD_ENV_FLEET_REGION=us-east-1

fresh_copy
expect_rejected "an invalid value name" lovely/apps/base/logging "${env[@]}" -e ARGOCD_ENV_FLEET_bad-key=x

# An unknown token anywhere under RENDER_ROOT stops the render, even in a
# file this Application does not use.
fresh_copy
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\ndata:\n  k: "<::NOT_SET::>"\n' \
  >"$work/repo/lovely/apps/base/monitoring/unset.yaml"
expect_rejected "an unknown token" lovely/apps/base/logging "${env[@]}"

# Any value the Application passes is a token, with no change to the plugin.
fresh_copy
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\ndata:\n  tier: "<::TIER::>"\n' \
  >"$work/repo/lovely/apps/base/logging/tier.yaml"
yq -i '.resources += ["tier.yaml"]' "$work/repo/lovely/apps/base/logging/kustomization.yaml"
tier=$(run_plugin lovely/apps/base/logging "${env[@]}" -e ARGOCD_ENV_FLEET_TIER=edge) ||
  fail "a render with an extra value failed"
grep -q 'tier: edge' <<<"$tier" || fail "the TIER value did not fill its token"
echo "ok   any value is a token"

# Plugin settings for lovely itself never come from an Application: a
# preprocessor that fails would fail the render if it ran.
fresh_copy
run_plugin lovely/apps/base/logging "${env[@]}" -e ARGOCD_ENV_LOVELY_PREPROCESSORS=false >/dev/null ||
  fail "an Application-supplied lovely preprocessor ran"
echo "ok   Application-supplied lovely settings are ignored"

echo "render-test: ok"
