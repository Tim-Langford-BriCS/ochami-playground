# §8 — Boot parameters

*(Upstream: guide §3.3 / tutorial Part 2.5. Time: ~5 minutes. On the head
node; fresh token needed.)*

## Concepts

**BSS (Boot Script Service)** answers one question, per node: *"a machine
with MAC X is asking how to boot — what do I tell it?"* The answer is a
generated **iPXE script**: which kernel to fetch, which initramfs, and the
kernel command line. We now store that answer for our five MACs.

The kernel command line is where diskless boot actually gets wired
together, so let's dissect the one we're about to set:

| Token | Meaning |
|---|---|
| `root=live:http://172.16.0.254:7070/boot-images/...` | dracut's live-boot syntax: "your root filesystem is this SquashFS — fetch it over HTTP" (this is what `dmsquash-live`+`livenet` in §7's initramfs exist for) |
| `overlayroot=tmpfs overlayroot_cfgdisk=disabled` | writable tmpfs overlay on the read-only image; forget everything at reboot |
| `ip=dhcp` | the initramfs asks CoreDHCP for its address (again — firmware leases don't survive into Linux) |
| `console=ttyAMA0,115200` | serial console on ARM (🔀 upstream says `ttyS0` — that's x86; get this wrong and `virsh console` shows nothing after the kernel loads) |
| `cloud-init=enabled ds=nocloud-net;s=http://172.16.0.254:8081/cloud-init` | point cloud-init at OpenCHAMI's metadata server (§9) — same NoCloud mechanism as §4's seed ISO, but over the network |
| `apparmor=0 selinux=0 nomodeset ro ip6=off` | keep the live image simple: no MAC-security relabelling of a read-only root, no graphics modes, no IPv6 surprises |

## Step 8.1 — Generate the BSS payload from what's really in S3

Rather than hand-typing artifact URLs (kernel versions change with every
Rocky update), list the bucket and build the payload from it:

```
head$ sudo mkdir -p /etc/openchami/data/boot/bss
head$ URIS=$(s3cmd ls -Hr s3://boot-images | grep compute/debug | awk '{print $4}' \
        | sed 's-s3://-http://172.16.0.254:7070/-' | xargs)
head$ URI_IMG=$(echo "$URIS" | cut -d' ' -f1)
head$ URI_INITRAMFS=$(echo "$URIS" | cut -d' ' -f2)
head$ URI_KERNEL=$(echo "$URIS" | cut -d' ' -f3)
head$ echo "$URI_KERNEL"; echo "$URI_INITRAMFS"; echo "$URI_IMG"
```

(Check all three echo something sensible before continuing. The `sed`
rewrites `s3://boot-images/...` into the plain-HTTP URL nodes will use —
note it's the raw IP, not `demo.openchami.cluster`: booting nodes have no
`/etc/hosts` entry and DNS isn't up yet that early in boot.)

```
head$ cat << EOF | sudo tee /etc/openchami/data/boot/bss/compute-debug-rocky9.yaml
---
kernel: '${URI_KERNEL}'
initrd: '${URI_INITRAMFS}'
params: 'nomodeset ro root=live:${URI_IMG} ip=dhcp overlayroot=tmpfs overlayroot_cfgdisk=disabled apparmor=0 selinux=0 console=ttyAMA0,115200 ip6=off cloud-init=enabled ds=nocloud-net;s=http://172.16.0.254:8081/cloud-init'
macs:
  - 52:54:00:be:ef:01
  - 52:54:00:be:ef:02
  - 52:54:00:be:ef:03
  - 52:54:00:be:ef:04
  - 52:54:00:be:ef:05
EOF
```

## Step 8.2 — Load it into BSS

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
head$ ochami bss boot params set -f yaml -d @/etc/openchami/data/boot/bss/compute-debug-rocky9.yaml
head$ ochami bss boot params get -F yaml
```

(`set` replaces idempotently — re-run it freely; `add` would refuse to
overwrite. Later, pointing nodes at a different image = regenerate the
payload from the other S3 prefix and `set` again. That's the whole
"reprovision the cluster" workflow.)

## ✅ Checkpoint — pretend to be a booting node

```
head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01"
#!ipxe
kernel --name kernel http://172.16.0.254:7070/boot-images/efi-images/compute/debug/vmlinuz-... initrd=initrd nomodeset ro root=live:http://... xname=x1000c0s0b0n0 nid=1 || goto boot_retry
initrd --name initrd http://172.16.0.254:7070/boot-images/efi-images/compute/debug/initramfs-... || goto boot_retry
boot || goto boot_retry
:boot_retry
sleep 30
chain https://${SYSTEM_URL}/apis/bss/boot/v1/bootscript?mac=52:54:00:be:ef:01&retry=1
```

That is *the actual script* the compute node's iPXE will execute in §10 —
note BSS appended `xname=` and `nid=` (it knows the node from SMD) and
built in retry logic. And confirm the three artifacts are fetchable the
way a node fetches them:

```
head$ for u in "$URI_KERNEL" "$URI_INITRAMFS" "$URI_IMG"; do
        curl -s -o /dev/null -r 0-0 -w "%{http_code} $u\n" "$u"; done
206 http://172.16.0.254:7070/boot-images/efi-images/compute/debug/vmlinuz-...
206 http://172.16.0.254:7070/boot-images/efi-images/compute/debug/initramfs-...
206 http://172.16.0.254:7070/boot-images/compute/debug/rocky9.8-compute-debug-rocky9
```

(206 = "partial content OK" — we asked for 1 byte of each.)

Next: [§9 — Configuring cloud-init](09-cloud-init-config.md)
