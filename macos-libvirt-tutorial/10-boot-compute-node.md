# §10 — Booting the compute node

*(Upstream: guide §4 / tutorial Part 2.6 + 2.8. Time: ~10 minutes. Back on
the **host** (`host$`) for the virt-install; verification from the head.)*

## Concepts

Everything so far was preparation; this is the payoff — the moment the
control plane provisions the first node of the **worker plane** (§0). We
create a VM with **no disk at all** — just a NIC on the internal wire with
one of §6's MACs — and switch it on. Watch what happens against the chain
from §0:

1. **UEFI firmware** finds nothing else to boot and PXE-boots the NIC:
   broadcasts a DHCP request *asking for boot instructions*.
2. **CoreDHCP** (head) looks up `52:54:00:be:ef:01` in its SMD cache →
   leases **172.16.0.1** and answers with "boot file: iPXE, from
   172.16.0.254" (coresmd bundles aarch64 EFI iPXE binaries — no config
   needed for the architecture).
3. Firmware TFTP-downloads **iPXE** — a much smarter bootloader — which
   re-DHCPs, fetches `config.ipxe`, and chains to **BSS**:
   `http://172.16.0.254:8081/boot/v1/bootscript?mac=...`
4. BSS returns §8's script; iPXE downloads **kernel + initramfs** from S3
   and boots the kernel with our dissected command line.
5. The initramfs (dracut `livenet`) re-DHCPs *again*, streams the 1.4 GiB
   **SquashFS**, mounts it with a tmpfs **overlay**, and pivots into it.
6. **cloud-init** runs against `http://172.16.0.254:8081/cloud-init`,
   applies §9's layers (hostname `compute1`, root SSH key), and the login
   prompt appears.

## Step 10.1 — Create and start the diskless VM

```
host$ virt-install \
    --name compute1 \
    --memory 3072 \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant rocky9 \
    --disk none \
    --pxe \
    --network network=openchami-net-internal,model=virtio,mac=52:54:00:be:ef:01 \
    --boot uefi \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole
```

Differences from §4's head: `--disk none --pxe` (no storage, boot from the
network — this is the whole point); a single NIC, on the **internal**
network only, with the MAC that SMD maps to 172.16.0.1; and 3 GiB of RAM —
remember the OS itself lives in that RAM (1.4 GiB SquashFS + overlay +
running system), so don't go much lower.

## Step 10.2 — Watch it boot

```
host$ virsh console compute1
```

(Exit with `Ctrl+]`.) What you'll see, mapped to the chain: the firmware's
PXE messages (stage 1–2) → iPXE's banner and the chain URL (3) → kernel
boot messages on `ttyAMA0` (4) → a pause with dracut messages while the
SquashFS streams (5 — the longest stage, ~30 s on our VM-internal network)
→ cloud-init output → `compute1 login:` (6).

Log in as `testuser` / `testuser` — §7's debug layer, existing for exactly
this moment.

## Step 10.3 — Prove it's a live diskless system

At the console (or later over SSH):

```
compute$ findmnt /
TARGET SOURCE        FSTYPE  OPTIONS
/      LiveOS_rootfs overlay rw,relatime,lowerdir=/run/rootfsbase,...

compute$ uname -m
aarch64
```

`overlay` with `lowerdir=/run/rootfsbase` *is* the diskless architecture,
visible: the read-only SquashFS underneath, tmpfs writes on top.

## Step 10.4 — SSH in as root (the cloud-init proof)

From the head node:

```
head$ ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@172.16.0.1
[root@compute1 ~]# hostname
compute1
[root@compute1 ~]# cloud-init status
status: done
```

Working root SSH is the end-to-end receipt: the key travelled
§9 defaults → group template → rendered per-node config → fetched over the
internal wire at boot → applied by cloud-init. And the hostname is the
per-node override, not the `de01` default.

(Host keys regenerate every boot — a diskless node is *new* every time —
hence the two `-o` flags. For a lab, park them in
`~/.ssh/config` on the head:
`Match host=172.16.0.*` / `UserKnownHostsFile=/dev/null` /
`StrictHostKeyChecking=no`.)

## Step 10.5 — The reboot party trick

```
host$ virsh destroy compute1 && virsh start compute1
```

`destroy` is a power-yank, and it doesn't matter: no disk, no state,
nothing to corrupt. ~90 seconds later the node is back, fresh from the
image. This is how thousand-node systems stay uniform — and how you
"reinstall" in OpenCHAMI: change the image or boot params on the head and
power-cycle.

## ✅ Checkpoint

All of: console reaches `compute1 login:`; `testuser` can log in;
`findmnt /` shows the overlay; root SSH from the head works;
`cloud-init status` = `done`. Also see the node from the control plane's
side:

```
head$ ochami smd component get | jq '.Components[] | select(.ID=="x1000c0s0b0n0")'
```

## Common failures → §11

The boot chain has many links; §11's table maps every symptom we have
actually hit to its cause. The two big ones: stuck getting a
`172.16.0.200`-range address (bootloop lease — the head's DHCP can't read
SMD; certificate gotcha from §5.10) and cloud-init erroring with
`http://cloud-init:27777` URLs (the §9 memstore gotcha).

Next: [§11 — Troubleshooting](11-troubleshooting.md)
