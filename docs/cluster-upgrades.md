# Cluster Upgrades — Best Practices for Production & Large Clusters

This page is the customer-facing reference for upgrading a managed-K8s cluster on CloudSigma. It focuses on the **staged upgrade flow** (control plane first, workers under your control), the knobs that matter when you run **stateful workloads on large nodes (≥256 GB RAM, individual pods of 50–100 GB)**, and the practical sequence we recommend for clusters with **20+ nodes**.

> **Audience.** You manage your cluster through the CloudSigma marketplace UI and use your downloaded `kubeconfig` (admin or private) for `kubectl` against **your own cluster** (your workloads, your PDBs, your namespaces). You do **not** have access to the management plane that hosts your control plane. Anywhere this page says "support request" or "operator-managed", it means a knob exists but is not yet on a UI screen — file a ticket and we apply it on your behalf. The roadmap section below lists what we plan to surface in the UI next.

---

## TL;DR

1. **Control plane and workers upgrade independently.** Pick "Control plane only" in the upgrade wizard first; upgrade each worker pool afterwards when you're ready.
2. **You can pause any worker pool** mid-rollout from the UI. Pause is the **circuit-breaker** for large clusters: roll one node, validate, then resume.
3. **Default rolling strategy is `maxSurge=1, maxUnavailable=0`** — one extra node provisioned at a time, zero unavailability. This is the safest default; it is also the slowest. Tuning this is a support request today (roadmap: UI).
4. **There is no automatic capacity check.** For a 20-node pool with 70 GB-RAM pods, you must verify that the remaining 19 nodes can hold the evicted pod before rolling. The platform won't do this math for you.
5. **`PodDisruptionBudget`s are respected** during voluntary eviction — set them on every stateful workload in your cluster with your `kubectl`.
6. **Drain timeout is configurable per pool** but support-request today — set it to at least the longest pod startup + drain time, otherwise a node can be force-deleted before your stateful pod has finished shutting down. Roadmap: UI.
7. **Add-ons (CSI, CCM, CoreDNS, Cilium, MetalLB, kube-api-proxy) are upgraded out-of-band by us**, not with the Kubernetes version bump. Their lifecycle is independent of the cluster upgrade.

---

## How upgrades work — the model

A managed-K8s cluster has **two halves** with separate lifecycles:

| Half | Where it runs | What you do |
|---|---|---|
| **Control plane** (kube-apiserver, controller-manager, scheduler, etcd) | Inside our management cluster (we operate it for you) | Choose the target version in the upgrade wizard and pick "Control plane only" mode. Rolling takes a few minutes and **does not touch your workloads**. |
| **Worker pools** (your VMs running kubelet + your workloads) | In your CloudSigma account, attached via the cloud VLAN | Upgrade each pool from the pool row in the UI. One node at a time, by default, with workload rescheduling. |

Because the two halves are decoupled, the recommended journey is:

```
            ┌────────────────────────────────────────────────┐
            │ 1. Upgrade control plane (cp-only mode)        │
            │    → workers stay on their current version     │
            └────────────────────┬───────────────────────────┘
                                 │ Verify CP healthy, run smoke tests
                                 ▼
            ┌────────────────────────────────────────────────┐
            │ 2. Upgrade worker pool A                       │
            │    → one node at a time (default)              │
            │    → pause from the UI if anything looks wrong │
            └────────────────────┬───────────────────────────┘
                                 │ Wait until pool A is Ready
                                 ▼
            ┌────────────────────────────────────────────────┐
            │ 3. Upgrade worker pools B, C, …                │
            │    (same pattern, one pool at a time)          │
            └────────────────────────────────────────────────┘
```

This is the staged flow the UI's upgrade wizard implements (three-step dialog: target version → pre-flight checks → confirm).

### Kubernetes version skew rule

Kubernetes enforces that **worker `kubelet` versions may not exceed the control plane version**, and may lag by **at most two minor versions**. Practically:

- You can upgrade the control plane ahead of the workers (recommended).
- You **cannot** upgrade a worker pool past the control plane.
- You can leave worker pools on `v1.N.x` while the control plane goes to `v1.N+2.x`, but no further.

The UI's upgrade wizard prevents you from selecting an out-of-skew target.

---

## What the platform does during a rollout

The platform handles the per-node mechanics for you. For each worker node being replaced, the cycle is:

1. **Provision** a brand-new worker VM with the target Kubernetes version (one "surge" slot — see below).
2. Wait for the new node to **join the cluster and become `Ready`**.
3. **Cordon** the old node (no new pods scheduled).
4. **Drain** the old node — voluntary pod eviction, respecting `PodDisruptionBudget`s.
5. **Wait** for the drain to complete, up to the drain-timeout for the pool.
6. **Delete** the old node and its VM.
7. Repeat on the next node.

