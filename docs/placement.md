# Problem 1 — node drain blocked by client and `dist` pods

The cluster autoscaler will only scale a node down if every pod on it can be
evicted. Two WEKA pods block that by default.

## Blocker A — the WekaClient pod is non-evictable

The WekaClient pod runs with priority class `weka-targeted-no-evict` and
tolerates node-pressure taints, so the autoscaler treats it as non-evictable and
refuses to drain the node.

## Blocker B — the `dist` pod lands on an autoscaling node

The `dist` (driver-distribution) container hands the compiled kernel driver to
client nodes. It must run somewhere stable. If it schedules onto an autoscaling
node, the autoscaler tries to drain it, fails, and **scale-down on that node is
blocked indefinitely.**

---

## Fix A — scope clients to the autoscaling pool

Pin WekaClient pods to the autoscaling node pool with a `nodeSelector`, so they
only ever land where you intend:

```yaml
# WekaClient.spec  (see manifests/wekaclient-autoscale.yaml)
spec:
  nodeSelector:
    weka.io/supports-clients: "true"        # operator's client-scheduling label
    <your-pool-label>: <autoscaling-pool>   # e.g. cloud.google.com/gke-nodepool: clients
```

## Fix B — pin `dist` to the stable pool (v1.10.4: `WekaPolicy`)

In v1.10.4 the `dist` placement is controlled by the **WekaPolicy** driver-dist
payload, not the WekaClient:

```yaml
# WekaPolicy …spec.payload.driverDistPayload  (see manifests/wekapolicy-dist-pinning.yaml)
distNodeSelector:
  weka.io/role: backend        # a label only your fixed backend/stable nodes carry
```

The stable pool (backends, management, `dist`) must be **excluded from the
autoscaler** (fixed count) and carry the `weka.io/role: backend` label.

## Fix C — make the client evictable on scale-down

By default the WekaClient pod is non-evictable: it runs with priority class
`weka-targeted-no-evict` and tolerates essentially every node taint (including
`node.kubernetes.io/unschedulable:NoExecute`), so the autoscaler will not drain
it. You make it evictable with the `safe-to-evict` annotation, and optionally
add a taint/toleration to make placement deterministic.

### C1 (recommended, validated on v1.10.4) — `safe-to-evict` via the WekaClient CR annotation

The cluster autoscaler evicts a pod that carries:

```
cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
```

**How you set it on v1.10.4:** the `WekaClient` CR has no `rawPodAnnotations`
field in v1.10.4 (that arrives in later operators). Instead, **annotations you
put on the `WekaClient` CR's metadata are propagated by the operator onto the
client pod** (the operator records what it copied in
`weka.io/applied-annotations`). Validated live — see [../RESULTS.md](../RESULTS.md).

```bash
kubectl annotate wekaclient <name> \
  cluster-autoscaler.kubernetes.io/safe-to-evict=true --overwrite
```

Or declaratively in the CR:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaClient
metadata:
  name: autoscale-clients
  annotations:
    cluster-autoscaler.kubernetes.io/safe-to-evict: "true"   # propagated to the pod
spec:
  ...
```

On a **newer** operator, set it directly via `WekaClient.spec.rawPodAnnotations`.

### C2 (optional) — taint the pool, tolerate it on the client

To keep the client (and your jobs) on the intended pool and make scale-down
deterministic, taint the autoscaling pool and add the matching toleration to the
WekaClient (`spec.tolerations` / `spec.rawTolerations`, both present in v1.10.4):

```yaml
# WekaClient.spec
spec:
  rawTolerations:
    - key: weka.io/client
      operator: Exists
      effect: NoSchedule
```

(Replace with the taint your pool actually carries.) Note: a taint by itself
does **not** make the client evictable — you still need the `safe-to-evict`
annotation from C1.

---

## Putting it together — node pool design

| Pool | Autoscaled? | Label | Runs |
|------|-------------|-------|------|
| **Stable** | No (fixed) | `weka.io/role: backend` | backends, management, `dist` |
| **Clients** | Yes | `weka.io/supports-clients: "true"` + pool label/taint | WekaClient pods + your jobs |

With clients scoped to the autoscaling pool, `dist` pinned to the stable pool,
and clients made evictable, the autoscaler can drain and remove client nodes
cleanly. Combine with [cleanup-deadlock.md](cleanup-deadlock.md) so the scale-out
side doesn't leave stuck finalizers behind.
