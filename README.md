# ArgoCD ApplicationSet Patterns

Two approaches for managing app deployment across a large fleet of clusters using ArgoCD ApplicationSets and Kustomize overlays.

**Goal:** Deploy a base set of apps to all clusters, apply per-location configuration overrides, and selectively deploy additional apps to specific clusters.

---

## Approach 1: Overlay (`overlay/`)

A single ApplicationSet with a **git directory generator** that scans a per-cluster overlay directory. Each subdirectory becomes an ArgoCD Application. Apps are selected by directory presence — if a cluster's overlay doesn't include an app directory, it doesn't get deployed.

### Structure

```
overlay/
├── apps/                              # Base app definitions
│   ├── monitoring/
│   │   ├── deployment.yaml
│   │   └── kustomization.yaml
│   ├── ingress/
│   ├── logging/
│   ├── gpu-operator/                  # Available but not deployed everywhere
│   └── edge-cache/
│
├── clusters/
│   └── homelab/                       # This cluster's app selection
│       ├── monitoring/
│       │   └── kustomization.yaml     # → refs ../../../apps/monitoring
│       ├── ingress/
│       │   └── kustomization.yaml
│       └── logging/
│           └── kustomization.yaml
│       # gpu-operator and edge-cache: not included → not deployed
│
└── applicationset.yaml
```

### How It Works

1. All app definitions live in `apps/` as kustomize bases
2. Each cluster has a directory under `clusters/` containing only the apps it should run
3. Each cluster-app overlay is a `kustomization.yaml` that references the base app (and can add patches)
4. The ApplicationSet scans `overlay/clusters/<cluster>/*` — directory presence = deployment
5. To add an app: create the overlay directory. To remove: delete it (auto-sync prunes it)

### ApplicationSet

```yaml
generators:
  - git:
      repoURL: <repo>
      revision: HEAD
      directories:
        - path: overlay/clusters/homelab/*
```

### Trade-offs

| Pro | Con |
|-----|-----|
| Simple to understand | One ApplicationSet per cluster |
| Easy to add/remove apps per cluster | Doesn't scale well to thousands of clusters |
| Standard kustomize patterns | No built-in cluster parameter injection |
| Overlays can patch base apps | Per-cluster directories needed for every app |

---

## Approach 2: Matrix (`matrix/`)

Two ApplicationSets using the **matrix generator** to combine cluster identity with app discovery. Cluster config files provide parameters (location, server URL, etc.) that feed into the second generator's path templates.

This separates the problem into two layers:
- **Base apps with location overrides** — every cluster gets these, rendered through its location's kustomize overlay
- **Cluster-specific addons** — only clusters that opt in (via directory presence) get these

### Structure

```
matrix/
├── apps/
│   ├── base/                          # Deployed to ALL clusters
│   │   ├── monitoring/
│   │   ├── ingress/
│   │   └── logging/
│   └── addons/                        # Deployed selectively per cluster
│       ├── gpu-operator/
│       └── edge-cache/
│
├── locations/                         # Per-location kustomize overlays
│   ├── us-east/
│   │   ├── config.yaml                # location: us-east
│   │   └── apps/
│   │       ├── monitoring/
│   │       │   └── kustomization.yaml # refs base + location patches
│   │       ├── ingress/
│   │       └── logging/
│   └── eu-west/
│       ├── config.yaml
│       └── apps/
│           ├── monitoring/
│           ├── ingress/
│           └── logging/
│
├── clusters/                          # Per-cluster identity + addon selection
│   ├── cluster-001/
│   │   ├── config.yaml                # cluster_name, location, cluster_server
│   │   └── addons/
│   │       └── gpu-operator/
│   │           └── kustomization.yaml # refs ../../../../apps/addons/gpu-operator
│   ├── cluster-002/
│   │   └── config.yaml                # No addons directory → no extra apps
│   └── cluster-003/
│       ├── config.yaml
│       └── addons/
│           ├── gpu-operator/
│           └── edge-cache/
│
└── applicationsets.yaml               # Two ApplicationSets
```

### Cluster Config

Each cluster declares its identity and which location it belongs to:

```yaml
# clusters/cluster-001/config.yaml
cluster_name: cluster-001
location: us-east
cluster_server: https://cluster-001.example.com
```