The default settings give you a **safe but slow** rollout: one extra surge node, zero unavailability, voluntary eviction only. For large clusters, the practical sequence is to validate the first replacement, then let the rest of the pool roll in the same shape.

---

## The knobs that govern the rollout

All knobs apply **per worker pool**, so a multi-pool cluster can mix policies (e.g. fast on stateless pools, conservative on the database pool).

### Today — exposed in the UI

| Knob | What it does | UI surface |
|---|---|---|
| Cluster target version | Sets the control plane version. Workers stay on their current version when you pick "cp-only" mode. | Upgrade wizard step 1 |
| Per-pool target version | Bumps one worker pool to a new version (must be ≤ control plane). | Pool row → "Upgrade" |
| Pause pool | Immediately halts an in-flight rollout for that pool. Already-replaced nodes stay; un-replaced nodes stay. Spec changes are accepted but don't trigger replacement until you resume. | Pool row → "Pause" |
| Resume pool | Restarts the rollout after a pause. | Pool row → "Resume" |
| Upgrade mode | `cp-only` (control plane only) or `all` (cascade through every pool). | Upgrade wizard step 1 |
| Per-pool replicas | Independent of upgrade flow, but useful to **scale up before** an upgrade to add headroom. | Pool row → "Scale" |

### Today — support request only (roadmap: UI)

| Knob | What it controls | Why it matters for large clusters |
|---|---|---|
| **maxSurge** | How many extra nodes are provisioned concurrently during a rollout. Default: **1**. | Raising this from `1` to `2` (or `"10%"`) **roughly halves wall-clock time** on a 20-node pool. Costs one extra surge VM of CloudSigma quota per slot, for the duration of the rollout. |
| **maxUnavailable** | How many nodes may be down concurrently. Default: **0**. | Keep this at 0 for stateful workloads — raising it allows the platform to delete a node before its replacement is `Ready`, which is how you lose data on a stateful pool. We don't recommend raising it. |
| **nodeDrainTimeoutSeconds** | How long the platform waits for voluntary pod eviction on a node before **force-deleting** the node. Default: wait indefinitely. | For long-shutdown workloads (database WAL flush, JVM graceful drain, replication catchup), you want a generous but finite value — e.g. **1800 s (30 min)**. Without a timeout, a single stuck pod can deadlock the rollout forever. With a too-short timeout, your stateful pod can be killed mid-flush. |
| **CCM image** (per worker pool) | Pinned at cluster creation and persists across upgrades. | Change requires a support ticket; we coordinate it as a separate change from the Kubernetes upgrade. |
| **Cluster-level abort / rollback** | Pause is per-pool today; full reversal of a partially-rolled pool requires us to coordinate with you. | If you decide mid-rollout that the new version is bad, pause the pool, then file a ticket — we will roll un-replaced nodes back to the old version manually. Already-replaced nodes can be rolled back too, but it costs another drain cycle for each one. |

When you open a support request for one of these, tell us:

