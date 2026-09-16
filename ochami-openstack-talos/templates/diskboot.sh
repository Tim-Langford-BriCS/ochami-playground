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
# diskboot.sh <instance> — return an instance to booting from its own disk (§7.6).
#
# The manual equivalent of the Redfish operation
#     BootSourceOverrideTarget = Hdd   +   Reset
#
# Run this after Talos has installed itself (§10), so the node boots the OS it
# just wrote instead of network-booting into a reinstall loop.
#
# Usage:  source ~/tw/tw-env.sh && ~/tw/diskboot.sh tw-cp1

set -euo pipefail

: "${OS_CLOUD:?source ~/tw/tw-env.sh first}"

node="${1:?usage: diskboot.sh <instance-name>}"

status=$(openstack server show "$node" -c status -f value)

case "$status" in
  RESCUE)
    openstack server unrescue "$node"
    echo "$node unrescued; it will reboot from its own disk"
    ;;
  ACTIVE)
    echo "$node is already ACTIVE (not rescued) — nothing to do"
    ;;
  *)
    echo "$node is $status — refusing to act. Check it with:"
    echo "  openstack server show $node -c status -c fault"
    exit 1
    ;;
esac
