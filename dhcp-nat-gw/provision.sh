#!/usr/bin/env bash
#
# Provision a DHCP + NAT gateway VM on CloudSigma.
#
# The VM gets three NICs:
#   ens3 — public IP (DHCP from CloudSigma) for internet access & SSH
#   ens4 — cloud VLAN (static IP) for visibility into the management network
#   ens5 — customer private VLAN (static IP) serving DHCP + NAT
#
# Usage:
#   cp config.env.example config.env   # edit values
#   ./provision.sh
#
# Output: writes VM UUID to ./vm-uuid.txt and public IP to ./vm-ip.txt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
CONFIG="${SCRIPT_DIR}/config.env"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: ${CONFIG} not found. Copy config.env.example and edit it."
    exit 1
fi
# shellcheck source=config.env.example
source "${CONFIG}"

CS_AUTH="${CS_USER}:${CS_PASS}"

api() {
    local method="$1" path="$2"; shift 2
    curl -sf -u "${CS_AUTH}" -H 'Content-Type: application/json' \
        "${CS_API_BASE}${path}" -X "${method}" "$@"
}

echo "==> Cloning library drive ${LIB_DRIVE_UUID}..."
DRIVE_UUID=$(api POST "/libdrives/${LIB_DRIVE_UUID}/action/?do=clone" \
    -d "{\"name\": \"${VM_NAME}-disk\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['objects'][0]['uuid'])")
echo "    Drive UUID: ${DRIVE_UUID}"

echo "==> Waiting for drive clone to complete..."
for i in $(seq 1 30); do
    STATUS=$(api GET "/drives/${DRIVE_UUID}/" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    if [[ "${STATUS}" == "unmounted" ]]; then
        echo "    Drive ready."
        break
    fi
    echo "    Status: ${STATUS} (attempt ${i}/30)"
    sleep 5
done

echo "==> Creating server ${VM_NAME}..."
SERVER_UUID=$(api POST "/servers/" -d "{
  \"objects\": [{
    \"name\": \"${VM_NAME}\",
    \"cpu\": ${VM_CPU},
    \"mem\": ${VM_MEM},
    \"vnc_password\": \"KubeDC-NAT-GW!\",
    \"drives\": [{
      \"boot_order\": 1,
      \"dev_channel\": \"0:0\",
      \"device\": \"virtio\",
      \"drive\": {\"uuid\": \"${DRIVE_UUID}\"}
    }],
    \"nics\": [
      {\"ip_v4_conf\": {\"conf\": \"dhcp\"}, \"model\": \"virtio\"},
      {\"vlan\": {\"uuid\": \"${CLOUD_VLAN_UUID}\"}, \"model\": \"virtio\"},
      {\"vlan\": {\"uuid\": \"${CUSTOMER_VLAN_UUID}\"}, \"model\": \"virtio\"}
    ],
    \"meta\": {
      \"ssh_public_key\": \"${SSH_PUBLIC_KEY}\"
    }
  }]
}" | python3 -c "import sys,json; print(json.load(sys.stdin)['objects'][0]['uuid'])")
echo "    Server UUID: ${SERVER_UUID}"
echo "${SERVER_UUID}" > "${SCRIPT_DIR}/vm-uuid.txt"

echo "==> Starting server..."
api POST "/servers/${SERVER_UUID}/action/?do=start" > /dev/null
echo "    Started."

echo "==> Waiting for public IP..."
PUBLIC_IP=""
for i in $(seq 1 30); do
    PUBLIC_IP=$(api GET "/servers/${SERVER_UUID}/" \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
nics=d.get('runtime',{}).get('nics',[])
for n in nics:
    ip=n.get('ip_v4',{})
    if ip:
        print(ip.get('uuid','')); break
" 2>/dev/null || true)
    if [[ -n "${PUBLIC_IP}" ]]; then
        break
    fi
    echo "    Waiting... (attempt ${i}/30)"
    sleep 10
done

if [[ -z "${PUBLIC_IP}" ]]; then
    echo "ERROR: Could not get public IP after 5 minutes."
    exit 1
fi
echo "    Public IP: ${PUBLIC_IP}"
echo "${PUBLIC_IP}" > "${SCRIPT_DIR}/vm-ip.txt"

echo ""
echo "==> VM provisioned successfully!"
echo "    UUID:      ${SERVER_UUID}"
echo "    Public IP: ${PUBLIC_IP}"
echo ""
echo "Wait ~30s for cloud-init, then run:"
echo "    ./setup.sh"
