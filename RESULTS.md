# Results — validated on a live operator v1.10.4 cluster

All claims in this repo were checked against a real operator-managed WEKA
cluster, not just docs. Raw command output is in [`transcripts/`](transcripts/).

## Lab

| | |
|---|---|
| Operator | **v1.10.4** (pinned to match the target environment) |
| WEKA image | `quay.io/weka.io/weka-in-container:4.4.10.183` |
| Kubernetes | v1.32, Ubuntu 22.04 (kernel 6.8), GCP |
| Topology | 6 backend nodes (compute+drive) + 1 client worker; UDP mode |
| Cluster | `WekaCluster/cluster-dev` → **Ready** (6/6 compute, 6/6 drive, 6/6 drives); `weka status` OK, IO STARTED, 1.18 TiB, fully protected |

See [`transcripts/cluster-ready.txt`](transcripts/cluster-ready.txt).

## What was validated

### Problem 1 — the client is non-evictable by default ✔ confirmed
The client pod runs with `priorityClassName: weka-targeted-no-evict` and
tolerates essentially every node taint (incl. `unschedulable:NoExecute`), and
has **no** `safe-to-evict` annotation. cluster-autoscaler will not drain it.
→ [`transcripts/client-not-evictable.txt`](transcripts/client-not-evictable.txt)

### Placement fix — `safe-to-evict` via the WekaClient CR annotation ✔ confirmed
v1.10.4 `WekaClient` has **no** `rawPodAnnotations` field. Annotating the
**WekaClient CR metadata** with `cluster-autoscaler.kubernetes.io/safe-to-evict=true`
caused the operator to **propagate the annotation onto the client pod** (and
record it under `weka.io/applied-annotations`). This is the v1.10.4 mechanism.
→ [`transcripts/safe-to-evict-propagation.txt`](transcripts/safe-to-evict-propagation.txt)

### `dist` pinning ✔ field confirmed
`dist` placement is controlled by the `WekaPolicy` driver-dist payload's
`distNodeSelector` in v1.10.4 (not the WekaClient). See
[`manifests/wekapolicy-dist-pinning.yaml`](manifests/wekapolicy-dist-pinning.yaml).

### Problem 2 — removed-node cleanup deadlock ✔ mechanism confirmed
- The client WekaContainer is **node-pinned** (`spec.nodeAffinity: <node>`) and
  `mode: client` (has persistent storage), so it takes the cleanup path.
- On teardown the operator creates a cleanup Job
  **`weka-cleanup-container-<uid>`** in `weka-operator-system`, pinned via
  `nodeSelector: {kubernetes.io/hostname: <node>}` (operator source
  `cleanup_persistent_dir.go`).
- **Important nuance, observed live:** on a **Ready** node — even a **cordoned**
  one — that Job schedules and completes (it tolerates the unschedulable taint),
  so cordon/drain alone does **not** deadlock. The deadlock requires the node to
  be **`NotReady`/removed** — the actual scale-out case (and what produced the
  200+ stuck containers in the field).
  → [`transcripts/cleanup-job-on-teardown.txt`](transcripts/cleanup-job-on-teardown.txt)

### Cleanup fix — `skipCleanupPersistentDir` ✔ confirmed accepted
`kubectl patch wekacontainer … spec.overrides.skipCleanupPersistentDir=true` is
accepted and stored on the client WekaContainer in v1.10.4 (the field is **not**
available on `WekaClientSpecOverrides`, only on the WekaContainer).
→ [`transcripts/skipcleanup-accepted.txt`](transcripts/skipcleanup-accepted.txt)

### `EVICT_CONTAINER_ON_DELETION` — correctly does NOT apply to clients
Source-confirmed gating `IsBackend() && … && !IsProtocolContainer()`; client
mode is not a backend, so the flag has no effect on stuck client deletions.

## Honesty notes

- The deadlock's terminal "Job stuck forever" state under a **`NotReady`** node
  was **not** forced live (it requires taking a node down); it is established by
  the operator source + the documented field incident. Every other step above
  was reproduced on the live cluster.
- The cluster used UDP clients on GCP; the CR fields and behaviors are
  cloud-agnostic. Node-pool *labels* (`weka.io/role`, pool selectors) differ per
  environment — adjust to match yours (e.g. OKE/OCI).
