# weka-operator-autoscale-clients

Worked examples for running **WEKA operator-managed clients on an autoscaling
Kubernetes node pool** — so the cluster autoscaler can scale client nodes in and
out cleanly, **without blocking node drain and without the removed-node
finalizer deadlock**.

Built and validated against an operator **v1.10.4** lab cluster (the version
running in the target environment). CR field availability is version-sensitive;
see [Version notes](#version-notes).

---

## Who this is for

You run WEKA via the operator, and some of your client nodes are in a
**cluster-autoscaler-managed pool** (e.g. CPU-only worker nodes that mount WEKA
for jobs and scale to zero between them). Backends and the driver-distribution
(`dist`) role live on a **stable, non-autoscaled** pool.

That is exactly the shape this repo addresses: **UDP clients on an autoscaling
pool, backends + `dist` pinned to fixed nodes.**

---

## The two problems

Autoscaling client nodes hit two distinct failures. They are independent — you
can have one fixed and still be bitten by the other.

| # | Problem | Symptom | Layer |
|---|---------|---------|-------|
| 1 | **Node drain is blocked** | cluster-autoscaler never scales the node down; it sits idle and costs money | pod placement / eviction |
| 2 | **Removed-node cleanup deadlock** | client `WekaContainer`s get stuck on their finalizer after scale-out; they pile up and jam the operator reconcile loop | finalizer / cleanup |

### Problem 1 — why drain is blocked
- The WekaClient pod has priority class `weka-targeted-no-evict` and tolerates
  node-pressure taints, so the autoscaler treats it as **non-evictable** and
  refuses to drain the node.
- The `dist` container distributes the kernel driver to client nodes. If it
  lands on an autoscaling node, the autoscaler tries to drain it, fails, and
  **scale-down is blocked on that node indefinitely.**

### Problem 2 — why cleanup deadlocks
When a node is scaled out, the operator's `CLEANUP_REMOVED_NODES` path sets a
`deletionTimestamp` on the client `WekaContainer`, then `HandleDeletion →
CleanupPersistentDir` spawns a cleanup **Job pinned to that node's hostname**
(`kubernetes.io/hostname`). If the node is already gone (or lingering
`NotReady`), the Job can never schedule and the finalizer never clears. These
stack up — hundreds of stuck containers can jam the reconcile loop.

The operator *already* self-skips cleanup when the Node **object** is fully
gone (`GetNodeInfo → NotFound → "node is deleted, no need for cleanup"`). The
deadlock happens in the window where the **machine** is gone but the **Node
object lingers `NotReady`** (the autoscaler tore down the VM but never reaped
the Node object).

---

## TL;DR — the fixes

| Fix | What it solves | Where it goes |
|-----|----------------|---------------|
| Scope clients to the autoscaling pool | clients only land where you expect | `WekaClient.spec.nodeSelector` |
| Pin `dist` to the stable pool | unblocks scale-down (Problem 1) | `WekaPolicy …driverDistPayload.distNodeSelector` |
| Let the autoscaler evict the client | unblocks scale-down (Problem 1) | `safe-to-evict` annotation **or** node taint + client toleration |
| `skipCleanupPersistentDir: true` | kills the cleanup deadlock at the source (Problem 2) | `WekaContainer.spec.overrides` |
| Reap orphaned Node objects on scale-in | root-cause hygiene (Problem 2) | autoscaler / a small reaper, **not** a label cronjob |

> **Do not** reach for `EVICT_CONTAINER_ON_DELETION=true` to fix stuck *clients*.
> That flag is gated to **backend** containers only — it has no effect on
> clients and changes backend teardown behavior. See
> [docs/cleanup-deadlock.md](docs/cleanup-deadlock.md).

---

## If you're using the label-cleanup cronjob today — read this

A common workaround is a **cronjob that strips the `weka.io/supports-clients`
label before scale-down**, so the operator tears the client down while the
node-agent is still alive. It works, but it is fragile: if the cronjob is
disabled, mistimed, or removed as "unused," **Problem 2 comes straight back**
and stuck containers pile up.

**The change this repo recommends:** retire the cronjob and replace it with two
durable, operator-native pieces:

1. **`skipCleanupPersistentDir: true`** on the autoscale client `WekaContainer`s
   — short-circuits the node-pinned cleanup Job before it is ever created, so
   there is nothing to deadlock on. Available in v1.10.4 (the version you're
   already running).
2. **Orphaned Node-object reaping** on scale-in — ensure your autoscaler /
   cloud-controller actually deletes the `Node` object when it deletes the VM
   (`kubectl delete node <name>` is the manual equivalent). With the Node gone,
   the operator self-skips cleanup; with it lingering `NotReady`, you get the
   deadlock.

Keep your existing placement fixes (client `nodeSelector` + `dist` pinning +
eviction) — those are correct and still needed. Only the **cleanup mechanism**
changes.

---

## Layout

```
manifests/      # the CRs / patches, each demonstrating one fix
scripts/        # numbered walkthrough: show state, simulate scale-in, observe, fix
docs/           # deeper explanation per problem
transcripts/    # real captured output from the lab run (see RESULTS.md)
RESULTS.md      # what was validated, on what cluster, with evidence
```

Start with `scripts/demo.sh` for the end-to-end walkthrough, or read
[docs/placement.md](docs/placement.md) and
[docs/cleanup-deadlock.md](docs/cleanup-deadlock.md).

---

## Version notes

Validated on **operator v1.10.4**. Field availability differs across versions:

- `WekaClient.spec.nodeSelector`, `.tolerations`, `.rawTolerations` — present in
  v1.10.4.
- `WekaPolicy …driverDistPayload.distNodeSelector` — present in v1.10.4; this is
  how you pin the `dist` role.
- `WekaContainer.spec.overrides.skipCleanupPersistentDir` — present in v1.10.4.
  **Note:** this is a `WekaContainer` override; `WekaClientSpecOverrides` does
  **not** expose it in v1.10.4, so it is applied to the client containers (see
  [docs/cleanup-deadlock.md](docs/cleanup-deadlock.md) for how).
- `rawPodAnnotations` on `WekaClient` — **not** present in v1.10.4 (it appears in
  later operators). On v1.10.4 the `safe-to-evict` signal is delivered by
  annotating the **WekaClient CR metadata** — the operator propagates CR
  annotations onto the client pod (validated live; see
  [docs/placement.md](docs/placement.md) and [RESULTS.md](RESULTS.md)).

The removed-node cleanup path (the delete trigger + the node-pinned cleanup Job)
is **unchanged from v1.10.4 through v1.13.0**, so upgrading the operator does not
remove the need for these fixes.
