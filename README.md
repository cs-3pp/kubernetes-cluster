# Kubernetes Cluster Examples

Examples and tools for Kubernetes clusters on CloudSigma.

## Service Exposure Options

### Public Services (CCM LoadBalancer)

Expose services to the internet using CloudSigma CCM LoadBalancer controller.

- Uses **CloudSigma static IPs** (subscribed IPs from your account)
- CCM **attaches IPs to worker nodes** via CloudSigma API
- **Cross-subnet routing** — IP doesn't need to be in the same L2 segment as workers
- **Automatic failover** — CCM moves IP to another node if current node fails
- **Firewall auto-opens** — CCM switches node NIC to manual mode

**Example:** [`examples/services/public/nginx-ccm-loadbalancer.yaml`](examples/services/public/nginx-ccm-loadbalancer.yaml)

```bash
kubectl apply -f examples/services/public/nginx-ccm-loadbalancer.yaml
kubectl get svc nginx-public  # wait for EXTERNAL-IP
curl http://<EXTERNAL-IP>/
```

### Private VLAN Services (MetalLB)

Expose services on your **customer private VLAN** using MetalLB L2 mode.

- Services **only reachable from your private VLAN** (e.g., 10.8.0.0/24)
- **No public internet access** — fully isolated within customer network
- MetalLB **auto-deployed* when `privateApiEndpointIP` is set
- Uses **worker NIC 2** (ens4) on the customer VLAN

**Documentation:** [`examples/services/private/README.md`](examples/services/private/README.md)

**Example:** [`examples/services/private/nginx-loadbalancer.yaml`](examples/services/private/nginx-loadbalancer.yaml)

```bash
kubectl apply -f examples/services/private/nginx-loadbalancer.yaml
# Test from a VM on the customer VLAN:
curl http://10.8.0.9/
```

---

## DHCP/NAT Gateway for Customer VLANs

Provision a DHCP and NAT gateway VM for customer private VLAN clusters.

**Directory:** [`dhcp-nat-gw/`](dhcp-nat-gw/)

The gateway VM provides:
- **DHCP server** on customer VLAN (dnsmasq)
- **NAT gateway** for internet access from worker nodes
- **DNS forwarding** to public resolvers

### Usage

1. Copy and configure:
   ```bash
   cd dhcp-nat-gw/
   cp config.env.example config.env
   # Edit config.env with your CloudSigma credentials and VLAN UUIDs
   ```

2. Provision the VM:
   ```bash
   ./provision.sh  # Creates and starts the VM
   ./setup.sh      # Configures DHCP + NAT via cloud-init
   ```

3. Verify:
   ```bash
   ssh cloudsigma@<gateway-public-ip>
   sudo systemctl status dnsmasq
   sudo iptables -t nat -L -n -v  # Check MASQUERADE rule
   ```

4. Clean up (when done):
   ```bash
   ./destroy.sh
   ```

### Network Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Worker Nodes                                            │
│  ens3 (cloud VLAN): 100.64.x.x/16 — kubelet ↔ kube-api  │
│  ens4 (customer VLAN): 10.8.0.x/24 — default route      │
│         ↓ DHCP + default GW                             │
│         ↓                                               │
│  DHCP/NAT GW: 10.8.0.1 → NAT → Internet                 │
└─────────────────────────────────────────────────────────┘
```

- **Cloud VLAN (ens3):** No default gateway, only subnet route for API connectivity
- **Customer VLAN (ens4):** DHCP-assigned IP, default route via NAT gateway
- **Internet traffic:** Routes through NAT gateway on customer VLAN

---

## Quick Reference

| Task | Method | Example |
|------|--------|---------|
| Expose to internet | CCM LoadBalancer | [`nginx-ccm-loadbalancer.yaml`](examples/services/public/nginx-ccm-loadbalancer.yaml) |
| Expose to private VLAN | MetalLB L2 | [`nginx-loadbalancer.yaml`](examples/services/private/nginx-loadbalancer.yaml) |
| Configure MetalLB | Auto | [`private/README.md`](examples/services/private/README.md) |
| Set up DHCP/NAT GW | Provision script | [`dhcp-nat-gw/`](dhcp-nat-gw/) |

---

## IP Pool Planning (Customer VLAN)

Reserve ranges outside the DHCP pool for static services:

| Range | Purpose |
|-------|---------|
| `10.8.0.1` | NAT gateway VM |
| `10.8.0.2-10.8.0.9` | MetalLB static VIPs |
| `10.8.0.10-10.8.0.250` | DHCP range (worker nodes) |

Configure in `dhcp-nat-gw/config.env`:
```bash
DHCP_RANGE_START="10.8.0.10"
DHCP_RANGE_END="10.8.0.250"
```

Configure in MetalLB `IPAddressPool`:
```yaml
spec:
  addresses:
  - 10.8.0.2-10.8.0.9
```
