# Persistent Storage

Managed clusters get the CloudSigma CSI driver installed automatically. There is
nothing to deploy — check what you have and start claiming volumes.

```bash
kubectl get storageclass
```

## The StorageClass name is per-location

The driver creates **one default StorageClass**, named for the drive tier the
account subscribes to — `cloudsigma-<tier>`. That tier is **not the same
everywhere**: different CloudSigma locations sell different storage products,
so a cluster in one location may offer `cloudsigma-nvme` while another offers a
different tier entirely.

The practical consequence: **do not hardcode the StorageClass name** in a
manifest you intend to use in more than one place. It is the default, so simply
omit `storageClassName` and the right one is used. Asking for a tier the account
does not sell fails at the CloudSigma API, and the PVC sits `Pending` with the
real reason visible only in the csi-controller log:

```
Allowed drive storage types are ['...']
```

## Two behaviours that look like bugs and are not

**A PVC with no Pod stays `Pending` forever.** `volumeBindingMode` is
`WaitForFirstConsumer`, so the volume is created where the Pod is scheduled, not
when the claim is written. It binds when something mounts it. A bare
`kubectl apply -f pvc.yaml` followed by `kubectl get pvc` showing `Pending` is
the expected result, not a failure.

**Volumes are `ReadWriteOnce`.** They are block devices attached to one node.
Several replicas cannot share one claim — give each replica its own with
`volumeClaimTemplates` (see `statefulset.yaml`).

## Examples

| File | What it shows |
|---|---|
| `pvc-and-pod.yaml` | Minimal claim + a Pod that writes to it |
| `statefulset.yaml` | Per-replica volumes via `volumeClaimTemplates` |

```bash
kubectl apply -f pvc-and-pod.yaml
kubectl wait --for=condition=Ready pod/data-writer --timeout=120s || \
  kubectl get pvc data -o wide
kubectl logs data-writer
```

## What to expect

Measured on managed clusters, 5 Gi claim, from `kubectl apply` to a Pod that has
mounted the volume and written to it:

| Stage | Typical |
|---|---|
| PVC `Pending` → `Bound` (once a Pod exists) | ~11–12 s |
| `apply` → Pod `Succeeded` having written | ~22–23 s |
| Sequential write throughput inside the Pod | ~460 MB/s |

Identical on public and private-VLAN clusters — storage does not care which
network model the cluster uses.

If a PVC stays `Pending` for much longer than that, look at the provisioner
rather than the claim:

```bash
kubectl -n cloudsigma-csi get pods
kubectl -n cloudsigma-csi logs deploy/csi-controller -c csi-provisioner --tail=50
```

A `csi-controller` stuck in `ContainerCreating` on a missing `cloudsigma-token`
Secret means the cluster's cloud-controller has not published CloudSigma
credentials into the cluster yet — the driver is installed but cannot call the
API. That is a platform-side condition, not something to fix in your manifests.
