# Problem 2 — removed-node cleanup deadlock

## What happens

When the cluster autoscaler scales a client node **out**:

1. The operator's `CLEANUP_REMOVED_NODES` path notices the node is gone and sets
   a `deletionTimestamp` on that node's client `WekaContainer`.
2. `HandleDeletion → CleanupPersistentDir` runs. For a client with local
   persistence (no PVC), it creates a cleanup **Job pinned to the node**:

   ```yaml
   nodeSelector:
     kubernetes.io/hostname: <the-now-gone-node>
   ```
3. That node no longer exists (or is `NotReady`), so the Job is unschedulable.
   The cleanup never completes, the finalizer never clears, and the
   `WekaContainer` is stuck `Terminating` forever.
4. These accumulate. Hundreds of stuck containers can jam the operator's
   reconcile loop.

## Why it sometimes "just works" and sometimes deadlocks

`cleanupPersistentDir` already has an escape hatch: if the **Node object** is
fully gone, `GetNodeInfo` returns `NotFound` and the operator logs
`"node is deleted, no need for cleanup"` and skips it cleanly.

The deadlock is the **race window**: the VM is destroyed but the **Node object
lingers `NotReady`** (the autoscaler deleted the machine but never reaped the
`Node`). In that window the cleanup neither skips (Node object still present)
nor succeeds (machine gone) — it spins.

### What we observed in the lab (important nuance)

On teardown the operator creates a cleanup Job named
`weka-cleanup-container-<uid>` in the operator namespace
(`weka-operator-system`), pinned via `nodeSelector: {kubernetes.io/hostname:
<node>}`.

- On a **Ready** node — even a **cordoned** one — the Job schedules and
  completes; the container goes `Destroying` → gone, finalizer clears. The
  cleanup Job tolerates the `unschedulable` taint, so **cordon/drain alone does
  NOT reproduce the deadlock.**
- The deadlock requires the node to be **`NotReady` or gone** (kubelet not
  running to start the pinned Job, or no node to bind to). That is exactly the
  autoscaler scale-out case, and what produced the 200+ stuck containers in the
  field.

So the trigger is specifically *node removed/NotReady*, not *node cordoned*.

## Fix 1 (primary): `skipCleanupPersistentDir` on the client WekaContainer

Setting this override makes the operator short-circuit cleanup **before** the
node-pinned Job is created:

```yaml
# WekaContainer (client), spec.overrides
spec:
  overrides:
    skipCleanupPersistentDir: true
```

Trade-off: the client's local data under `/opt/k8s-weka` is left on the node —
which is exactly what you want for a node that is being destroyed anyway.

> **v1.10.4 placement of the field.** `skipCleanupPersistentDir` lives on
> `WekaContainerSpecOverrides`, **not** `WekaClientSpecOverrides` (which in
> v1.10.4 only exposes `skipActiveMountsCheck`). So it is applied to the client
> `WekaContainer`(s), not the parent `WekaClient`. See
> `manifests/wekacontainer-skipcleanup-patch.yaml` for the exact patch and
> `scripts/04-apply-skipcleanup.sh`.

## Fix 2 (root cause): reap orphaned Node objects on scale-in

The deadlock only exists because Node objects linger `NotReady`. If your
autoscaler / cloud-controller deletes the `Node` object when it deletes the VM,
the operator self-skips cleanup and finalizers clear on their own — no
per-container override needed.

Manual equivalent to clear a stuck backlog right now:

```bash
kubectl delete node <orphaned-NotReady-node>
```

This flips every container pinned to that node into the clean
"node is deleted, skip cleanup" path and releases their finalizers.

`scripts/04-reap-orphaned-nodes.sh` shows a safe sweep (only nodes that are
`NotReady` **and** have no running non-DaemonSet pods).

## Why NOT `EVICT_CONTAINER_ON_DELETION=true`

It is tempting, but it does not help here and can change backend behavior:

- The eviction branch is gated `IsBackend() && … && !IsProtocolContainer()`.
  **Client containers are not backends**, so the flag has **no effect** on the
  stuck client deletions.
- It *does* change how **backend** containers terminate on pod deletion, so
  flipping it on a fragile cluster is a net negative. Leave it `false`.

## Don't rely on the label-cleanup cronjob

Stripping the `weka.io/supports-clients` label before scale-down (so teardown
runs while the node-agent is alive) works until the cronjob is disabled,
mistimed, or removed — then this deadlock returns. Fixes 1 + 2 are durable and
operator-native; retire the cronjob.

## Version note

The removed-node cleanup path (the delete trigger and the node-pinned cleanup
Job) is **unchanged from operator v1.10.4 through v1.13.0**. v1.13.0 adds an
unrelated active-mounts improvement, but nothing in the cleanup/finalizer path.
**Upgrading does not remove the need for these fixes.**