- Pool name(s) and the values you want.
- Whether the change is **for this upgrade only** (we'll revert after) or **permanent** (it stays on the pool for future upgrades).

We can typically apply these in minutes during business hours.

---

## Recommended sequence for large clusters (≥20 nodes, ≥256 GB RAM, ≥50 GB pods)

### Before you start — checklist you run yourself

These checks all use **your own kubeconfig** against **your own cluster** — nothing here requires our access.

1. **Verify capacity headroom.** With the default `maxSurge=1`, one node is replaced at a time. The displaced pod has to fit somewhere — either on an existing node with room, or on the freshly-provisioned surge node. Practical formula:
   ```
   per-node RAM × (N - 1)   ≥   sum of all pod RAM requests   (including DaemonSet overhead)
   ```
   If this is tight, scale up the pool first, raise `maxSurge` via a support request, or temporarily scale down non-critical workloads.
2. **Set or audit PDBs** on every stateful workload. The platform respects them during voluntary eviction. Example for a 3-replica StatefulSet:
   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: db-pdb
     namespace: data
   spec:
     maxUnavailable: 1
     selector:
       matchLabels:
         app: db
   ```
   Apply with `kubectl apply -f` against your own cluster.
3. **Request a non-default `nodeDrainTimeoutSeconds`** on each pool that runs long-shutdown workloads. We recommend **1800 s** as a safe floor; pick a higher value if your shutdown sequence (WAL flush, JVM stop, replication drain) can exceed 30 minutes. Without this, a stuck pod can deadlock the rollout forever.
4. **Verify your CloudSigma account quota.** Each surge slot needs an unused worker VM allocation (CPU + RAM + disk). On a 256 GB-RAM pool, one surge slot = one extra 256 GB VM provisioned for ~10–15 min per node-replacement.
5. **Snapshot critical volumes.** CloudSigma snapshots are independent of the K8s upgrade and don't slow it down.
6. **Pause your CD pipelines.** A fresh Deployment landing during a rollout will be evicted again on the next node and waste cycles. We recommend a release freeze for the duration of the rollout.

### The actual upgrade — what you click

**Step 1 — Upgrade the control plane only**

- Open the cluster in the marketplace UI.
- Click **Upgrade**.
- In step 1 of the wizard: select the target Kubernetes version and pick mode **"Control plane only"**.
- Walk through pre-flight checks (the wizard verifies no pools are paused, no rollouts in flight, control-plane datastore healthy).
- Confirm. The control plane rolls in our management cluster. Your worker nodes and workloads are untouched.

Wait for the dashboard to show the new control plane version. Run smoke tests against your own cluster:

```bash
# Use your downloaded kubeconfig
kubectl get --raw='/readyz?verbose'
kubectl version
kubectl get nodes      # all nodes still on previous version - this is expected
kubectl apply -f some-test-manifest.yaml   # round-trip works
```

**Step 2 — Upgrade one worker pool, with a canary checkpoint**

- In the cluster dashboard, find the pool's row.
- Click **Upgrade** on the pool.
- The pool starts rolling — you'll see the row's phase change to `Upgrading`, and `Updated / Replicas` counters tick up.
- **When the first node has been replaced** (counter reaches `1 / N`) and your workload is healthy on it, click **Pause** on the pool row.
- Validate your stateful workload on the new node for as long as you need (replica behavior, IO, latency, query patterns — whatever matters to you).
- When you're satisfied, click **Resume**. The remaining nodes roll one by one.

This canary-then-pause-then-resume pattern is the safest way to upgrade a large stateful pool. The first node is the highest-risk; once it's validated, the rest of the pool is incremental.

**Step 3 — Upgrade the remaining pools**

One at a time. If your cluster has spare capacity and you've already validated the new version on pool A, you can upgrade B and C without the pause checkpoint. Do not start two upgrades at the same time unless you've checked you have enough capacity for two parallel rollouts.

### When things go wrong — what you see, what to do

| Symptom | What's happening | What to do |
|---|---|---|
| Pool stuck in `Upgrading`, counters not advancing | New node stuck provisioning (CloudSigma quota?) or new pod stuck `Pending` (insufficient capacity / image pull) | Check the new node's events with your kubeconfig: `kubectl describe nodes`; check `kubectl get events -n <ns>` for pending pods. Quota issues need CloudSigma billing UI; capacity issues need scale-up or workload adjustment. |
| Drain stuck for a long time on a node | A pod has a stuck finalizer, or a PDB is blocking eviction (`maxUnavailable: 0` PDB with all replicas on the draining node, etc.) | `kubectl get events --field-selector reason=FailedEviction`; fix the underlying PDB or finalizer in your namespace. If you cannot, the drain timeout (if set) eventually force-deletes the node. |
| You want to abort the rollout | Pool is mid-rollout, you've decided the new version is bad | **Pause** the pool from the UI. Then open a support ticket — we will revert un-replaced nodes' target version (free) and, if needed, re-roll already-replaced nodes back to the old version (costs one more drain cycle per node). |
| A node was force-deleted, workload is gone | `nodeDrainTimeoutSeconds` expired with a PDB or finalizer still blocking | Restore from your CloudSigma snapshot / re-deploy. Raise the drain timeout via support request before the next upgrade. |
| Control plane fails to come up healthy after upgrade | Rare; we operate the control plane | Open a support ticket immediately. Your data plane (workers and workloads) is unaffected because workers don't restart for a CP-only upgrade — they continue serving traffic, they just can't reach the API until the CP is back. |

---

## Sizing math — concrete example

**Scenario:** 20-node pool, 256 GB RAM per node, one 70 GB stateful pod per node, default `maxSurge=1, maxUnavailable=0`.

- Each step provisions a 21st node, drains node 1, deletes node 1. Drain moves the 70 GB pod somewhere with room.
- **At least one node must have 70 GB free** for the pod to reschedule there. If every node is running its own 70 GB pod with no slack, the pod can only land on the freshly-provisioned surge node.
- The surge node has 256 GB free, so it accepts the 70 GB pod. Drain succeeds. Node 1 is deleted.
- Step 2: a new node is provisioned, node 2 is drained, etc. Pods may bounce around as new nodes appear.

**Wall-clock time per step** ≈ 10–15 min (VM provision + node join) + drain time (depends on pod shutdown) + pod startup on target. For a database WAL replay taking 5 min, expect ~25 min per node = **~8 hours for a 20-node rollout** with `maxSurge=1`.

**Roughly halve this with `maxSurge=2`** (file a support request before the upgrade): you trade 2 surge VMs of CloudSigma quota for 4–5 hours saved on a 20-node pool. The catch is that the scheduler is now juggling two drains at once — make sure the cluster has the capacity for two displaced pods to find homes simultaneously. For pure-compute workloads this is a clear win; for memory-heavy stateful workloads it depends on how much idle RAM you have across the pool.

**`maxSurge=4` (≈25%)** is the upper limit we recommend for stateful pools — 4 surge VMs is a lot of money for a one-time event, and scheduling 4 simultaneous drains on a stateful pool stresses the eviction path. For stateless pools we've seen `maxSurge="25%"` work cleanly.

---

## Add-ons — they upgrade independently

The cluster ships with Cilium, CoreDNS, kube-api-proxy, CloudSigma CSI, CloudSigma CCM, MetalLB (private-link), and konnectivity-agent. **None of them are tied to the Kubernetes version upgrade.** They are reconciled separately by the platform's add-on management.

What this means in practice:

- Bumping the cluster's Kubernetes version **does not** touch the Cilium DaemonSet, CSI controller, or CCM image. Their versions stay as configured.
- We upgrade add-ons on our own schedule, usually following platform-wide rollouts. You typically see the change as a brief restart of the add-on's pods (sub-minute, no node restart).
- If a Kubernetes version bump deprecates an API that an add-on uses, **we coordinate the add-on upgrade with the cluster upgrade ourselves** before announcing the new version is available. You don't need to plan around it.
- The **CloudSigma CCM image is pinned per worker pool at cluster creation** and persists across upgrades. Change is a support request.

See [cluster-addons.md](cluster-addons.md) for the full add-on lifecycle model.

---

## What's NOT in the UI today (honest list, with roadmap)

These are real gaps. Customer-priority feedback influences the order we close them.

| Gap | Workaround today | Roadmap |
|---|---|---|
| No automatic capacity check before rollout | Run the formula in the "Before you start" checklist | Pre-flight capacity report in the upgrade wizard |
| No way to set `maxSurge` / `maxUnavailable` from the UI | Support request | Per-pool strategy editor in the upgrade wizard's confirm step |
| No way to set `nodeDrainTimeoutSeconds` from the UI | Support request | Per-pool drain-timeout field on the pool edit page |
| No rollback button | Pause + support ticket | One-click "Roll back to previous version" on the pool row, scoped to un-replaced nodes |
| No cluster-level pause (only per-pool) | Pause each pool individually | Cluster-wide pause toggle |
| No CSI / Cilium / CoreDNS version surfaced alongside Kubernetes version | Support request to read | Add-on version panel on the cluster dashboard |
| No per-step progress for the control plane upgrade | Wait for the version field to change | CP rollout progress indicator with current Kamaji replica state |

If any of these blocks your operational model, please tell us — they're real items, prioritized by who asks loudest.

---

## Quick reference — what you can do, where

| Action | Where today | Coming to UI |
|---|---|---|
| Upgrade control plane only | Upgrade wizard, mode = "Control plane only" | — (already in UI) |
| Upgrade everything in one shot | Upgrade wizard, mode = "All" | — |
| Upgrade one worker pool | Pool row → "Upgrade" | — |
| Pause a pool | Pool row → "Pause" | — |
| Resume a pool | Pool row → "Resume" | — |
| Set `maxSurge` on a pool | Support request | Yes |
| Set `maxUnavailable` on a pool | Support request (rarely needed) | Yes |
| Set `nodeDrainTimeoutSeconds` on a pool | Support request | Yes |
| Roll back a partially-upgraded pool | Pause + support request | Yes |
| Surface add-on versions | Support request | Yes |
| See per-pool rollout progress | Pool row shows phase + counts | — (already in UI) |
| Set PDBs on your own workloads | `kubectl apply` against your cluster | Stays your responsibility — the platform respects PDBs but doesn't generate them |

If you're managing 20+ nodes with large stateful workloads and you'd like a personalized runbook reviewed before your first upgrade, open a support ticket — we'll go through your specific pool layout, PDBs, and timing with you.
