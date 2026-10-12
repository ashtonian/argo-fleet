# Argo CD fleet patterns

[![CI](https://github.com/ashtonian/argo-fleet/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/ashtonian/argo-fleet/actions/workflows/ci.yaml)
[![Plugin image](https://img.shields.io/github/v/release/ashtonian/argo-fleet?label=plugin%20image)](https://github.com/ashtonian/argo-fleet/releases/latest)

Four ways to run the same applications across a fleet of Kubernetes
clusters with Argo CD ApplicationSets, from one Git repository: base
applications on every cluster, per-group overrides, and addons on selected
clusters. The choices are weighed for fleets of one cluster, a few hundred,
and 10,000. Five more patterns, which need more repositories or other
tooling, are compared under [Other patterns](#other-patterns).

Tested with Argo CD 3.5.4 (argo-cd chart 10.10.2, argocd-apps chart 2.0.6,
bundled Kustomize 5.8.1) on Kubernetes 1.36, External Secrets 2.12.0,
argocd-lovely-plugin 2.0.0 and [charmap](https://github.com/ashtonian/charmap)
2.0.0. On every change, CI installs the lovely and native approaches into
kind clusters, the native one with External Secrets delivering the identity.
The overlay and matrix manifests are built and validated against Argo CD's
schemas.

## Contents

- [Which one?](#which-one)
  - [By fleet size](#by-fleet-size)
  - [What each approach costs](#what-each-approach-costs)
  - [Directories to maintain](#directories-to-maintain)
- [The fleet identity](#the-fleet-identity)
  - [The cluster Secret](#the-cluster-secret)
  - [Seed and handover](#seed-and-handover)
  - [Rings and revisions](#rings-and-revisions)
- [Approach 1: Overlay](#approach-1-overlay)
- [Approach 2: Matrix](#approach-2-matrix)
- [Approach 3: Lovely + charmap](#approach-3-lovely--charmap)
  - [Templated manifests](#templated-manifests)
  - [Prerequisites](#prerequisites)
  - [Try it in kind](#try-it-in-kind)
  - [Bootstrapping a cluster](#bootstrapping-a-cluster)
  - [Configuration reference](#configuration-reference)
  - [Using it in your own repository](#using-it-in-your-own-repository)
  - [Day-2 operations](#day-2-operations)
  - [The plugin sidecar image](#the-plugin-sidecar-image)
  - [Troubleshooting](#troubleshooting)
  - [Upgrading](#upgrading)
  - [Limitations](#limitations)
- [Approach 4: Native Kustomize](#approach-4-native-kustomize)
  - [Values in manifests](#values-in-manifests)
  - [Group Components](#group-components)
  - [Prerequisites (native)](#prerequisites-native)
  - [Try it in kind (native)](#try-it-in-kind-native)
  - [Bootstrapping a cluster (native)](#bootstrapping-a-cluster-native)
  - [Configuration reference (native)](#configuration-reference-native)
  - [Using it in your own repository (native)](#using-it-in-your-own-repository-native)
  - [Day-2 operations (native)](#day-2-operations-native)
  - [Troubleshooting (native)](#troubleshooting-native)
  - [Upgrading (native)](#upgrading-native)
  - [Limitations (native)](#limitations-native)
- [Other patterns](#other-patterns)
- [Deletion safety](#deletion-safety)
- [Scale](#scale)
- [Monitoring](#monitoring)
- [Security](#security)
- [Group overrides](#group-overrides)
- [CI](#ci)
- [Repository layout](#repository-layout)

## Which one?

- **Native Kustomize** for most fleets where every cluster runs its own Argo
  CD. There is nothing to run besides Argo CD, and a bad file breaks only its
  own application.
- **Lovely + charmap** when manifests need many values inside strings, such
  as URLs and lines of embedded configuration files, where Kustomize cannot
  reach. It costs a plugin image to maintain.
- **Matrix**, or a [hub with cluster labels](#other-patterns), when one
  central Argo CD manages every cluster and the fleet stays in the hundreds.
- **Overlay** for a handful of clusters that each need their own patches.
- **A repository per group** when ownership or approvals differ by group,
  and **rendered manifests** when the exact YAML must be reviewed; see
  [Other patterns](#other-patterns).

Lovely and native share the rest. Each cluster's identity, values, addon
list and revision live on its own Argo CD registration
([the fleet identity](#the-fleet-identity)), written from a secrets manager.
Clusters join with no Git change, changes apply on their own, and rings
promote with one write.

| | [Overlay](#approach-1-overlay) | [Matrix](#approach-2-matrix) | [Lovely + charmap](#approach-3-lovely--charmap) | [Native Kustomize](#approach-4-native-kustomize) |
|---|---|---|---|---|
| **Topology** | Argo CD in every cluster | One hub Argo CD deploying to every cluster | Argo CD in every cluster | Argo CD in every cluster |
| **Mechanism** | Git directory generator over a per-cluster directory | Matrix of a per-cluster `config.yaml` and per-group Kustomize overlays | Cluster generator crossed with Git directories; values substituted by a Config Management Plugin | Cluster generator crossed with Git directories; Argo CD's built-in Kustomize, with components, labels and a patch per Application |
| **Cluster identity lives in** | The cluster's directory path, set in its ApplicationSet | `matrix/clusters/<cluster>/config.yaml` | The cluster's Argo CD registration Secret | The cluster's Argo CD registration Secret |
| **Per-cluster Git state** | A directory per application | A `config.yaml`, and a directory per addon | None | None |
| **Base applications** | Listed per cluster | All, through the cluster's group overlay | All | All |
| **Group overrides** | Patches in each cluster's overlays | Kustomize overlay per group and application | A Kustomize Component per group, chosen by a `<::GROUP::>` token | A Kustomize Component per group, added by each Application |
| **Values in manifests** | Patches | Patches | A `<::KEY::>` token anywhere in a file | A `fleet-identity` ConfigMap: environment variables, or a replacement per field |
| **New value with no Git change** | No | No | Yes | Adding it, yes; its first use in a manifest is a Git change |
| **Identity change takes effect** | On merge | On merge | On its own | On its own |
| **Addon selection** | Per cluster (directory presence) | Per cluster (directory presence) | Per cluster (an annotation listing them) | Per cluster (an annotation listing them) |
| **Add a cluster** | A directory per application, plus an ApplicationSet | One `config.yaml`, plus registering the cluster with the hub | Install Argo CD with the shared values and a cluster Secret; no Git change | Install Argo CD with the shared values and a cluster Secret; no Git change |
| **Add a base application** | A directory in every cluster | A directory in every group | One directory | One directory |
| **Per-cluster exceptions** | Yes | Yes (addons) | Addons and values per cluster; structure through a group of one | Addons and values per cluster; structure through a group of one |
| **Rollout** | Edit each cluster's revision | All clusters at once from the hub | Per cluster or ring, a revision pulled from the secrets manager | Per cluster or ring, a revision pulled from the secrets manager |
| **Extra component to run** | None | None | The plugin sidecar image | None |
| **A bad file breaks** | That application | That application | Every application on the clusters that see it | That application; a bad group Component, every application in that group |
| **Rendered output to diff** | `kustomize build` | `kustomize build` | Needs the plugin image ([how](#try-it-in-kind)) | `kustomize build` with the Application's settings ([how](#try-it-in-kind-native)) |

### By fleet size

What each decision should be for one cluster, a few hundred, and 10,000.
Numbers assume 20 base applications, 2 addons per cluster, and Argo CD's
default 3-minute refresh.

| Decision | 1 cluster | Hundreds | 10,000 |
|---|---|---|---|
| **Approach** | Any. Lovely if manifests are full of values inside strings, such as private details kept out of a public repository | Native; lovely for string-heavy manifests | Native; lovely for string-heavy manifests. Nothing that keeps per-cluster state in Git |
| **Topology** | Argo CD in the cluster | Argo CD in every cluster. A hub still works with sharding (300 × 22 ≈ 6,600 Applications) | Argo CD in every cluster. A hub would reconcile 220,000 Applications and hold every cluster's credentials |
| **Revision** | A branch is fine | Commits or tags | Full commit SHAs only. Argo CD resolves a branch or tag with a Git request every 3 minutes on every cluster: about 56 a second, against GitHub's guidance of 15 per repository. A full SHA needs no request, and its renders are cached |
| **Promotion** | Change the cluster's revision | One write per ring ([rings](#rings-and-revisions)) | One write per ring, with rings that grow, for example 10, 100, 1,000, then the rest, each gated on the previous ring's health ([monitoring](#monitoring)) |
| **Promotion bursts** | — | Direct from the Git host | A ring of 5,000 clusters picks up a new revision within the 5-minute refresh: at least 17 fetches a second. Serve the repository from mirrors, or publish each revision as an OCI artifact ([Scale](#scale)) |
| **Identity delivery** | By hand or by the provisioner | The provisioner writes the seed; External Secrets keeps it current ([seed and handover](#seed-and-handover)) | The same, with the provisioner and the secrets-manager entries fed from one inventory, and workload identity instead of a stored secret for the secret store |
| **Secrets-manager reads** | — | 300 clusters × 2 entries every 5 minutes: 2 a second | 10,000 × 2 every 5 minutes: about 67 a second. Check the provider's quota |
| **Per-cluster exceptions** | — | Addons and values as data; structure through a group of one | The same. Each group of one is a Component in Git, so keep them rare |
| **Fleet visibility** | Argo CD's UI | Central metrics with a cluster label | Central metrics, and each Application's revision label for promotion gates |
| **Directories in Git** | Any | Native 31, lovely 30; matrix 1,025 at 300 clusters | Native 31, lovely 30; matrix 30,125, overlay 220,025 |

### What each approach costs

Everything to maintain or run besides the applications themselves, for 20
base applications, 5 addons, 5 groups, an average of 2 addons per cluster,
and N clusters:

| | Overlay | Matrix | Lovely + charmap | Native Kustomize |
|---|---|---|---|---|
| **Repositories** | 1 | 1 | 1 | 1 |
| **Git, per cluster** | 22 overlay directories, and a copy of the ApplicationSet | A `config.yaml` and 2 addon directories | Nothing | Nothing |
| **Git, per group** | Nothing | 20 overlays, one per base application | One Component, usually one file | One Component, usually one file |
| **Git, per base application** | A directory in every cluster that runs it | A directory, and an overlay in every group | One directory | One directory |
| **Git, per value** | A patch in each cluster's overlays | A patch in each group's overlays | A token where it is used | A reference where it is used: one `envFrom` for every value as environment variables; a replacement per other field |
| **State outside Git, per cluster** | The applied ApplicationSet | A registration on the hub | A cluster Secret | A cluster Secret |
| **Runs besides Argo CD** | Nothing | Nothing; one Argo CD for the whole fleet, holding every cluster's credentials | A plugin sidecar in every repo-server, from an image to build, publish, pin by digest and upgrade | Nothing |
| **Templating logic to own** | None | Generator templates | Go templates in the ApplicationSets, the plugin's `generate` script, and charmap's token rules | Go templates in the ApplicationSets: identity checks, the addon list, values |
| **To apply an identity change** | A commit | A commit | Change the Secret | Change the Secret |
| **CI to keep green** | `kustomize build` | `kustomize build` | The plugin image build, a render test inside it, a kind test | `kustomize build` the way Argo CD runs it, a kind test |

Lovely and native keep per-cluster state out of Git, so it has to live
somewhere else. Writing it from a secrets manager means an entry per
cluster, and External Secrets (or another writer) running on every cluster.
That is the price of joining clusters with no Git change, not of either
approach.

### Directories to maintain

Counting every application directory (each a `kustomization.yaml`) and
per-cluster directory, for the same fleet:

| Clusters | Overlay | Matrix | Lovely | Native |
|---|---|---|---|---|
| 10 | 245 | 155 | 30 | 31 |
| 500 | 11,025 | 1,625 | 30 | 31 |
| 10,000 | 220,025 | 30,125 | 30 | 31 |

<details>
<summary>How the numbers are derived</summary>

| Component | Overlay | Matrix | Lovely | Native |
|---|---|---|---|---|
| Application definitions (20 base + 5 addons) | 25 | 25 | 25 | 25 |
| Group overlays (5 groups × 20 base) | | 100 | | |
| Group Components (5) | | | 5 | 5 |
| The identity Component | | | | 1 |
| Per cluster | 20 base + 2 addons = 22 | `config.yaml` directory + 2 addons = 3 | 0 | 0 |
| **Total for N clusters** | 25 + 22N | 125 + 3N | 30 | 31 |

Lovely and native move per-cluster state out of Git into a Secret in each
cluster, so their counts do not grow with the fleet. The Secrets still have
to be managed, for example from a secrets manager.

</details>

---

## The fleet identity

Lovely and native read a cluster's identity the same way: from its
registration with its own Argo CD, a cluster Secret in `argocd` that the
ApplicationSets' cluster generator reads. The examples are in `identity/`.

### The cluster Secret

```yaml
# identity/cluster-secret.example.yaml
apiVersion: v1
kind: Secret
metadata:
  name: fleet-local
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    fleet.ashtonian.dev/managed: "true"
    fleet.ashtonian.dev/group: us-east
    fleet.ashtonian.dev/ring: canary
  annotations:
    fleet.ashtonian.dev/revision: main
    fleet.ashtonian.dev/addons: gpu-operator
    values.fleet.ashtonian.dev/REGION: us-east-1
type: Opaque
stringData:
  name: cluster-001
  server: https://kubernetes.default.svc
  config: "{}"
```

| Field | Kind | Required | Description |
|---|---|---|---|
| `argocd.argoproj.io/secret-type: cluster` | label | Yes | Makes it a cluster registration Argo CD reads. |
| `fleet.ashtonian.dev/managed: "true"` | label | Yes | Selects this Secret in every fleet generator. Exactly one Secret per cluster may carry it: a second makes `fleet-bootstrap` fail on the duplicate Application name. |
| `fleet.ashtonian.dev/group` | label | Yes | The cluster's group: selects `<approach>/components/groups/<group>` and labels every resource. `GROUP` in the manifests. |
| `fleet.ashtonian.dev/ring` | label | No | The rollout ring, which picks the revision ([rings](#rings-and-revisions)). |
| `fleet.ashtonian.dev/revision` | annotation | Yes | The Git revision the cluster runs, for the bootstrap and every Application. It labels every Application, so it must be a valid label value: a commit, a tag, or a branch without `/`. |
| `fleet.ashtonian.dev/addons` | annotation | No | Comma-separated addon names, each a directory under `<approach>/apps/addons`: lowercase letters, digits and `-`, at most 63 characters. Spaces, empty entries and duplicates are ignored. |
| `values.fleet.ashtonian.dev/<KEY>` | annotation | No | A value: lovely's `<::KEY::>` token, or key `<KEY>` of native's `fleet-identity` ConfigMap. Use `[A-Za-z_][A-Za-z0-9_]*`; lovely rejects anything else, and values with a newline. `GROUP`, `CLUSTER_NAME` and `REVISION` are reserved. |
| `name` | data | Yes | The cluster's name, a valid label value: the `fleet.ashtonian.dev/cluster` label, and `CLUSTER_NAME` in the manifests. |
| `server` | data | Yes | `https://kubernetes.default.svc` |
| `config` | data | Yes | `{}`: Argo CD reaches its own cluster with its own service account, so the Secret holds no credentials. |

Labels must be 63 characters or fewer, of letters, digits, `-`, `_` and
`.`; anything free-form goes in an annotation. A Secret's annotations
together must stay under Kubernetes' 256 KiB limit, which leaves room for
thousands of values.

Before generating anything, the ApplicationSets check the identity.
Generation fails with a message naming the problem, and nothing is created,
changed or deleted, if any of these holds:
- the group label or the revision annotation is missing;
- the revision or the cluster name is not a valid label value;
- a value name is reserved, or (in lovely) is not a valid token name;
- an addon name is invalid.

`missingkey=error` alone would not catch these: a missing label read with
`index` is an empty string, not an error.

### Seed and handover

Something must write the cluster Secret before Argo CD can render the
fleet, and it must not be something the fleet installs. If the only writer
is an ExternalSecret, and External Secrets is itself one of the fleet's
applications, nothing ever starts. So:

1. **The provisioner writes the seed** when it creates the cluster, before or
   after it installs Argo CD. It can be Terraform, Cluster API or an image
   pipeline. The seed is at least the `argocd.argoproj.io/secret-type: cluster`
   label and `name`, `server` and `config`; the provisioner can also write the
   whole identity from the inventory. The provisioner also gives the secret
   store its access: workload identity where the platform has it, otherwise
   a credential (secret zero).
2. **External Secrets keeps it current** with
   `identity/external-secret.example.yaml`. That ExternalSecret uses
   `creationPolicy: Merge`, which updates the existing Secret and never
   creates or deletes it:
   - Until the seed exists, External Secrets waits.
   - If the entry breaks, External Secrets reports it and leaves the
     Secret as it was.
   - Deleting the ExternalSecret leaves the last identity in place.

   External Secrets can come from the provisioner or from the fleet itself,
   since the seed already exists.

With no Secret, Argo CD still runs and the fleet's generators simply match
nothing, so applications that do not need the identity can still deploy.

The ExternalSecret reads two entries. The cluster's own:

```json
{"name": "cluster-001", "group": "us-east", "ring": "canary",
 "addons": "gpu-operator", "values": {"REGION": "us-east-1"}}
```

and the fleet's rings, below. Every property of `values` becomes a
`values.fleet.ashtonian.dev/<KEY>` annotation, so a new value changes
neither the ExternalSecret nor Git. Each of these fails the ExternalSecret,
which then leaves the Secret unchanged:
- a missing entry;
- an entry without `name` or `group`;
- a `values` that is not a JSON object.

### Rings and revisions

A cluster's revision comes from its ring:

```json
{"revisions": {"canary": "4f1c2e…", "stable": "9a07b3…"}}
```

- **Promote a ring** with one write to `fleet/rings`. Every cluster in the
  ring picks it up within the ExternalSecret's `refreshInterval` (5 minutes in
  the example), and the ApplicationSets apply it at once. No `helm upgrade`,
  no Git change, and no access to the clusters.
- **Pin one cluster** with a `revision` in its own entry, which overrides its
  ring's.
- **Roll back** by writing the previous revision.

The `fleet-bootstrap` Application, and so the fleet's ApplicationSets, and
every Application they generate, follow the cluster's revision. Use full
commit SHAs at scale ([by fleet size](#by-fleet-size)). With a branch, the
bootstrap and the Applications resolve it separately and can briefly run
different commits.

A revision that does not exist breaks no workload. The Applications that
read it report a `ComparisonError` and keep what they have, and `fleet-base`
fails to read its directories and changes nothing; the e2e test promotes a
ring to one.

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
values (`lovely/argocd-values.yaml`), which add a Config Management Plugin
sidecar. Manifests carry `<::GROUP::>`, `<::CLUSTER_NAME::>`, `<::REVISION::>`
and a token for every value of [the cluster's identity](#the-fleet-identity),
anywhere in a file. The fleet's ApplicationSets pass the identity to the
plugin in each Application's spec. The plugin replaces the tokens with
[charmap](https://github.com/ashtonian/charmap), then renders with
[argocd-lovely-plugin](https://github.com/crumbhole/argocd-lovely-plugin),
which runs Kustomize or Helm as each directory needs.

```
lovely/
├── apps/
│   ├── base/                # every cluster; manifests carry <::TOKENS::>
│   └── addons/              # on the clusters whose addon list names them
├── components/
│   └── groups/
│       ├── us-east/         # a Component per group: any Kustomize change
│       └── eu-west/
├── bootstrap/               # installed by the fleet-bootstrap Application
│   ├── kustomization.yaml
│   ├── project.yaml                 # AppProject "fleet"
│   ├── fleet-base.yaml              # ApplicationSet: the base applications
│   ├── fleet-addons.yaml            # ApplicationSet: the cluster's addons
│   └── applicationset-common.yaml   # what both share: identity to plugin settings, safeguards
├── cmp/                     # the plugin sidecar image
│   ├── Dockerfile
│   └── plugin.yaml
├── argocd-values.yaml       # Argo CD Helm values, the same for every cluster
└── bootstrap-values.yaml    # argocd-apps values: the fleet-bootstrap ApplicationSet
```

### How it fits together

1. Bootstrap installs Argo CD with `lovely/argocd-values.yaml`, and the
   cluster's registration Secret appears ([seed and
   handover](#seed-and-handover)).
2. A second Helm release, the argocd-apps chart with
   `lovely/bootstrap-values.yaml`, creates the `fleet-bootstrap`
   ApplicationSet. Its cluster generator reads the Secret's revision and
   creates the `fleet-bootstrap` Application at that revision, which
   installs `lovely/bootstrap` with plain Kustomize. The release's values
   are the same on every cluster.
3. `fleet-base` crosses the cluster generator with the directories under
   `lovely/apps/base`, and `fleet-addons` with the cluster's addon list. Each
   generated Application targets the cluster's revision, names the plugin
   (`plugin.name: lovely-charmap`), and carries the identity in
   `plugin.env`: `FLEET_GROUP`, `FLEET_CLUSTER_NAME`, and `FLEET_<KEY>` for
   each value.
4. The plugin receives them as `ARGOCD_ENV_FLEET_*` and replaces the tokens
   across `lovely/`, so bases and Components referenced by relative path are
   covered too. It replaces `<::REVISION::>` with the commit Argo CD
   resolved, then renders.

The identity is part of each Application's spec, and Argo CD's render cache
keys on the spec, so a changed value re-renders on its own: no repo-server
restart and no hard refresh.

The plugin's `generate` script (`lovely/cmp/plugin.yaml`) stops on any
failure, and the Application then shows the error, with the file, line and
column of a bad token. Nothing is applied. Failures include:
- an unset or empty `GROUP` or `CLUSTER_NAME`;
- a token with no value;
- a malformed token or an invalid value name;
- a group without a Component;
- a rendering error.

Every render works on a private copy of the repository.

### Templated manifests

A token works in any file `RENDER_INCLUDE` selects: YAML, and by default
`json`, `conf`, `cfg`, `ini`, `toml`, `properties`, `txt` and `tpl` files.
The examples use tokens in labels, inside a URL, inside a configuration file,
and in the path that picks the group's Component:

```yaml
# lovely/apps/base/ingress/deployment.yaml
env:
  - name: PUBLIC_URL
    value: "https://ingress.<::REGION::>.example.com/healthz"
```

```ini
# lovely/apps/base/logging/logging.conf, carried by a generated ConfigMap
[OUTPUT]
    Host  logs.<::REGION::>.example.com
    Tag   <::GROUP::>.<::CLUSTER_NAME::>
```

```yaml
# lovely/apps/base/monitoring/kustomization.yaml
resources:
  - deployment.yaml
components:
  - "../../../components/groups/<::GROUP::>"
```

Tokens are plain string substitution: the value is inserted as it is, with
no YAML escaping. Keep values to simple strings; the ApplicationSets reject
a value with a newline. A token in a ConfigMap generated by
`configMapGenerator` changes the ConfigMap's name, so the pods that mount it
roll when the value changes.

| For | Against |
|---|---|
| A value can go anywhere in a file, including URLs and configuration files | Needs the plugin sidecar image |
| Adding a cluster or a value changes nothing in Git | A token with no value, anywhere under `lovely/`, fails every Application on that cluster |
| Identity changes apply on their own; rings promote with one write | Rendered output exists only inside Argo CD; render it locally with the plugin image ([CI](#ci)) |
| Group overrides are full Kustomize | Values are inserted unescaped |

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
- Optional: [External Secrets](https://external-secrets.io/) to keep the
  identity current from a secrets manager ([seed and
  handover](#seed-and-handover)).

### Try it in kind

Render every lovely application locally, the way the sidecar does, with no
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
docker build -t fleet-cmp:dev lovely/cmp && kind load docker-image fleet-cmp:dev --name fleet
scripts/e2e.sh fleet-cmp:dev "$(git ls-remote https://github.com/ashtonian/argo-fleet.git refs/heads/main | cut -f1)"
kind delete cluster --name fleet
```

### Bootstrapping a cluster

1. **Install Argo CD** with the shared values:

   ```sh
   helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
     --version 10.10.2 --namespace argocd --create-namespace \
     --values lovely/argocd-values.yaml --wait
   ```

2. **Register the cluster with its identity**
   ([seed and handover](#seed-and-handover)). By hand: set the group,
   revision, addons, values and name in a copy of
   `identity/cluster-secret.example.yaml`, and `kubectl apply -f` it. From a
   secrets manager: write the seed, create the cluster's entry, then apply a
   copy of `identity/external-secret.example.yaml` with `key` set to that
   entry.

3. **Install the bootstrap.** The values are the same on every cluster:

   ```sh
   helm install fleet-bootstrap argocd-apps --repo https://argoproj.github.io/argo-helm \
     --version 2.0.6 --namespace argocd --values lovely/bootstrap-values.yaml
   ```

4. `fleet-bootstrap` syncs, creates the `fleet` AppProject and the two
   ApplicationSets, and they create the cluster's Applications.

Steps 2 and 3 can run in either order. Check it with
`kubectl -n argocd get applications`: on the example cluster you see
`fleet-bootstrap`, `base-ingress`, `base-logging`, `base-monitoring` and
`addon-gpu-operator`, all `Synced` and `Healthy`.

### Configuration reference

**The cluster's identity:** see [the cluster Secret](#the-cluster-secret).
Every value is a token; `GROUP`, `CLUSTER_NAME` and `REVISION` are always
set.

| Token | From |
|---|---|
| `GROUP` | The `fleet.ashtonian.dev/group` label |
| `CLUSTER_NAME` | The Secret's `name` |
| `REVISION` | The commit Argo CD resolved for the Application |
| `<KEY>` | Each `values.fleet.ashtonian.dev/<KEY>` annotation |

**`lovely/argocd-values.yaml`** (argo-cd chart)

| Setting | Default | Description |
|---|---|---|
| `repoServer.extraContainers[0].image` | `ghcr.io/ashtonian/argo-fleet-lovely-cmp:<version>@sha256:…` | The plugin image. Keep it pinned by digest. |
| `…env RENDER_ROOT` | `lovely` | Directory, relative to the repository root, where tokens are replaced on every render. It must contain every file any Application uses. |
| `…env RENDER_INCLUDE` | `\.(ya?ml\|json\|conf\|cfg\|ini\|toml\|properties\|txt\|tpl)$` | Files under `RENDER_ROOT` whose path matches have their tokens replaced. Binary files, such as packaged Helm charts, must not match. |
| `…env LOVELY_HELM_PATH` | unset (Helm 4) | Set to `/usr/local/bin/helm3` to render Helm charts with Helm 3, for every Application on the cluster. |
| `…resources` | requests 100m CPU, 256Mi memory, 1Gi ephemeral storage; limits 1Gi memory, 2Gi ephemeral storage | Sidecar resources. Raise memory for large Helm charts or many concurrent renders. |
| `repoServer.volumes` `lovely-charmap-tmp` | disk-backed `emptyDir`, `sizeLimit: 2Gi` | Scratch for per-render repository copies. |
| `configs.params."applicationsetcontroller.policy"` | `create-update` | ApplicationSets never delete Applications (see [Deletion safety](#deletion-safety)). |
| `configs.params."reposerver.plugin.tar.exclusions"` | `.git` | Paths not streamed to the plugin. Add large unused directories here. |
| `controller.metrics.applicationLabels` | enabled, `fleet.ashtonian.dev/revision` and `fleet.ashtonian.dev/group` | Exports each Application's revision and group on `argocd_app_labels` ([Monitoring](#monitoring)). |

**`lovely/bootstrap-values.yaml`** (argocd-apps chart)

| Setting | Default | Description |
|---|---|---|
| `applicationsets.fleet-bootstrap.template.spec.source.repoURL`, `projects.fleet-bootstrap.sourceRepos` | this repository | Where the fleet definition lives. |
| `applicationsets.fleet-bootstrap.template.spec.source.path` | `lovely/bootstrap` | The directory the bootstrap installs. |
| `applicationsets.fleet-bootstrap.template.spec.syncPolicy` | automated, no prune, 5 retries | Pruning is off: pruning an ApplicationSet deletes every Application it owns. |
| `projects.fleet-bootstrap` | the `argocd` namespace; AppProjects and ApplicationSets only | What the bootstrap may manage. |

**`lovely/bootstrap/applicationset-common.yaml`**, the settings every fleet
Application gets:

| Setting | Value | Description |
|---|---|---|
| `project` | `fleet` | Only this repository, only this cluster, no `argocd` or `kube-*` namespace, no cluster-scoped resource except a Namespace. |
| `source.targetRevision` | the revision annotation | Every Application follows the cluster's revision. |
| `source.plugin` | `lovely-charmap`, with `env` from the identity | Written by the `templatePatch`, which also checks the identity. |
| `metadata.labels` | `fleet.ashtonian.dev/group`, `fleet.ashtonian.dev/revision` | For [Monitoring](#monitoring). |
| `syncPolicy` | automated with prune and self-heal, `CreateNamespace`, `PruneLast`, 5 retries | Each application's namespace is its name. |
| `syncPolicy.applicationsSync` (ApplicationSet) | `create-update`, `preserveResourcesOnDeletion` | See [Deletion safety](#deletion-safety). |

**Inside the plugin** (`lovely/cmp/plugin.yaml`): it reads
`ARGOCD_ENV_FLEET_*`, `RENDER_ROOT`, `RENDER_INCLUDE`, and Argo CD's
`ARGOCD_APP_SOURCE_PATH`, `ARGOCD_APP_REVISION`, `KUBE_VERSION` and
`KUBE_API_VERSIONS`. It removes every `ARGOCD_ENV_*` variable before
argocd-lovely-plugin runs, so an Application can pass values but never
settings for lovely itself.

### Using it in your own repository

1. **Copy `lovely/`, `identity/`, `scripts/` and `.github/`** into your
   repository. Drop `overlay/`, `matrix/`, `native/` and
   `scripts/e2e-native.sh`; in `.github/workflows/ci.yaml`, remove their
   `kubeconform` lines and the `e2e-native` job.
2. **Point it at your repository.** The URL appears in
   `lovely/bootstrap/applicationset-common.yaml`,
   `lovely/bootstrap/fleet-base.yaml`, `lovely/bootstrap/project.yaml` and
   `lovely/bootstrap-values.yaml` (twice):

   ```sh
   grep -rl 'https://github.com/ashtonian/argo-fleet.git' lovely |
     xargs sed -i.bak 's#https://github.com/ashtonian/argo-fleet.git#https://github.com/<you>/<repo>.git#g'
   find lovely -name '*.bak' -delete
   ```

   For a private repository, add Argo CD repository credentials (see
   [Prerequisites](#prerequisites)).
3. **Use your own domain** for the labels and annotations:

   ```sh
   grep -rl 'fleet\.ashtonian\.dev' lovely identity scripts |
     xargs sed -i.bak 's/fleet\.ashtonian\.dev/fleet.example.com/g'
   find lovely identity scripts -name '*.bak' -delete
   ```

4. **The plugin image.** Keep using `ghcr.io/ashtonian/argo-fleet-lovely-cmp`
   as pinned, unless you change `lovely/cmp/plugin.yaml`. Then publish your
   own: set `IMAGE` in `.github/workflows/cmp-image.yaml`, push a
   `cmp-v<version>` tag, and pin the printed digest in
   `lovely/argocd-values.yaml`.
5. **Directory names.** If `lovely/` moves, set `RENDER_ROOT` and the paths
   in `fleet-base.yaml`, `fleet-addons.yaml` and
   `lovely/bootstrap-values.yaml`.
6. **Replace the example workloads** in `lovely/apps` and the groups in
   `lovely/components/groups`. Keep the `components` line with the
   `<::GROUP::>` token in each application's `kustomization.yaml`. An
   application that needs CRDs, ClusterRoles or other cluster-scoped
   resources needs its own AppProject; `fleet` allows only Namespaces.
7. **Adjust the tests:** `scripts/render-test.sh` and `scripts/e2e.sh` check
   the example groups, values and Application names.

### Day-2 operations

Changes in Git reach a cluster when its revision includes them
([rings](#rings-and-revisions)). Changes to a cluster's identity apply when
its Secret changes: with External Secrets, within the ExternalSecret's
`refreshInterval` of the entry changing.

- **Add a base application:** create `lovely/apps/base/<app>/` with a
  `kustomization.yaml`, its manifests, and the group `components` line.
  Every cluster gets `base-<app>` in namespace `<app>`.
- **Add an addon:** define it in `lovely/apps/addons/<app>/`, then add `<app>`
  to the `addons` of the clusters that should run it. They get
  `addon-<app>`.
- **Add a group:** add `lovely/components/groups/<group>/`, and let it reach
  the clusters' revision before setting their group to it. A cluster whose
  group has no Component fails to render and changes nothing until it does.
- **Move a cluster to another group:** change its group. Every application
  re-renders with the new group's Component and tokens.
- **Add a value:** add it to the clusters' entries, then use its token. Every
  cluster that sees a manifest using it needs the value before that manifest
  reaches it: a cluster without it fails every render and changes nothing
  until it has it.
- **Change a value:** change it in the entry. The Applications re-render.
- **Remove an addon from a cluster:** remove it from `addons`, then delete
  `addon-<app>` on purpose ([Deletion safety](#deletion-safety)); the
  ApplicationSet keeps it.
- **Give one cluster its own structure:** give it a group of one whose
  Component includes its group's ([how](#group-components)).
- **Retire an application:** see [Deletion safety](#deletion-safety).

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
choose it themselves, because the plugin drops their lovely settings.

The sidecar runs as UID 999 with a read-only root filesystem, no
capabilities and the RuntimeDefault seccomp profile. It meets the restricted
Pod Security Standard, which the CI end-to-end test enforces. Its scratch
space is a disk-backed `emptyDir` limited to 2 GiB.

### Troubleshooting

Start with the ApplicationSets' and Applications' conditions. A failed
identity check names the label or annotation; a render error names the file,
line and column:

```sh
kubectl -n argocd get applicationset -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status} {.message}; {end}{"\n"}{end}'
kubectl -n argocd get application <name> \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
kubectl -n argocd get application <name> -o jsonpath='{.spec.source.plugin.env}'   # the values it renders with
```

| Symptom | Check | Then |
|---|---|---|
| An ApplicationSet reports `error calling fail: …` | The message names the label or annotation | See [Troubleshooting (native)](#troubleshooting-native): the identity checks are the same. Lovely also rejects a value name that is not a token name, `REVISION` as a value, and a value with a newline. |
| `ComparisonError: … <file>:<line>:<column>: no value for REGION` | `kubectl -n argocd get secret -l fleet.ashtonian.dev/managed=true -o jsonpath='{.items[0].metadata.annotations}'` | Add the value to the cluster. Every Application on it fails until then, since every file under `RENDER_ROOT` is checked. |
| `ComparisonError: … ARGOCD_ENV_FLEET_GROUP: parameter null or not set` | The Application's `spec.source.plugin.env` | Only the fleet ApplicationSets set it; an Application made by hand needs it too. |
| `ComparisonError: … malformed token` | The reported file, line and column | Fix the token. The file may belong to another Application. |
| `ComparisonError: … components/groups/<group>' … no such file or directory` | Does the Component exist at the cluster's revision? `git ls-tree -d <revision> lovely/components/groups/` | Add the group's Component, or fix the group label. |
| `addon-<name>`: `… app path does not exist` | `git ls-tree -d <revision> lovely/apps/addons/` | Fix the name in `addons`, or add the addon at that revision. |
| `could not find cmp-server plugin with name "lovely-charmap"` | `kubectl -n argocd get pod -l app.kubernetes.io/component=repo-server -o jsonpath='{.items[0].status.containerStatuses[*].name}'` | The `lovely-charmap` container must be running; check its logs below. |
| A token is left in a deployed file | Does its path match `RENDER_INCLUDE`? | Widen `RENDER_INCLUDE`, or rename the file. |
| A changed value does not reach the cluster | [Troubleshooting (native)](#troubleshooting-native), the External Secrets row | — |
| Pods keep an old value | Is the value in a file of a ConfigMap with a fixed name? | Generate the ConfigMap with `configMapGenerator`, so its name changes with its content, or restart the pods. |
| A sync keeps failing | `kubectl -n argocd get application <name> -o jsonpath='{.status.operationState.message}'` | Fix the cause. Automated sync retries 5 times with backoff, then waits for the next change. |

Plugin logs: `kubectl -n argocd logs deploy/argocd-repo-server -c lovely-charmap`.
To reproduce a render exactly, run `scripts/render-test.sh` against the
pinned image ([Try it in kind](#try-it-in-kind)).

### Upgrading

- **Argo CD:** change the chart version in the [bootstrap
  commands](#bootstrapping-a-cluster), in CI (`ARGO_CD_CHART_VERSION` in
  `.github/workflows/ci.yaml`) and in the default in `scripts/e2e-lib.sh`,
  let CI's end-to-end test pass, then `helm upgrade argocd` ring by ring.
- **The plugin image** (argocd-lovely-plugin, charmap): Dependabot proposes
  new base digests in `lovely/cmp/Dockerfile`, and CI builds and tests the
  image on the pull request. After merging, push a `cmp-v<version>` tag, pin
  the printed digest in `lovely/argocd-values.yaml`, and roll it out with
  `helm upgrade argocd` ring by ring. A major argocd-lovely-plugin version
  can change how Helm charts render; read its release notes.
- **GitHub Actions:** Dependabot proposes updates to the pinned actions.

### Limitations

- **A token with no value fails every Application on the cluster**, since
  every file under `RENDER_ROOT` is rendered.
- **Values are inserted unescaped**, and may not contain a newline.
- **Value names are token names**: letters, digits and `_`, not starting with
  a digit.
- **Group and cluster names are label values**: at most 63 characters of
  letters, digits, `-`, `_` and `.`.
- **A branch as revision** lets the bootstrap and the Applications resolve
  different commits briefly; use commits or tags.
- **Removed addons stay** until deleted on purpose.
- **One repository per fleet**, polled by every cluster (see [Scale](#scale)).
- **The example workloads are placeholders** (`busybox` printing a message).

## Approach 4: Native Kustomize

`native/`. Every cluster runs its own Argo CD, installed with the same Helm
values (`native/argocd-values.yaml`) and nothing added: no plugin and no
sidecar. The fleet's ApplicationSets read [the cluster's
identity](#the-fleet-identity) and turn it into each Application's Kustomize
settings, which Argo CD's built-in Kustomize renders.

```
native/
├── apps/
│   ├── base/                # every cluster; plain Kustomize, no tokens
│   └── addons/              # on the clusters whose addon list names them
├── components/
│   ├── identity/            # generates the fleet-identity ConfigMap
│   └── groups/
│       ├── us-east/         # a Component per group: any Kustomize change
│       └── eu-west/
├── bootstrap/               # installed by the fleet-bootstrap Application
│   ├── kustomization.yaml
│   ├── project.yaml                 # AppProject "fleet"
│   ├── fleet-base.yaml              # ApplicationSet: the base applications
│   ├── fleet-addons.yaml            # ApplicationSet: the cluster's addons
│   └── applicationset-common.yaml   # what both share: identity to Kustomize settings, safeguards
├── argocd-values.yaml       # Argo CD Helm values: the ApplicationSet policy and metrics
└── bootstrap-values.yaml    # argocd-apps values: the fleet-bootstrap ApplicationSet
```

### How it fits together (native)

1. Bootstrap installs Argo CD with `native/argocd-values.yaml`, and the
   cluster's registration Secret appears ([seed and
   handover](#seed-and-handover)).
2. A second Helm release, the argocd-apps chart with
   `native/bootstrap-values.yaml`, creates the `fleet-bootstrap`
   ApplicationSet. Its cluster generator reads the Secret's revision and
   creates the `fleet-bootstrap` Application at that revision, which
   installs `native/bootstrap`. The release's values are the same on every
   cluster.
3. `fleet-base` crosses the cluster generator with the directories under
   `native/apps/base`, and `fleet-addons` with the cluster's addon list.
   Each generated Application targets the cluster's revision, with these
   Kustomize settings (`native/bootstrap/applicationset-common.yaml`):
   - **components:** `components/identity`, which generates the
     `fleet-identity` ConfigMap, and `components/groups/<group>`;
   - **commonLabels:** `fleet.ashtonian.dev/group` and
     `fleet.ashtonian.dev/cluster` on every resource and pod template, never
     on selectors, which are immutable;
   - **patches:** one patch that sets `fleet-identity`'s data to the
     cluster's `GROUP`, `CLUSTER_NAME` and values.
4. Argo CD's built-in Kustomize renders each Application. The identity is
   part of the Application's spec, which is part of Argo CD's render cache
   key, and the ApplicationSet controller watches cluster Secrets. A changed
   identity therefore re-renders on its own: no restart, no hard refresh.

| For | Against |
|---|---|
| Nothing to run besides Argo CD | A value's first use in a manifest is a Git change: a reference or a replacement |
| Identity changes apply on their own; rings promote with one write | Kustomize replaces whole fields or delimited parts of them, not text inside a string |
| A bad file breaks only its application | Group and cluster names must be valid label values |
| Group overrides are full Kustomize | Go templates in the ApplicationSets carry the identity checks and wiring |

### Values in manifests

Kustomize has no string tokens. A value reaches a manifest through
`fleet-identity`, a ConfigMap in every Application's namespace:

| Key | From |
|---|---|
| `GROUP` | The `fleet.ashtonian.dev/group` label |
| `CLUSTER_NAME` | The Secret's `name` |
| `<KEY>` | Each `values.fleet.ashtonian.dev/<KEY>` annotation |

**As environment variables**, every key at once, as the example workloads
do:

```yaml
envFrom:
  - prefix: FLEET_          # FLEET_GROUP, FLEET_CLUSTER_NAME, FLEET_REGION
    configMapRef:
      name: fleet-identity
```

or one at a time with `valueFrom.configMapKeyRef`. Kustomize gives the
ConfigMap a name with a hash of its content and rewrites every reference to
it, so a changed value rolls the pods that use it. A key a cluster lacks is
simply not set.

**In any other field**, with a Kustomize replacement in the application's
`kustomization.yaml`. `native/apps/base/ingress` puts the cluster's `REGION`
into its Service's DNS name:

```yaml
replacements:
  - source:
      kind: ConfigMap
      name: fleet-identity
      fieldPath: data.REGION
    targets:
      - select:
          kind: Service
          name: ingress
        fieldPaths:
          - metadata.annotations.[external-dns.alpha.kubernetes.io/hostname]
        options:
          delimiter: "."
          index: 1   # ingress.REGION.example.com -> ingress.us-east-1.example.com
```

A cluster without the value fails to render that application (`fieldPath
data.REGION is missing for replacement source`), and nothing changes.

This is the per-value cost of the native approach. Adding a value needs no
Git change, but using it does: one `envFrom` per container covers every
value as environment variables, and every other field needs its own
replacement. A replacement can set a whole field, or one part of a field
split on a delimiter; it cannot reach text inside a larger string, such as a
line of a configuration file embedded in a ConfigMap. Where many such values
are needed, lovely's tokens are the simpler tool.

The values are JSON-encoded into the patch, so no value can change the
patch's structure: the e2e test checks that a value made of quotes, `#` and
a patch operation on new lines arrives in `fleet-identity` unchanged.
`fleet-identity` is a reserved name: an application must not define its
own.

### Group Components

A group's Component is a full Kustomize layer, applied to every application,
base and addon, on the group's clusters. Lovely uses the same Components,
chosen by a token instead of by the Application.

```yaml
# native/components/groups/us-east/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  - target:
      kind: Deployment
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
```

- **Every group needs a Component**, so a misspelt group fails to render
  instead of silently getting no overrides. A Component cannot be empty
  (Kustomize reports `kustomization.yaml is empty`); a group with no
  override carries a marker, as `eu-west` does with an annotation.
- **A patch that matches nothing is skipped**, so one Component serves
  applications that lack the kinds it patches.
- **A group of one builds on its group.** A Component can include another,
  so a cluster that needs its own structure gets a group whose Component
  starts from its group's:

  ```yaml
  # native/components/groups/us-east-gpu/kustomization.yaml
  apiVersion: kustomize.config.k8s.io/v1alpha1
  kind: Component
  components:
    - ../us-east
  patches:
    - target:
        kind: Deployment
      patch: |-
        - op: add
          path: /spec/template/spec/nodeSelector
          value: {gpu: "true"}
  ```

### Prerequisites (native)

- **Kubernetes** 1.36 is tested.
- **Argo CD** 3.5.4 (argo-cd chart 10.10.2, which bundles Kustomize 5.8.1)
  and the argocd-apps chart 2.0.6 are tested. Other Argo CD 3.x releases are
  likely to work but are untested.
- **Helm** 3.8 or later, or Helm 4, and `kubectl` with cluster-admin rights
  to install Argo CD.
- **Network:** the repo-server needs HTTPS access to the Git repository, and
  nodes need to pull the workloads' images. No other image is involved.
- **A private repository** needs Argo CD repository credentials: a Secret
  labelled `argocd.argoproj.io/secret-type: repository` in `argocd`.
- Optional: [External Secrets](https://external-secrets.io/) 2.12 (tested)
  with a `ClusterSecretStore` named `fleet` that can read the clusters'
  entries, and permission to write Secrets in `argocd`
  ([seed and handover](#seed-and-handover)).

### Try it in kind (native)

Build every native application for every group, the way Argo CD does, with
the example cluster's values and no cluster (needs `kustomize` and `yq`):

```sh
scripts/kustomize-build.sh
```

To see one application's exact output, run the commands the script runs on
a copy of `native/`: in the application's directory,
`kustomize edit add label`, the `fleet-identity` patch and
`kustomize edit add component`, then `kustomize build`. On a running
cluster, `argocd app manifests <name>` prints what Argo CD rendered.

Install the whole fleet, External Secrets included, into a disposable kind
cluster (needs `kind`, `kubectl`, `helm`, `yq` and `jq`). The script
installs Argo CD into the current context, so it refuses any context not
named `kind-*`. The revision must be a full commit SHA on GitHub that
contains `native/`:

```sh
kind create cluster --name fleet
scripts/e2e-native.sh "$(git ls-remote https://github.com/ashtonian/argo-fleet.git refs/heads/main | cut -f1)"
kind delete cluster --name fleet
```

### Bootstrapping a cluster (native)

1. **Install Argo CD** with the shared values:

   ```sh
   helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
     --version 10.10.2 --namespace argocd --create-namespace \
     --values native/argocd-values.yaml --wait
   ```

2. **Register the cluster with its identity**
   ([seed and handover](#seed-and-handover)). By hand: set the group,
   revision, addons, values and name in a copy of
   `identity/cluster-secret.example.yaml`, and `kubectl apply -f` it. From a
   secrets manager: write the seed, create the cluster's entry, then apply a
   copy of `identity/external-secret.example.yaml` with `key` set to that
   entry.

3. **Install the bootstrap.** The values are the same on every cluster:

   ```sh
   helm install fleet-bootstrap argocd-apps --repo https://argoproj.github.io/argo-helm \
     --version 2.0.6 --namespace argocd --values native/bootstrap-values.yaml
   ```

4. `fleet-bootstrap` syncs, creates the `fleet` AppProject and the two
   ApplicationSets, and they create the cluster's Applications.

Steps 2 and 3 can run in either order: the ApplicationSets act as soon as
the Secret appears. Check it with `kubectl -n argocd get applications`: on
the example cluster you see `fleet-bootstrap`, `base-ingress`,
`base-logging`, `base-monitoring` and `addon-gpu-operator`, all `Synced` and
`Healthy`.

### Configuration reference (native)

**The cluster's identity:** see [the cluster Secret](#the-cluster-secret);
the values land in `fleet-identity` ([Values in
manifests](#values-in-manifests)).

**`native/argocd-values.yaml`** (argo-cd chart)

| Setting | Default | Description |
|---|---|---|
| `configs.params."applicationsetcontroller.policy"` | `create-update` | ApplicationSets never delete Applications (see [Deletion safety](#deletion-safety)). |
| `controller.metrics.applicationLabels` | enabled, `fleet.ashtonian.dev/revision` and `fleet.ashtonian.dev/group` | Exports each Application's revision and group on `argocd_app_labels` ([Monitoring](#monitoring)). |

Everything else is the chart's default.

**`native/bootstrap-values.yaml`** (argocd-apps chart)

| Setting | Default | Description |
|---|---|---|
| `applicationsets.fleet-bootstrap.template.spec.source.repoURL`, `projects.fleet-bootstrap.sourceRepos` | this repository | Where the fleet definition lives. |
| `applicationsets.fleet-bootstrap.template.spec.source.path` | `native/bootstrap` | The directory the bootstrap installs. |
| `applicationsets.fleet-bootstrap.template.spec.syncPolicy` | automated, no prune, 5 retries | Pruning is off: pruning an ApplicationSet deletes every Application it owns. |
| `projects.fleet-bootstrap` | the `argocd` namespace; AppProjects and ApplicationSets only | What the bootstrap may manage. |

**`native/bootstrap/applicationset-common.yaml`**, the settings every fleet
Application gets:

| Setting | Value | Description |
|---|---|---|
| `project` | `fleet` | Only this repository, only this cluster, no `argocd` or `kube-*` namespace, no cluster-scoped resource except a Namespace. |
| `source.targetRevision` | the revision annotation | Every Application follows the cluster's revision. |
| `source.kustomize.components` | `components/identity`, `components/groups/<group>` | Paths relative to the application's directory. |
| `source.kustomize.commonLabels` | group and cluster | With `labelWithoutSelector` and `labelIncludeTemplates`: on pod templates, never on selectors. |
| `source.kustomize.patches` | `fleet-identity`'s data | Written by the `templatePatch`, which also checks the identity. |
| `metadata.labels` | `fleet.ashtonian.dev/group`, `fleet.ashtonian.dev/revision` | For [Monitoring](#monitoring). |
| `syncPolicy` | automated with prune and self-heal, `CreateNamespace`, `PruneLast`, 5 retries | Each application's namespace is its name. |
| `syncPolicy.applicationsSync` (ApplicationSet) | `create-update`, `preserveResourcesOnDeletion` | See [Deletion safety](#deletion-safety). |

### Using it in your own repository (native)

1. **Copy `native/`, `identity/`, `scripts/kustomize-build.sh`,
   `scripts/e2e-lib.sh`, `scripts/e2e-native.sh` and
   `.github/workflows/ci.yaml`.** In `ci.yaml`, keep the `static` and
   `e2e-native` jobs, drop `render` and `e2e`, and remove the overlay, matrix
   and lovely `kubeconform` lines.
2. **Point it at your repository.** The URL appears in
   `native/bootstrap/applicationset-common.yaml`,
   `native/bootstrap/fleet-base.yaml`, `native/bootstrap/project.yaml` and
   `native/bootstrap-values.yaml` (twice):

   ```sh
   grep -rl 'https://github.com/ashtonian/argo-fleet.git' native |
     xargs sed -i.bak 's#https://github.com/ashtonian/argo-fleet.git#https://github.com/<you>/<repo>.git#g'
   find native -name '*.bak' -delete
   ```

   For a private repository, add Argo CD repository credentials (see
   [Prerequisites](#prerequisites-native)).
3. **Use your own domain** for the labels and annotations. Replacing
   `fleet.ashtonian.dev` covers `values.fleet.ashtonian.dev` too:

   ```sh
   grep -rl 'fleet\.ashtonian\.dev' native identity scripts |
     xargs sed -i.bak 's/fleet\.ashtonian\.dev/fleet.example.com/g'
   find native identity scripts -name '*.bak' -delete
   ```

4. **Directory names.** If `native/` moves, change `native/apps/base/*` in
   `fleet-base.yaml`, `native/apps/addons/` in `fleet-addons.yaml` and
   `native/bootstrap` in `native/bootstrap-values.yaml`. The Component paths
   are relative to each application and need no change while
   `apps/` and `components/` stay side by side.
5. **Replace the example workloads** in `native/apps` and the groups in
   `native/components/groups`. An application that needs CRDs, ClusterRoles
   or other cluster-scoped resources needs its own AppProject; `fleet`
   allows only Namespaces.
6. **Adjust the tests:** `scripts/kustomize-build.sh` uses the values of
   `identity/cluster-secret.example.yaml`, and `scripts/e2e-native.sh`
   checks the example Application names, labels and values.

### Day-2 operations (native)

Changes in Git reach a cluster when its revision includes them
([rings](#rings-and-revisions)). Changes to a cluster's identity apply when
its Secret changes: with External Secrets, within the ExternalSecret's
`refreshInterval` of the entry changing.

- **Add a base application:** create `native/apps/base/<app>/` with a
  `kustomization.yaml` and its manifests. Every cluster gets `base-<app>` in
  namespace `<app>`.
- **Add an addon:** define it in `native/apps/addons/<app>/`, then add
  `<app>` to the `addons` of the clusters that should run it. They get
  `addon-<app>`.
- **Add a group:** add `native/components/groups/<group>/`, and let it reach
  the clusters' revision before setting their group to it. A cluster whose
  group has no Component fails to render and changes nothing until it does.
- **Move a cluster to another group:** change its group. Every application
  re-renders with the new group's Component. Nothing is left behind,
  because addons belong to the cluster, not the group.
- **Add a value:** add it to the `values` of the clusters' entries, then use
  it in manifests. If an application wires it to a field with a replacement,
  every cluster running that application needs the value before the change
  reaches it.
- **Change a value:** change it in the entry. The Applications re-render,
  and pods that use `fleet-identity` roll.
- **Remove an addon from a cluster:** remove it from `addons`, then delete
  `addon-<app>` on purpose ([Deletion safety](#deletion-safety)); the
  ApplicationSet keeps it.
- **Give one cluster its own structure:** give it a group of one whose
  Component builds on its group's ([how](#group-components)).
- **Retire an application:** see [Deletion safety](#deletion-safety).

### Troubleshooting (native)

Start with the ApplicationSets' and Applications' conditions. A failed
identity check names the label or annotation; a render error names the file
or field:

```sh
kubectl -n argocd get applicationset -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status} {.message}; {end}{"\n"}{end}'
kubectl -n argocd get application <name> \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
kubectl -n argocd get secret -l fleet.ashtonian.dev/managed=true -o yaml   # the identity
```

| Symptom | Check | Then |
|---|---|---|
| No `fleet-bootstrap` Application | `kubectl -n argocd get secret -l fleet.ashtonian.dev/managed=true` | Exactly one Secret must carry the label, with a revision annotation. |
| `ErrorOccurred: … error calling fail: cluster Secret has no fleet.ashtonian.dev/group label` (or `revision annotation`) | The Secret's labels and annotations | Set it, in the secrets-manager entry if External Secrets writes the Secret. Nothing changes until then. |
| `… revision "…" is not a valid label value` | The revision annotation | Use a commit, a tag, or a branch without `/`. |
| `… values.fleet.ashtonian.dev/GROUP is reserved` | The Secret's annotations | Remove the `GROUP` or `CLUSTER_NAME` value; both come from the identity. |
| `… cluster name "…" is not a valid label value` | The Secret's `name` | At most 63 characters of letters, digits, `-`, `_` and `.`, starting and ending with a letter or digit. |
| `… addon "…" in fleet.ashtonian.dev/addons is not a valid name` | The `addons` annotation | Lowercase letters, digits and `-`. |
| `ComparisonError: … fieldPath data.<KEY> is missing for replacement source` | `kubectl -n argocd get secret -l fleet.ashtonian.dev/managed=true -o jsonpath='{.items[0].metadata.annotations}'` | Add `<KEY>` to the cluster's values. Only applications that wire `<KEY>` to a field are affected. |
| `ComparisonError: … components/groups/<group> has no match` | `git ls-tree -d <revision> native/components/groups/` | Add the group's Component, or fix the group label. |
| `ComparisonError: … kustomization.yaml is empty` | The group's Component | Give it at least one setting. |
| `addon-<name>`: `… app path does not exist` | `git ls-tree -d <revision> native/apps/addons/` | Fix the name in `addons`, or add the addon at that revision. |
| After a promotion, `fleet-bootstrap` and the addons report a `ComparisonError`, and `fleet-base` an error reading the repository | `kubectl -n argocd get application fleet-bootstrap -o jsonpath='{.spec.source.targetRevision}'` | The ring's revision does not exist in the repository. Write a valid one to `fleet/rings`; nothing was applied meanwhile. |
| A changed value does not reach the cluster | `kubectl -n argocd get externalsecret fleet-local`: is it `SecretSynced`? If not, `kubectl -n argocd describe externalsecret fleet-local` shows the cause in its events. Then check the Secret's annotations, then the Application's spec | Fix the entry (a missing `name` or `group`, a `values` that is not a JSON object) or the store. The condition itself only says `could not update secret`. |
| Pods keep an old value | Does the workload reference `fleet-identity` in its manifest (`envFrom`, `configMapKeyRef`, a volume)? | Kustomize renames only references it can see; a workload that reads the ConfigMap by name at run time must be restarted. |
| A sync keeps failing | `kubectl -n argocd get application <name> -o jsonpath='{.status.operationState.message}'` | Fix the cause. Automated sync retries 5 times with backoff, then waits for the next change. |

ApplicationSet controller logs:
`kubectl -n argocd logs deploy/argocd-applicationset-controller`.

### Upgrading (native)

- **Argo CD:** change the chart version in the [bootstrap
  commands](#bootstrapping-a-cluster-native), in CI
  (`ARGO_CD_CHART_VERSION`) and in the default in `scripts/e2e-lib.sh`. Set
  CI's `KUSTOMIZE_VERSION` to the Kustomize the new release bundles (its
  `hack/tool-versions.sh`), since a Kustomize change can change rendering.
  Let CI pass, then `helm upgrade argocd` ring by ring.
- **External Secrets:** change `EXTERNAL_SECRETS_CHART_VERSION` in CI and
  the default in `scripts/e2e-lib.sh`, and let `e2e-native` pass. The
  example uses the `v1` API and template engine v2.
- **GitHub Actions:** Dependabot proposes updates to the pinned actions.

### Limitations (native)

- **A value's first use is a Git change**: a reference or a replacement. Text
  inside a larger string, such as a line of an embedded configuration file,
  is out of reach of a replacement.
- **Group and cluster names are label values**: at most 63 characters of
  letters, digits, `-`, `_` and `.`.
- **Helm charts** render through Kustomize's `helmCharts` only with
  `--enable-helm` in Argo CD's `kustomize.buildOptions`, which this
  repository does not set.
- **A branch as revision** lets the bootstrap and the Applications resolve
  different commits briefly; use commits or tags.
- **Identity values are visible** in `fleet-identity`, the Application specs
  and Argo CD's UI; they are not for secrets.
- **Removed addons stay** until deleted on purpose.
- **One repository per fleet**, polled by every cluster (see [Scale](#scale)).
- **The example workloads are placeholders** (`busybox` printing a message).

## Other patterns

Not implemented here: each needs more repositories, a render pipeline or a
beta feature. Costs are counted for the same fleet as above, at 500
clusters: 20 base applications, 5 addons, 5 groups, 2 addons per cluster.

| Pattern | What it is | Fits when | Costs |
|---|---|---|---|
| **Repository per cluster** | Each cluster's Argo CD follows its own repository, holding its applications as overlays of a shared catalog's bases. | A few clusters owned by different teams or customers; regulated or air-gapped environments. | 501 repositories (one per cluster and the catalog) holding the overlay approach's 11,025 directories. A shared change is a pull request per affected cluster; repositories drift; nothing shows the whole fleet. Impractical past dozens of clusters. |
| **Repository per group, versioned base** | A catalog repository holds the applications. Each group's repository pulls them as Kustomize remote bases pinned to a tag: `resources: [https://github.com/org/catalog//apps/monitoring?ref=v1.4.0]`. | Groups have separate owners or approvals, or need their own release trains. | 6 repositories (5 groups and the catalog); the 25 definitions plus 110 group overlays, with addons chosen per group. Remote bases are fetched on every render, which needs network access and, for a private catalog, Git credentials for Kustomize. Promoting a catalog release is a pull request per group. In return: rollout and access control per group, and Git reads spread over repositories. |
| **Rendered manifests** | CI, or Argo CD's Source Hydrator (beta since 3.5.0), renders each group's or cluster's manifests into a branch or OCI artifact; clusters apply plain YAML. | Every change must be reviewed as the exact YAML that lands, or clusters must not render. | A render pipeline to run and secure; a rendered copy per variant (5 per group, or 500 per cluster) regenerated and diffed on every change. Identity can no longer come from the cluster: the renderer must know every cluster. Source Hydrator is beta. |
| **Helm values per group** | Argo CD multi-source Applications: a chart plus `$values/groups/<group>/<app>.yaml`. | The fleet's applications are mostly Helm charts. | A values file per group per application (100), the matrix approach's growth; changes are limited to what each chart exposes as values. |
| **Hub with cluster labels** | The matrix topology, but the hub's ApplicationSets select spokes by labels on their cluster Secrets, as lovely and native do, instead of `config.yaml` files. Application names must then include the cluster's name. | One central Argo CD is acceptable, and every spoke is reachable from it. | No per-cluster files, but the hub holds every cluster's credentials, is a single point of failure, and reconciles 11,000 Applications (500 × 22) alone, which needs controller sharding. At 10,000 clusters, 220,000. |

## Deletion safety

A shrinking generator result must not delete workloads. A directory rename,
a deleted `config.yaml`, a mistyped group or a deleted cluster Secret would
otherwise remove applications from every affected cluster. So:

- Every ApplicationSet sets `applicationsSync: create-update` (it never
  deletes Applications) and `preserveResourcesOnDeletion: true` (its
  Applications carry no resources finalizer).
- The lovely and native values also set
  `applicationsetcontroller.policy: create-update` on the controller, which
  overrides any ApplicationSet's own policy.
- `goTemplateOptions: ["missingkey=error"]` makes a missing parameter an
  error instead of an empty string. The lovely and native ApplicationSets
  also check the labels and annotations they read, since `index` returns an
  empty string for a missing one, and fail generation instead.
- `fleet-bootstrap` does not prune, since pruning an ApplicationSet would
  delete every Application it owns.
- In lovely and native, deleting the cluster Secret or its `managed` label
  empties every generator, and every Application stays. Deleting the
  ExternalSecret leaves the Secret itself in place (`creationPolicy: Merge`).

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
whatever the layout; [By fleet size](#by-fleet-size) sums them up.

- **Git requests.** Every Argo CD instance reads the repository itself.
  - **A branch or tag** is resolved with a Git request on every refresh: by
    default every 3 minutes, shared by every Application on the cluster. At
    10,000 clusters that is about 56 requests a second; GitHub
    [recommends at most 15 Git read operations per second](https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits)
    per repository.
  - **A full commit SHA** needs no request: Argo CD 3.5 skips `ls-remote`
    for one, and caches directory listings and rendered manifests by
    revision (24 hours by default). A cluster then reads Git when its
    revision changes, or after its repo-server loses its cache.
- **Promotion bursts.** A ring's clusters fetch a new revision within the
  ExternalSecret's `refreshInterval`: 5,000 clusters in 5 minutes is at
  least 17 fetches a second. To spread the load:
  - Grow rings gradually.
  - Serve the repository from read-only mirrors near the clusters.
  - Publish each revision as an OCI artifact. Argo CD 3.5 accepts OCI
    Application sources, but the ApplicationSet Git generator reads only
    Git, so `fleet-base` would list its applications with a list generator
    instead of reading directories.

  Use a webhook relay rather than shorter polling intervals.
- **Secrets-manager reads.** Each cluster's ExternalSecret reads two entries
  every `refreshInterval`: about 67 reads a second at 10,000 clusters and 5
  minutes. Check the provider's quota, and lengthen the interval if needed;
  promotions then take longer to arrive.
- **Rendering.** Lovely streams the repository to the plugin sidecar on each
  render; the values exclude `.git`, so keep the rest of the repository
  small, or exclude more with `reposerver.plugin.tar.exclusions`. Native
  renders inside the repo-server, with no copy.
- **Applications.** Each cluster's Argo CD reconciles only its own
  Applications, so per-cluster cost stays flat. Fleet-wide cost is linear
  in clusters × applications.

## Monitoring

Argo CD's metrics cover the fleet; scrape the application controller and
ApplicationSet controller, and send them to a central store with a label for
the cluster. Useful signals:

- `argocd_app_info` by `sync_status` and `health_status`: alert when an
  Application stays `OutOfSync` or not `Healthy`.
- `argocd_app_condition` by `condition`: alert on `ComparisonError`, which
  is how every render failure shows up, including a missing value.
- `argocd_app_labels` with `label_fleet_ashtonian_dev_revision` and
  `label_fleet_ashtonian_dev_group`: the lovely and native values export
  each Application's revision and group. `argocd_app_info` carries no
  revision, so this is what promotion gates count. For example, Applications
  synced and healthy at each revision, with `cluster` added by the metrics
  pipeline:

  ```promql
  count by (label_fleet_ashtonian_dev_revision) (
    argocd_app_labels
    * on (cluster, namespace, name) group_left
    argocd_app_info{sync_status="Synced", health_status="Healthy"}
  )
  ```

- `argocd_appset_info` by `resource_update_status`: anything other than
  `ApplicationSetUpToDate` means generation failed, which is how a failed
  identity check shows up. `argocd_appset_reconcile` times each reconcile.
- `externalsecret_status_condition` (External Secrets): an entry that no
  longer writes the cluster Secret.
- Lovely: `kube_pod_container_status_restarts_total` for the
  `lovely-charmap` container (kube-state-metrics).

Alert on a drop in the number of Applications on a cluster too: with
`create-update` nothing deletes them, so a drop means someone did.

## Security

- **Repository writers deploy to every cluster.** Protect the default
  branch and the revisions clusters follow; staged rollout limits how many
  clusters a bad change reaches before it is caught.
- **Identity writers decide what a cluster runs.** That means whoever can
  write the cluster Secret, its secrets-manager entry, the rings entry or
  the ExternalSecret: they set the revision, group, addons and values.
  Restrict write access to Secrets in `argocd`, to the entries, and to the
  secret store External Secrets reads. Give each cluster's store access to
  its own entry and the rings entry only.
- **AppProjects** limit what the generated Applications can do: `fleet`,
  `overlay` and `matrix` allow only this repository as a source, refuse the
  `argocd` and `kube-*` namespaces, and allow no cluster-scoped resource
  except a Namespace. `fleet-bootstrap` may only manage the fleet's
  AppProject and ApplicationSets. An operator that needs CRDs or
  ClusterRoles belongs in its own project.
- **Identity values** end up in rendered manifests, Application specs and
  Argo CD's UI. Keep secrets out of them; deliver workload secrets to their
  namespaces directly, for example with External Secrets. The cluster
  Secret holds no credentials.
- **The lovely plugin** substitutes only the values an Application passes
  (`ARGOCD_ENV_FLEET_*`) and `REVISION` (the resolved commit). argocd-lovely-plugin
  would also accept settings, including commands to run, from an
  Application's `plugin.env`. The `generate` script drops every
  `ARGOCD_ENV_*` variable before lovely runs, so only the sidecar's own
  configuration applies. Values are inserted unescaped; the ApplicationSets
  reject one with a newline.
- **Native values** are JSON-encoded into the `fleet-identity` patch, so a
  value cannot add patch operations or change the Application.

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

Approaches 3 and 4 keep that power with one Component per group instead of
an overlay per group and application ([Group
Components](#group-components)). Native adds the Component to every
Application; lovely names it with a token in each application's
`kustomization.yaml`. Values come from the cluster, not from Git.

## CI

`.github/workflows/ci.yaml` runs on every pull request and push to `main`:

- **static**: actionlint; shellcheck on the scripts and the plugin's
  `generate` script; `scripts/kustomize-build.sh`, which builds every
  application, and every native application for every group the way Argo CD
  does (labels, the `fleet-identity` patch and components added to a copy of
  its `kustomization.yaml`, with the Kustomize version Argo CD bundles);
  ApplicationSets, AppProjects, both bootstrap releases and the identity
  examples, including the ExternalSecret, validated against their CRD
  schemas.
- **render**: builds the plugin image and runs `scripts/render-test.sh`.
  That renders every lovely application inside the image, for a us-east and
  an eu-west identity, with a read-only root filesystem as in the sidecar,
  and validates the output. It fails on any error or leftover token, and
  checks the group's Component, tokens inside a URL and a configuration
  file, and `REVISION`. It also checks that each of these stops the render
  with no output:
  - an empty identity or a missing value;
  - a group without a Component;
  - an invalid value name or an unknown token.

  It also checks that any value fills its token, and that lovely settings
  passed by an Application are ignored.
- **e2e**: `scripts/e2e.sh` installs Argo CD with `lovely/argocd-values.yaml`
  and the image built from the commit, and the bootstrap with
  `lovely/bootstrap-values.yaml`. It runs in a kind cluster whose `argocd`
  namespace enforces the restricted Pod Security Standard, with the example
  identity. It checks:
  - the expected Applications, synced and healthy at the commit under test;
  - tokens in labels, a URL and a configuration file, and the group's
    Component;
  - the revision label in Argo CD's metrics;
  - a changed value applies with no repo-server restart;
  - an added addon is created;
  - a missing value changes nothing;
  - a missing group label stops generation and keeps everything.
- **e2e-native**: `scripts/e2e-native.sh` installs External Secrets, Argo CD
  with `native/argocd-values.yaml` and the bootstrap, in a kind cluster that
  enforces the same standard. A seed Secret plus External Secrets' fake
  provider deliver the identity. It checks:
  - External Secrets merged the identity and the ring's revision into the
    seed;
  - the expected Applications, synced and healthy at the commit under test;
  - the group and cluster labels on Deployments and pods, with selectors
    unchanged, and the us-east Component's 2 replicas;
  - `GROUP`, `CLUSTER_NAME` and `REGION` in `fleet-identity`, in the running
    pods' environment, and in the ingress Service's hostname;
  - the revision label on every Application and in Argo CD's metrics;
  - a changed `REGION` reaches the hostname and the running pods, with no
    repo-server restart;
  - a value made of quotes, `#` and a patch operation on new lines arrives
    in `fleet-identity` unchanged;
  - an addon added to the entry is created;
  - promoting the ring to a revision that does not exist reaches the
    Applications and breaks no workload, and the cluster's own revision then
    overrides the ring's;
  - removing `REGION` fails only `base-ingress`, which keeps its Service;
  - an entry without a group fails the ExternalSecret and changes nothing;
  - deleting the ExternalSecret keeps the Secret, and removing the group
    label fails generation, while every Application and workload stays.

`.github/workflows/cmp-image.yaml` publishes the plugin image on a
`cmp-v<version>` tag, after checking each platform runs its own charmap.
Dependabot (`.github/dependabot.yml`) proposes updates to the actions and the
plugin image's bases.

## Repository layout

| Path | Contents |
|---|---|
| `overlay/` | Approach 1: base applications, per-cluster overlays, AppProject and ApplicationSet |
| `matrix/` | Approach 2: base applications and addons, group overlays, cluster configs, AppProject and ApplicationSets |
| `identity/` | The cluster Secret and the ExternalSecret that keeps it current, shared by approaches 3 and 4 |
| `lovely/apps`, `lovely/components` | Approach 3: templated applications and addons, a Component per group |
| `lovely/bootstrap` | The fleet AppProject and ApplicationSets, with their shared spec |
| `lovely/cmp` | The plugin sidecar image and its `generate` pipeline |
| `lovely/argocd-values.yaml`, `lovely/bootstrap-values.yaml` | Argo CD Helm values with the sidecar; argocd-apps values: the `fleet-bootstrap` ApplicationSet |
| `native/apps`, `native/components` | Approach 4: plain Kustomize applications and addons, the identity Component and a Component per group |
| `native/bootstrap` | The fleet AppProject and ApplicationSets, with their shared spec |
| `native/argocd-values.yaml`, `native/bootstrap-values.yaml` | Argo CD Helm values; argocd-apps values: the `fleet-bootstrap` ApplicationSet |
| `scripts/kustomize-build.sh` | Builds every application; native ones as Argo CD does, for every group |
| `scripts/render-test.sh` | Renders every lovely application in the plugin image |
| `scripts/e2e.sh`, `scripts/e2e-native.sh` | Install and check the lovely and native fleets in a disposable kind cluster |
| `scripts/e2e-lib.sh` | Shared by the end-to-end tests |
| `.github/workflows/` | CI and the plugin image release |
| `.github/dependabot.yml` | Update proposals for actions and the plugin image's bases |
