#!/usr/bin/env bash
# Read-only inventory of how your autoscale clients are placed and whether the
# autoscaler can evict them. Run against your cluster (kubectl configured).
#
#   NS=default CLIENT=cluster-dev-clients ./01-show-state.sh
set -euo pipefail
NS="${NS:-default}"
CLIENT="${CLIENT:-}"

echo "== WekaClients =="
kubectl get wekaclient -n "$NS" -o wide 2>/dev/null || true

echo; echo "== client WekaContainers (mode=client) =="
kubectl get wekacontainer -n "$NS" -o json 2>/dev/null \
| jq -r '.items[] | select(.spec.mode=="client")
        | "\(.metadata.name)\tnode=\(.spec.nodeAffinity // .status.nodeAffinity // "?")\tskipCleanup=\(.spec.overrides.skipCleanupPersistentDir // false)"' \
| column -t || true

echo; echo "== client pod evictability (the thing the autoscaler checks) =="
for p in $(kubectl get pods -n "$NS" -o name 2>/dev/null | grep -i client); do
  pc=$(kubectl get "$p" -n "$NS" -o jsonpath='{.spec.priorityClassName}' 2>/dev/null)
  se=$(kubectl get "$p" -n "$NS" -o jsonpath='{.metadata.annotations.cluster-autoscaler\.kubernetes\.io/safe-to-evict}' 2>/dev/null)
  node=$(kubectl get "$p" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  printf "  %-50s node=%-20s priorityClass=%-24s safe-to-evict=%s\n" \
    "${p#pod/}" "$node" "${pc:-<none>}" "${se:-<MISSING -> not evictable>}"
done

echo; echo "== dist placement (should be on the STABLE pool, not autoscaling) =="
kubectl get pods -A -o wide 2>/dev/null | grep -iE 'drivers-dist|dist' | grep -v drivers-builder || echo "  (no dist pod found by name match; check your driver-dist WekaPolicy)"

echo; echo "Interpretation:"
echo "  - safe-to-evict MISSING + priorityClass weka-targeted-no-evict => autoscaler will NOT drain the node (Problem 1)."
echo "  - a client WekaContainer with skipCleanup=false + node-pinned => exposed to the removed-node cleanup deadlock (Problem 2)."
