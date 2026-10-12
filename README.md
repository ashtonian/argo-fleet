# Argo CD fleet patterns

Three ways to run the same applications across a fleet of Kubernetes
clusters with Argo CD ApplicationSets, from one Git repository: base
applications on every cluster, per-group overrides, and addons on selected
clusters.

| | [Overlay](#approach-1-overlay) | [Matrix](#approach-2-matrix) | [Lovely + charmap](#approach-3-lovely--charmap) |
|---|---|---|---|
| **Topology** | Argo CD in every cluster | One hub Argo CD deploying to every cluster | Argo CD in every cluster |
| **Mechanism** | Git directory generator over a per-cluster directory | Matrix of a per-cluster `config.yaml` and per-group Kustomize overlays | Git directory generators; cluster identity substituted into manifests by a Config Management Plugin |
| **Cluster identity** | The cluster's directory path, set in its ApplicationSet | `matrix/clusters/<cluster>/config.yaml` | A `cluster-identity` Secret in the cluster (can come from a secrets manager) |
| **Base applications** | Listed per cluster | All, through the cluster's group overlay | All |
| **Group overrides** | Patches in each cluster's overlays | Kustomize overlay per group and application | `<::GROUP::>` tokens in manifests; Kustomize for structure |
| **Addon selection** | Per cluster (directory presence) | Per cluster (directory presence) | Per group (directory presence) |
| **Add a cluster** | A directory per application, plus an ApplicationSet | One `config.yaml`, plus registering the cluster with the hub | Install Argo CD with the shared values and a Secret; no Git change |
| **Add a base application** | A directory in every cluster | A directory in every group | One directory |
| **Per-cluster exceptions** | Yes | Yes (addons) | No; selection is per group |

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

To add an application to a cluster, add its overlay directory. To patch it
for one cluster, add a patch to that overlay.

| For | Against |
|---|---|
| Plain Kustomize, easy to read | A directory per application per cluster |
| Any per-cluster patch | Each cluster needs its own ApplicationSet path |
| | Shared changes touch every cluster's directory |

## Approach 2: Matrix

`matrix/`. A hub-and-spoke layout: one Argo CD instance deploys to every
cluster listed under `matrix/clusters/`. Each of those clusters must be
registered with the hub (a cluster Secret whose server matches
`cluster_server` in its `config.yaml`). Installing these ApplicationSets in
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
in a `cluster-identity` Secret, not in Git. Manifests carry
`<::GROUP::>` and `<::CLUSTER_NAME::>` tokens. A Config Management Plugin
sidecar replaces them with
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
   `lovely/argocd-values.yaml`, which adds the plugin sidecar. The sidecar's
   environment holds `GROUP` and `CLUSTER_NAME` from the Secret.
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
   pinned to that same commit. Each one names the plugin (`plugin.name: lovely-charmap`), which replaces
   the tokens in its manifests and renders them.

The plugin's `generate` script (`lovely/cmp/plugin.yaml`) stops on any
failure: an unset or empty identity value, an unknown or malformed token, or
a rendering error. The Application then shows the error, with the file,
line and column of a bad token, and nothing is applied. charmap replaces
tokens across the whole `fleet.renderRoot` directory (`lovely/`), not just
the Application's own directory. Tokens in a base referenced by relative
path, such as the group addons' `../../../../apps/addons/...`, are therefore
replaced too. Every render works on a private copy of the repository.

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

Tokens are plain string substitution. For structural differences between
groups, use Kustomize in the application's directory, or a group-specific
addon directory.

| For | Against |
|---|---|
| No per-cluster or per-group overlay directories | Needs the plugin sidecar image |
| Adding a cluster changes nothing in Git | String substitution only; structure needs Kustomize |
| Adding a base application is one directory | Addons are selected per group, not per cluster |
| Cluster identity can come from a secrets manager | Rendered output exists only inside Argo CD; diff it with the plugin image (see CI) |

## Bootstrapping a cluster (lovely)

1. **Create the identity Secret** in the `argocd` namespace, before
   installing Argo CD, since the sidecar reads it at start:

   ```sh
   kubectl create namespace argocd
   kubectl -n argocd create secret generic cluster-identity \
     --from-literal=group=us-east \
     --from-literal=cluster-name=cluster-001
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
     data:
       - secretKey: group
         remoteRef: {key: fleet/cluster-identity, property: group}
       - secretKey: cluster-name
         remoteRef: {key: fleet/cluster-identity, property: cluster-name}
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
and `addon-gpu-operator`.

## The plugin sidecar image

`lovely/cmp/Dockerfile` builds `ghcr.io/ashtonian/argo-fleet-lovely-cmp`
from the argocd-lovely-plugin CMP image, adding charmap and
`lovely/cmp/plugin.yaml`. The binaries and the pipeline that runs them ship
as one image: a plugin change rolls the repo-server pod, and nothing is
copied in at pod start.

To publish, push a tag `cmp-v<version>` (for example `cmp-v1.0.1`). The
`CMP image` workflow builds linux/amd64 and linux/arm64, checks each runs a
charmap built for its platform, and prints the digest. Pin
`repoServer.extraContainers[0].image` in `lovely/argocd-values.yaml` to it.

The image renders Helm charts with Helm 4, as argocd-lovely-plugin 2 does.
For charts that still need Helm 3, set `LOVELY_HELM_PATH=/usr/local/bin/helm3`
in the sidecar's `env` in `lovely/argocd-values.yaml`. It applies to every
Application on the cluster: Applications cannot choose it themselves,
because the plugin ignores their `plugin.env` (see [Security](#security)).

The sidecar runs as UID 999 with a read-only root filesystem, no
capabilities and the RuntimeDefault seccomp profile. It meets the restricted
Pod Security Standard, which the CI end-to-end test enforces. Its scratch
space is a disk-backed `emptyDir` limited to 2 GiB.

## Staged rollout and rollback

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

## Changing a cluster's identity

`GROUP` and `CLUSTER_NAME` are read from the Secret when the sidecar
starts, and Argo CD's manifest cache key does not include the sidecar's
environment. After changing the Secret:

1. Restart the repo-server: `kubectl -n argocd rollout restart deployment argocd-repo-server`.
2. Hard-refresh every Application so it re-renders:

   ```sh
   kubectl -n argocd get applications -o name |
     xargs -I{} kubectl -n argocd annotate {} argocd.argoproj.io/refresh=hard --overwrite
   ```

When a cluster moves to another group, the new group's addons are created,
but the old group's addons stay, because ApplicationSets never delete
(below). Remove them on purpose.

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

To retire an application: remove its directory, then delete its
Application together with its resources with
`argocd app delete <name> --cascade`.

## Failure behaviour (lovely)

| What goes wrong | What you see | What is applied |
|---|---|---|
| `cluster-identity` missing a key | The repo-server pod does not start (`CreateContainerConfigError`) | Nothing changes |
| Identity value empty | Application `ComparisonError`: `GROUP: parameter null or not set` | Nothing changes |
| Unknown or malformed token anywhere under `fleet.renderRoot` | Application `ComparisonError` naming `path:line:column` | Nothing changes |
| Plugin sidecar missing or misnamed | Application `ComparisonError`: plugin not found | Nothing changes; no fallback renderer |
| Generator matches nothing (typo, rename) | Fewer Applications generated | Existing Applications and resources stay |
| A sync fails | Retried 5 times with backoff up to 5 minutes, then shown as failed | The previous state stays |

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
- **AppProjects** limit what the generated Applications can do: `fleet`,
  `overlay` and `matrix` allow only this repository as a source, refuse the
  `argocd` and `kube-*` namespaces, and allow no cluster-scoped resource
  except a Namespace. `fleet-bootstrap` may only manage the fleet's
  AppProject and ApplicationSets. An operator that needs CRDs or
  ClusterRoles belongs in its own project.
- **Identity values** end up in rendered manifests and Argo CD's UI. Do not
  put secrets in the `cluster-identity` Secret; deliver workload secrets to
  their namespaces directly, for example with External Secrets.
- **The plugin** substitutes only `GROUP`, `CLUSTER_NAME` and `REVISION`
  (the resolved commit);
  charmap reads nothing else from the environment. argocd-lovely-plugin
  would also accept settings, including commands to run, from an
  Application's `plugin.env`; the `generate` script drops every
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
  `generate` script; `kustomize build` of every application; ApplicationSets
  and AppProjects validated against Argo CD's CRD schemas.
- **render**: builds the plugin image and runs `scripts/render-test.sh`.
  That renders every lovely Application inside the image, for a us-east and
  an eu-west identity, with a read-only root filesystem as in the sidecar. It
  fails on any error or leftover token. It also checks that an empty
  identity or an unknown token stops the render with no output, and
  validates the rendered manifests.
- **e2e**: `scripts/e2e.sh` installs Argo CD with `lovely/argocd-values.yaml`
  and the bootstrap with `lovely/bootstrap-values.yaml`
  into a kind cluster whose `argocd` namespace enforces the restricted Pod
  Security Standard. It checks that the fleet comes up from the commit under
  test: the expected Applications, synced and healthy, with the identity and
  revision on the workloads.

`.github/workflows/cmp-image.yaml` publishes the plugin image (see above).

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
| `scripts/e2e.sh` | Installs and checks the lovely fleet in a disposable cluster |

The example workloads are placeholder Deployments (`busybox` printing a
message), there to show delivery, not working monitoring, ingress or GPU
operators.
