#!/usr/bin/env bash
# Renders every lovely Application the way the CMP sidecar does: the exact
# generate script from lovely/cmp/plugin.yaml, run inside the plugin image on
# a fresh copy of the repository. Checks each example identity renders with
# no token left, and that a missing identity or an unknown token stops the
# render with nothing on stdout.
#
# Usage: scripts/render-test.sh CMP_IMAGE [OUT_DIR]
# OUT_DIR, when given, receives the rendered manifests for later validation.
set -euo pipefail

image=${1:?usage: render-test.sh CMP_IMAGE [OUT_DIR]}
out=${2:-}
repo=$(git rev-parse --show-toplevel)
script=$(yq '.spec.generate.args[0]' "$repo/lovely/cmp/plugin.yaml")
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

# run_plugin GROUP CLUSTER_NAME APP_PATH [DOCKER_ARGS...]: runs the generate script in the
# plugin image against $work/repo with a read-only root filesystem, as the
# sidecar runs. The files belong to the calling user, so the container runs as
# that user too.
run_plugin() {
  local group=$1 cluster=$2 path=$3
  shift 3
  docker run --rm --read-only --tmpfs /tmp --user "$(id -u):$(id -g)" "$@" \
    -v "$work/repo:/repo" -w "/repo/$path" \
    -e GROUP="$group" -e CLUSTER_NAME="$cluster" -e RENDER_ROOT=lovely \
    -e ARGOCD_APP_SOURCE_PATH="$path" -e ARGOCD_APP_REVISION="$revision" \
    -e KUBE_VERSION=1.35.0 -e KUBE_API_VERSIONS=v1,apps/v1 \
    --entrypoint bash "$image" -c "$script"
}

# render GROUP CLUSTER_NAME APP_PATH: prints the manifests on stdout.
render() {
  fresh_copy
  run_plugin "$@"
}

for identity in us-east:cluster-001 eu-west:cluster-003; do
  group=${identity%%:*}
  cluster=${identity##*:}
  paths=(lovely/bootstrap)
  for d in "$repo"/lovely/apps/base/*/ "$repo"/lovely/groups/"$group"/addons/*/; do
    paths+=("${d#"$repo"/}")
  done
  for path in "${paths[@]}"; do
    path=${path%/}
    manifests=$(render "$group" "$cluster" "$path") || fail "$group/$cluster $path: render failed"
    [[ -n $manifests ]] || fail "$group/$cluster $path: rendered nothing"
    if grep -q '<::' <<<"$manifests"; then
      fail "$group/$cluster $path: token left in output: $(grep -m1 '<::' <<<"$manifests")"
    fi
    if [[ -n $out ]]; then
      mkdir -p "$out/$cluster"
      printf '%s\n' "$manifests" >"$out/$cluster/${path//\//_}.yaml"
    fi
    echo "ok   $group/$cluster $path"
  done

  bootstrap=$(render "$group" "$cluster" lovely/bootstrap)
  grep -q "path: lovely/groups/$group/addons/\*" <<<"$bootstrap" || fail "bootstrap does not select $group addons"
  # Each ApplicationSet pins its generator (revision) and its template
  # (targetRevision) to the resolved commit.
  [[ $(grep -cE "^ +revision: $revision$" <<<"$bootstrap") == 2 &&
    $(grep -cE "^ +targetRevision: $revision$" <<<"$bootstrap") == 2 ]] ||
    fail "bootstrap does not pin both ApplicationSets to the resolved commit"
  base=$(render "$group" "$cluster" lovely/apps/base/monitoring)
  grep -q "group: \"\?$group\"\?" <<<"$base" || fail "monitoring is not labelled with group $group"
  grep -q "cluster: \"\?$cluster\"\?" <<<"$base" || fail "monitoring is not labelled with cluster $cluster"
done

# An empty identity value stops the render before anything is printed.
if stdout=$(render "" cluster-001 lovely/apps/base/monitoring 2>/dev/null); then
  fail "render succeeded with an empty GROUP"
fi
[[ -z $stdout ]] || fail "render with an empty GROUP printed manifests"
echo "ok   empty GROUP is rejected"

# Plugin environment set by an Application never reaches lovely: a
# preprocessor that fails would fail the render if it ran.
fresh_copy
run_plugin us-east cluster-001 lovely/apps/base/logging -e ARGOCD_ENV_LOVELY_PREPROCESSORS=false >/dev/null ||
  fail "an Application-supplied lovely preprocessor ran"
echo "ok   Application plugin environment is ignored"

# An unknown token anywhere under RENDER_ROOT stops the render, even in a
# file this Application does not use.
fresh_copy
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\ndata:\n  k: "<::NOT_SET::>"\n' \
  >"$work/repo/lovely/apps/base/monitoring/unset.yaml"
if stdout=$(run_plugin us-east cluster-001 lovely/apps/base/logging 2>/dev/null); then
  fail "render succeeded with an unknown token under RENDER_ROOT"
fi
[[ -z $stdout ]] || fail "render with an unknown token printed manifests"
echo "ok   unknown token is rejected"

echo "render-test: ok"
