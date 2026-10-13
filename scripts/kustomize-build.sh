#!/usr/bin/env bash
# Builds every Kustomization in the repository. A native application builds
# only the way its Application builds it, so each one is built, for every
# group, the way Argo CD does: on a copy, its kustomization.yaml gets the
# Application's labels, patches and components, in that order, with the
# values of the example cluster (identity/cluster-secret.example.yaml).
# scripts/e2e-native.sh renders them through Argo CD itself. A lovely
# application builds only after charmap has replaced its tokens, which
# scripts/render-test.sh does in the plugin image.
#
# Usage: scripts/kustomize-build.sh
set -euo pipefail
shopt -s nullglob

repo=$(git rev-parse --show-toplevel)
cd "$repo"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# build DIR DESCRIPTION
build() {
  if kustomize build "$1" >/dev/null; then
    echo "ok   $2"
  else
    echo "FAIL $2" >&2
    failed=1
  fi
}

while IFS= read -r -d '' kustomization; do
  dir=$(dirname "$kustomization")
  [[ $(yq '.kind' "$kustomization") == Component ]] && continue
  [[ $dir == ./native/apps/* || $dir == ./lovely/apps/* ]] && continue
  build "$dir" "$dir"
done < <(find . -name kustomization.yaml -not -path './.git/*' -print0 | sort -z)

example=identity/cluster-secret.example.yaml
prefix=values.fleet.ashtonian.dev/
for component in native/components/groups/*/; do
  group=$(basename "$component")
  cluster=$(yq '.stringData.name' "$example")
  # fleet-identity's data as the ApplicationSets' templatePatch writes it.
  values=$(GROUP=$group PREFIX=$prefix yq -o=json -I=0 '
    (.metadata.annotations // {}
      | with_entries(select(.key | test("^" + strenv(PREFIX))) | .key |= sub("^" + strenv(PREFIX); "")))
    + {"GROUP": strenv(GROUP), "CLUSTER_NAME": .stringData.name}' "$example")
  for app in native/apps/base/*/ native/apps/addons/*/; do
    app=${app%/}
    rm -rf "$work/native"
    cp -R native "$work/native"
    (
      cd "$work/$app"
      kustomize edit add label --without-selector --include-templates \
        "fleet.ashtonian.dev/group:$group" "fleet.ashtonian.dev/cluster:$cluster"
      VALUES=$values yq -i '.patches += [{
        "target": {"kind": "ConfigMap", "name": "fleet-identity"},
        "patch": "- op: add\n  path: /data\n  value: " + strenv(VALUES)}]' kustomization.yaml
      kustomize edit add component ../../../components/identity "../../../components/groups/$group"
    )
    build "$work/$app" "$app with group $group"
  done
done

exit "$failed"
