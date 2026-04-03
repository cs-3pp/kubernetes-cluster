#!/usr/bin/env bash
#
# Destroy the DHCP + NAT gateway VM and its drive.
#
# Usage:
#   ./destroy.sh              # uses UUID from vm-uuid.txt
#   ./destroy.sh <server-uuid>
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG="${SCRIPT_DIR}/config.env"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: ${CONFIG} not found."
    exit 1
fi
source "${CONFIG}"

CS_AUTH="${CS_USER}:${CS_PASS}"
SERVER_UUID="${1:-$(cat "${SCRIPT_DIR}/vm-uuid.txt" 2>/dev/null || true)}"

if [[ -z "${SERVER_UUID}" ]]; then
    echo "ERROR: No server UUID. Pass as argument or run provision.sh first."
    exit 1
fi

api() {
    local method="$1" path="$2"; shift 2
    curl -sf -u "${CS_AUTH}" -H 'Content-Type: application/json' \
        "${CS_API_BASE}${path}" -X "${method}" "$@"
}

echo "==> Stopping server ${SERVER_UUID}..."
api POST "/servers/${SERVER_UUID}/action/?do=stop" > /dev/null 2>&1 || true
sleep 10

# Get attached drives before deleting
echo "==> Fetching attached drives..."
DRIVE_UUIDS=$(api GET "/servers/${SERVER_UUID}/" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
for drv in d.get('drives',[]):
    u = drv.get('drive',{})
    if isinstance(u, dict):
        print(u.get('uuid',''))
    else:
        print(u)
" 2>/dev/null || true)

echo "==> Deleting server..."
api DELETE "/servers/${SERVER_UUID}/" > /dev/null 2>&1 || true

for uuid in ${DRIVE_UUIDS}; do
    if [[ -n "${uuid}" ]]; then
        echo "==> Deleting drive ${uuid}..."
        api DELETE "/drives/${uuid}/" > /dev/null 2>&1 || true
    fi
done

rm -f "${SCRIPT_DIR}/vm-uuid.txt" "${SCRIPT_DIR}/vm-ip.txt"
echo "==> Destroyed."
