#!/usr/bin/env bash
# Register the remote clusters and start GitOps after Compose starts K3s.
# Argo CD installation and resources live in argocd/helmchart.yaml.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_CLUSTERS=(internal stg)
step() { echo "==> $*"; }

step "Waiting for all clusters to be ready..."
for cluster in prod "${REMOTE_CLUSTERS[@]}"; do
  deadline=$((SECONDS + 120))
  until docker exec "k3s-$cluster" kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for the k3s-$cluster API." >&2
      exit 1
    fi
    sleep 2
  done
  docker exec "k3s-$cluster" kubectl wait --for=create node --all --timeout=120s
  docker exec "k3s-$cluster" kubectl wait --for=condition=ready node --all --timeout=120s
done

step "Configuring prod DNS for the remote clusters..."
# Docker assigns these addresses at container creation. Merge only our keys so
# the separately managed azurite.override entry is preserved.
COREDNS_DATA=""
for cluster in "${REMOTE_CLUSTERS[@]}"; do
  ip=$(docker inspect "k3s-$cluster" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  [[ -n "$ip" ]] || { echo "No Docker IP found for k3s-$cluster." >&2; exit 1; }
  COREDNS_DATA+="  ${cluster}.override: |
    template IN A {
      match \"^k3s-${cluster}\\.\"
      answer \"{{ .Name }} 60 IN A ${ip}\"
      fallthrough
    }
"
done
docker exec k3s-prod kubectl -n kube-system wait --for=create configmap/coredns-custom --timeout=120s
docker exec -i k3s-prod kubectl patch configmap coredns-custom -n kube-system --type merge --patch-file=/dev/stdin <<EOF
data:
$COREDNS_DATA
EOF
docker exec k3s-prod kubectl rollout restart deployment/coredns -n kube-system
docker exec k3s-prod kubectl rollout status deployment/coredns -n kube-system --timeout=120s

step "Waiting for Argo CD..."
# On a fresh cluster the Helm controller must create these workloads first.
# Existing installations can also use this registration script independently.
for workload in deployment/argocd-server deployment/argocd-repo-server \
  deployment/argocd-applicationset-controller statefulset/argocd-application-controller; do
  docker exec k3s-prod kubectl -n argocd wait --for=create "$workload" --timeout=600s
  docker exec k3s-prod kubectl -n argocd rollout status "$workload" --timeout=300s
done

step "Registering internal and stg as managed clusters..."
for cluster in "${REMOTE_CLUSTERS[@]}"; do
  # The token controller fills this Secret asynchronously. Tokens persist with
  # the cluster volumes; read them again after a cluster is rebuilt.
  docker exec "k3s-$cluster" kubectl -n kube-system wait --for=create secret/argocd-manager-token --timeout=120s
  docker exec "k3s-$cluster" kubectl -n kube-system wait --for=jsonpath='{.data.token}' secret/argocd-manager-token --timeout=120s
  token=$(docker exec "k3s-$cluster" kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
  docker exec -i k3s-prod kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster}-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster}
  server: https://k3s-${cluster}:6443
  config: |
    {"bearerToken":"$token","tlsClientConfig":{"insecure":true}}
EOF
done
unset token

step "Applying the root Application..."
docker exec -i k3s-prod kubectl apply -n argocd -f - < "$REPO_ROOT/argocd/root-app.yaml"
echo "Managed clusters: prod, internal, stg. Open the UI with ./scripts/argocd-ui.sh"
