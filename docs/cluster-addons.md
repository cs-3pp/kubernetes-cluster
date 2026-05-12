# Cluster Add-ons

Each Kubernetes cluster you create on CloudSigma's managed-K8s service ships with a curated set of add-ons preinstalled and kept up to date for you. This page is the customer-facing reference for what those add-ons are, what they do, how you interact with them from your `kubeconfig`, and what's configurable from the marketplace UI vs. what requires a support request.

> **Audience.** You manage your cluster through the CloudSigma marketplace UI and use the downloaded `kubeconfig` (admin or private) for `kubectl`. You do **not** have direct access to the management plane that hosts the cluster's control plane. Anywhere this page mentions "operator-managed" or "support request", it means *we* operate that piece for you.

---

## TL;DR — what's running and what you can change

| Add-on | Status | What you can do | What you can't change |
|---|---|---|---|
| **Cilium** (CNI) | Always on | Inspect with `kubectl get pods -n kube-system -l k8s-app=cilium`; create your own `NetworkPolicy` / `CiliumNetworkPolicy` objects | Cilium version, Helm values, eBPF tuning |
| **CoreDNS** (DNS) | Always on | Add your own `ConfigMap` for upstream stubs IF you also override the Corefile — but Corefile is reverted (see below) | Corefile, replicas, image |
| **kube-api-proxy** | Always on | Nothing — it's transparent; without it, in-cluster pods can't talk to `kubernetes.default` | Anything |
| **CloudSigma CSI** | Default storage | Create `PersistentVolumeClaim`s using the `cloudsigma-dssd` `StorageClass`; create your own `StorageClass`es with custom parameters | CSI controller/node Deployments, image |
| **MetalLB** | On for private-link clusters | Create `Service type=LoadBalancer` and MetalLB assigns a VIP from your customer VLAN pool | The IP pool / advertisement config |
| **CloudSigma CCM** | Always on (CloudSigma workers) | Create `Service type=LoadBalancer` — CCM auto-attaches a subscribed CloudSigma static IP from your account (optional `cloudsigma.com/ip-pool` annotation) | CCM image (set at cluster creation, then immutable in UI) |
| **konnectivity-agent** | Always on | Nothing — Kamaji-managed | Anything |

If something below says "support request", that means: open a ticket in the marketplace and we'll change it on the operator side.

---

## How add-on lifecycle works (so the next bit makes sense)

We deploy each add-on through a tool called **Sveltos** running in our management cluster. Sveltos selects clusters by label, then **continuously** reconciles the add-on's manifests in your cluster — meaning if you `kubectl edit deployment/cilium-operator -n kube-system`, your change reverts within a minute. **This is intentional**: it keeps every cluster identical to the tested baseline.

What that means for you in practice:

- **Workload-level resources** you create (your own Deployments, Services, PVCs, NetworkPolicies, StorageClasses, etc.) — yours, never touched.
- **Add-on internals** (the `cilium` DaemonSet, the `coredns` ConfigMap, the MetalLB IPAddressPool, the `kube-api-proxy` Deployment) — reverted on every reconcile. If you need them different, open a support request.
- **Cluster-level objects we don't ship** — yours, never touched.

---

## Network architecture you need to know about

Your worker nodes have **two NICs**:

| NIC | Network | Used for |
|---|---|---|
| `ens3` | `100.64.0.0/16` (CloudSigma cloud VLAN) | **Direct, private path between worker nodes and the Kubernetes API server** (your control plane lives in our management cluster). Worker bootstrap, kubelet ↔ apiserver, CCM ↔ apiserver, kube-api-proxy upstream — all go over this. |
| `ens4` | `10.x.x.x/24` (your customer VLAN, optional) | **Your private VLAN.** Used by MetalLB to advertise LoadBalancer VIPs to other VMs on the same VLAN; used for the optional private kubeconfig endpoint. |

