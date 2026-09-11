#!/usr/bin/env bash
# One-time bootstrap: installs Argo CD into the prod cluster's chaos-prod
# namespace via the official install manifest (same as any real Argo CD
# install, portable beyond this repo), then registers internal and stg as
# managed clusters.
#
# This can't be pure auto-applied YAML like everything in manifests/ - all
# three clusters generate independent, fresh credentials on every boot, so
# bridging internal's and stg's ServiceAccount tokens into prod's Argo CD
# means reading a live value and writing it elsewhere. It also has to patch
# prod's CoreDNS with each remote cluster's current docker-network IP (also
# not stable across restarts) so prod's Argo CD can even reach their API
# servers by name.
# Run this after `docker compose up -d`, once all three clusters are healthy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The remote clusters prod's Argo CD needs to reach by name - everything
# else in this script (CoreDNS override, token bridging, cluster
# registration) loops over this list, so adding a fourth remote cluster
# later is a one-line change here plus a manifests/<name>/ directory.
REMOTE_CLUSTERS=(internal stg)

step() { echo "==> $*"; }

step "Waiting for all clusters to be ready..."
docker exec k3s-prod kubectl wait --for=condition=ready node --all --timeout=120s
for cluster in "${REMOTE_CLUSTERS[@]}"; do
  docker exec "k3s-$cluster" kubectl wait --for=condition=ready node --all --timeout=120s
done

step "Teaching prod's CoreDNS how to resolve each remote cluster..."
# --server-side --field-manager (rather than plain client-side apply) so
# scripts/bootstrap-keda.sh can later add its own "azurite.override" key
# to this same coredns-custom ConfigMap without wiping the keys this
# script owns - plain `apply` does a client-side 3-way merge against the
# last-applied-configuration annotation, and would interpret a key it
# didn't write as "removed" the next time a different script's partial
# manifest gets applied. Server-side apply tracks ownership per key
# instead, so each script's own entries survive the other's applies.
# docker-compose's DNS (which resolves container names like "k3s-internal")
# only works from the k3s-prod container's own network namespace, not from
# inside a pod's separate network namespace - so prod's CoreDNS can't
# resolve a remote cluster's hostname on its own, even though the
# containers share a docker network. This adds a k3s-supported CoreDNS
# customization (a `coredns-custom` ConfigMap) mapping each hostname to
# that cluster's current docker-network IP, discovered fresh here since
# it isn't guaranteed stable across restarts.
COREDNS_DATA=""
for cluster in "${REMOTE_CLUSTERS[@]}"; do
  # Each container only ever joins the one network docker-compose.yaml
  # defines (k8s-management), so grab whichever network it's on rather
  # than hardcoding the network's full name - that name is
  # "<compose-project-name>_k8s-management", and the project name
  # defaults to the current directory's basename, so a hardcoded value
  # here silently breaks the moment this directory is renamed or cloned
  # somewhere else.
  ip=$(docker inspect "k3s-$cluster" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  COREDNS_DATA+="  ${cluster}.override: |
    template IN A {
      match \"^k3s-${cluster}\\.\"
      answer \"{{ .Name }} 60 IN A ${ip}\"
      fallthrough
    }
"
done
docker exec -i k3s-prod kubectl apply --server-side --field-manager=bootstrap-argocd -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
$COREDNS_DATA
EOF
docker exec k3s-prod kubectl rollout restart deployment/coredns -n kube-system
docker exec k3s-prod kubectl rollout status deployment/coredns -n kube-system --timeout=60s

step "Installing Argo CD into chaos-prod (official manifest, namespace-relocated via kustomize)..."
# Plain `kubectl apply -n chaos-prod -f install.yaml` is NOT enough here:
# the official manifest hardcodes the "argocd" namespace inside its
# ClusterRoleBindings' subjects, which `-n` does not rewrite. That leaves
# argocd-application-controller with a binding for the wrong identity and
# no real permissions. kustomize's namespace transformer rewrites both
# object namespaces and RBAC subject references correctly.
docker exec k3s-prod mkdir -p /tmp/argocd-kustomize
docker exec -i k3s-prod sh -c 'cat > /tmp/argocd-kustomize/kustomization.yaml' \
  < "$REPO_ROOT/scripts/argocd-kustomize/kustomization.yaml"
docker exec k3s-prod kubectl apply -k /tmp/argocd-kustomize --server-side --force-conflicts
docker exec k3s-prod kubectl rollout status deployment/argocd-server -n chaos-prod --timeout=300s

step "Registering internal and stg as managed clusters..."
for cluster in "${REMOTE_CLUSTERS[@]}"; do
  token=$(docker exec "k3s-$cluster" kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)

  docker exec -i k3s-prod kubectl apply -n chaos-prod -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster}-cluster
  namespace: chaos-prod
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster}
  server: https://k3s-${cluster}:6443
  config: |
    {
      "bearerToken": "$token",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF
done

step "Restarting application-controller so it picks up the new registrations..."
# argocd-application-controller started (in the previous step) before the
# cluster secrets existed. Argo CD is supposed to notice new cluster
# secrets dynamically, but in testing this was unreliable - Applications
# targeting a remote cluster would sit with empty status forever, never
# even attempted, while prod-targeting ones (known since startup) worked
# fine. Restarting after registration forces a clean connection attempt
# with all clusters known from the start.
docker exec k3s-prod kubectl delete pod -n chaos-prod -l app.kubernetes.io/name=argocd-application-controller
docker exec k3s-prod kubectl rollout status statefulset/argocd-application-controller -n chaos-prod --timeout=120s

step "Applying root Application (app-of-apps)..."
docker exec -i k3s-prod kubectl apply -n chaos-prod -f - < "$REPO_ROOT/argocd/root-app.yaml"

step "Exposing Argo CD UI on the host..."
docker exec -d k3s-prod kubectl port-forward -n chaos-prod svc/argocd-server --address 0.0.0.0 9000:443

ARGOCD_PASS=$(docker exec k3s-prod kubectl -n chaos-prod get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo ""
echo "Argo CD:          https://localhost:9000  (admin / $ARGOCD_PASS)"
echo "Managed clusters: prod (in-cluster), internal (https://k3s-internal:6443), stg (https://k3s-stg:6443)"
