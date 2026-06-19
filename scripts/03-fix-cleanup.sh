#!/usr/bin/env bash
# Avoid the removed-node cleanup deadlock (Problem 2) by setting
# skipCleanupPersistentDir=true on the autoscale client WekaContainers, so the
# operator never creates the node-pinned cleanup Job that deadlocks when the
# node is gone/NotReady. Idempotent. Retires the need for a label-cleanup cronjob.
#
#   NS=default ./03-fix-cleanup.sh
#
# Pair with reaping orphaned Node objects on scale-in (see 04-reap-orphaned-nodes.sh)
# — that is the root-cause hygiene fix.
set -euo pipefail
NS="${NS:-default}"

mapfile -t CLIENTS < <(
  kubectl get wekacontainer -n "$NS" -o json 2>/dev/null \
  | jq -r '.items[] | select(.spec.mode=="client") | .metadata.name'
)

if [ "${#CLIENTS[@]}" -eq 0 ]; then echo "No client WekaContainers in ns/$NS."; exit 0; fi

for c in "${CLIENTS[@]}"; do
  echo "[*] $c  -> spec.overrides.skipCleanupPersistentDir=true"
  kubectl patch wekacontainer "$c" -n "$NS" --type merge \
    -p '{"spec":{"overrides":{"skipCleanupPersistentDir":true}}}'
done

echo
echo "Verify:"
kubectl get wekacontainer -n "$NS" -o json 2>/dev/null \
| jq -r '.items[] | select(.spec.mode=="client")
        | "  \(.metadata.name)\tskipCleanup=\(.spec.overrides.skipCleanupPersistentDir // false)"'
echo
echo "[note] Also ensure your autoscaler/cloud-controller deletes the Node object"
echo "       on scale-in. If Node objects linger NotReady, run 04-reap-orphaned-nodes.sh."
