# §4 — The head node VM

*(Upstream: guide §"Create the Head Node VM". Time: ~15 minutes.)*

## Concepts

The head node is an ordinary VM with **two network interfaces** — one on
each network from §3 — that will run the entire OpenCHAMI control plane:

| NIC | Network | Address | Purpose |
|---|---|---|---|
| eth0 | openchami-net-external | 192.168.200.2 (static) | SSH in; downloads out |
| eth1 | openchami-net-internal | 172.16.0.254 (static) | serves DHCP/TFTP/DNS/boot artifacts to compute nodes |

`172.16.0.254` matters: every OpenCHAMI config in §§5–9 refers to it. It is
the "cluster head" address that compute nodes talk to.

🔀 **Deviation — how the OS gets onto the disk.** The upstream guide
network-installs Rocky with **kickstart** (the answer-file format for the
Anaconda **OS installer** — Red Hat's, *not* the Python/conda distribution
of the same name — served from a throwaway web server). We instead use Rocky's
**GenericCloud image** — a pre-installed disk — personalised on first boot
by **cloud-init**. Two reasons: it's dramatically fewer moving parts, and
it's the same mechanism OpenCHAMI itself uses to personalise compute nodes
(§9), so you learn it twice. It's also how clouds (including an OpenStack
deployment) provision machines. The kickstart flow — worth knowing for
bare-metal work — is written up in [Appendix A](appendix-a-kickstart.md).

**How NoCloud seeding works:** cloud-init inside the image searches, at
boot, for a data source. One option is a CD-ROM with the volume label
`cidata` containing three files: `meta-data` (identity), `user-data`
(cloud-config: users, keys, commands), and optionally `network-config`.
We build that tiny ISO by hand — this is the "seed".

## Step 4.1 — An SSH key for reaching the head

```
host$ ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

(`-N ''` = no passphrase; this key lives only inside the disposable lab.)
Run this from anywhere — `-f ~/.ssh/id_ed25519` is an absolute path, so the
key lands in `~/.ssh/` regardless of your current directory. (§4.2 is the
first step where the working directory matters, and it starts with
`cd ~/cluster`.)

## Step 4.2 — Fetch the Rocky cloud image and make the head's disk

```
host$ cd ~/cluster
host$ wget -O rocky9-base.qcow2 \
    https://rockylinux.mirrorservice.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud.latest.aarch64.qcow2
```

> 💡 We fetch from the UK Mirror Service; `dl.rockylinux.org` has throttled
> us to KB/s more than once. Any mirror from
> `https://mirrors.rockylinux.org/mirrorlist?arch=aarch64&repo=rocky-9` works.
> If you already run Lima VMs from this image, the file is in
> `~/Library/Caches/lima/download/` on your Mac and can be copied in with
> `limactl copy` instead of downloading.

```
host$ qemu-img create -f qcow2 -F qcow2 -b "$PWD/rocky9-base.qcow2" head.qcow2 40G
```

This makes `head.qcow2` a **copy-on-write overlay** on the pristine base
image: the head's disk starts as a few KB of metadata, reads fall through
to the base, writes land in the overlay, and it can grow to 40 GB.

🔀 **Deviation — disk size.** The guide says 20 GB. Our head also hosts the
S3 artifact store, an OCI registry, and the image builds (§7): 20 GB fills
up mid-build. 40 GB.

Finally, let the hypervisor reach these files. QEMU runs VMs as its own
unprivileged `qemu` user, which cannot traverse your home directory, so
grant it search (`x`) permission — without this, §4.5 fails with
`Cannot access storage file ... Permission denied` (a failure the upstream
tutorial documents too):

```
host$ setfacl -m u:qemu:x "$HOME"
```

## Step 4.3 — Write the cloud-init seed files

```
host$ cat > meta-data << 'EOF'
instance-id: ochami-head
local-hostname: head
EOF
```

```
host$ cat > user-data << EOF
#cloud-config
users:
  - name: rocky
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub)
write_files:
  - path: /etc/selinux/config
    content: |
      SELINUX=permissive
      SELINUXTYPE=targeted
runcmd:
  - setenforce 0 || true
EOF
```

(Note the **unquoted** `EOF`: we *want* the shell to substitute
`$(cat ~/.ssh/id_ed25519.pub)` so your public key lands in the file. The
`user-data` must start with the literal line `#cloud-config`.)

```
host$ cat > network-config << 'EOF'
version: 2
ethernets:
  eth0:
    match:
      macaddress: "52:54:00:c0:fe:01"
    set-name: eth0
    addresses: ["192.168.200.2/24"]
    gateway4: 192.168.200.1
    nameservers:
      addresses: [192.168.200.1]
  eth1:
    match:
      macaddress: "52:54:00:be:ef:ff"
    set-name: eth1
    addresses: ["172.16.0.254/24"]
EOF
```

