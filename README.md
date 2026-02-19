# ArgoCD ApplicationSet Patterns

Three approaches for managing app deployment across a large cluster fleet using ArgoCD ApplicationSets and Kustomize.

**Goal:** Base apps on every cluster, per-group overrides, and selective addons per cluster.

## Summary

| | Overlay | Matrix | Lovely + Charmap |
|---|---|---|---|
| **Mechanism** | Git directory generator | Matrix generator + kustomize overlays per group | Matrix generator + CMP template substitution |
| **Base app selection** | Directory presence per cluster | Directory presence per group | All base apps auto-deploy to all clusters |
| **Group overrides** | Manual per-cluster patches | Kustomize overlays shared per group | `<::VAR::>` template markers resolved at render time |
| **Addon selection** | Directory presence per cluster | Directory presence per cluster | Directory presence per cluster |
| **ApplicationSets** | 1 per cluster | 2 total | 2 total |
| **Add a cluster** | Create N app overlay dirs | Create 1 `config.yaml` | Create 1 `config.yaml` |
| **Add a base app** | Touch every cluster dir | Add 1 kustomization per group | Add 1 app dir (done) |
| **Add a group** | N/A | Create group dir + N kustomizations | Set a value in config |
| **Best for** | < 10 clusters | 10-100 clusters | 100+ clusters |

At **3,000 clusters / 50 groups / 20 base apps**: Overlay = ~60k dirs, Matrix = ~4k dirs, Lovely = ~3k dirs.

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
│   └── homelab/                       # Only apps this cluster should run
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
        - path: overlay/clusters/homelab/*
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

Matrix generator with **argocd-lovely-plugin + charmap** for template variable substitution. Base app manifests contain `<::VAR::>` markers resolved at render time via `source.plugin.env` — **no per-group overlay directories needed**.

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
│   └── addons/
│       ├── gpu-operator/
│       └── edge-cache/
├── clusters/
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

No `groups/` directory. Group config is a value in each cluster's `config.yaml`, resolved by charmap at render time.

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
  - matrix:
      generators:
        - git:
            files:
              - path: lovely/clusters/*/config.yaml
        - git:
            directories:
              - path: lovely/apps/base/*
template:
  spec:
    source:
      path: '{{.path.path}}'
      plugin:
        env:
          - name: GROUP
            value: '{{.group}}'
          - name: CLUSTER_NAME
            value: '{{.cluster_name}}'
```

`source.plugin.env` passes ApplicationSet parameters as environment variables to the CMP. Charmap resolves `<::GROUP::>` → `us-east`, `<::CLUSTER_NAME::>` → `cluster-001`, etc.

### ApplicationSet 2: Cluster Addons

Same as Approach 2 — directory presence under `clusters/<name>/addons/`.

### CMP Configuration

One-time change to the ArgoCD repo-server CMP config to pass through the new variables:

```sh
charmap --mode flag \
  --set GROUP=${GROUP} \
  --set CLUSTER_NAME=${CLUSTER_NAME} \
```

### Result

Same 11 Applications as Approach 2, but with ~1,000 fewer overlay files.

### Trade-offs

| Pro | Con |
|-----|-----|
| Fewest files — no per-group overlay dirs | Requires argocd-lovely-plugin + charmap CMP |
| Adding a group = set a value in config | String substitution only (no structural transforms) |
| Adding a base app = 1 dir, all clusters get it | CMP config must declare each passthrough variable |
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
