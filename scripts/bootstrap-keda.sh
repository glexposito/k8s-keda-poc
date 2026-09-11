#!/usr/bin/env bash
# One-time bootstrap: teaches every cluster's CoreDNS how to resolve
# "azurite" by name. Independent of bootstrap-argocd.sh - can run before
# or after it, in either order, any number of times.
#
# KEDA's azure-queue scaler (installed by argocd/keda-appset.yaml) runs
# as a pod in each cluster and polls the queue directly from there, so
# each cluster needs to resolve "azurite" from inside a pod's own network
# namespace - same problem bootstrap-argocd.sh solves for cross-cluster
# k3s hostnames, and the same fix: a `coredns-custom` ConfigMap mapping
# the hostname to azurite's current docker-network IP, discovered fresh
# here since it isn't guaranteed stable across restarts.
#
# Run this after `docker compose up -d`, once azurite is healthy.
set -euo pipefail

ALL_CLUSTERS=(internal stg prod)

step() { echo "==> $*"; }

step "Discovering azurite's docker-network IP..."
AZURITE_IP=$(docker inspect azurite --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

step "Teaching every cluster's CoreDNS how to resolve azurite..."
for cluster in "${ALL_CLUSTERS[@]}"; do
  # `kubectl patch --type merge` (JSON Merge Patch), not `apply` - this
  # ConfigMap is shared with bootstrap-argocd.sh on the prod cluster
  # (which owns internal.override/stg.override there), and a plain
  # `apply` of a partial manifest - client-side OR --server-side - was
  # confirmed to replace the *whole* data map rather than merge it by
  # key, silently deleting the other script's entries. JSON Merge Patch
  # is what actually merges by key regardless of prior history. See the
  # matching comment in bootstrap-argocd.sh.
  docker exec "k3s-$cluster" kubectl get configmap coredns-custom -n kube-system >/dev/null 2>&1 || \
    docker exec "k3s-$cluster" kubectl create configmap coredns-custom -n kube-system
  docker exec -i "k3s-$cluster" kubectl patch configmap coredns-custom -n kube-system --type merge --patch-file=/dev/stdin <<EOF
data:
  azurite.override: |
    template IN A {
      match "^azurite\."
      answer "{{ .Name }} 60 IN A $AZURITE_IP"
      fallthrough
    }
EOF
  docker exec "k3s-$cluster" kubectl rollout restart deployment/coredns -n kube-system
  docker exec "k3s-$cluster" kubectl rollout status deployment/coredns -n kube-system --timeout=60s
done

echo ""
echo "All three clusters can now resolve azurite:10001 from inside pods."
