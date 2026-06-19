#!/usr/bin/env bash
# Make an autoscale WekaClient's pods evictable so cluster-autoscaler can drain
# the node (Problem 1, Fix C). Idempotent.
#
# v1.10.4: the WekaClient CR has no rawPodAnnotations; the operator propagates
# annotations from the WekaClient CR onto the client pod. So we annotate the CR.
#
#   NS=default CLIENT=cluster-dev-clients ./02-make-evictable.sh
set -euo pipefail
NS="${NS:-default}"
CLIENT="${CLIENT:?set CLIENT=<wekaclient name>}"

echo "[*] Annotating WekaClient/$CLIENT safe-to-evict=true (operator will propagate to the pod)"
kubectl annotate wekaclient "$CLIENT" -n "$NS" \
  cluster-autoscaler.kubernetes.io/safe-to-evict=true --overwrite

echo "[*] Waiting for the operator to propagate to the pod..."
for i in $(seq 1 12); do
  sleep 5
  ok=$(kubectl get pods -n "$NS" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.name|test("'"$CLIENT"'"))
             | .metadata.annotations["cluster-autoscaler.kubernetes.io/safe-to-evict"]] | any(.=="true")')
  [ "$ok" = "true" ] && { echo "[ok] client pod now carries safe-to-evict=true"; break; }
done

echo
echo "[note] This unblocks DRAIN (scale-down). It does NOT address the removed-node"
echo "       cleanup deadlock on scale-OUT — run 03-fix-cleanup.sh for that."
echo "[note] Pin the dist role to your stable pool too (see manifests/wekapolicy-dist-pinning.yaml)."
