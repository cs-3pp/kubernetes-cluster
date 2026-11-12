# Persistent Storage

Managed clusters get the CloudSigma CSI driver installed automatically. There is
nothing to deploy — check what you have and start claiming volumes.

```bash
kubectl get storageclass
```

## The StorageClass name is per-location

The driver creates **one default StorageClass**, named for the storage type the
account subscribes to — `cloudsigma-<type>`. That storage type is **not the
same everywhere**: different CloudSigma locations sell different storage
products, so a cluster in one location may offer `cloudsigma-nvme` while
another offers a different storage type entirely. A cluster may also have
extra classes for performance tiers (see [Performance tiers](#performance-tiers)).

The practical consequence: **do not hardcode the StorageClass name** in a
manifest you intend to use in more than one place. It is the default, so simply
omit `storageClassName` and the right one is used. Asking for a storage type
the account does not sell fails at the CloudSigma API, and the PVC sits
`Pending`; the reason is in the claim's events:

```bash
kubectl describe pvc <name>    # Events: ProvisioningFailed ... Allowed drive storage types are ['...']
```

## Performance tiers

Where CloudSigma offers **storage tiers** for your account and location, your
cluster may have extra StorageClasses next to the default one, one per tier.
A tier is a performance profile (IOPS and bandwidth limits) on the same
storage; you choose one per volume by picking its StorageClass. List what your
cluster has:

```console
$ kubectl get storageclass
NAME                         PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
cloudsigma-nvme (default)    csi.cloudsigma.com   Delete          WaitForFirstConsumer   true
cloudsigma-nvme-basic        csi.cloudsigma.com   Delete          WaitForFirstConsumer   true
cloudsigma-nvme-fast         csi.cloudsigma.com   Delete          WaitForFirstConsumer   true
cloudsigma-nvme-super-fast   csi.cloudsigma.com   Delete          WaitForFirstConsumer   true
```

For example, one location configured with four NVMe tiers offers these
(names, the default tier and the limits depend on the location):

| StorageClass | Tier | IOPS limit |
|---|---|---|
| `cloudsigma-nvme-basic` | Basic | 600 |
| `cloudsigma-nvme` (default) | Standard (that location's default) | 3,000 |
| `cloudsigma-nvme-fast` | Fast | 5,000 |
| `cloudsigma-nvme-super-fast` | Super Fast | 10,000 |

Each tier has a minimum and maximum IOPS limit and may scale between them with
the volume size; in the example above, Standard gives 3,000 IOPS at both 10 Gi
and 100 Gi. Higher tiers also have higher bandwidth limits. Tiers can be priced
differently; see your CloudSigma pricing.

**Use a tier** by naming its class in the claim. A claim binds only once a Pod
uses it, so [`pvc-performance-tier.yaml`](pvc-performance-tier.yaml) creates
both, in the `default` namespace:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-data
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cloudsigma-nvme-fast
  resources:
    requests:
      storage: 20Gi
```

In a StatefulSet, put the same `storageClassName` in `volumeClaimTemplates`.

**Check which tier a volume got**, once the claim is `Bound`:

```bash
kubectl apply -f pvc-performance-tier.yaml
kubectl -n default wait --for=jsonpath='{.status.phase}'=Bound pvc/db-data --timeout=120s
PV=$(kubectl -n default get pvc db-data -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeAttributes.storageTier}{"\n"}'
kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeAttributes.csi\.cloudsigma\.com/storage-tier-uuid}{"\n"}'
```

The first prints the tier the class asked for (`nvme_fast`); it is empty for
the default class. The second prints the UUID of the tier the volume was
created on, recorded for every volume that has one, default-class volumes
included.

**What to know**

- **Resizing keeps the tier.** Grow a tiered claim like any other
  (`kubectl -n default patch pvc db-data -p '{"spec":{"resources":{"requests":{"storage":"40Gi"}}}}'`);
  it stays on its tier, and its IOPS limit follows the tier's rules for the
  new size. The claim shows the new capacity once the filesystem has grown,
  which happens while a running Pod has the volume mounted.
- **Changing an existing volume's tier is not supported** by the CSI driver.
  To move data to another tier, create a claim on the new class and copy the
  data across.
- **Tier names differ between locations.** Each location configures its own
  tiers, so `cloudsigma-nvme-fast` may not exist elsewhere. Check
  `kubectl get storageclass` in each cluster; a manifest that must work
  everywhere should use the default class.
- **A tier the location does not offer** leaves the claim `Pending`, and the
  reason is on the claim itself:

  ```bash
  kubectl -n default describe pvc db-data    # Events: ProvisioningFailed ... storage tier "..." is not offered ...
  ```

  No drive is created in that case.
- **Volumes created before tiers were available** keep working as they are;
  they are not moved to a tier.

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
| `pvc-performance-tier.yaml` | A claim on a performance tier + a Pod that uses it |

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
