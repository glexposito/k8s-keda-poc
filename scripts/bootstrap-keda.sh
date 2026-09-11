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
  # --server-side --field-manager=bootstrap-keda: this ConfigMap is
  # shared with bootstrap-argocd.sh on the prod cluster (which owns
  # internal.override/stg.override there) - server-side apply tracks
  # ownership per data key, so this script's own key survives regardless
  # of which script ran first or how many times either re-runs. See the
  # matching comment in bootstrap-argocd.sh.
  docker exec -i "k3s-$cluster" kubectl apply --server-side --field-manager=bootstrap-keda -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
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
