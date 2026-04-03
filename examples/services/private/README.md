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

Manual MetalLB configuration (for reference only — normally auto-deployed).

### nginx-loadbalancer.yaml

Nginx exposed on the customer VLAN at `10.8.0.9`.

```bash
kubectl apply -f nginx-loadbalancer.yaml

# Test from any VM on the customer VLAN (10.8.0.0/24)
curl http://10.8.0.9/
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
