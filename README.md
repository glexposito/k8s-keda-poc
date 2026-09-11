# k8s-keda-poc

A tiny, throwaway PoC for showing people how we plan to lay out namespaces,
labels, and per-namespace guardrails in Kubernetes — before we wire up the
real GitOps flow. Anyone can clone this and spin up three local k3s clusters
to poke around.

## What this shows

Three independent single-node k3s clusters running as Docker containers:

- **internal** (`localhost:6444`)
- **stg** (`localhost:6446`)
- **prod** (`localhost:6445`)

Each cluster gets the same namespace layout (`manifests/<cluster>/`).
Those directories are bind-mounted into each container's
`/var/lib/rancher/k3s/server/manifests/custom` (a subdirectory, so k3s can
still write its own required manifests like `coredns.yaml`/`traefik.yaml`
alongside ours), and k3s auto-applies everything under `server/manifests`
recursively — `docker compose up -d` alone is enough to get a fully-seeded
cluster, no separate apply step needed.

This repo deploys two worker variants, `worker1` and `worker2` — same
chart, same image, same everything except the `QUEUE_NAME` env var (and,
once KEDA is added, their scaling rules) — both into a namespace called
`core-workers` on each cluster. The namespace name doesn't carry a stage
suffix: each cluster is already dedicated to one environment (silo model,
see "Namespace design rationale" below), so the cluster boundary is what
tells `core-workers` on `internal` apart from `core-workers` on `prod` —
namespace names aren't global, so reusing the same one across clusters is
fine and avoids a redundant suffix.

| Namespace      | Cluster  | Purpose                                              |
| -------------- | -------- | ----------------------------------------------------- |
| `core-workers` | internal | Safe to break, catches issues before anything customer-facing |
| `core-workers` | stg      | Customer-facing canary gate for `core-workers` on prod |
| `core-workers` | prod     | Customer-facing, full production traffic               |
| `chaos-prod`   | prod     | Fixed platform namespace — Argo CD lives here, not a workload tenant |

Every workload namespace carries `environment`, `stage`, `cost-center`, and
`managed-by` labels — `environment` and `stage` are the same value today
since each cluster maps 1:1 to one stage, kept as separate labels anyway
in case that changes again later:

```bash
docker exec k3s-internal kubectl get ns -l environment=internal
docker exec k3s-prod kubectl get ns -l stage=prod
```

Every cluster's `core-workers` namespace also has its own `ResourceQuota`, a
`LimitRange`, and a default-deny-except-same-namespace `NetworkPolicy` —
defined per cluster in `manifests/<cluster>/01-policies.yaml`, so the exact
same namespace name can carry a completely different quota on each cluster
(they're separate API servers; nothing links them by name). Each worker
runs the same `replicaCount` per environment (`internal`: 1, `stg`: 2,
`prod`: 5), so the actual pod floor per cluster is double that (both
workers combined) — quotas are sized to hold that floor plus headroom for
future scale-up, graduated by environment: `internal` is smallest, `stg`
is mid-sized, `prod` is largest.

## Prerequisites

- Docker + Docker Compose

That's it — no `kubectl` needed on your host. Each k3s container ships its
own `kubectl`, already pointed at itself, so you explore via `docker exec`
instead of setting up a local kubeconfig.

## Usage

```bash
docker compose up -d   # starts all three clusters, auto-applies manifests/internal, manifests/stg, manifests/prod
./scripts/bootstrap-argocd.sh   # installs Argo CD into chaos-prod, registers internal and stg as managed clusters
```

`bootstrap-argocd.sh` is the one step that isn't auto-applied YAML like
everything else — installing Argo CD itself, and bridging a cross-cluster
credential from `internal` and from `stg` into `prod`, both require reading
live values generated at boot, not just dropping a static file in
`manifests/`.

The `argocd/` directory holds the app-of-apps bootstrap:

- `root-app.yaml` — applied once by the script; everything else here is
  then picked up and synced automatically.
- `clusters-appset.yaml` — one `Application` per cluster, syncing
  `manifests/<cluster>/` (namespaces, quotas, RBAC, network policies) via
  GitOps instead of k3s's own auto-deploy mount.
- `core-workers-appset.yaml` — one `ApplicationSet` with a matrix
  generator crossing every stage with every worker, deploying
  `charts/core-workers` (both `worker1` and `worker2`) into their shared
  namespace on all three clusters — 6 Applications from one file.
- `projects/platform.yaml`, `projects/core-workers.yaml` — `AppProject`s
  scoping what each Application is actually allowed to touch: `platform`
  (the governance layer above) can create cluster-scoped resources like
  `Namespace`; `core-workers` is restricted to only its own namespaces,
  with no cluster-scoped access at all.

All of these reference this repo's real remote
(`https://github.com/glexposito/k8s-keda-poc.git`) as `repoURL`, so they
sync as-is once Argo CD is running.

`charts/core-workers` is a small, generic Helm chart (not tied to any real
app or company) — one `values.yaml` with shared defaults, plus two
independent axes of overrides layered on top by the appset:
`values-internal.yaml`/`values-stg.yaml`/`values-prod.yaml` (environment:
`replicaCount` and `APP_ENV`) and `values-worker1.yaml`/
`values-worker2.yaml` (worker identity: `QUEUE_NAME` today, scaling rules
once KEDA is added). `charts/common` holds shared name/label helpers used
by the chart.

Then explore (pick the container for the cluster you want: `k3s-internal`,
`k3s-stg`, or `k3s-prod`):

```bash
docker exec k3s-internal kubectl get ns --show-labels
docker exec k3s-stg kubectl get ns --show-labels
docker exec k3s-prod kubectl get ns --show-labels
docker exec k3s-internal kubectl -n core-workers get pods -o wide
docker exec k3s-internal kubectl -n core-workers get resourcequota,limitrange
docker exec k3s-stg kubectl -n core-workers get resourcequota,limitrange
docker exec k3s-prod kubectl -n core-workers get resourcequota,limitrange
docker exec k3s-prod kubectl -n chaos-prod get pods                     # Argo CD components
docker exec k3s-prod kubectl -n chaos-prod get secrets -l argocd.argoproj.io/secret-type=cluster  # managed clusters
```

Tear down:

```bash
docker compose down            # keep volumes (cluster state persists)
docker compose down -v         # also wipe cluster state
```
