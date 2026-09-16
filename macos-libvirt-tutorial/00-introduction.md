# §0 — Introduction: what we're building and why

## What OpenCHAMI is (in one paragraph)

**OpenCHAMI** (Open Composable Heterogeneous Adaptive Management
Infrastructure) is an open-source toolkit for provisioning and booting HPC
clusters, built as a set of small cooperating services rather than one
monolithic cluster manager. A management ("head") node runs those services
in containers; compute nodes have no OS installed at all — they network-boot
a shared image at power-on and personalise themselves from a metadata
server. It was founded by LANL, NERSC, CSCS, HPE and the University of
Bristol. For the full background read
[../openchami-summary.md](../openchami-summary.md); this tutorial is about
*doing* rather than reading.

## The cast of characters

You'll meet these services in §5; keep this table handy:

| Service | Job | Analogy |
|---|---|---|
| **SMD** | inventory database: which nodes exist, their MACs, IPs, groups | the cluster's address book |
| **BSS** | hands each node its boot script (kernel, initrd, kernel args) | the concierge's key rack |
| **CoreSMD** (CoreDHCP + CoreDNS plugins) | DHCP leases and DNS names *derived from SMD*, plus TFTP for PXE | reception desk |
| **cloud-init server** | per-node configuration (users, SSH keys, hostnames) served at boot | the welcome pack |
| **Magellan** | discovers real hardware via Redfish BMCs (not used here — VMs have no BMCs) | the census taker |
| step-ca, haproxy, postgres, OIDC (hydra/opaal) | certificates, API gateway, storage, auth tokens | back office |

The key design idea: **SMD is the single source of truth**, and everything
else (DHCP, DNS, boot scripts, node config) is *derived from it on demand*.
Add a node to SMD and the whole stack knows about it.

## The two planes

Name the two layers you're building — the same split scales straight up to
the real PTR cluster, so we use this vocabulary throughout:

- **Control plane / substrate** — the head node and the two networks,
  running the OpenCHAMI services above. This is the layer that *does the
  provisioning*. (Strictly, the *substrate* is the infrastructure the head
  sits on and the *control plane* is the OpenCHAMI software running on it;
  they stand up together as one layer, so we pair the terms.) In this lab
  the substrate is a **Lima VM + libvirt networks** (§§1–4); on the PTR it's
  **OpenStack instances + Neutron networks** built by StackHPC. What runs on
  top — OpenCHAMI (§§5–9) — is identical either way.
- **Worker plane / bare metal** — the compute nodes: the layer that *gets
  provisioned* and runs the actual workloads. Here they're diskless KVM VMs
  (§10); on the PTR they're real bare-metal servers. OpenCHAMI network-boots
  them (Redfish/DHCP/PXE) and they hold no local state.

The dividing line is **who provisions whom**: something stands up the
control plane (OpenStack on the PTR, Lima/libvirt here), then the control
plane stands up the worker plane (always OpenCHAMI, exactly as you build in
§§5–10). Keeping the two planes distinct is what lets the same OpenCHAMI
skills carry from this laptop lab to the tank room.

## How a diskless node boots (the chain we'll build)

```
power on → UEFI firmware PXE-boots            (§10)
        → DHCP: CoreDHCP looks the MAC up in SMD, leases its IP     (§5, §6)
        → TFTP: firmware downloads the iPXE bootloader              (§5)
        → iPXE asks BSS for this node's boot script                 (§8)
        → downloads kernel + initramfs from the S3 store            (§7, §8)
        → initramfs streams a SquashFS root image over HTTP,
          overlays a RAM-backed writable layer, pivots into it      (§7)
        → cloud-init fetches this node's config and applies it      (§9)
        → login prompt / SSH                                        (§10)
```

Nothing is ever installed on the compute node. Reboot it and it rebuilds
itself from scratch in about a minute — which is exactly how large HPC
systems keep thousands of nodes identical.

## How the Mac stands in for a Linux host

The upstream guide assumes a Linux machine running **libvirt/KVM**. macOS
has neither, but Apple Silicon (M3 onwards) supports **nested
virtualization**: a VM can itself run hardware-accelerated VMs. So:

| Upstream guide | This tutorial |
|---|---|
| Linux host with libvirt/KVM | **Lima VM** (`ochami-host`) running Rocky Linux 9, with libvirt/KVM inside it |
| head node = libvirt VM on the host | head node = KVM VM *inside* the Lima VM |
| compute nodes = libvirt VMs on the host | compute VMs *inside* the Lima VM, siblings of the head |
| x86_64 everywhere | **aarch64** everywhere (Apple Silicon is ARM) |

[Lima](https://lima-vm.io) is a thin, scriptable wrapper around Apple's
Virtualization.framework — think "Docker Machine for Linux VMs on macOS".
Everything below the Lima VM is identical to what you'd do on a real Rocky
Linux server, which is the point: the skills transfer.

The aarch64 switch has a handful of consequences you'll see flagged as we
go: UEFI firmware is `edk2-aarch64` instead of x86 OVMF, the serial console
device is `ttyAMA0` instead of `ttyS0`, and the compute-node image must be
built from aarch64 package repositories. None of them change the OpenCHAMI
concepts.

## Fidelity note

We follow the guide's **architecture** exactly (host / head VM / two
networks / diskless computes) but use the **current** OpenCHAMI conventions
from the main tutorial where the older guide has drifted (S3 backend,
discovery file format, tool versions). Each such point gets a 🔀 Deviation
box in place. One structural change: the head node is installed from a
cloud image with cloud-init (§4) rather than the guide's kickstart flow —
kickstart is covered in [Appendix A](appendix-a-kickstart.md), and the 🔀
box in §4 explains the trade-off.

Next: [§1 — The host: a Lima VM with nested virtualization](01-the-host-lima-vm.md)
