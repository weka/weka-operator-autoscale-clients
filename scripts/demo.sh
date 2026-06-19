#!/usr/bin/env bash
# Walkthrough: show current state, apply the fixes, show the result.
# Read-only by default; pass --apply to actually apply the fixes.
#
#   NS=default CLIENT=cluster-dev-clients ./demo.sh           # inspect only
#   NS=default CLIENT=cluster-dev-clients ./demo.sh --apply   # inspect + fix + re-inspect
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
NS="${NS:-default}"; export NS
CLIENT="${CLIENT:-}"; export CLIENT

echo "############################################################"
echo "# 1. Current state"
echo "############################################################"
bash "$here/01-show-state.sh"

if [ "${1:-}" != "--apply" ]; then
  echo; echo "Dry run. Re-run with --apply (and CLIENT set) to apply the fixes:"
  echo "  - 02-make-evictable.sh  (Problem 1: let the autoscaler drain the node)"
  echo "  - 03-fix-cleanup.sh     (Problem 2: avoid the removed-node cleanup deadlock)"
  echo "  - manifests/wekapolicy-dist-pinning.yaml (pin dist to the stable pool)"
  exit 0
fi

: "${CLIENT:?set CLIENT=<wekaclient name> to --apply}"
echo; echo "############################################################"
echo "# 2. Apply fixes"
echo "############################################################"
bash "$here/02-make-evictable.sh"
bash "$here/03-fix-cleanup.sh"

echo; echo "############################################################"
echo "# 3. State after"
echo "############################################################"
bash "$here/01-show-state.sh"
