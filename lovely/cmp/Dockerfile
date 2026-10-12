# The Config Management Plugin sidecar: argocd-lovely-plugin with charmap and
# this repository's plugin configuration baked in. Binaries and the pipeline
# that runs them ship as one immutable image, so a change to either rolls the
# repo-server pod, and nothing is copied in at pod start.
ARG LOVELY_IMAGE=ghcr.io/crumbhole/argocd-lovely-plugin-cmp:v2.0.0@sha256:7fb7711233d2aa76505bca5930b056bce6f4d0c18a2d905af98d10ee0094e894
ARG CHARMAP_IMAGE=docker.io/ashtonian/charmap:2.0.0

FROM ${CHARMAP_IMAGE} AS charmap

FROM ${LOVELY_IMAGE}
COPY --from=charmap /usr/local/bin/charmap /usr/local/bin/charmap
COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml
