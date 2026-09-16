# Appendix D — Lineage: upstream tutorial → this lab → the PTR

Two comparisons in one place:

1. **Upstream tutorial → this lab** — where and why we deviated (backward-looking).
2. **This lab → the PTR OpenStack build** — what changes, what stays, and
   the genuine open decisions (forward-looking).

The organising idea from §0 does the heavy lifting here: **the OpenCHAMI
layer (§§5–9) is identical in all three columns.** Only the *substrate* under
it — and the *worker plane* it provisions — changes. That is exactly why the
lab is worth doing: the skills transfer.

> **A note on certainty.** The first two columns are *done and validated*.
> The PTR column is *forward-looking* — StackHPC build the OpenStack
> substrate and several decisions are still open. Cells marked **?** are
> choice points, not facts.

## The three-way table

| Concern | Upstream tutorial | This lab (Mac / Lima) | PTR (OpenStack) |
|---|---|---|---|
| **Substrate** | A Linux host with libvirt/KVM | A **Lima VM** running Rocky 9 with nested KVM | **OpenStack** — Nova instances + Neutron networks, built by StackHPC (likely via Kayobe/Terraform) |
| **CPU arch** | x86_64 | **aarch64** (Apple Silicon) | **?** — whatever the PTR hardware is; images + UEFI/console settings follow it |
| **Head-node install** | **kickstart** (Anaconda net-install) | **cloud image + cloud-init** (seed ISO) | cloud image + cloud-init — native to OpenStack (Nova + config-drive/metadata). *Our lab choice is the PTR-native one.* |
| **Head-node placement** | libvirt VM on the host | KVM VM inside the Lima VM | **?** — an OpenStack VM instance, or a dedicated bare-metal head |
| **Networks** | libvirt XML (NAT + isolated) | 2 × libvirt networks (`br-ochami-ext/int`) | **Neutron** networks; provisioning wire = a provider/VLAN network with libvirt-style DHCP **off** so CoreDHCP owns it |
| **Provisioning wire** | isolated libvirt bridge | isolated libvirt bridge, no DHCP/DNS | a physical management VLAN; same rule — **only CoreDHCP may answer DHCP on it** |
| **S3 artifact store** | MinIO :9000 | **Versity :7070** | Versity/S3 — backing store at scale is a **?** (local disk vs Ceph/RGW) |
| **Node discovery** | static YAML (flat schema) | **static YAML** (nested `bmcs:`/`nodes:`) | **dynamic — Magellan over Redfish** against real BMCs |
| **Node MACs/IPs** | hand-written | hand-invented (`52:54:00:be:ef:0x`) | **discovered** from real NICs/BMCs; IP policy still ours |
| **Power control** | — | `virsh destroy/start` | **Redfish** BMC power on/off/reset |
| **Worker plane** | libvirt VMs | diskless **KVM VMs** | **real bare-metal servers** |
| **Diskless boot chain** | DHCP→TFTP→iPXE→BSS→SquashFS→cloud-init | identical | identical (this is the whole point) |
| **libvirt/API access** | `sudo` | unprivileged user + `libvirt` group + `LIBVIRT_DEFAULT_URI` | **Keystone RBAC** — roles + `clouds.yaml`/`openrc` (see [Appendix C](appendix-c-access-models.md)) |
| **Certs / TLS** | step-ca internal CA | step-ca internal CA | step-ca — integration with site DNS/PKI is a **?** |
| **SELinux** | disabled | permissive | **?** — enforcing for production |
| **Scale** | 1 head, few nodes | 1 head, 1 booted node (5 in SMD) | many nodes; control-plane **HA** a **?** |
| **The OpenCHAMI layer (§§5–9)** | — | SMD, BSS, CoreSMD, cloud-init, images, boot params | **identical** |

## 1. Upstream tutorial → this lab (what we deviated, and why)

Every row here has a 🔀 box at the point it occurs in the tutorial; §13 lists
them with one-line rationale. Grouped by *why* we changed them:

**Because the upstream guide drifted behind the current tutorial** (we
followed the tutorial):
- **S3 backend** — MinIO :9000 → **Versity :7070**. The biggest stale-URL trap.
- **Discovery file format** — flat `bmc_mac:`/`bmc_ip:` → nested
  `bmcs:`/`nodes:` lists. The old shape is now rejected outright.

**Because a stock libvirt host needs it**:
- **External subnet** — 192.168.122.0/24 → **192.168.200.0/24** (the .122
  range collides with libvirt's built-in `default` network).
- **No DHCP on the external net** — static IP via cloud-init instead of a
  libvirt DHCP static-host entry. One fewer mechanism on the wire.

**Because it's simply better for a teaching lab** (our own calls):
- **Head install: kickstart → cloud image + cloud-init.** The headline
  change. Fewer moving parts, and cloud-init is *reused* to personalise the
  compute nodes (§9) and is how OpenStack itself provisions — so it earns its
  keep three times over. Kickstart is preserved in [Appendix A](appendix-a-kickstart.md).
- **Disk 20 GB → 40 GB** (the head also hosts S3 + registry + image builds).
- **SELinux permissive, not disabled** (keeps it observable).
- **libvirt driven as an unprivileged user, not `sudo`** — the least-
  privilege style, chosen because it maps cleanly to cloud RBAC ([Appendix C](appendix-c-access-models.md)).

**Because the Mac is ARM** (mechanical, concept-neutral): aarch64 images,
`edk2-aarch64` UEFI, `ttyAMA0` serial console.

## 2. This lab → the PTR OpenStack build (what changes, what stays)

**What stays the same — the reassuring part.** Everything from §5 onward:
installing OpenCHAMI, SMD as the source of truth, BSS boot scripts, the
CoreDHCP/CoreDNS config, image building, boot parameters, cloud-init
layering, and the entire diskless boot chain. If you can do §§5–10 here, you
can do them on the PTR. That is the dividend of the two-plane model (§0).

**What changes — and it's all *below* OpenCHAMI or *at the edges*:**

- **The substrate is built by StackHPC, in OpenStack, not by you in libvirt.**
  Your `virsh net-define` + `virt-install` steps (§§3–4) become OpenStack
  primitives: Neutron networks/subnets/ports and a Nova instance for the
  head — most likely expressed as Terraform/Heat/Kayobe rather than typed by
  hand. The head's cloud-init (§4) carries over almost verbatim, because
  OpenStack feeds cloud-init the same way (metadata service / config-drive) —
  which is precisely why we chose cloud-init in the lab.

- **Discovery goes dynamic.** The single most important shift. Our VMs have
  no BMCs, so we hand-wrote `nodes.yaml` and ran `ochami discover static`. On
  the PTR the servers have real **BMCs**, so you run **Magellan** to discover
  them over **Redfish** — SMD gets populated from the hardware itself. This
  brings new concerns the lab never touches: **BMC credentials management**,
  the management network reaching every BMC, and Redfish-based **power
  control** replacing `virsh destroy/start`.

- **The worker plane is real metal.** Diskless boot is identical in principle,
  but now failures are physical: firmware/UEFI settings per vendor, real NIC
  MACs (discovered, not invented), PXE/iPXE on real firmware, and the
  provisioning VLAN being a real switched network where **nothing but
  CoreDHCP may answer DHCP** — the same rule as our isolated bridge, with
  higher stakes.

- **Access is Keystone, not a Unix group.** The lab's "unprivileged user in
  the `libvirt` group" becomes OpenStack **roles/projects** and a
  `clouds.yaml`/`openrc`; see [Appendix C](appendix-c-access-models.md) for
  the mapping. OpenCHAMI's own JWT auth is unchanged.

**Genuine open decisions for the PTR (the choice points):**

1. **Where does the control plane live?** An OpenStack VM instance (easy,
   matches the lab) vs a dedicated bare-metal head (more like a production
   HPC head, no nesting). 
2. **How is the substrate defined?** StackHPC's Kayobe/Terraform tooling vs
   hand-built — affects reproducibility and who owns it.
3. **CPU architecture** of the compute nodes — sets the image build arch and
   the UEFI/console details (the aarch64-isms in this lab may or may not
   carry over).
4. **S3 backing store at scale** — local disk vs Ceph/RGW behind Versity.
5. **Control-plane HA** — single head (lab-style) vs highly-available.
6. **SELinux posture** — permissive for bring-up vs enforcing for production.
7. **Cert/PKI integration** — step-ca's internal CA standalone vs tied into
   site DNS/PKI.

None of these change *how you drive OpenCHAMI*; they shape the substrate it
runs on and the metal it provisions.

## The one-sentence version

Going upstream → lab we swapped a drifted x86 libvirt guide for a current,
cloud-init-based aarch64 Lima lab; going lab → PTR we swap the libvirt
substrate for a StackHPC OpenStack one and static discovery for dynamic
Redfish — **and the OpenCHAMI layer in the middle never changes.**

Related: [§13 — Summary](13-summary.md) · [Appendix B — mapping to upstream & automation](appendix-b-mapping.md) · [Appendix C — access models](appendix-c-access-models.md)
