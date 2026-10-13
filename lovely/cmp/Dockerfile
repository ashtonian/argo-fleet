# The Config Management Plugin sidecar: argocd-lovely-plugin with charmap and
# this repository's plugin configuration baked in. Binaries and the pipeline
# that runs them ship as one immutable image, so a change to either rolls the
# repo-server pod, and nothing is copied in at pod start.
#
# Both bases are pinned by digest; Dependabot proposes updates. To build
# against an unreleased charmap, override the stage with a named context,
# e.g. --build-context docker.io/ashtonian/charmap:2.0.0=oci-layout://<dir>.
FROM docker.io/ashtonian/charmap:2.0.0@sha256:74df476a9a2dd40e46c550935da25e76bbc75e308b383e03061c91c23a6bdabc AS charmap

FROM ghcr.io/crumbhole/argocd-lovely-plugin-cmp:v2.0.0@sha256:7fb7711233d2aa76505bca5930b056bce6f4d0c18a2d905af98d10ee0094e894
COPY --from=charmap /usr/local/bin/charmap /usr/local/bin/charmap
COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml
