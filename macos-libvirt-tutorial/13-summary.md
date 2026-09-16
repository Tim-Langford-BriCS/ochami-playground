# §13 — Summary: what we built, and what we decided

A one-page recap of the whole tutorial — for coming back cold, or for
explaining to someone else what this lab was. If you read only one file,
read this one.

## What OpenCHAMI is

**OpenCHAMI** (Open Composable Heterogeneous Adaptive Management
Infrastructure) is an open-source toolkit for provisioning and booting HPC
clusters. Instead of one monolithic cluster manager, it is a set of small
cooperating services that run in containers on a management ("head") node.
Compute nodes have **no OS installed** — at power-on they network-boot a
shared image and personalise themselves from a metadata server. Founded by
LANL, NERSC, CSCS, HPE and the University of Bristol.

The one design idea that explains everything else: **SMD is the single
source of truth**, and DHCP, DNS, boot scripts and per-node config are all
*derived from it on demand*. Add a node to SMD and the whole stack knows.

## What it's made of

| Service | Job |
|---|---|
| **SMD** | inventory database — which nodes exist, their MACs/IPs/groups (the source of truth) |
| **BSS** | hands each node its boot script — kernel, initramfs, kernel command line |
| **CoreSMD** (CoreDHCP + CoreDNS) | DHCP leases, DNS names and PXE/TFTP, all *generated from SMD* |
| **cloud-init server** | per-node config (users, SSH keys, hostname) served at boot |
| **Magellan** | Redfish/BMC hardware discovery (unused here — VMs have no BMCs; matters on the PTR) |
| **step-ca / haproxy / postgres / OIDC** (hydra, opaal) | private CA + TLS, API gateway, storage, JWT auth — the back office |

Plus two non-OpenCHAMI helpers the images need: an **OCI registry** (:5000,
image layers) and the **Versity S3 gateway** (:7070, bootable artifacts).

## The two planes (the mental model that scales to the PTR)

- **Control plane / substrate** — the head node + networks running the
  OpenCHAMI services. The layer that *does the provisioning*. Here: a Lima
  VM + libvirt networks. On the PTR: **OpenStack instances + Neutron
  networks** built by StackHPC. What runs on top (OpenCHAMI) is identical.
- **Worker plane / bare metal** — the compute nodes: the layer that *gets
  provisioned*. Here: diskless KVM VMs. On the PTR: real bare-metal servers.

Dividing line = **who provisions whom**. Something stands up the control
plane (OpenStack / Lima), then the control plane stands up the worker plane
(always OpenCHAMI). That split is why the skills from this laptop carry
straight to the tank room.

## What we did

Built a complete OpenCHAMI-managed mini-cluster **entirely on an Apple
Silicon Mac**, by hand, one documented step at a time:

| §§ | What | Result |
|---|---|---|
| 1–2 | A Lima VM as the "Linux host", nested virtualization, libvirt/KVM, packages | `/dev/kvm` present inside the VM |
| 3 | Two libvirt networks — NAT external, isolated internal (no DHCP/DNS) | the provisioning wire is silent until OpenCHAMI speaks |
| 4 | Head node VM from a Rocky cloud image + cloud-init seed ISO | `head` up, two pinned NICs (192.168.200.2 / 172.16.0.254) |
| 5 | Installed OpenCHAMI — ~18 quadlet services under `openchami.target` | control plane live; BSS running, SMD healthy |
| 6 | Static discovery: 5 nodes described in `nodes.yaml` → SMD | inventory loaded |
| 7 | Built layered diskless images (rocky-base → compute-base → debug) | 6 artifacts in S3 (2 SquashFS + kernel/initramfs each) |
| 8 | BSS boot parameters — the kernel command line, per MAC | valid iPXE script; artifacts fetch (HTTP 206) |
| 9 | cloud-init config — hostname, SSH key, per-node override | `de01` default overridden to `compute1` |
| 10 | Booted a **diskless** `compute1` and watched the whole chain fire | login prompt; `findmnt /` = SquashFS + tmpfs overlay |

End state: a compute node running a full OS **that exists on no disk
anywhere** — reboot it and it rebuilds from scratch in about a minute. Every
checkpoint in the doc shows real captured output; the walkthrough was
executed by hand and the doc corrected where reality disagreed.

## What we came up with — decisions & choice points

Every 🔀 in the doc is a place we chose differently from the upstream guide.
The ones that matter beyond this lab, and how they'd play out on the PTR:

| Decision | What we did | Choice point / PTR implication |
|---|---|---|
| **Head install method** (§4) | Cloud image + cloud-init, *not* kickstart | Fewest moving parts and it's how clouds/OpenStack provision. Real bare-metal heads use kickstart/preseed — kept in [Appendix A](appendix-a-kickstart.md). |
| **S3 backend** (§5) | Versity on :7070 (current tutorial) | The old guide's MinIO :9000 is the single biggest stale-URL trap. Pick one convention and hold it. |
| **Node discovery** (§6) | **Static** YAML (VMs have no BMCs) | On the PTR with real BMCs this becomes **dynamic Magellan/Redfish** discovery. Static is also what an OpenStack deployment would do. |
| **External subnet** (§3) | 192.168.200.0/24, not the guide's .122 | .122 collides with libvirt's default network. Trivial here, real on any shared host. |
| **DHCP on external net** (§3) | None — static IP via cloud-init | One mechanism fewer on the wire. |
| **Disk / SELinux** (§4, §2) | 40 GB head; SELinux *permissive* not disabled | 20 GB fills mid-build. Permissive = lab convenience; production would keep it enforcing. |
| **libvirt access model** (§2, App C) | Unprivileged user + `libvirt` group + `LIBVIRT_DEFAULT_URI`, not `sudo` | The least-privilege, "standard" style; maps to IAM/Keystone roles on AWS/OpenStack. See [Appendix C](appendix-c-access-models.md). |
| **Architecture** | aarch64 throughout (Apple Silicon) | `edk2-aarch64` UEFI, `ttyAMA0` console, arm64 image repos — cosmetic vs the concepts, but every one bites if missed. |

Two bugs the hand-walk surfaced and we fixed: the §7 checkpoint `awk` column
(printed the date, not the size) and a §5 note clarifying that head-node
`sudo` is ordinary Unix, unrelated to the host's libvirt/polkit story.

## For the weekly report

> Stood up a complete OpenCHAMI-managed cluster from scratch on a Mac — head-node control plane plus a diskless compute node that network-boots with zero local OS — validating the exact provisioning stack we'll run on the StackHPC OpenStack substrate in the PTR.

Next: [Appendix A — the kickstart install path](appendix-a-kickstart.md)
