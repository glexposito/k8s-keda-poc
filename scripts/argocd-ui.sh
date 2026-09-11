#!/usr/bin/env bash
# Open the local Argo CD UI independently of cluster registration.
set -euo pipefail

case "${1:-}" in
  -h|--help)
    echo "Usage: ./scripts/argocd-ui.sh [--password]"
    echo "Open https://localhost:9000, or print the initial admin password."
    exit 0
    ;;
  --password)
    [[ $# -eq 1 ]] || { echo "Usage: ./scripts/argocd-ui.sh [--password]" >&2; exit 2; }
    password=$(docker exec k3s-prod kubectl -n argocd get secret argocd-initial-admin-secret \
      --ignore-not-found -o jsonpath='{.data.password}')
    if [[ -z "$password" ]]; then
      echo "Initial admin password is unavailable. Wait for Argo CD to initialize, or use your existing password if the initial Secret was removed." >&2
      exit 1
    fi
    printf '%s' "$password" | base64 -d
    printf '\n'
    exit 0
    ;;
  "") ;;
  *) echo "Usage: ./scripts/argocd-ui.sh [--password]" >&2; exit 2 ;;
esac

docker exec k3s-prod kubectl -n argocd rollout status deployment/argocd-server --timeout=120s
echo "Argo CD: https://localhost:9000 (username: admin)"
echo "For the initial password, run ./scripts/argocd-ui.sh --password in another terminal."
echo "Keep this terminal open; press Ctrl+C to stop forwarding."
exec docker exec -it k3s-prod kubectl port-forward -n argocd svc/argocd-server --address 0.0.0.0 9000:443
