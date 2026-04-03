#!/usr/bin/env bash
#
# Configure the DHCP + NAT gateway VM after provisioning.
#
# This script SSHes into the VM and:
#   1. Assigns static IPs to cloud VLAN (ens4) and customer VLAN (ens5)
#   2. Enables IP forwarding
#   3. Configures iptables MASQUERADE for NAT (customer VLAN → internet)
#   4. Installs and configures dnsmasq as DHCP server on the customer VLAN
#   5. Persists all configuration across reboots
#
# Usage:
#   ./setup.sh              # uses IP from vm-ip.txt
#   ./setup.sh 1.2.3.4      # explicit IP
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
CONFIG="${SCRIPT_DIR}/config.env"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: ${CONFIG} not found."
    exit 1
fi
source "${CONFIG}"

PUBLIC_IP="${1:-$(cat "${SCRIPT_DIR}/vm-ip.txt" 2>/dev/null || true)}"
if [[ -z "${PUBLIC_IP}" ]]; then
    echo "ERROR: No public IP. Pass as argument or run provision.sh first."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"
SSH_CMD="ssh ${SSH_OPTS} cloudsigma@${PUBLIC_IP}"

echo "==> Waiting for SSH on ${PUBLIC_IP}..."
for i in $(seq 1 20); do
    if ${SSH_CMD} "true" 2>/dev/null; then
        echo "    SSH ready."
        break
    fi
    echo "    Attempt ${i}/20..."
    sleep 10
done

echo "==> Configuring network interfaces..."
${SSH_CMD} "sudo bash -s" <<REMOTE
set -euo pipefail

# --- systemd-networkd static config for cloud VLAN (ens4) ---
cat > /etc/systemd/network/05-ens4.network <<EOF
[Match]
Name=ens4
[Network]
Address=${CLOUD_VLAN_IP}/${CLOUD_VLAN_PREFIX}
DHCP=no
LinkLocalAddressing=no
[Link]
RequiredForOnline=no
EOF

# --- systemd-networkd static config for customer VLAN (ens5) ---
cat > /etc/systemd/network/05-ens5.network <<EOF
[Match]
Name=ens5
[Network]
Address=${CUSTOMER_VLAN_IP}/${CUSTOMER_VLAN_PREFIX}
DHCP=no
LinkLocalAddressing=no
[Link]
RequiredForOnline=no
EOF

systemctl restart systemd-networkd
sleep 2
echo "    Interfaces configured."
REMOTE

echo "==> Enabling IP forwarding and NAT..."
${SSH_CMD} "sudo bash -s" <<REMOTE
set -euo pipefail

# Persistent IP forwarding
cat > /etc/sysctl.d/90-nat-gw.conf <<EOF
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/90-nat-gw.conf

# iptables: MASQUERADE traffic from customer VLAN going out ens3 (public)
# This allows worker nodes on the customer VLAN to reach the internet
iptables -t nat -C POSTROUTING -s ${CUSTOMER_VLAN_IP%.*}.0/${CUSTOMER_VLAN_PREFIX} -o ens3 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s ${CUSTOMER_VLAN_IP%.*}.0/${CUSTOMER_VLAN_PREFIX} -o ens3 -j MASQUERADE

# Allow forwarding between interfaces
iptables -C FORWARD -i ens5 -o ens3 -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i ens5 -o ens3 -j ACCEPT
iptables -C FORWARD -i ens3 -o ens5 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i ens3 -o ens5 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Persist iptables rules across reboots
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1
netfilter-persistent save

echo "    NAT configured."
REMOTE

echo "==> Installing and configuring dnsmasq DHCP server..."
${SSH_CMD} "sudo bash -s" <<REMOTE
set -euo pipefail

DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq > /dev/null 2>&1

cat > /etc/dnsmasq.d/customer-vlan.conf <<EOF
# DHCP server for customer private VLAN
interface=ens5
bind-interfaces

# DHCP range
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${CUSTOMER_VLAN_IP%.*}.0,${DHCP_LEASE_TIME}

# Gateway — this VM is the NAT gateway
dhcp-option=option:router,${CUSTOMER_VLAN_IP}

# DNS servers
dhcp-option=option:dns-server,8.8.8.8,8.8.4.4

# Netmask
dhcp-option=option:netmask,255.255.255.0
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

echo "    dnsmasq configured."
REMOTE

echo "==> Installing kubectl (bastion tools)..."
${SSH_CMD} "sudo bash -s" <<'REMOTE'
set -euo pipefail

# Install kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq kubectl > /dev/null 2>&1

# Create .kube dir for cloudsigma user
mkdir -p /home/cloudsigma/.kube
chown -R cloudsigma:cloudsigma /home/cloudsigma/.kube

echo "    kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
REMOTE

echo ""
echo "==> Setup complete!"
echo ""
echo "DHCP + NAT Gateway: ${PUBLIC_IP}"
echo "  ens3: public (${PUBLIC_IP}) — internet uplink"
echo "  ens4: cloud VLAN (${CLOUD_VLAN_IP}/${CLOUD_VLAN_PREFIX})"
echo "  ens5: customer VLAN (${CUSTOMER_VLAN_IP}/${CUSTOMER_VLAN_PREFIX}) — DHCP + NAT"
echo ""
echo "DHCP range: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo "NAT:        ${CUSTOMER_VLAN_IP%.*}.0/${CUSTOMER_VLAN_PREFIX} → ens3 (MASQUERADE)"
echo ""
echo "Workers on the customer VLAN will:"
echo "  1. Get an IP via DHCP from this server"
echo "  2. Use ${CUSTOMER_VLAN_IP} as their gateway"
echo "  3. Reach the internet via NAT through this VM"
echo ""
echo "Access worker nodes via this gateway:"
echo "  ssh cloudsigma@${PUBLIC_IP}"
echo "  ssh ubuntu@10.8.0.x  # from the gateway VM"
