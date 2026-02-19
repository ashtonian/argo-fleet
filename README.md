# ArgoCD ApplicationSet Patterns

Three approaches for managing app deployment across a large cluster fleet using ArgoCD ApplicationSets and Kustomize.

Uses [crumbhole/argocd-lovely-plugin](https://github.com/crumbhole/argocd-lovely-plugin) and [ashtonian/charmap](https://github.com/ashtonian/charmap) for template variable substitution in Approach 3.

**Goal:** Base apps on every cluster, per-group overrides, and selective addons per cluster.

## Summary

| | Overlay | Matrix | Lovely + Charmap |
|---|---|---|---|
| **Mechanism** | Git directory generator | Matrix generator + kustomize overlays per group | Simple directory generator + CMP template substitution |
| **Base app selection** | Directory presence per cluster | Directory presence per group | All base apps auto-deploy to all clusters |
| **Group overrides** | Manual per-cluster patches | Kustomize overlays shared per group | `<::VAR::>` template markers resolved at render time |
| **Addon selection** | Directory presence per cluster | Directory presence per cluster | Directory presence per group |
| **Cluster identity** | Hardcoded per cluster | `config.yaml` per cluster | ArgoCD env vars (set at bootstrap) |
| **Per-cluster git dirs** | N (one per app per cluster) | 1 (config.yaml + optional addons) | 0 |
| **ApplicationSets** | 1 per cluster | 2 total | 2 total |
| **Add a cluster** | Create N app overlay dirs | Create 1 `config.yaml` | Bootstrap ArgoCD with env vars (no git change) |
| **Add a base app** | Touch every cluster dir | Add 1 kustomization per group | Add 1 app dir (done) |
| **Add a group** | N/A | Create group dir + N kustomizations | Create group dir + addon selection |
| **Best for** | < 10 clusters | 10-100 clusters | 100+ clusters |

### Directory count at scale (3,000 clusters / 50 groups / 20 base apps / 5 addons)

| | Overlay | Matrix | Lovely |
|---|---|---|---|
| Base app definitions | 20 | 20 | 20 |
| Group overlay dirs | — | 50 x 20 = 1,000 | — |
| Cluster config dirs | 3,000 x 20 = 60,000 | 3,000 | 0 |
| Addon dirs (avg 2/group) | (included above) | 6,000 | 50 x 2 = 100 |
| ApplicationSets | 3,000 | 2 | 2 |
| **Total** | **~63,000** | **~10,000** | **~120** |

---

## Approach 1: Overlay (`overlay/`)

Git directory generator scans a per-cluster overlay directory. Each subdirectory becomes an Application. Directory presence = deployment.

### Structure

```
overlay/
├── apps/                              # Base app definitions
│   ├── monitoring/
│   ├── ingress/
│   ├── logging/
│   ├── gpu-operator/                  # Available but not deployed everywhere
│   └── edge-cache/
├── clusters/
│   └── cluster-001/                       # Only apps this cluster should run
│       ├── monitoring/
│       │   └── kustomization.yaml     # refs ../../../apps/monitoring
│       ├── ingress/
│       │   └── kustomization.yaml
│       └── logging/
│           └── kustomization.yaml
└── applicationset.yaml
```

### ApplicationSet

```yaml
generators:
  - git:
      directories:
        - path: overlay/clusters/cluster-001/*
```

Each cluster-app overlay is a `kustomization.yaml` referencing the base app. Can add patches per cluster. To add an app: create the directory. To remove: delete it (auto-sync prunes).

### Trade-offs

| Pro | Con |
|-----|-----|
| Simple to understand | One ApplicationSet per cluster |
| Standard kustomize patterns | No cluster parameter injection |
| Overlays can patch base apps | Per-cluster dirs needed for every app |

---

## Approach 2: Matrix (`matrix/`)

Matrix generator combines cluster identity (from `config.yaml` files) with app discovery. Two layers: base apps through group overlays, and selective addons per cluster.

### Structure

```
matrix/
├── apps/
│   ├── base/                          # Deployed to ALL clusters
│   │   ├── monitoring/
│   │   ├── ingress/
│   │   └── logging/
│   └── addons/                        # Deployed selectively
│       ├── gpu-operator/
│       └── edge-cache/
├── groups/                            # Per-group kustomize overlays
│   ├── us-east/
│   │   ├── config.yaml
│   │   └── apps/
│   │       ├── monitoring/
│   │       │   └── kustomization.yaml # refs base + group patches
│   │       ├── ingress/
│   │       └── logging/
│   └── eu-west/
│       ├── config.yaml
│       └── apps/...
├── clusters/                          # Per-cluster identity + addon selection
│   ├── cluster-001/
│   │   ├── config.yaml                # cluster_name, group, cluster_server
│   │   └── addons/gpu-operator/
│   ├── cluster-002/
│   │   └── config.yaml
│   └── cluster-003/
│       ├── config.yaml
│       └── addons/{gpu-operator,edge-cache}/
└── applicationsets.yaml
```

### Cluster Config

```yaml
cluster_name: cluster-001
group: us-east
cluster_server: https://cluster-001.example.com
```

### ApplicationSet 1: Base Apps

```yaml
generators:
  - matrix:
      generators:
        - git:
            files:
              - path: matrix/clusters/*/config.yaml        # → cluster_name, group, cluster_server
        - git:
            directories:
              - path: 'matrix/groups/{{.group}}/apps/*'    # scoped by group from Generator 1
```

Generator 1 reads cluster configs. Generator 2 uses `{{.group}}` to scan that group's app overlays. Every cluster gets all base apps rendered through its group's kustomize overlay.

### ApplicationSet 2: Cluster Addons

```yaml
generators:
  - matrix:
      generators:
        - git:
            files:
              - path: matrix/clusters/*/config.yaml
        - git:
            directories:
              - path: 'matrix/clusters/{{.cluster_name}}/addons/*'
```

Only clusters with an `addons/<app>/` directory get that addon deployed.

### Result

| Cluster | Base Apps | Addons | Group |
|---------|-----------|--------|-------|
| cluster-001 | monitoring, ingress, logging | gpu-operator | us-east |
| cluster-002 | monitoring, ingress, logging | _(none)_ | us-east |
| cluster-003 | monitoring, ingress, logging | gpu-operator, edge-cache | eu-west |

**11 Applications** from 2 ApplicationSets.

### Trade-offs

| Pro | Con |
|-----|-----|
| 2 ApplicationSets for all clusters | Per-group overlay dirs for every base app |
| Cluster params from config files | Adding a base app touches every group |
| Full kustomize power per group | More directory indirection |
| Adding a cluster = 1 config.yaml | Group must exist before clusters reference it |

---

## Approach 3: Lovely + Charmap (`lovely/`)

**argocd-lovely-plugin + charmap** for template variable substitution. Each cluster runs its own ArgoCD instance with cluster identity (`CLUSTER_NAME`, `GROUP`, etc.) set as environment variables at bootstrap. Base app manifests contain `<::VAR::>` markers resolved at render time — **no per-cluster directories and no per-group overlay directories needed**.

Since ArgoCD runs independently per cluster, the base app ApplicationSet is a simple directory generator — no matrix needed. Addons are selected at the group level.

### Structure

```
lovely/
├── apps/
│   ├── base/                          # Deployed to ALL clusters (templated)
│   │   ├── monitoring/
│   │   │   ├── deployment.yaml        # Uses <::GROUP::>, <::CLUSTER_NAME::>
│   │   │   └── kustomization.yaml
│   │   ├── ingress/
│   │   └── logging/
│   └── addons/                        # Addon definitions
│       ├── gpu-operator/
│       └── edge-cache/
├── groups/                            # Addon selection per group
│   ├── us-east/
│   │   └── addons/
│   │       └── gpu-operator/
│   │           └── kustomization.yaml # refs ../../../apps/addons/gpu-operator
│   └── eu-west/
│       └── addons/
│           ├── gpu-operator/
│           │   └── kustomization.yaml
│           └── edge-cache/
│               └── kustomization.yaml
└── applicationsets.yaml
```

No `clusters/` directory. Cluster identity comes from ArgoCD's own environment variables, set during cluster bootstrap (Terraform, Ansible, etc.). Adding a new cluster is a bootstrap operation — no git change required.

### Templated Manifests

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monitoring
  labels:
    app: monitoring
    group: "<::GROUP::>"
    cluster: "<::CLUSTER_NAME::>"
spec:
  template:
    metadata:
      labels:
        group: "<::GROUP::>"
        cluster: "<::CLUSTER_NAME::>"
    spec:
      containers:
        - name: monitoring
          command: ['sh', '-c', 'echo "monitoring on <::CLUSTER_NAME::> (<::GROUP::>)"']
```

### ApplicationSet 1: Base Apps

```yaml
generators:
  - git:
      directories:
        - path: lovely/apps/base/*
```

No matrix. No per-cluster config. Every ArgoCD instance deploys all base apps. Charmap resolves `<::GROUP::>`, `<::CLUSTER_NAME::>`, etc. from the env vars already configured on the ArgoCD repo-server.

### ApplicationSet 2: Group Addons

```yaml
generators:
  - git:
      directories:
        - path: 'lovely/groups/<::GROUP::>/addons/*'
```

The `<::GROUP::>` in the ApplicationSet path is resolved by charmap from the ArgoCD instance's env. Each cluster's ArgoCD only sees addons for its own group.

### CMP Configuration

One-time change to the ArgoCD repo-server CMP config to pass through the cluster identity variables:

```sh
charmap --mode flag \
  --set GROUP=${GROUP} \
  --set CLUSTER_NAME=${CLUSTER_NAME} \
```

These env vars are set on the ArgoCD repo-server at cluster bootstrap time.

### Result

Each cluster deploys all base apps plus its group's addons. No per-cluster git state needed.

### Trade-offs

| Pro | Con |
|-----|-----|
| Near-zero git dirs — no per-cluster state | Requires argocd-lovely-plugin + charmap CMP |
| Adding a cluster = bootstrap only, no git change | String substitution only (no structural transforms) |
| Adding a base app = 1 dir, all clusters get it | CMP config must declare each passthrough variable |
| Addon selection at group level scales to thousands | Per-cluster addon exceptions require additional mechanism |
| Kustomize still available for structural changes | Harder to diff rendered output without running charmap |

---

## Group Overrides

**Approach 2** uses kustomize overlays per group — full structural power (patches, replicas, resource overrides, image swaps).

**Approach 3** uses template variables for string values (labels, annotations, config endpoints, DNS suffixes). For structural changes, combine with kustomize patches in the base app's `kustomization.yaml`.

Example group overlay (Approach 2):

```yaml
# groups/us-east/apps/monitoring/kustomization.yaml
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

Equivalent in Approach 3 — no overlay file needed, just a template marker in the base manifest:

```yaml
# apps/base/monitoring/deployment.yaml
metadata:
  labels:
    group: "<::GROUP::>"
```