The `location` field links the cluster to its location overlay, which controls how base apps are configured.

### ApplicationSet 1: Base Apps (all clusters × location overlays)

```yaml
generators:
  - matrix:
      generators:
        # Generator 1: Discover clusters, read their config
        - git:
            files:
              - path: matrix/clusters/*/config.yaml
        # Generator 2: Find base apps for each cluster's location
        # {{.location}} comes from Generator 1
        - git:
            directories:
              - path: 'matrix/locations/{{.location}}/apps/*'
```

**Flow:**
1. Generator 1 reads `clusters/*/config.yaml` → `{cluster_name: cluster-001, location: us-east, ...}`
2. Generator 2 uses `{{.location}}` → scans `locations/us-east/apps/*` → finds `monitoring`, `ingress`, `logging`
3. Matrix merges both parameter sets → generates `cluster-001-monitoring`, `cluster-001-ingress`, etc.
4. Repeat for every cluster — each gets all base apps through its location's overlay

### ApplicationSet 2: Cluster Addons (selective per cluster)

```yaml
generators:
  - matrix:
      generators:
        # Generator 1: Discover clusters, read their config
        - git:
            files:
              - path: matrix/clusters/*/config.yaml
        # Generator 2: Find addons for EACH cluster
        # {{.cluster_name}} comes from Generator 1
        - git:
            directories:
              - path: 'matrix/clusters/{{.cluster_name}}/addons/*'
```

**Flow:**
1. Generator 1 reads cluster configs
2. Generator 2 scans `clusters/<cluster_name>/addons/*` — only finds directories that exist
3. cluster-001 has `addons/gpu-operator/` → gets `cluster-001-gpu-operator`
4. cluster-002 has no `addons/` → gets nothing extra
5. cluster-003 has `addons/gpu-operator/` and `addons/edge-cache/` → gets both

### Generated Applications

| Cluster | Base Apps | Addons | Location |
|---------|-----------|--------|----------|
| cluster-001 | monitoring, ingress, logging | gpu-operator | us-east |
| cluster-002 | monitoring, ingress, logging | _(none)_ | us-east |
| cluster-003 | monitoring, ingress, logging | gpu-operator, edge-cache | eu-west |

**Total: 11 Applications** from 2 ApplicationSets and 3 cluster configs.

### Trade-offs

| Pro | Con |
|-----|-----|
| Single pair of ApplicationSets for all clusters | More indirection in the directory structure |
| Cluster params injected from config files | Requires understanding of matrix generator mechanics |
| Location overlays shared across clusters | Two levels of kustomize (location → base) |
| Scales to thousands of clusters | Per-cluster addon directories still needed for selective apps |
| Adding a cluster = one config.yaml | Location must exist before clusters can reference it |

---

## Scaling Considerations

### Adding a New Cluster

**Overlay:** Create `clusters/<name>/` with a kustomization for each desired app.

**Matrix:** Create `clusters/<name>/config.yaml` with `cluster_name`, `location`, and `cluster_server`. All base apps auto-deploy via the location. Optionally add `addons/<app>/` for selective apps.

### Adding a New Base App

**Overlay:** Create the app in `apps/`, then add an overlay directory to every cluster that needs it.

**Matrix:** Create the app in `apps/base/`, then add a kustomization in each location's `apps/` directory. Every cluster in those locations automatically gets it.

### Adding a New Location

**Matrix only:** Create `locations/<name>/config.yaml` and `locations/<name>/apps/` with kustomizations for each base app. Clusters referencing this location will use these overlays.

### Adding a New Addon

Both approaches: Create the addon in the apps directory, then add a kustomization under each cluster that should receive it.

---

## Location Overrides

Location overlays use standard kustomize to customize base apps per region. Common overrides:

- **Labels/annotations** — region tags, compliance markers
- **Replicas** — scale differently per region
- **Resource limits** — adjust for regional hardware profiles
- **ConfigMap patches** — region-specific endpoints, DNS suffixes
- **Image overrides** — use regional registries

Example location overlay:

```yaml
# locations/us-east/apps/monitoring/kustomization.yaml
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
        path: /metadata/labels/location
        value: us-east
      - op: add
        path: /spec/template/metadata/labels/location
        value: us-east
```
