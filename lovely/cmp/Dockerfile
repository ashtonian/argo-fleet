# The Config Management Plugin sidecar: argocd-lovely-plugin with charmap and
# this repository's plugin configuration baked in. Binaries and the pipeline
# that runs them ship as one immutable image, so a change to either rolls the
# repo-server pod, and nothing is copied in at pod start.
ARG LOVELY_IMAGE=ghcr.io/crumbhole/argocd-lovely-plugin-cmp:1.2.5@sha256:9534361276328c3446b6d7cba3f2c0c22a945ddf0a29ddadc2c8f5db9df7af90
ARG CHARMAP_IMAGE=docker.io/ashtonian/charmap:2.0.0

FROM ${CHARMAP_IMAGE} AS charmap

FROM ${LOVELY_IMAGE}
COPY --from=charmap /usr/local/bin/charmap /usr/local/bin/charmap
COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml
