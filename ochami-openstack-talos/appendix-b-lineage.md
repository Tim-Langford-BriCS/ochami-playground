# Appendix B — Lineage: upstream → lab → this POC → the PTR

This repository now holds three reproductions of the same architecture on three different substrates. This appendix is the map. It extends [`../ochami-macos-libvirt/appendix-d-lineage.md`](../ochami-macos-libvirt/appendix-d-lineage.md), which was written when the OpenStack column was still speculative, and closes out the seven open questions it listed.

**The organising idea, restated:** the **OpenCHAMI layer is identical in every column.** Only the *substrate* underneath and the *worker plane* it provisions change. That is why the lab was worth doing, and why this POC transfers.

> **Certainty.** Columns 1–2 are done and validated. Column 3 (this tutorial) is written ahead of first execution — see the README's fidelity note. Column 4 is forward-looking; cells marked **?** are choice points, not facts.

## The four-way table

| Concern | Upstream tutorial | libvirt lab (Mac/Lima) | **This POC (OpenStack)** | PTR (real metal) |
|---|---|---|---|---|
| **Substrate** | a Linux host with libvirt/KVM | a Lima VM running Rocky 9 with nested KVM | **Nova instances + Neutron networks**, one instance per node | **Dell + HPE servers** in the PTR |
| **Nested virtualisation** | n/a | **required** (Apple M3+) | **deliberately not used** — disabled cloud-wide at DL | n/a |
| **CPU arch** | x86_64 | aarch64 | **x86_64** | x86_64, plus **aarch64 from 2026/27** |
| **Head-node install** | kickstart (Anaconda) | cloud image + cloud-init via seed ISO | cloud image + cloud-init via **Nova metadata** | **?** — cloud-init still, from OpenCHAMI or a seed |
| **Head-node placement** | libvirt VM on the host | KVM VM inside the Lima VM | a Nova instance | **?** — an instance, or dedicated bare metal. LANL suggest *several* control planes in VMs, one per developer |
| **Networks** | libvirt XML (NAT + isolated) | 2 × libvirt networks | 2 × **Neutron** networks; provisioning subnet `--no-dhcp --gateway none`, **port security off** | a physical management VLAN on a PowerSwitch S3248T-ON, plus 100 GbE RoCEv2 |
| **"Only CoreDHCP answers DHCP"** | isolated bridge, no `<ip>` | same | `--no-dhcp` on the subnet — **enforced by Neutron** | **a switch configuration and an agreement with the network team.** No flag to enforce it |
| **Node MACs** | hand-written | invented, via `virt-install` | invented, pinned onto **Neutron ports** | **discovered** from real NICs |
| **How a node network-boots** | `--boot network` | `--boot uefi,hd,network` | **iPXE *is* the root disk** — Nova cannot put a NIC in a boot order at all (§7) | firmware PXE setting, per vendor |
| **Node discovery** | static YAML (flat) | static YAML (nested) | static YAML — **or Magellan over sushy-tools** ([appendix A](appendix-a-redfish-sushy.md)) | **Magellan over Redfish** against real BMCs |
| **Power control** | — | `virsh start/destroy` | `openstack server start/stop`, or **Redfish via sushy-tools** | **Redfish** to iDRAC / iLO |
| **BMC credentials** | none | none | none (or unauthenticated emulators) | **a real design problem**, per chassis |
| **Worker plane OS** | Rocky, diskless SquashFS | Rocky, diskless SquashFS | **Talos**, installed to disk | **Talos** — except possibly the Gaudi node (§16.1) |
| **Node config mechanism** | cloud-init | cloud-init | **Talos machine config** via `talos.config` | same |
| **Image building** | `image-builder` → SquashFS | same | **none** — Talos assets are prebuilt | **Talos Image Factory schematics**, one per hardware class |
| **S3 artifact store** | MinIO :9000 | Versity :7070 | Versity :7070 | Versity — backing store **?** (local disk vs Ceph/RGW vs the PowerVault) |
| **Boot chain** | DHCP→TFTP→iPXE→BSS→image | identical | identical | identical — **this is the whole point** |
| **Kubernetes** | — | — | **Talos + KServe + vLLM + KubeRay** | same, plus device plugins |
| **Accelerators** | — | — | **none** (CPU-only inference) | Gaudi3, RTX Pro 6000, MI210 |
| **Storage class** | — | — | local-path on node disk | local-path for caches; **?** for shared weights (NFS host / PowerVault iSCSI / CSI) |
| **GitOps** | — | — | **FluxCD**, `clusters/techwatch-poc/` | FluxCD, `clusters/techwatch-ptr/` — **same repo** |
| **Identity / access** | `sudo` | `libvirt` group + `LIBVIRT_DEFAULT_URI` | **Keystone** application credentials + `clouds.yaml` | site auth for the head; **Redfish creds** for the BMCs |
| **Blast radius** | your host | your laptop | **a shared production cloud** — hence §1 | **the PTR**, and real power |
| **SELinux** | disabled | permissive | permissive | **?** — enforcing for production |
| **Certs / TLS** | step-ca | step-ca | step-ca | **?** — step-ca standalone vs site PKI |
| **Control-plane HA** | 1 head | 1 head | 1 head | **?** |
| **The OpenCHAMI layer** | — | SMD, BSS, CoreSMD, cloud-init | **identical** | **identical** |

## Closing out the libvirt lab's seven open questions

Appendix D of the libvirt lab listed seven choice points for the PTR. Three are now answered by this POC, and four remain genuinely open.

| # | The lab's question | Status |
|---|---|---|
| 1 | Where does the control plane live — an OpenStack VM or dedicated bare metal? | **Partly answered.** A single instance is demonstrably sufficient for a small cluster, which supports LANL's "one control plane per developer in a VM" suggestion. The PTR production choice is still open |
| 2 | How is the substrate defined — Kayobe/Terraform or hand-built? | **Answered for the POC:** hand-built here, with [OpenTofu + Ansible](../ochami-openstack-talos-iac/) as the reproducible form. Both are validated against each other |
| 3 | CPU architecture of the compute nodes? | **Answered:** x86_64 now, and this POC is x86_64 to match. aarch64 arrives 2026/27 — and the libvirt lab is the aarch64 reference, so both are documented |
| 4 | S3 backing store at scale — local disk vs Ceph/RGW? | **Still open.** The POC uses the head's local disk, which will not hold PTR-scale images |
| 5 | Control-plane HA — single head or highly available? | **Still open.** Single head throughout |
| 6 | SELinux posture — permissive for bring-up vs enforcing? | **Still open.** Permissive here; the deliberate choice of *permissive* rather than *disabled* means the audit log needed to move to enforcing is being generated |
| 7 | Cert/PKI integration — step-ca standalone vs site DNS/PKI? | **Still open.** step-ca standalone throughout |

## What this POC newly settled

Questions the libvirt lab could not have asked, now answered:

| Question | Answer |
|---|---|
| Can OpenCHAMI provision nodes on OpenStack **without nested virtualisation**? | **Yes** — one instance per node, network boot faked by making iPXE the root disk (§0, §7). This matters because DL has nested virt disabled and is unlikely to re-enable it |
| Is there a cloud equivalent of "network boot"? | **Yes, via rescue mode** — and it is the same mechanism sushy-tools uses for Redfish, so it is not throwaway (§0, appendix A) |
| Does Talos work as an OpenCHAMI-provisioned OS? | Demonstrated in the libvirt lab, repeated here on x86_64 |
| Can Redfish discovery be rehearsed without BMCs? | **Yes** — sushy-tools' OpenStack driver, one emulator per instance (appendix A) |
| Does the PTR's inference stack run end to end? | **The control path does**, on CPU. Performance is untested by design (§14, §19) |

## What still has no rehearsal at all

Listed so nobody is surprised. These are the things that will consume time when the hardware is powered on:

1. **Vendor firmware.** Dell and HPE UEFI settings, boot order, secure boot, PXE-on-which-NIC. No POC equivalent whatsoever.
2. **Vendor Redfish.** iDRAC and iLO differ from each other and from the spec. sushy-tools is the spec, politely.
3. **The fast fabric.** 100 GbE Broadcom RoCEv2, later SlingShot-400. A Neutron network is not a rehearsal for either.
4. **Accelerator drivers on Talos.** NVIDIA is well-trodden; AMD is workable; **Intel Gaudi is the open risk** (§16.1).
5. **Physical reality.** Power, cooling, cabling, the delayed S3248T-ON switch, and racks that are not adjacent.

## The one-paragraph version

Upstream → lab: we swapped a drifted x86 libvirt guide for a current, cloud-init based aarch64 Lima lab. Lab → this POC: we swapped the Lima substrate for OpenStack without nesting, found that Nova cannot network-boot an instance at all and made iPXE the node's root disk instead — so creating the instance *is* pressing the PXE button — flipped back to x86_64, and built the whole inference stack on top. POC → PTR: we swap Nova instances for Dell and HPE servers, sushy-tools for real BMCs, and CPU for accelerators — **and the OpenCHAMI layer in the middle still never changes.**

## Related

- [§19 — Summary](19-summary.md), for the decision list and open questions
- [Appendix A — virtual BMCs](appendix-a-redfish-sushy.md), which converts the "node discovery" row from static to dynamic
- [Appendix C — alternatives](appendix-c-alternatives.md)
- [`../ochami-macos-libvirt/appendix-d-lineage.md`](../ochami-macos-libvirt/appendix-d-lineage.md), the ancestor of this table