**Why this matters for add-ons**: node-level components — Cilium, CCM, kube-api-proxy, MetalLB speaker — and anything you deploy that needs to reach the Kubernetes API directly must have outbound connectivity from the worker node over `100.64.0.0/15` (cloud VLAN) to your cluster's control plane endpoint. If you write your own controller, operator, sidecar, or DaemonSet that calls the apiserver, **it works over this same network path** automatically — both via `kubernetes.default.svc` (resolved to kube-api-proxy in-cluster) and via direct `https://<api-endpoint>:6443` if it has the kubeconfig.

The cloud VLAN is shared infrastructure; we route between cloud-VLAN-attached customer workers and our management plane. It is **not** the public internet. If you ever firewall outbound traffic from worker nodes, do not block `100.64.0.0/15`.

---

## Add-on reference

### Cilium — Container Network Interface

**What it does**
Provides pod-to-pod networking (eBPF-based) and enforces `NetworkPolicy` / `CiliumNetworkPolicy`. Without it, pods cannot talk to each other or to `kubernetes.default`.

**Where it lives in your cluster**
- Namespace: `kube-system`
- Workloads: `DaemonSet/cilium` (one per node) + `Deployment/cilium-operator`
- ConfigMap: `cilium-config`

**Configuration available to you**
- **Enable/disable**: enabled by default. Disable only at cluster creation time via support request. **Don't** disable on a running cluster — your pods stop networking.
- **Custom NetworkPolicies**: you create as many as you need. They are your resources, never reverted.
- **Custom CiliumNetworkPolicies**: same — use the [Cilium docs](https://docs.cilium.io/en/stable/security/policy/) for the L7 features.

**Not configurable today** 
- Cilium version pin
- eBPF map sizes / Hubble visibility / encryption-at-rest

**Common operations**
```bash
# inspect cilium agents on each node
kubectl get pods -n kube-system -l k8s-app=cilium -o wide

# apply your own NetworkPolicy
kubectl apply -f my-network-policy.yaml
```

---

### CoreDNS — Cluster DNS

**What it does**
Resolves in-cluster names like `my-service.my-namespace.svc.cluster.local` and forwards external lookups (e.g. `s3.amazonaws.com`) to upstream resolvers.

**Where it lives**
- Namespace: `kube-system`
- Workload: `Deployment/coredns`
- ConfigMap: `coredns` (managed — edits revert)

**Configuration available to you**
- **Enable/disable**: enabled by default. Cannot be disabled — `kubernetes.default` resolution would break.

**Not configurable today** (support request)
- Custom Corefile (upstream stubs, query logging, cache TTLs)
- Replicas

**Common operations**
```bash
# verify cluster DNS works
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
```

---

### kube-api-proxy — Transparent API access for pods

**What it does**
A small nginx-based reverse proxy that lets in-cluster pods reach `kubernetes.default` over the worker network. Your control plane lives in our management cluster; without this proxy, pods couldn't authenticate to the apiserver because the TLS SAN wouldn't match the routing path. We ship it so you don't have to think about it.

**Where it lives**
- Namespace: `kube-system`
- Workload: `Deployment/kube-api-proxy`

**Configuration available to you**
None.

**Note for cluster operators (us, not you)**
If you ever see in-cluster API client errors like "x509: certificate is valid for X, not Y" right after a cluster upgrade, that means kube-api-proxy was disabled or removed by mistake. Open a support request — we automatically force-enable this add-on for clusters that have a private API endpoint, but a custom label override can disable it.

**Network**
Talks to your control plane apiserver over **`100.64.0.0/15`** (cloud VLAN). This is the direct, private path; it does not traverse the public internet.

---

### CloudSigma CSI — Persistent block storage

**What it does**
Provisions PersistentVolumes backed by CloudSigma DSSD volumes. The default `StorageClass` is `cloudsigma-dssd`; PVCs you create without a `storageClassName` will use it.

**Where it lives**
- Namespace: `cloudsigma-csi`
- Workloads: `Deployment/csi-controller`, `DaemonSet/csi-node`
- StorageClass: `cloudsigma-dssd` (default, managed — don't delete)

**Configuration available to you**
- **Create custom StorageClasses**: yours, never reverted. Use for parameter tuning (volume type, FS type, mount options).
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: my-fast-storage
  provisioner: csi.cloudsigma.com
  parameters:
    storageType: dssd
    fsType: ext4
  reclaimPolicy: Delete
  volumeBindingMode: WaitForFirstConsumer
  ```
- **Use the existing `cloudsigma-dssd` StorageClass**: just reference it in your `PersistentVolumeClaim.spec.storageClassName`.

**Not configurable today** (support request)
- CSI controller image / replicas
- CloudSigma API endpoint
- Default `reclaimPolicy` of `cloudsigma-dssd` (it's `Delete` — if you need `Retain` by default, create your own StorageClass).

**Network**
CSI controller talks to the CloudSigma API for volume create/delete, and to the management cluster for credential token refresh, over the cloud VLAN.

**Common operations**
```bash
# create a PVC bound to the default StorageClass
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi
  storageClassName: cloudsigma-dssd
EOF

# inspect provisioned volume
kubectl get pvc my-data
kubectl get pv $(kubectl get pvc my-data -o jsonpath='{.spec.volumeName}')
```

---

### MetalLB — Load balancer on your customer VLAN

**What it does**
Assigns IP addresses from a pool on your customer VLAN to `Service type=LoadBalancer` resources, and advertises them via ARP on your worker nodes' second NIC (`ens4`). Use this when you want a Service reachable from other VMs on your private VLAN, but not from the public internet.

**When you get it**
Only deployed if you set a **Private API Endpoint IP** at cluster creation in the marketplace UI. That option enables MetalLB AND wires up the private kubeconfig at the same time.

**Where it lives**
- Namespace: `metallb-system`
- Workloads: `Deployment/metallb-controller`, `DaemonSet/metallb-speaker`
- IP pool: `customer-vlan-pool` (managed — its range is the customer VLAN subnet excluding DHCP range)

**Configuration available to you**
- **Create LoadBalancer Services**: standard Kubernetes:
  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: my-private-service
    annotations:
      metallb.universe.tf/address-pool: customer-vlan-pool   # optional, this is the default
  spec:
    type: LoadBalancer
    selector:
      app: my-app
    ports:
      - port: 80
  ```
- **Request a specific IP** with `spec.loadBalancerIP: 10.x.x.x` (must be in your VLAN pool).

**Not configurable today** (support request)
- IP pool range
- BGP mode (we use L2 only)
- Speaker NIC selection

**Network**
The Speaker DaemonSet runs on worker NICs attached to the customer VLAN and answers ARP probes for advertised VIPs. To consume a private LoadBalancer Service, your client VM must also be on the same customer VLAN. See [`examples/services/private/`](../examples/services/private/) for a full nginx walk-through.

---

### CloudSigma CCM — Public LoadBalancer services

**What it does**
For `Service type=LoadBalancer`, CCM **auto-discovers a subscribed static IP from your CloudSigma account**, attaches it to a worker node via the CloudSigma API, opens the firewall on that node, and configures local routing so traffic reaching the IP lands on the Service. No kube-dc-specific annotation is needed — a plain `type=LoadBalancer` Service is enough.

**Where it lives**
Runs in our management cluster (in your cluster's namespace), not in your cluster — but you create/manage Services from your kubeconfig like on any cluster.

**Configuration available to you**

- **Public LoadBalancer Service** — minimal manifest, no annotations required:
  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: nginx-public
  spec:
    type: LoadBalancer
    selector:
      app: nginx
    ports:
      - port: 80
  ```
  CCM picks any free **subscribed static IP** from your CloudSigma account and populates `status.loadBalancer.ingress[0].ip` once attached.

- **IP pool selection** (optional, only annotation CCM reads):
  ```yaml
  annotations:
    cloudsigma.com/ip-pool: "static"     # default — uses your subscribed IPs
    # cloudsigma.com/ip-pool: "dynamic"  # in development — uses unassigned floating IPs
  ```
  Omit the annotation and you get the static pool.

- **Pre-requisites on the CloudSigma account side** (you control these in the CloudSigma billing UI, not the cluster UI):
  - At least one subscribed static IP available (i.e. not already attached to another VM or Service).
  - Account quota allows the IP to be attached to managed-K8s worker VMs.

- **Resulting CloudSigma-side metadata** — once CCM attaches an IP, the IP gets tagged in CloudSigma so you can find it: `cloudsigma.com/ip=<the-ip>`, `cloudsigma.com/svc=<cluster-ip>`. Visible in the CloudSigma webapp under the IP's tags.

- **Failover** — if the worker holding the IP becomes unhealthy, CCM detaches the IP from that node and re-attaches it to a healthy one, with the node NIC switched to manual mode so the CloudSigma firewall doesn't strip the new flows. You don't do anything; the Service's `status.loadBalancer.ingress` stays the same IP.

**Not configurable today**
- CCM image (set once at cluster creation in the marketplace UI's CCM image field; immutable thereafter without re-creating the cluster).
- Health-check parameters.
- Custom IP pool tagging.
- `cloudsigma.com/ip-pool: dynamic` — listed in the example for completeness but the CCM marks it as in-development.

**Network**
CCM runs in our management cluster, reaches the CloudSigma API for IP attach/detach, and reaches your cluster's apiserver for Service / Endpoints reconciliation. All control-plane traffic flows over the `100.64.0.0/15` cloud VLAN — no public-internet hops are involved. Once an IP is attached and the firewall opened, ingress from the internet to the worker VM goes directly over the VM's primary NIC.

See [the project README](../README.md) and [`examples/services/public/nginx-ccm-loadbalancer.yaml`](../examples/services/public/nginx-ccm-loadbalancer.yaml) for the full walk-through.

---

### konnectivity-agent — Control plane reverse tunnel

**What it does**
Allows the apiserver (hosted in our management cluster) to call back into your worker nodes for things like `kubectl exec`, `kubectl logs`, `kubectl port-forward`, and metrics-server scraping.

**Configuration available to you**
None. Managed by Kamaji as part of the control plane.

**Network**
Worker nodes initiate outbound TCP to the management cluster's konnectivity-server on port 8132. This goes over the `100.64.0.0/15` cloud VLAN.

---

## When you write your own controllers, sidecars, or apps that call the Kubernetes API

You do not need to do anything special. Inside a pod:

- `kubernetes.default` resolves to `kube-api-proxy` in-cluster, which forwards to the real apiserver over the cloud VLAN.
- The standard service account `Token` and `ca.crt` mounted at `/var/run/secrets/kubernetes.io/serviceaccount/` work the same as on any Kubernetes cluster.
- For non-Pod contexts (e.g. a CronJob using your downloaded admin kubeconfig from outside the cluster), the kubeconfig points at the cluster's public or private endpoint as appropriate.

If you have an off-cluster controller (running in your CloudSigma VMs but not as a Pod) that needs to talk to the cluster apiserver, use the **private kubeconfig** option at cluster creation. That gives you a kubeconfig pointing at a stable `10.x.x.x:6443` endpoint on your customer VLAN, with the same admin permissions, no need to expose the apiserver publicly.

---

## What's NOT shipped (you bring it yourself if you need it)

The cluster ships with the bare necessities for managed-K8s. The following are NOT preinstalled — install whichever you need via Helm or manifests:

- **Ingress controller** — install ingress-nginx, Traefik, Istio, or any other; use a `Service type=LoadBalancer` (CCM-public or MetalLB-private) for its entry point.
- **cert-manager** — for TLS certificate automation.
- **metrics-server** — for `kubectl top` and HPA. (`kubelet` exposes metrics, but the in-cluster aggregator is your choice to install or not.)
- **External secrets / Vault / sealed-secrets / etc.** — pick the secret-management you want.
- **Service mesh (Istio, Linkerd)** — not preinstalled.
- **Monitoring stack (Prometheus, Grafana for your apps)** — not preinstalled. (Note: cluster-level observability — control-plane logs and metrics — IS visible from the marketplace UI's Logs and Dashboards tabs.)

These are workload-level deployments, not add-ons; Sveltos doesn't touch them. Install them with your kubeconfig, manage them like you would on any standard Kubernetes cluster.

---