Why match by MAC? Linux interface names depend on PCI enumeration
(`enp1s0`, `ens4`…) and vary by machine type. We choose the MACs ourselves
in step 4.5, match on them here, and *pin* the names to `eth0`/`eth1` —
so §5's DHCP config can say "listen on eth1" and always be right. The MACs
are the upstream guide's own values (`…:c0:fe:01` external,
`…:be:ef:ff` internal). eth1 has no gateway: the internal wire routes
nowhere by design.

## Step 4.4 — Build the seed ISO

```
host$ genisoimage -output seed.iso -volid cidata -joliet -rock \
    user-data meta-data network-config
```

`-volid cidata` is the magic: that volume label is how cloud-init
recognises the disk as a NoCloud datasource.

## Step 4.5 — Create the VM

```
host$ virt-install \
    --name head \
    --memory 4096 \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant rocky9 \
    --import \
    --disk path=$PWD/head.qcow2,format=qcow2,bus=virtio \
    --disk path=$PWD/seed.iso,device=cdrom \
    --network network=openchami-net-external,model=virtio,mac=52:54:00:c0:fe:01 \
    --network network=openchami-net-internal,model=virtio,mac=52:54:00:be:ef:ff \
    --boot uefi \
    --graphics none \
    --console pty,target_type=serial \
    --autostart \
    --noautoconsole
```

Flag by flag:

- `--cpu host-passthrough` — expose the real CPU to the guest. **Required**
  for VMs inside a Virtualization.framework VM; without it the nested
  hypervisor refuses to start vCPUs.
- `--os-variant rocky9` — lets virt-install pick sensible defaults
  (virtio devices, correct machine type) for this OS.
- `--import` — "the disk already contains an OS; don't run an installer."
  This is what makes the cloud-image flow so short.
- The **first** `--disk` is the overlay from 4.2; the **second** attaches
  the seed ISO as a CD-ROM. On aarch64 there is no IDE bus (the classic
  x86 CD-ROM attachment), so virt-install places the cdrom on SCSI — if
  your virt-install is old enough to try IDE you'll see
  `IDE controllers are unsupported`; add
  `--controller type=scsi,model=virtio-scsi` and
  `,bus=scsi` on the cdrom line.
- `--network …,mac=…` — plugs a virtio NIC into each §3 network with
  exactly the MACs our network-config matches.
- `--boot uefi` — aarch64 guests *only* boot UEFI; virt-install selects
  the edk2-aarch64 firmware from §2 automatically.
- `--graphics none --console pty,target_type=serial` — a headless VM
  whose console is reachable with `virsh console` (serial device; on ARM
  the guest sees it as `ttyAMA0`).
- `--noautoconsole` — return to the shell instead of attaching the console.

## Step 4.6 — Wait for first boot, then SSH in

First boot takes a minute or two (cloud-init applies our seed, regenerates
host keys, grows the filesystem to 40 GB). Watch it if you like:

```
host$ virsh console head        # exit with Ctrl+]
```

Then:

```
host$ ssh rocky@192.168.200.2
```

You are now "on the head node" — prompts shown as `head$` from here.

## ✅ Checkpoint

```
head$ cat /etc/rocky-release
Rocky Linux release 9.8 (Blue Onyx)

head$ ip -br addr | grep eth
eth0             UP             192.168.200.2/24 ...
eth1             UP             172.16.0.254/24 ...

head$ ping -c1 dl.rockylinux.org > /dev/null && echo internet OK
internet OK

head$ getenforce
Permissive
```

Both NICs, with *those names* and *those addresses*, prove the whole
MAC-match/seed-ISO mechanism worked. Internet via NAT proves §3's external
network. If SSH is refused, give cloud-init another minute; if it never
answers, `virsh console head` and log in on the console to debug
(`sudo cloud-init status --long`).

## Common failures

| Symptom | Cause / fix |
|---|---|
| `IDE controllers are unsupported` | old virt-install chose IDE for the cdrom — see step 4.5 note |
| VM boots but has cloud defaults (no key, wrong IPs) | seed ISO not found: check `-volid cidata` and that the cdrom is attached (`virsh dumpxml head \| grep -A3 cdrom`) |
| `Cannot access storage file … Permission denied` | the step-4.2 `setfacl` was skipped — qemu's user can't traverse your home directory |

Next: [§5 — Installing OpenCHAMI](05-install-openchami.md)
