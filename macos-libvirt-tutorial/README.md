# OpenCHAMI on your Mac — the libvirt guide, step by step with Lima

A hands-on tutorial that builds a complete, working **OpenCHAMI**-managed
mini-cluster **entirely on an Apple Silicon Mac**: a virtual "Linux host",
a head node VM running the OpenCHAMI control plane, and a diskless compute
node that network-boots from it — exactly the architecture of the upstream
[libvirt guide](https://openchami.org/docs/guides/libvirt/), with macOS
(Lima + Apple's Virtualization.framework) standing in for the Linux
hypervisor host.

Every step gives the **full command or config file**, then explains **what
it does and why it's done that way**. By the end you will have touched, by
hand: Lima and nested virtualization, libvirt networks and UEFI VMs on
aarch64, Podman Quadlets, DHCP/TFTP/PXE/iPXE, the OpenCHAMI microservices
(SMD, BSS, CoreSMD, cloud-init), JWT-authenticated APIs, diskless SquashFS
images, and cloud-init-driven node personalisation.

## What you will build

```
your Mac (Apple Silicon)
└── Lima VM "ochami-host"          ← §1   the guide's "Linux host with libvirt"
    ├── openchami-net-external     ← §3   NAT network (SSH path to the head)
    ├── openchami-net-internal     ← §3   isolated network (PXE/boot wire)
    ├── VM "head"                  ← §4   Rocky 9, 192.168.200.2 + 172.16.0.254
    │     └── OpenCHAMI            ← §5-9 quadlet services, images, boot config
    └── VM "compute1"              ← §10  diskless: PXE-boots from the head
```

## Prerequisites

| Requirement | Why |
|---|---|
| Apple Silicon **M3 or newer**, macOS 15+ | nested virtualization (VMs inside the Lima VM) |
| ~16 GiB of RAM free for the lab | host VM 16 GiB (head 4 + compute 3 inside it) |
| ~40 GB free disk | VM images + a ~3 GB boot-image store |
| [Lima](https://lima-vm.io) ≥ 2.0 (`brew install lima`) | the macOS virtualisation layer |
| A reasonable network connection | ~3–4 GB of downloads (OS images, containers, packages) |

No other tools are needed on the Mac itself — everything else happens
inside VMs and is deleted by the teardown section.

## Contents

| § | File | Upstream ref |
|---|---|---|
| 0 | [Introduction — what we're building and why](00-introduction.md) | guide intro |
| 1 | [The host: a Lima VM with nested virtualization](01-the-host-lima-vm.md) | guide §"a Linux host" |
| 2 | [Preparing the host](02-host-preparation.md) | guide §1.2 |
| 3 | [The two networks](03-networks.md) | guide §1.3–1.4 |
| 4 | [The head node VM](04-head-node-vm.md) | guide §1.1 (🔀 cloud-image flow) |
| 5 | [Installing OpenCHAMI](05-install-openchami.md) | guide §2 / tutorial Part 1 |
| 6 | [Telling OpenCHAMI about our nodes](06-node-discovery.md) | guide §3.1 / tutorial 2.2 |
| 7 | [Building the compute node image](07-image-building.md) | guide §3.2 / tutorial 2.3–2.4 |
| 8 | [Boot parameters](08-boot-parameters.md) | guide §3.3 / tutorial 2.5 |
| 9 | [Configuring cloud-init](09-cloud-init-config.md) | guide §3.4 / tutorial 2.7 |
| 10 | [Booting the compute node](10-boot-compute-node.md) | guide §4 / tutorial 2.6+2.8 |
| 11 | [Troubleshooting](11-troubleshooting.md) | — |
| 12 | [Teardown](12-teardown.md) | guide §5 |
| 13 | [Summary — what we built and decided](13-summary.md) | — |
| A | [Appendix: the kickstart install path](appendix-a-kickstart.md) | guide §1.1 verbatim flow |
| B | [Appendix: mapping to upstream docs & our automation](appendix-b-mapping.md) | — |
| C | [Appendix: two ways to drive libvirt (and which to learn for cloud)](appendix-c-access-models.md) | — |
| D | [Appendix: lineage — upstream → this lab → the PTR](appendix-d-lineage.md) | — |

Reading order is 0 → 13. Budget **half a day** the first time: most of it is
waiting for downloads and image builds, with §5 and §7 the long poles.

## Conventions and fidelity

- Commands are shown with the prompt of the machine they run on:
  `mac$` (your Mac), `host$` (inside the Lima VM), `head$` (inside the head
  node VM), `compute$` (on the booted compute node).
- ✅ **Checkpoint** blocks show the expected (real, captured) output so you
  know you're on track before moving on.
- 🔀 **Deviation** boxes mark every place we differ from the upstream guide
  and say why (usually: the guide has drifted behind the main tutorial, or
  x86-isms need aarch64 equivalents). The full drift analysis lives in
  [../openchami-tutorial-notes.md](../openchami-tutorial-notes.md).
- ⚠ **Gotcha** boxes are lessons paid for in hours during our first two
  reproductions (`~/work/brics/ochami-lab` and `~/work/brics/ochami-iac`) —
  read them even if you skip everything else.
- **libvirt is driven as your own user, not via `sudo`.** §2.2 adds you to
  the `libvirt` group and sets `LIBVIRT_DEFAULT_URI=qemu:///system`, so every
  `virsh …` and `virt-install …` in this guide is written with no `sudo` and
  no `--connect`. (Commands that genuinely need root — `dnf`, `systemctl`,
  writing under `/etc` — still show `sudo`.)

Every command in §§1–10 and §12 was executed on an Apple M5 Pro
(macOS 26.5, Lima 2.1.4) on 2026-07-10. Those first runs used `sudo virsh`/
`sudo virt-install`; on 2026-07-12 the guide was switched to the sudo-free
pattern above (cleaner, and it's how you'd manage a real cluster). The
network and lifecycle `virsh` operations were re-verified live in that mode;
`virt-install` builds the identical `qemu:///system` domain either way (same
polkit action authorises it, the guest still runs as the `qemu` user, and
the §4.2 `setfacl` step already grants that user access), so it was not
rebuilt from scratch.
