# DHCP + NAT Gateway for Customer Private VLAN

A lightweight VM deployed in the customer's CloudSigma account that provides
**DHCP** and **NAT** services on the customer's private VLAN, giving Kubernetes
worker nodes internet access through an isolated network path.

The VM also provides SSH access to worker nodes on the customer VLAN,
useful for debugging and cluster operations.

## Architecture

```
                        INTERNET
                           │
                           │
┌──────────────────────────┼───────────────────────────────────────┐
│  CUSTOMER ACCOUNT        │                                       │
│                          │                                       │
│  ┌───────────────────────┼───────────────────────────────────┐   │
│  │  DHCP + NAT Gateway VM                                    │   │
│  │                       │                                   │   │
│  │  ens3 ────────────────┘  public IP (DHCP from CloudSigma) │   │
│  │       │  NAT MASQUERADE (iptables)                        │   │
│  │       │  ip_forward = 1                                   │   │
│  │       │                                                   │   │
│  │  ens4 ──── cloud VLAN ──── 100.64.200.1/16                │   │
│  │       │    (visibility into mgmt network)                 │   │
│  │       │                                                   │   │
│  │  ens5 ──── customer VLAN ── 10.8.0.1/24                   │   │
│  │            │  DHCP server (dnsmasq)                       │   │
│  │            │  Gateway for customer VLAN                   │   │
│  └────────────┼──────────────────────────────────────────────┘   │
│               │                                                  │
│    ═══════════╪═══════════════════════════════════════           │
│       CUSTOMER PRIVATE VLAN (L2)                                 │
│    ═══════════╪════════════════╪══════════════════════           │
│               │                │                                 │
│  ┌────────────┴───┐  ┌────────┴─────────────────────┐            │
│  │  Worker Node   │  │  Worker Node                 │            │
│  │                │  │                              │            │
│  │  ens3: cloud   │  │  ens3: cloud VLAN            │            │
│  │    VLAN (IPAM) │  │    100.64.128.x/16 (static)  │            │
│  │                │  │                              │            │
│  │  ens4: customer│  │  ens4: customer VLAN         │            │
│  │    VLAN (DHCP) │  │    10.8.0.x/24 (DHCP)        │            │
│  │    gw: 10.8.0.1│  │    gw: 10.8.0.1              │            │
│  └────────────────┘  └──────────────────────────────┘            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Traffic Flows

### Worker → Internet (via NAT)

```
Worker ens4 (10.8.0.x)
  → gateway 10.8.0.1  (NAT GW VM, ens5)
  → iptables MASQUERADE
  → ens3 (public IP)
  → internet
```

### Worker → Control Plane (via cloud VLAN, no NAT)

```
Worker ens3 (100.64.128.x/16)
  → gateway 100.64.0.1
  → kube-apiserver EIP 100.64.0.x:6443
```

### Customer VM → Kubernetes Service (via MetalLB on customer VLAN)

```
Customer VM (10.8.0.y)
  → MetalLB VIP (10.8.0.z) on customer VLAN
  → kube-proxy → Pod
```

## Prerequisites

- A CloudSigma account with:
  - Access to the **cloud VLAN** (shared with the management cluster)
  - A **customer private VLAN** (owned by the customer)
- `curl`, `python3`, `ssh` on your workstation
- An SSH key pair (ed25519 recommended)

## Quick Start

```bash
# 1. Configure
cp config.env.example config.env
vim config.env   # set credentials, VLAN UUIDs, subnet ranges

# 2. Provision the VM
chmod +x provision.sh setup.sh destroy.sh
./provision.sh

# 3. Wait ~30s for cloud-init, then configure
./setup.sh

# 4. (Optional) Destroy when no longer needed
./destroy.sh
```

## Configuration

All settings are in `config.env`. Key parameters:

| Variable | Description | Example |
|---|---|---|
| `CS_API_BASE` | CloudSigma API endpoint | `https://zrh.cloudsigma.com/api/2.0` |
| `CS_USER` / `CS_PASS` | API credentials | |
| `CLOUD_VLAN_UUID` | Shared cloud VLAN UUID | `eb22472a-...` |
| `CLOUD_VLAN_IP` | Static IP on cloud VLAN | `100.64.200.1` |
| `CUSTOMER_VLAN_UUID` | Customer private VLAN UUID | `09d36477-...` |
| `CUSTOMER_VLAN_IP` | Gateway IP on customer VLAN | `10.8.0.1` |
| `DHCP_RANGE_START/END` | DHCP allocation range | `10.8.0.10` - `10.8.0.250` |

## What Gets Configured

### VM NICs

| NIC | Interface | Network | Purpose |
|-----|-----------|---------|---------|
| 0 | `ens3` | Public (DHCP) | Internet uplink, SSH access |
| 1 | `ens4` | Cloud VLAN (static) | Visibility into mgmt network |
| 2 | `ens5` | Customer VLAN (static) | DHCP server + NAT gateway |

### Services

- **dnsmasq** — DHCP server bound to `ens5`, serves IPs in the configured range
  with gateway pointing to this VM (`10.8.0.1`)
- **iptables NAT** — MASQUERADE rule for customer VLAN traffic going out `ens3`
- **IP forwarding** — `net.ipv4.ip_forward = 1` persisted via sysctl
- **kubectl** — installed during setup for cluster operations from the gateway VM

### Accessing Worker Nodes

The gateway VM can reach worker nodes on the customer VLAN, making it useful
for debugging:

```bash
# SSH into the gateway VM
ssh cloudsigma@<public-ip>

# SSH to a worker node via customer VLAN (no public IP needed)
ssh ubuntu@10.8.0.x

# Use kubectl with your tenant cluster kubeconfig
kubectl --kubeconfig=<your-kubeconfig> get nodes
```

### Persistence

All configuration survives reboots:
- Network: `systemd-networkd` `.network` files in `/etc/systemd/network/`
- DHCP: dnsmasq config in `/etc/dnsmasq.d/customer-vlan.conf`
- NAT: iptables rules saved via `iptables-persistent`
- Forwarding: sysctl in `/etc/sysctl.d/90-nat-gw.conf`

> **Note**: The public IP changes on VM restart (CloudSigma DHCP). Update
> `vm-ip.txt` if you need to re-run `setup.sh` after a restart.

## Worker Node Integration

Worker nodes attached to the customer VLAN receive via DHCP:
- **IP address** in the configured range (e.g. `10.8.0.x/24`)
- **Gateway** pointing to this VM (`10.8.0.1`) for internet-bound traffic
- **DNS** servers (`8.8.8.8`, `8.8.4.4`)

The worker's **default route stays on the cloud VLAN** (`ens3`) for
control-plane communication. The customer VLAN route is a subnet route only,
with the NAT gateway as the next hop for any traffic leaving the `10.8.0.0/24`
subnet.

## Files

```
dhcp-nat-gw/
├── config.env.example   # Configuration template
├── config.env           # Your local config (git-ignored)
├── provision.sh         # Create and start the VM via CloudSigma API
├── setup.sh             # SSH into VM and configure DHCP, NAT, kubectl
├── destroy.sh           # Stop and delete VM + drive
├── vm-uuid.txt          # Created by provision.sh (git-ignored)
├── vm-ip.txt            # Created by provision.sh (git-ignored)
└── README.md            # This file
```
