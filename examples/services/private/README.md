# Private VLAN Service Exposure

Services exposed on the **customer private VLAN** using MetalLB L2 mode.

## Automated Deployment

MetalLB is **automatically deployed**  when `privateApiEndpointIP` is set
on a CloudSigma worker pool in the KdcCluster spec. No manual installation needed.

## How It Works

MetalLB L2 mode announces VIPs on the customer private VLAN (worker NIC 2, `ens4`):

1. **MetalLB speaker** runs on worker nodes (with `KUBERNETES_SERVICE_HOST` fix for Kamaji)
2. **L2Advertisement** binds to `ens4` interface (customer VLAN)
3. **kube-api-proxy-lb** gets VIP from the configured IP pool
4. **Speaker announces via ARP** on the customer VLAN
5. **Customer VMs access kube-api** via the VIP using token-based kubeconfig

## Network Isolation

- VIPs are **only reachable from the customer private VLAN** (e.g. `10.8.0.0/24`)
- **No public internet access** — API remains isolated within the customer network
- Only **token-based auth** works through kube-api-proxy (client certs are stripped)

## Examples

### metallb-customer-vlan.yaml

An **additional** IPAddressPool for your own services.

MetalLB itself is auto-deployed and already owns a pool containing the private
API endpoint address. This adds a second pool for application VIPs — and the two
**must not overlap**. MetalLB rejects an overlapping configuration wholesale: it
stops allocating for every Service, and the only symptom is

```
Failed to allocate IP for "ns/svc": ["10.8.0.9"] is not allowed in config
```

on a Service whose address is plainly inside a pool `kubectl get ipaddresspools`
shows. Nothing marks the offending pool as invalid. Removing the overlap makes
allocation succeed within seconds.

You do **not** need to install MetalLB or delete its webhook — both pools apply
cleanly with the webhook in place.

### nginx-loadbalancer.yaml

Nginx exposed on the customer VLAN at `10.8.0.6`.

Measured: the VIP is allocated about **6 s** after the Service is created, and
serves in **6-12 ms** from a VM on the same VLAN.

```bash
kubectl apply -f metallb-customer-vlan.yaml   # pool first
kubectl apply -f nginx-loadbalancer.yaml

# Test from any VM on the customer VLAN (10.8.0.0/24)
curl http://10.8.0.6/
```

## IP Pool Planning

Reserve a range **outside the DHCP range** for MetalLB VIPs:

| Range | Purpose |
|-------|---------|
| `10.8.0.1` | NAT gateway VM |
| `10.8.0.2-10.8.0.9` | **MetalLB pool** (static VIPs) |
| `10.8.0.10-10.8.0.250` | DHCP range (worker nodes) |

## Troubleshooting

**Service stuck in `<pending>` state:**
- Check MetalLB speaker logs: `kubectl logs -n metallb-system -l component=speaker`
- Verify IPAddressPool is created: `kubectl get ipaddresspool -n metallb-system`
- Verify L2Advertisement is created: `kubectl get l2advertisement -n metallb-system`

**VIP not reachable from customer VLAN:**
- Verify worker NIC 2 (`ens4`) is on customer VLAN: `ssh ubuntu@10.8.0.x ip addr show ens4`
- Check ARP table on customer VM: `arp -n | grep 10.8.0.2`
- Verify MetalLB speaker is announcing on correct interface: check speaker logs

## Address planning on the customer VLAN

Everything on this VLAN has to coexist in one /24. A layout that works:

| Range | Owner |
|---|---|
| `10.8.0.1` | the DHCP/NAT gateway VM |
| `10.8.0.5` | private kube-api endpoint — MetalLB already owns this |
| `10.8.0.6`-`10.8.0.9` | your service VIPs |
| `10.8.0.10`-`10.8.0.250` | DHCP range served to workers |

Two rules follow from it, and both have bitten in practice: a VIP must never sit
inside the DHCP range, and an application pool must never include the API
endpoint address.

## Known limitation: pod logs

`kubectl logs` against a private cluster can return
`No agent available` — log and exec streaming go through the control plane's
konnectivity agent, which is not always reachable on this network model. The
workload itself is unaffected; write to a volume or a log sink if you need
output you can rely on.
