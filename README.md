# Argo CD fleet patterns

[![CI](https://github.com/ashtonian/argo-fleet/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/ashtonian/argo-fleet/actions/workflows/ci.yaml)
[![Plugin image](https://img.shields.io/github/v/release/ashtonian/argo-fleet?label=plugin%20image)](https://github.com/ashtonian/argo-fleet/releases/latest)

Three ways to run the same applications across a fleet of Kubernetes
clusters with Argo CD ApplicationSets, from one Git repository: base
applications on every cluster, per-group overrides, and addons on selected
clusters.

Tested with Argo CD 3.5.4 (argo-cd chart 10.10.2, argocd-apps chart 2.0.6)
on Kubernetes 1.36, argocd-lovely-plugin 2.0.0 and
[charmap](https://github.com/ashtonian/charmap) 2.0.0. CI installs the
lovely approach into a kind cluster on every change; the overlay and matrix
manifests are built and validated against Argo CD's schemas.

## Contents

- [Which one?](#which-one)
- [Approach 1: Overlay](#approach-1-overlay)
- [Approach 2: Matrix](#approach-2-matrix)
- [Approach 3: Lovely + charmap](#approach-3-lovely--charmap)
  - [Prerequisites](#prerequisites)
  - [Try it in kind](#try-it-in-kind)
  - [Bootstrapping a cluster](#bootstrapping-a-cluster)
  - [Configuration reference](#configuration-reference)
  - [Using it in your own repository](#using-it-in-your-own-repository)
  - [Day-2 operations](#day-2-operations)
  - [Staged rollout and rollback](#staged-rollout-and-rollback)
  - [The plugin sidecar image](#the-plugin-sidecar-image)
  - [Troubleshooting](#troubleshooting)
  - [Monitoring](#monitoring)
  - [Upgrading](#upgrading)
  - [Limitations](#limitations)
- [Deletion safety](#deletion-safety)
- [Scale](#scale)
- [Security](#security)
- [Group overrides](#group-overrides)
- [CI](#ci)
- [Repository layout](#repository-layout)

## Which one?

- **Overlay** for a handful of clusters that each need their own patches.
- **Matrix** when one central Argo CD manages every cluster and groups
  need structural differences (replicas, resources, images).
- **Lovely + charmap** when every cluster runs its own Argo CD: clusters
  join with no Git change, identity comes from the cluster (a secrets
  manager, for example), and each cluster runs one pinned commit, so changes
  roll out ring by ring.

| | [Overlay](#approach-1-overlay) | [Matrix](#approach-2-matrix) | [Lovely + charmap](#approach-3-lovely--charmap) |
|---|---|---|---|
| **Topology** | Argo CD in every cluster | One hub Argo CD deploying to every cluster | Argo CD in every cluster |
| **Mechanism** | Git directory generator over a per-cluster directory | Matrix of a per-cluster `config.yaml` and per-group Kustomize overlays | Git directory generators; cluster identity substituted into manifests by a Config Management Plugin |
| **Cluster identity** | The cluster's directory path, set in its ApplicationSet | `matrix/clusters/<cluster>/config.yaml` | A `cluster-identity` Secret in the cluster (can come from a secrets manager) |
| **Base applications** | Listed per cluster | All, through the cluster's group overlay | All |
| **Group overrides** | Patches in each cluster's overlays | Kustomize overlay per group and application | `<::GROUP::>`-style tokens in manifests; Kustomize for structure |
| **Addon selection** | Per cluster (directory presence) | Per cluster (directory presence) | Per group (directory presence) |
| **Add a cluster** | A directory per application, plus an ApplicationSet | One `config.yaml`, plus registering the cluster with the hub | Install Argo CD with the shared values and a Secret; no Git change |
| **Add a base application** | A directory in every cluster | A directory in every group | One directory |
| **Per-cluster exceptions** | Yes | Yes (addons) | Through a group of one ([how](#day-2-operations)) |
| **Rollout** | Edit each cluster's revision | All clusters at once from the hub | Per cluster or ring, each pinned to one commit |

The [scale section](#scale) explains why directory count is not the only
cost that grows with the fleet.

### Directories to maintain

Counting every application directory (each a `kustomization.yaml`) and
per-cluster directory, for 20 base applications, 5 addons, 5 groups, an
average of 2 addons per cluster (overlay, matrix) or per group (lovely):

| Clusters | Overlay | Matrix | Lovely |
|---|---|---|---|
| 10 | 245 | 155 | 35 |
| 500 | 11,025 | 1,625 | 35 |
| 10,000 | 220,025 | 30,125 | 35 |

<details>
<summary>How the numbers are derived</summary>

| Component | Overlay | Matrix | Lovely |
|---|---|---|---|
| Application definitions (20 base + 5 addons) | 25 | 25 | 25 |
| Group overlays (5 groups × 20 base) | | 100 | |
| Group addon selections (5 groups × 2) | | | 10 |
| Per cluster | 20 base + 2 addons = 22 | `config.yaml` directory + 2 addons = 3 | 0 |
| **Total for N clusters** | 25 + 22N | 125 + 3N | 35 |

Lovely moves per-cluster state out of Git into a Secret in each cluster, so
its count does not grow with the fleet. The Secrets still have to be
managed, for example from a secrets manager.

</details>

---

## Approach 1: Overlay

`overlay/`. Every cluster runs its own Argo CD with its own copy of
`overlay/applicationset.yaml`, pointed at its own directory under
`overlay/clusters/`. Each subdirectory there is a Kustomize overlay of a base
application, and becomes one Application.

```
overlay/
├── apps/                    # base application definitions
│   ├── monitoring/  ingress/  logging/  gpu-operator/  edge-cache/
├── clusters/
│   └── cluster-001/         # only the applications this cluster runs
│       ├── monitoring/kustomization.yaml   # resources: ../../../apps/monitoring
│       ├── ingress/
│       └── logging/
└── applicationset.yaml      # AppProject + ApplicationSet for cluster-001
```

- **Add a cluster:** create `overlay/clusters/<cluster>/<app>/kustomization.yaml`
  for each application it runs, copy `applicationset.yaml` with the generator
  path changed to `overlay/clusters/<cluster>/*`, and apply that copy to the
  cluster's Argo CD.
- **Add an application to a cluster:** add its overlay directory. To patch
  it for one cluster, add a patch to that overlay.

| For | Against |
|---|---|
| Plain Kustomize, easy to read | A directory per application per cluster |
| Any per-cluster patch | Each cluster needs its own ApplicationSet path |
| | Shared changes touch every cluster's directory |

## Approach 2: Matrix

`matrix/`. A hub-and-spoke layout: one Argo CD instance deploys to every
cluster listed under `matrix/clusters/`. Installing these ApplicationSets in
every cluster's own Argo CD would make each of them try to deploy to the
whole fleet.

```
matrix/
├── apps/
│   ├── base/                # deployed to every cluster
│   └── addons/              # deployed where a cluster opts in
├── groups/
│   ├── us-east/apps/<app>/kustomization.yaml   # base + us-east patches
│   └── eu-west/apps/<app>/kustomization.yaml
├── clusters/
│   ├── cluster-001/
│   │   ├── config.yaml      # cluster_name, group, cluster_server
│   │   └── addons/gpu-operator/
│   ├── cluster-002/config.yaml
│   └── cluster-003/
│       ├── config.yaml
│       └── addons/{gpu-operator,edge-cache}/
└── applicationsets.yaml     # AppProject + two ApplicationSets
```

Each ApplicationSet is a matrix of two Git generators: the cluster configs,
and the application directories selected by a value from each config.

```yaml
generators:
  - matrix:
      generators:
        - git:
            files:
              - path: matrix/clusters/*/config.yaml   # cluster_name, group, cluster_server
            pathParamPrefix: cluster
        - git:
            directories:
              - path: "matrix/groups/{{.group}}/apps/*"
            pathParamPrefix: app
```

Both Git generators emit `path` parameters. Without `pathParamPrefix`, the
cluster config's `path` overwrites the application's, and every generated
Application would point at a cluster directory. With it, the template uses
`{{.app.path.path}}` and `{{.app.path.basename}}`.

- **Add a cluster:** register it with the hub, so a cluster Secret's server
  matches its `cluster_server` (for example
  `argocd cluster add <kube-context> --name cluster-004`), then add
  `matrix/clusters/cluster-004/config.yaml`.
- **Add a base application:** add it under `matrix/apps/base/` and an overlay
  for it in every group under `matrix/groups/<group>/apps/`.
- **Add an addon to a cluster:** add `matrix/clusters/<cluster>/addons/<app>/kustomization.yaml`
  referencing `../../../../apps/addons/<app>`.

The result for the example clusters, 12 Applications:

| Cluster | Group | Base applications | Addons |
|---|---|---|---|
| cluster-001 | us-east | monitoring, ingress, logging | gpu-operator |
| cluster-002 | us-east | monitoring, ingress, logging | none |
| cluster-003 | eu-west | monitoring, ingress, logging | gpu-operator, edge-cache |

| For | Against |
|---|---|
| Two ApplicationSets for the whole fleet | The hub holds credentials for every cluster and is a single point of failure |
| Full Kustomize per group | Every base application needs an overlay per group |
| Adding a cluster is one `config.yaml` | Each cluster must also be registered with the hub |

## Approach 3: Lovely + charmap

`lovely/`. Every cluster runs its own Argo CD, installed with the same Helm
values (`lovely/argocd-values.yaml`). Cluster identity lives in the cluster,
in a `cluster-identity` Secret, not in Git. Every key of that Secret is a
token: manifests carry `<::GROUP::>`, `<::CLUSTER_NAME::>` or any other key
you add. A Config Management Plugin sidecar replaces them with
[charmap](https://github.com/ashtonian/charmap) and then renders with
[argocd-lovely-plugin](https://github.com/crumbhole/argocd-lovely-plugin),
which runs Kustomize or Helm as each directory needs.

```
lovely/
├── apps/
│   ├── base/                # every cluster; manifests use <::GROUP::>, <::CLUSTER_NAME::>
│   └── addons/              # addon definitions
├── groups/
│   ├── us-east/addons/gpu-operator/              # resources: ../../../../apps/addons/gpu-operator
│   └── eu-west/addons/{gpu-operator,edge-cache}/
├── bootstrap/               # rendered by the plugin through the fleet-bootstrap Application
│   ├── project.yaml         # AppProject "fleet"
│   └── applicationsets.yaml # fleet-base, fleet-group-addons
├── cmp/                     # the plugin sidecar image
│   ├── Dockerfile
│   └── plugin.yaml
├── argocd-values.yaml       # Argo CD Helm values, the same for every cluster
└── bootstrap-values.yaml    # argocd-apps values: the fleet-bootstrap Application
```

### How it fits together

1. Bootstrap creates the `cluster-identity` Secret and installs Argo CD with
   `lovely/argocd-values.yaml`, which adds the plugin sidecar. The sidecar
   loads every key of the Secret into its environment with a `FLEET_`
   prefix: key `GROUP` becomes `FLEET_GROUP`.
2. A second Helm release, the argocd-apps chart with
   `lovely/bootstrap-values.yaml`, creates the `fleet-bootstrap` Application.
   It is separate because a release cannot create Argo CD resources before
   it has installed their CRDs.
3. `fleet-bootstrap` renders `lovely/bootstrap` through the plugin, so the
   tokens in the ApplicationSets are replaced before the ApplicationSet
   controller reads them. The addon generator's path becomes
   `lovely/groups/us-east/addons/*` on a us-east cluster, and
   `<::REVISION::>` becomes the commit `fleet-bootstrap` resolved. A
   generator path is never rendered by a plugin on its own, so applying
   `applicationsets.yaml` directly would leave the tokens in place and match
   nothing.
4. The ApplicationSets generate `base-<app>` and `addon-<app>` Applications,
   pinned to that same commit. Each one names the plugin
   (`plugin.name: lovely-charmap`), which replaces the tokens in its
   manifests and renders them.

The plugin's `generate` script (`lovely/cmp/plugin.yaml`) stops on any
failure: an unset or empty `GROUP` or `CLUSTER_NAME`, an unknown or
malformed token, an invalid key name, or a rendering error. The Application
then shows the error, with the file, line and column of a bad token, and
nothing is applied. charmap replaces tokens across the whole `RENDER_ROOT`
directory (`lovely/`), not just the Application's own directory. Tokens in a
base referenced by relative path, such as the group addons'
`../../../../apps/addons/...`, are therefore replaced too. Every render works
on a private copy of the repository.

### Templated manifests

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monitoring
  labels:
    app: monitoring
    group: "<::GROUP::>"
    cluster: "<::CLUSTER_NAME::>"
```

Tokens are plain string substitution: the value is inserted as is, with no
YAML escaping, so keep values to simple strings. For structural differences
between groups, use Kustomize in the application's directory, or a
group-specific addon directory.

| For | Against |
|---|---|
| No per-cluster or per-group overlay directories | Needs the plugin sidecar image |
| Adding a cluster changes nothing in Git | String substitution only; structure needs Kustomize |
| Adding a base application is one directory | Addons are selected per group, not per cluster |
| Cluster identity can come from a secrets manager; adding a value needs no Git or image change | Rendered output exists only inside Argo CD; render it locally with the plugin image ([CI](#ci)) |

### Prerequisites

- **Kubernetes** 1.36 is tested. The plugin sidecar meets the restricted Pod
  Security Standard.
- **Argo CD** 3.5.4 (argo-cd chart 10.10.2) and the argocd-apps chart 2.0.6
  are tested. Other Argo CD 3.x releases are likely to work but are untested.
- **Helm** 3.8 or later, or Helm 4, and `kubectl` with cluster-admin rights
  to install Argo CD.
- **Network:** the repo-server needs HTTPS access to the Git repository
  (github.com for this one), and nodes need to pull
  `ghcr.io/ashtonian/argo-fleet-lovely-cmp` and the workloads' images.
- **A private repository** needs Argo CD repository credentials: a Secret
  labelled `argocd.argoproj.io/secret-type: repository` in `argocd`.
- Optional: [External Secrets](https://external-secrets.io/) to fill the
  identity Secret from a secrets manager.

### Try it in kind

Render every lovely Application locally, the way the sidecar does, with no
cluster (needs Docker, `yq`, `rsync` and `git`):

```sh
docker build -t fleet-cmp lovely/cmp
scripts/render-test.sh fleet-cmp rendered/   # rendered manifests land in rendered/
```

Install the whole fleet into a disposable kind cluster (needs `kind`,
`kubectl`, `helm` and `yq`). The script installs Argo CD into the current
context, so it refuses any context not named `kind-*`. The revision must be
a full commit SHA that exists on GitHub, since Argo CD fetches it from there:

```sh
kind create cluster --name fleet
scripts/e2e.sh "$(yq '.repoServer.extraContainers[0].image' lovely/argocd-values.yaml)" \
  "$(git ls-remote https://github.com/ashtonian/argo-fleet.git refs/heads/main | cut -f1)"
kind delete cluster --name fleet
```

### Bootstrapping a cluster

1. **Create the identity Secret** in the `argocd` namespace, before
   installing Argo CD, since the sidecar reads it at start:

   ```sh
   kubectl create namespace argocd
   kubectl -n argocd create secret generic cluster-identity \
     --from-literal=GROUP=us-east \
     --from-literal=CLUSTER_NAME=cluster-001
   ```

   Or have [External Secrets](https://external-secrets.io/) write it from a
   secrets manager:

   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: cluster-identity
     namespace: argocd
   spec:
     refreshInterval: 1h
     secretStoreRef:
       kind: ClusterSecretStore
       name: fleet
     target:
       name: cluster-identity
     # Every property of the entry becomes a key, and so a token:
     # {"GROUP": "us-east", "CLUSTER_NAME": "cluster-001", "REGION": "us-east-1"}
     dataFrom:
       - extract:
           key: fleet/cluster-identity
   ```

2. **Install Argo CD** with the shared values:

   ```sh
   helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
     --version 10.10.2 --namespace argocd --values lovely/argocd-values.yaml --wait
   ```

3. **Install the bootstrap**, with the revision this cluster follows (see
   [Staged rollout](#staged-rollout-and-rollback)):

   ```sh
   helm install fleet-bootstrap argocd-apps --repo https://argoproj.github.io/argo-helm \
     --version 2.0.6 --namespace argocd --values lovely/bootstrap-values.yaml \
     --set applications.fleet-bootstrap.source.targetRevision=main
   ```

4. `fleet-bootstrap` syncs, creates the `fleet` AppProject and the two
   ApplicationSets, and they create the cluster's Applications.

Check it with `kubectl -n argocd get applications`: on a us-east cluster
you see `fleet-bootstrap`, `base-ingress`, `base-logging`, `base-monitoring`
and `addon-gpu-operator`, all `Synced` and `Healthy`.

### Configuration reference

**Cluster identity** (Secret `cluster-identity` in `argocd`). Every key is a
token. Keys must match `[A-Za-z_][A-Za-z0-9_]*`; any other key fails every
render.

| Key | Required | Used for |
|---|---|---|
| `GROUP` | Yes, non-empty | Selects `lovely/groups/<GROUP>/addons/*`; the `group` label in the example manifests |
| `CLUSTER_NAME` | Yes, non-empty | The `cluster` label in the example manifests |
| any other key, e.g. `REGION` | No | Available as `<::REGION::>` in any manifest under `RENDER_ROOT` |
| `REVISION` | Reserved | Always the commit Argo CD resolved; a `REVISION` key is ignored |

**`lovely/argocd-values.yaml`** (argo-cd chart)

| Setting | Default | Description |
|---|---|---|
| `repoServer.extraContainers[0].image` | `ghcr.io/ashtonian/argo-fleet-lovely-cmp:<version>@sha256:…` | The plugin image. Keep it pinned by digest. |
| `…envFrom[0].prefix` | `FLEET_` | Prefix under which the Secret's keys enter the sidecar. `plugin.yaml` reads this prefix; change both together. |
| `…env RENDER_ROOT` | `lovely` | Directory, relative to the repository root, where tokens are replaced on every render. It must contain every file any Application uses. |
| `…env LOVELY_HELM_PATH` | unset (Helm 4) | Set to `/usr/local/bin/helm3` to render Helm charts with Helm 3, for every Application on the cluster. |
| `…resources` | requests 100m CPU, 256Mi memory, 1Gi ephemeral storage; limits 1Gi memory, 2Gi ephemeral storage | Sidecar resources. Raise memory for large Helm charts or many concurrent renders. |
| `repoServer.volumes` `lovely-charmap-tmp` | disk-backed `emptyDir`, `sizeLimit: 2Gi` | Scratch for per-render repository copies. |
| `configs.params."applicationsetcontroller.policy"` | `create-update` | ApplicationSets never delete Applications (see [Deletion safety](#deletion-safety)). |
| `configs.params."reposerver.plugin.tar.exclusions"` | `.git` | Paths not streamed to the plugin. Add large unused directories here. |

**`lovely/bootstrap-values.yaml`** (argocd-apps chart)

| Setting | Default | Description |
|---|---|---|
| `applications.fleet-bootstrap.source.targetRevision` | `main` | The revision this cluster follows: a branch, tag or commit. The one per-cluster rollout setting. |
| `applications.fleet-bootstrap.source.repoURL`, `projects.fleet-bootstrap.sourceRepos` | this repository | Where the fleet definition lives. |
| `applications.fleet-bootstrap.syncPolicy` | automated, no prune, 5 retries | Pruning is off: pruning an ApplicationSet deletes every Application it owns. |

**Inside the plugin** (`lovely/cmp/plugin.yaml`): it reads `FLEET_*`,
`RENDER_ROOT`, and Argo CD's `ARGOCD_APP_SOURCE_PATH`,
`ARGOCD_APP_REVISION`, `KUBE_VERSION` and `KUBE_API_VERSIONS`. It removes
every `ARGOCD_ENV_*` variable an Application sets before running anything.

### Using it in your own repository

1. **Copy `lovely/`, `scripts/` and `.github/`** into your repository. Drop
   `overlay/` and `matrix/`, and remove their `kubeconform` line from
   `.github/workflows/ci.yaml`.
2. **Point it at your repository.** The URL appears in
   `lovely/bootstrap/applicationsets.yaml` (4 times),
   `lovely/bootstrap/project.yaml` and `lovely/bootstrap-values.yaml` (twice):

   ```sh
   grep -rl 'https://github.com/ashtonian/argo-fleet.git' lovely |
     xargs sed -i.bak 's#https://github.com/ashtonian/argo-fleet.git#https://github.com/<you>/<repo>.git#g'
   find lovely -name '*.bak' -delete
   ```

   For a private repository, add Argo CD repository credentials (see
   [Prerequisites](#prerequisites)).
3. **The plugin image.** Keep using `ghcr.io/ashtonian/argo-fleet-lovely-cmp`
   as pinned, unless you change `lovely/cmp/plugin.yaml`. Then publish your
   own: set `IMAGE` in `.github/workflows/cmp-image.yaml`, push a
   `cmp-v<version>` tag, and pin the printed digest in
   `lovely/argocd-values.yaml`.
4. **Directory names.** If `lovely/` moves, set `RENDER_ROOT` and the paths in
   `lovely/bootstrap/applicationsets.yaml` and `lovely/bootstrap-values.yaml`.
5. **Replace the example workloads** in `lovely/apps` with your own. An
   application that needs CRDs, ClusterRoles or other cluster-scoped
   resources needs its own AppProject; `fleet` allows only Namespaces.
6. **Adjust the tests:** `scripts/render-test.sh` checks the example groups,
   clusters and labels, and `scripts/e2e.sh` the example Application names.

### Day-2 operations

Every change below reaches a cluster when its `fleet-bootstrap` revision
includes it (see [Staged rollout](#staged-rollout-and-rollback)).

- **Add a base application:** create `lovely/apps/base/<app>/` with a
  `kustomization.yaml` and its manifests. Every cluster gets `base-<app>` in
  namespace `<app>`.
- **Add an addon:** define it in `lovely/apps/addons/<app>/`, then select it
  for a group with `lovely/groups/<group>/addons/<app>/kustomization.yaml`
  containing `resources: [../../../../apps/addons/<app>]`. Clusters in that
  group get `addon-<app>`.
- **Add a group:** set `GROUP` to the new name in the clusters' identity, and
  create `lovely/groups/<group>/addons/` with its addons. A group without
  addons needs no directory; its clusters get only the base applications.
- **Give one cluster different addons:** give it a group of its own (for
  example `us-east-gpu`) with its own addon selection.
- **Add an identity value:** add the key to the cluster's Secret (or its
  secrets-manager entry), then follow [Changing a cluster's
  identity](#changing-a-clusters-identity). Add the key to every cluster
  before merging manifests that use it: a cluster without it fails to render
  them, and changes nothing, until it has it.
- **Retire an application:** see [Deletion safety](#deletion-safety).

#### Changing a cluster's identity

The sidecar reads the Secret when it starts, and Argo CD's manifest cache key
does not include the sidecar's environment. After changing the Secret:

1. Restart the repo-server: `kubectl -n argocd rollout restart deployment argocd-repo-server`.
2. Hard-refresh every Application so it re-renders:

   ```sh
   kubectl -n argocd get applications -o name |
     xargs -I{} kubectl -n argocd annotate {} argocd.argoproj.io/refresh=hard --overwrite
   ```

When a cluster moves to another group, the new group's addons are created,
but the old group's addons stay, because ApplicationSets never delete. Remove
them on purpose ([Deletion safety](#deletion-safety)).

### Staged rollout and rollback

A cluster has one setting for what it runs: the `targetRevision` of its
`fleet-bootstrap` Application, a branch, tag or commit. The plugin replaces
`<::REVISION::>` with the commit `fleet-bootstrap` resolved, so the
ApplicationSets, and every Application they generate, are pinned to that
exact commit. A cluster therefore always runs one consistent snapshot of
the repository, even while the branch it follows moves.

- **Rings.** Give each ring its own revision: canary clusters a branch or
  the newest release tag, stable clusters the previous tag. To promote,
  `helm upgrade fleet-bootstrap` on the next ring with the new revision.
- **Rollback.** Set the revision back to the previous tag or commit.
- **One cluster.** Run `helm upgrade` on that cluster only:

  ```sh
  helm upgrade fleet-bootstrap argocd-apps --repo https://argoproj.github.io/argo-helm \
    --version 2.0.6 --namespace argocd --values lovely/bootstrap-values.yaml \
    --set applications.fleet-bootstrap.source.targetRevision=v1.4.0
  ```

A new revision re-renders `fleet-bootstrap`, which re-pins the
ApplicationSets, which update their Applications. No manual refresh is
needed.

### The plugin sidecar image

`lovely/cmp/Dockerfile` builds `ghcr.io/ashtonian/argo-fleet-lovely-cmp`
from the argocd-lovely-plugin CMP image, adding charmap and
`lovely/cmp/plugin.yaml`. Both bases are pinned by digest. The binaries and
the pipeline that runs them ship as one image: a plugin change rolls the
repo-server pod, and nothing is copied in at pod start. Published versions
are listed under [Releases](https://github.com/ashtonian/argo-fleet/releases).

The image renders Helm charts with Helm 4, as argocd-lovely-plugin 2 does,
and ships Helm 3 as `/usr/local/bin/helm3` (see `LOVELY_HELM_PATH` in the
[configuration reference](#configuration-reference)). Applications cannot
choose it themselves, because the plugin ignores their `plugin.env`.

The sidecar runs as UID 999 with a read-only root filesystem, no
capabilities and the RuntimeDefault seccomp profile. It meets the restricted
Pod Security Standard, which the CI end-to-end test enforces. Its scratch
space is a disk-backed `emptyDir` limited to 2 GiB.

### Troubleshooting

Start with the Application's conditions; a render error names the file,
line and column:

```sh
kubectl -n argocd get applications
kubectl -n argocd get application <name> \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

| Symptom | Check | Then |
|---|---|---|
| repo-server pod in `CreateContainerConfigError` | `kubectl -n argocd get secret cluster-identity` | Create the Secret, then let the pod restart. |
| `ComparisonError: … FLEET_GROUP: parameter null or not set` | `kubectl -n argocd exec deploy/argocd-repo-server -c lovely-charmap -- env \| grep '^FLEET_'` | Set a non-empty `GROUP` (or `CLUSTER_NAME`) in the Secret, then [restart and refresh](#changing-a-clusters-identity). |
| `ComparisonError: … no value for KEY` | The same command: is `FLEET_KEY` there? | Add the key to the Secret, then restart and refresh. A new key needs the restart. |
| `ComparisonError: … is not a valid key` | The Secret's key names | Rename keys to `[A-Za-z_][A-Za-z0-9_]*`. |
| `ComparisonError: … malformed token` | The reported file, line and column | Fix the token. The file may belong to another Application: every file under `RENDER_ROOT` is checked. |
| `could not find cmp-server plugin with name "lovely-charmap"` | `kubectl -n argocd get pod -l app.kubernetes.io/component=repo-server -o jsonpath='{.items[0].status.containerStatuses[*].name}'` | The `lovely-charmap` container must be running; check its logs below. |
| Addons missing on a cluster | `kubectl -n argocd get applicationset fleet-group-addons -o jsonpath='{.spec.generators[0].git.directories[0].path}'` | The path must name an existing `lovely/groups/<group>` directory at the pinned revision. |
| An ApplicationSet generates nothing | `kubectl -n argocd get applicationset -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status} {.message}; {end}{"\n"}{end}'` | An `ErrorOccurred` condition names the cause. |
| Old values after changing the Secret | — | [Restart and refresh](#changing-a-clusters-identity); the render cache ignores the sidecar's environment. |
| A sync keeps failing | `kubectl -n argocd get application <name> -o jsonpath='{.status.operationState.message}'` | Fix the cause. Automated sync retries 5 times with backoff, then waits for the next change. |

Plugin logs: `kubectl -n argocd logs deploy/argocd-repo-server -c lovely-charmap`.
To reproduce a render exactly, run `scripts/render-test.sh` against the
pinned image ([Try it in kind](#try-it-in-kind)).

### Monitoring

Argo CD's metrics cover the fleet; scrape the application controller and
ApplicationSet controller (the chart's `metrics` settings). Useful signals:

- `argocd_app_info` by `sync_status` and `health_status`: alert when an
  Application stays `OutOfSync` or not `Healthy`.
- `argocd_app_condition` by `condition`: alert on `ComparisonError`, which
  is how every render failure shows up.
- `argocd_appset_info` and `argocd_appset_reconcile`: ApplicationSet status
  and reconcile errors.
- `kube_pod_container_status_restarts_total` for the `lovely-charmap`
  container (kube-state-metrics).

Alert on a drop in the number of Applications on a cluster too: with
`create-update` nothing deletes them, so a drop means someone did.

### Upgrading

- **Argo CD:** change the chart version in the [bootstrap
  commands](#bootstrapping-a-cluster), in CI (`ARGO_CD_CHART_VERSION` in
  `.github/workflows/ci.yaml`) and in the default in `scripts/e2e.sh`, let
  CI's end-to-end test pass, then `helm upgrade argocd` ring by ring.
- **The plugin image** (argocd-lovely-plugin, charmap): Dependabot proposes
  new base digests in `lovely/cmp/Dockerfile`, and CI builds and tests the
  image on the pull request. After merging, push a `cmp-v<version>` tag, pin
  the printed digest in `lovely/argocd-values.yaml`, and roll it out with
  `helm upgrade argocd` ring by ring. A major argocd-lovely-plugin version
  can change how Helm charts render; read its release notes.
- **GitHub Actions:** Dependabot proposes updates to the pinned actions.

### Limitations

- **Per-group addon selection.** A per-cluster exception needs a group of one.
- **String substitution only.** Structural differences need Kustomize.
- **Identity changes need a restart and a hard refresh**, because the render
  cache ignores the sidecar's environment.
- **Every file under `RENDER_ROOT` must render** for every cluster: one bad
  token fails every Application on the clusters that see it.
- **One repository per fleet**, polled by every cluster (see [Scale](#scale)).
- **The example workloads are placeholders** (`busybox` printing a message).

## Deletion safety

A shrinking generator result must not delete workloads. A directory rename,
a deleted `config.yaml` or a mistyped group would otherwise remove
applications from every affected cluster. So:

- Every ApplicationSet sets `applicationsSync: create-update` (it never
  deletes Applications) and `preserveResourcesOnDeletion: true` (its
  Applications carry no resources finalizer).
- The lovely values also set `applicationsetcontroller.policy: create-update`
  on the controller, which overrides any ApplicationSet's own policy.
- `goTemplateOptions: ["missingkey=error"]` makes a missing parameter an
  error instead of an empty string.
- `fleet-bootstrap` does not prune, since pruning an ApplicationSet would
  delete every Application it owns.

To retire an application, remove its directory, then delete its Application
together with its resources: `argocd app delete <name> --cascade`, or with
kubectl, add the resources finalizer and delete:

```sh
kubectl -n argocd patch application <name> --type merge \
  -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
kubectl -n argocd delete application <name>
```

## Scale

Directory count is one cost. Others grow with the number of clusters
whatever the layout:

- **Git polling.** Every Argo CD instance polls the repository: by default
  ApplicationSet generators every 3 minutes, and Applications every 2
  minutes plus up to 1 minute of jitter. At even one fetch per instance in
  that window, 10,000 clusters make 55 to 83 fetches per second. GitHub
  [recommends at most 15 Git read operations per second](https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits)
  per repository. Beyond a few hundred clusters, serve the repository from
  read-only mirrors near the clusters, or publish releases as OCI artifacts.
  Use a webhook relay rather than shorter polling intervals.
- **Rendering.** Each render through the plugin streams the repository to
  the sidecar. The values exclude `.git`; keep the rest of the repository
  small, or exclude more with `reposerver.plugin.tar.exclusions`.
- **Applications.** Each cluster's Argo CD reconciles only its own
  Applications, so per-cluster cost stays flat. Fleet-wide cost is linear
  in clusters × applications.

## Security

- **Repository writers deploy to every cluster.** Protect the default
  branch and the revisions clusters follow; staged rollout limits how many
  clusters a bad change reaches before it is caught.
- **Identity Secret writers** decide what every token on that cluster
  becomes, and which group's addons it runs. Restrict write access to the
  Secret and to its secrets-manager entry.
- **AppProjects** limit what the generated Applications can do: `fleet`,
  `overlay` and `matrix` allow only this repository as a source, refuse the
  `argocd` and `kube-*` namespaces, and allow no cluster-scoped resource
  except a Namespace. `fleet-bootstrap` may only manage the fleet's
  AppProject and ApplicationSets. An operator that needs CRDs or
  ClusterRoles belongs in its own project.
- **Identity values** end up in rendered manifests and Argo CD's UI. Do not
  put secrets in the `cluster-identity` Secret; deliver workload secrets to
  their namespaces directly, for example with External Secrets.
- **The plugin** substitutes only the Secret's keys and `REVISION` (the
  resolved commit); charmap reads nothing else from the environment.
  argocd-lovely-plugin would also accept settings, including commands to
  run, from an Application's `plugin.env`; the `generate` script drops every
  Application-supplied variable first, so only the sidecar's own
  configuration applies.

## Group overrides

Approach 2 uses a Kustomize overlay per group, with full structural power
(patches, replicas, resources, images):

```yaml
# matrix/groups/us-east/apps/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../../apps/base/monitoring
patches:
  - target:
      kind: Deployment
      name: monitoring
    patch: |-
      - op: add
        path: /metadata/labels/group
        value: us-east
```

Approach 3 does the same for string values with a token in the base
manifest, and needs no overlay:

```yaml
# lovely/apps/base/monitoring/deployment.yaml
metadata:
  labels:
    group: "<::GROUP::>"
```

## CI

`.github/workflows/ci.yaml` runs on every pull request and push to `main`:

- **static**: actionlint; shellcheck on the scripts and the plugin's
  `generate` script; `kustomize build` of every application; ApplicationSets,
  AppProjects and the bootstrap release validated against Argo CD's CRD
  schemas.
- **render**: builds the plugin image and runs `scripts/render-test.sh`.
  That renders every lovely Application inside the image, for a us-east and
  an eu-west identity, with a read-only root filesystem as in the sidecar, and
  validates the output. It fails on any error or leftover token, and checks
  that the bootstrap pins both ApplicationSets to the resolved commit. It
  also checks that an empty identity, an invalid key name or an unknown
  token stops the render with no output, that any extra identity key fills
  its token, and that plugin environment set by an Application is ignored.
- **e2e**: `scripts/e2e.sh` installs Argo CD with `lovely/argocd-values.yaml`
  and the bootstrap with `lovely/bootstrap-values.yaml` into a kind cluster
  whose `argocd` namespace enforces the restricted Pod Security Standard. It
  checks that the fleet comes up from the commit under test: the expected
  Applications, synced and healthy, with the identity and revision on the
  workloads.

`.github/workflows/cmp-image.yaml` publishes the plugin image on a
`cmp-v<version>` tag, after checking each platform runs its own charmap.
Dependabot (`.github/dependabot.yml`) proposes updates to the actions and the
plugin image's bases.

## Repository layout

| Path | Contents |
|---|---|
| `overlay/` | Approach 1: base applications, per-cluster overlays, AppProject and ApplicationSet |
| `matrix/` | Approach 2: base applications and addons, group overlays, cluster configs, AppProject and ApplicationSets |
| `lovely/apps`, `lovely/groups` | Approach 3: templated base applications, addon definitions, addon selection per group |
| `lovely/bootstrap` | The fleet AppProject and ApplicationSets, rendered through the plugin |
| `lovely/cmp` | The plugin sidecar image and its `generate` pipeline |
| `lovely/argocd-values.yaml` | Argo CD Helm values for every lovely cluster |
| `lovely/bootstrap-values.yaml` | argocd-apps values: the `fleet-bootstrap` Application and its AppProject |
| `scripts/render-test.sh` | Renders every lovely Application in the plugin image |
| `scripts/e2e.sh` | Installs and checks the lovely fleet in a disposable kind cluster |
| `.github/workflows/` | CI and the plugin image release |
| `.github/dependabot.yml` | Update proposals for actions and the plugin image's bases |
