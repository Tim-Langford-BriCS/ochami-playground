#!/usr/bin/env bash
# ⚠ NOT ON THE MAIN PATH since 4 Aug 2026.
#
# §7 now makes iPXE the node's ROOT DISK, so there is no "PXE button" to press:
# the instance network-boots because that is what its disk does, and it stops
# because Talos overwrites it. §10 uses `openstack server reboot --hard` to
# start a node and `openstack server rebuild` to re-provision one, and needs
# neither this script nor diskboot.sh.
#
# Kept because it is still correct, and still needed for:
#   - appendix F's rescue and CD-ROM variants (if your cloud is not Digital Labs)
#   - appendix A, where sushy-tools implements Redfish Pxe via Nova rescue
#
# pxeboot.sh <instance> — make an OpenStack instance network-boot now (§7.6).
#
# This is the manual equivalent of the Redfish operation
#     BootSourceOverrideTarget = Pxe   +   Reset
# and it is literally what sushy-tools' OpenStack driver does when a Redfish
# client asks an emulated BMC to PXE boot. See appendix A.
#
# Usage:  source ~/tw/tw-env.sh && ~/tw/pxeboot.sh tw-cp1

set -euo pipefail

: "${TW_PREFIX:?source ~/tw/tw-env.sh first}"
: "${OS_CLOUD:?source ~/tw/tw-env.sh first}"

node="${1:?usage: pxeboot.sh <instance-name>}"

status=$(openstack server show "$node" -c status -f value)

# A rescued instance cannot be rescued again, and cannot be stopped either
# (Nova forbids stop/pause/suspend in RESCUE, because it would make unrescue
# impossible). So clear the state first.
if [ "$status" = RESCUE ]; then
  echo "$node is already in RESCUE; unrescuing first"
  openstack server unrescue "$node"
  sleep 5
fi

openstack --os-compute-api-version 2.87 server rescue \
    --image "${TW_PREFIX}-ipxe" "$node"

cat <<EOF
$node is network-booting.

Watch it with:
  openstack console log show $node --lines 60

Expect: iPXE banner → "Configuring (net0 <mac>)... ok" → an address from
CoreDHCP in the 172.16.0.1-5 range (NOT 172.16.0.2xx, which is a bootloop
lease meaning the MAC is unknown to SMD) → the BSS boot script → Talos.
EOF
