# k8s-keda-poc

A tiny, throwaway PoC for showing people how we plan to lay out namespaces,
labels, and per-namespace guardrails in Kubernetes — before we wire up the
real GitOps flow. Anyone can clone this and spin up three local k3s clusters
to poke around.

## Design philosophy

KISS — keep it simple, stupid. Every design decision in this repo picks the
boring, obvious option over the clever one, even when the clever option is
more "correct." A few examples baked into the repo, not just claimed:

- Fixed IP addresses in `docker-compose.yaml` instead of a script that runs
  `docker inspect` to discover them at runtime.
- Kubernetes' own `NodePort` service for the Argo CD UI instead of a script
  wrapping `kubectl port-forward` in a background process.
- Compose healthchecks (`condition: service_healthy`) instead of a
  hand-rolled polling loop waiting for clusters to come up.
- A hardcoded demo password instead of a secrets-management story this PoC
  doesn't need.

If a change here needs more moving parts than the problem actually has,
that's a sign to simplify the approach, not to add another script.

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
recursively. `docker compose up -d` applies this baseline, installs Argo CD
on prod through the separately mounted `argocd/helmchart.yaml`, and - once
all three clusters and Argo CD are healthy - the `argocd-bootstrap` service
connects the clusters and starts GitOps deployment of KEDA and the workers.
No script to run by hand.

This repo deploys two worker variants, `worker1` and `worker2` — same
chart, same image, same everything except the `QUEUE_NAME` env var (and,
once KEDA is added, their scaling rules) — both into a namespace called
`core-workers` on each cluster. The namespace name doesn't carry a stage
suffix: each cluster is already dedicated to one environment (silo model),
so the cluster boundary is what tells `core-workers` on `internal` apart
from `core-workers` on `prod` —
namespace names aren't global, so reusing the same one across clusters is
fine and avoids a redundant suffix.

| Namespace      | Cluster  | Purpose                                              |
| -------------- | -------- | ----------------------------------------------------- |
| `core-workers` | internal | Safe to break, catches issues before anything customer-facing |
| `core-workers` | stg      | Customer-facing canary gate for `core-workers` on prod |
| `core-workers` | prod     | Customer-facing, full production traffic               |
| `argocd`       | prod     | Fixed platform namespace — Argo CD lives here, not a workload tenant |

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
docker compose up -d             # starts clusters and Azurite; K3s installs Argo CD;
                                  # argocd-bootstrap registers clusters and applies the root Application
```

That's the whole workflow - open https://localhost:9000 (`admin` / `123`) once
Argo CD is up. Nothing else to run.

Argo CD installation is managed by K3s's built-in Helm controller. The
`HelmChart` pins chart `10.8.4` (Argo CD `v3.5.2`) and declares the application
controller's CPU and memory settings. Compose mounts only this file into
K3s's auto-deploy directory. The root Application excludes it from its
directory scan, leaving installation management with K3s.
See the [K3s Helm documentation](https://docs.k3s.io/add-ons/helm).

The `argocd-bootstrap` Compose service handles registration: it waits (via
`depends_on: condition: service_healthy` on all three k3s services, plus its
own in-script waits for Argo CD's Deployments) for Argo CD and for populated
ServiceAccount token Secrets, then registers internal/stg with Argo CD and
applies the root Application. It talks to each cluster directly over the
`k8s-management` network using the kubeconfig each k3s server writes to
`/etc/rancher/k3s/k3s.yaml` (shared via a per-cluster named volume), not
`docker exec`. Tokens persist across restarts with the cluster volumes; if
just one remote cluster's volume gets rebuilt, rerun registration with
`docker compose up -d --force-recreate argocd-bootstrap`. internal, stg, and
azurite all get fixed IPs in `docker-compose.yaml`, so prod's CoreDNS override
(`manifests/prod/05-cluster-dns.yaml`) is static, git-committed YAML too -
nothing is discovered at runtime.

UI access needs no script or `kubectl port-forward`: `argocd/helmchart.yaml`
sets `server.service.type: NodePort` on `30090`, mapped to host port 9000 in
`docker-compose.yaml`, and pins the `admin` password to `123` via
`configs.secret.argocdServerAdminPassword` (a bcrypt hash committed in that
file) - fine for a throwaway local PoC that never leaves `localhost`, not a
pattern to copy for anything real.

For a fresh install, inspect the Helm job if Argo CD does not become ready:

```bash
docker exec k3s-prod kubectl -n kube-system get helmchart argocd
docker exec k3s-prod kubectl -n kube-system logs job/helm-install-argocd
```

The `argocd/` directory holds the app-of-apps bootstrap:

- `helmchart.yaml` — installed directly by K3s through the Compose file mount;
  excluded from the root Application's scan.
- `root-app.yaml` — applied once by `argocd-bootstrap`; the ApplicationSets
  and AppProjects here are then picked up and synced automatically.
- `clusters-appset.yaml` — one `Application` per cluster, syncing
  `manifests/<cluster>/` (namespaces, quotas, RBAC, network policies) via
  GitOps instead of k3s's own auto-deploy mount.
- `keda-appset.yaml` — installs KEDA (the operator + CRDs behind
  `core-workers`' autoscaling) via its official Helm chart, once per
  cluster, since it's a cluster-scoped operator, not something the
  cluster running Argo CD can provide to the others.
- `core-workers-appset.yaml` — one `ApplicationSet` with a matrix
  generator crossing every stage with every worker, deploying
  `charts/core-workers` (both `worker1` and `worker2`) into their shared
  namespace on all three clusters — 6 Applications from one file. Each
  worker gets a KEDA `ScaledObject` scaling on `core-workers-queue`'s
  depth, with different messages-per-replica ratios and ceilings per
  environment: `internal` 1 per 50 (max 5), `stg` 1 per 25 (max 10),
  `prod` 1 per 10 (max 20) — all scale to zero when the queue's empty.
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
docker exec k3s-prod kubectl -n argocd get pods                     # Argo CD components
docker exec k3s-prod kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster  # managed clusters
```

### Queue messages

Use the helper to change the queue depth while watching KEDA scale the workers:

```bash
./scripts/queue-messages.sh add 100      # append 100 demo messages
./scripts/queue-messages.sh remove 95    # delete up to 95 visible messages
./scripts/queue-messages.sh count        # show the approximate message count
```

The default queue is `core-workers-queue`, shared by both workers in all three
clusters. The amount is how many messages to add or remove, not the desired
final count. For example, removing 95 from 100 leaves 5 if nothing else changes
the queue. Removal preserves the remaining messages and stops if no more
visible messages are available; the count also includes invisible messages.

The script uses the existing `queue-seed` Compose image and connection settings,
so no Python or Azure CLI installation is needed on the host. Azurite must
already be running (`docker compose up -d azurite`). `add` creates the queue if
it does not exist. An optional final argument selects another queue, for example
`./scripts/queue-messages.sh add 10 test-queue`. Run with `--help` for usage.

On Windows, `scripts/queue-messages.ps1` is the same tool for PowerShell 7+
(`pwsh`) - same subcommands, same output, same underlying `queue-seed` image:

```powershell
./scripts/queue-messages.ps1 add 100
./scripts/queue-messages.ps1 remove 95
./scripts/queue-messages.ps1 count
```

### Tear down

```bash
docker compose down            # keep volumes (cluster state persists)
docker compose down -v         # also wipe cluster state
```

If you rebuild just one remote cluster's volume (not the whole stack),
re-register it with `docker compose up -d --force-recreate argocd-bootstrap`.
