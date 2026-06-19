#!/usr/bin/env bash
# Reap orphaned Node objects left NotReady after a scale-in.
#
# The removed-node cleanup deadlock only exists while a Node object lingers
# NotReady after its VM is gone. Deleting that Node object flips the operator
# into its clean "node is deleted, skip cleanup" path and releases stuck
# WekaContainer finalizers — no per-container edits needed.
#
# This is the manual equivalent of the autoscaler/cloud-controller hygiene that
# SHOULD reap Node objects on scale-in. Safe by default: dry-run unless --apply,
# and only considers nodes that are NotReady AND run no non-DaemonSet pods.
#
# Usage:
#   ./04-reap-orphaned-nodes.sh            # dry run (prints what it would delete)
#   ./04-reap-orphaned-nodes.sh --apply    # actually delete the orphaned nodes
set -euo pipefail
APPLY="${1:-}"

mapfile -t NOTREADY < <(
  kubectl get nodes --no-headers 2>/dev/null \
  | awk '$2 ~ /NotReady/ {print $1}'
)

if [ "${#NOTREADY[@]}" -eq 0 ]; then
  echo "No NotReady nodes. Nothing to reap."
  exit 0
fi

for n in "${NOTREADY[@]}"; do
  # Count non-DaemonSet pods still scheduled to this node.
  busy=$(kubectl get pods -A --field-selector "spec.nodeName=${n}" -o json 2>/dev/null \
    | jq '[.items[] | select((.metadata.ownerReferences // []) | any(.kind=="DaemonSet") | not)] | length')
  if [ "${busy:-0}" -gt 0 ]; then
    echo "SKIP  ${n}  (NotReady but still has ${busy} non-DaemonSet pod(s))"
    continue
  fi
  if [ "$APPLY" = "--apply" ]; then
    echo "DELETE ${n}"
    kubectl delete node "${n}"
  else
    echo "WOULD DELETE ${n}  (NotReady, no non-DaemonSet pods)"
  fi
done

[ "$APPLY" = "--apply" ] || echo $'\nDry run. Re-run with --apply to delete.'
