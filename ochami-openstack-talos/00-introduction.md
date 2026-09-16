# §0 — Introduction: what we're building and why

*(Reading, no commands. ~15 minutes. Worth every one of them — the two decisions in this section are why the rest of the tutorial looks the way it does, and both are decisions you will have to re-make on the PTR.)*

## What OpenCHAMI is (in one paragraph)

**OpenCHAMI** (Open Composable Heterogeneous Adaptive Management Infrastructure) is an open-source toolkit for provisioning and booting HPC clusters, built as a set of small cooperating services rather than one monolithic cluster manager. A management ("head") node runs those services in containers; compute nodes have no OS installed at all — they network-boot a shared image at power-on and personalise themselves from a metadata server. It was founded by LANL, NERSC, CSCS, HPE and the University of Bristol, and is heading towards being an established Linux Foundation project. For the full background read [`../ochami-macos-libvirt/openchami-summary.md`](../ochami-macos-libvirt/openchami-summary.md).

## The Cast - OpenCHAMI Services

OpenCHAMI consists of a set of _services_ You'll meet these in §5:

| Service | Job | Analogy |
|---|---|---|
| **SMD** | inventory database: which nodes exist, their MACs, IPs, groups | the cluster's address book |
| **BSS** | hands each node its boot script (kernel, initrd, kernel args) | the concierge's key rack |
| **CoreSMD** (CoreDHCP + CoreDNS plugins) | DHCP leases and DNS names *derived from SMD*, plus TFTP for PXE | reception desk |
| **cloud-init Server** | per-node configuration served at boot | the welcome pack |
| **Magellan** | discovers real hardware by asking BMCs over Redfish | the census taker |
| step-ca, haproxy, postgres, OIDC (hydra/opaal) | certificates, API gateway, storage, auth tokens | back office |

The key design idea: **SMD is the single source of truth**, and everything else — DHCP, DNS, boot scripts, node config — is *derived from it on demand*. Add a node to SMD and the whole stack knows about it.

In this tutorial Magellan is the only one of those we don't use in the main flow, because our "nodes" are cloud instances with no BMCs. [Appendix A](appendix-a-redfish-sushy.md) fixes that by giving them fake ones, which is the closest we can get to the PTR without metal.

## The Stage - The two planes

Nodes in the cluster are split into two planes - The _Control Plane_ and the _Worker Plane_ (a.k.a _Data Plane_, _Compute Plane_):

- **Control plane / substrate** — the head node and the two networks, running the OpenCHAMI services. This is the layer that *does the provisioning*. Strictly, the *substrate* is the infrastructure the head sits on and the *control plane* is the OpenCHAMI software running on it; they stand up together, so we pair the terms. Here the substrate is **OpenStack** (§§3–4); in our libvirt lab it was a Lima VM; on the PTR it will be OpenStack again — in fact *this* OpenStack, since the PTR is TechWatch hardware added to the same StackHPC-operated cloud rather than a new one ([§1](01-safety-and-access.md)) — or bare metal.

- **Worker plane / bare metal** — the compute nodes: the layer that *gets provisioned* and runs the actual workloads. Here they're Nova instances (§7); on the PTR they're Dell and HPE servers.

The dividing line is **who provisions whom**. Something stands up the control plane (OpenStack here), then the control plane stands up the worker plane (always OpenCHAMI, exactly as you build in §§5–10).

⚠ **Do not confuse the two uses of "control plane".** From §10 onward there is a *second*, unrelated control plane: the **Kubernetes** control plane, running on the Talos node `tw-cp1`. OpenCHAMI's control plane provisions the machine; Kubernetes' control plane schedules containers on it. When it matters we say "OpenCHAMI control plane" or "Kubernetes control plane" in full.

## How a node boots (the chain we'll build)

```
power on → firmware network-boots                                    (§7)
        → DHCP: CoreDHCP looks the MAC up in SMD, leases its IP      (§5, §6)
        → the firmware / iPXE asks BSS for this node's boot script    (§9)
        → downloads Talos kernel + initramfs from the S3 store        (§8)
        → Talos boots into RAM, enters maintenance mode               (§10)
        → fetches its machine config from the `talos.config` URL      (§8, §9)
        → pulls its installer, writes itself to disk, reboots         (§10)
        → joins/forms a Kubernetes cluster                            (§10)
```

Steps 2 to 6 are *identical* to what happens on a real HPC cluster. Only step 1 — "power on and network-boot" — has to be faked on a cloud, and that is decision 2 below.

## Decision 1 — one instance per node, no nesting

There are two ways to model a cluster inside OpenStack, and the choice is forced for us.

**The nested way.** Give yourself a big OpenStack instance, install libvirt/KVM inside it, and run the head node and compute nodes as VMs *within* that instance. This is what our own libvirt lab does (with a Lima VM standing in for the OpenStack instance), and it is what HPE's [vTDS](https://github.com/Cray-HPE/vtds-core) does — the approach Stig Telfer (StackHPC) presented at the OpenCHAMI Developer Summit, with an OpenStack "blade" hosting a management VM plus several compute VMs. It has a real advantage: inside that instance you have full control of the virtual hardware, so PXE booting and Redfish emulation are easy.

It also requires **nested virtualisation** — a VM that can itself run hardware-accelerated VMs. And at Digital Labs, nested virtualisation is **switched off**. It was disabled across all hypervisors to mitigate a kernel vulnerability; the upstream patched kernel currently breaks the offloaded networking that BC5 depends on, so the mitigation stays. The decision was explicitly to apply it everywhere rather than carve out exceptions, which is the right call for a production service and leaves us with:

**The flat way — what this tutorial does.** Every node is its own Nova instance. The head node is an instance. Each compute node is an instance. There is no libvirt anywhere, and nothing needs `/dev/kvm` inside a guest.

```
    the nested way (vTDS)                    the flat way (this tutorial)
    — needs nested virt —                    — needs nothing special —

    ┌─ OpenStack instance ────────┐          ┌─ instance ─┐  ┌─ instance ─┐
    │  Ubuntu + libvirt/KVM       │          │  tw-head   │  │  tw-cp1    │
    │  ┌────────┐  ┌───────────┐  │          └────────────┘  └────────────┘
    │  │ mgmt   │  │ compute-1 │  │          ┌─ instance ─┐  ┌─ instance ─┐
    │  │ VM     │  │ VM        │  │          │  tw-w1     │  │  tw-w2     │
    │  └────────┘  └───────────┘  │          └────────────┘  └────────────┘
    └─────────────────────────────┘          all siblings on one Neutron wire
```

The flat model is also **closer to the PTR**, which is a nice accident: on real metal there is no nesting either — each node is a separate machine on a shared provisioning network. What we lose is control of the virtual firmware, and that loss is exactly decision 2.

🔀 **Deviation from our libvirt lab.** There, §§3–4 create libvirt networks and VMs with `virsh net-define` and `virt-install`. Here those become Neutron networks/ports and Nova instances. Everything from §5 onward — the entire OpenCHAMI layer — is unchanged, which is the whole reason the lab was worth doing.

## Decision 2 — "network boot" on a cloud means putting iPXE on the node's root disk

Here is the awkward truth at the centre of this tutorial: **OpenStack has no "boot from the network" button.** Nova boots an instance from an image or a volume. There is no equivalent of libvirt's `--boot network` or a server's "PXE first" firmware setting, and by default OpenStack will not ask the firmware to try the network at all.

📌 This was re-checked against Nova's source on 4 Aug 2026, not just its documentation: the class Nova renders a guest NIC from has no boot-order field, and the only boot devices it can name are `hd`, `cdrom` and `fd`. **The limitation is below the API**, so no microversion, image property or policy change reaches it. Three one-minute commands reproduce that finding — [DL-002.1a](DECISION-LOG.md#dl-0021a-verified-in-novas-source-not-only-in-its-documentation), with the full link index in [§7's references](appendix-f-network-boot-investigation.md#references).

**What we do about it, in one line:** `boot.ipxe.org` publishes `ipxe.usb`, a bootable *disk* image carrying a BIOS bootloader **and** `EFI/BOOT/BOOTX64.EFI`. Upload that to Glance and give it to each node as its **root disk**. The firmware boots a plain disk — the one thing Nova is always willing to boot — iPXE starts, and every step after that is unmodified OpenCHAMI. See [§7](07-node-instances-and-ipxe.md).

**And the obvious objection answers itself.** If iPXE is on the disk, won't the node network-boot for ever and reinstall itself on every power cycle? No: Talos installs to that same disk and overwrites the iPXE bootloader, so from the next boot the node boots Talos. Nothing has to remember which nodes are provisioned. That is the same self-terminating behaviour the libvirt lab gets from `--boot uefi,hd,network`, reached from the other direction.

| | Cost |
|---|---|
| Extra OpenStack resources | none — no Cinder volume, no second image, no boot-order API |
| Extra permissions | none — no rescue policy, no admin favour, no microversion |
| Firmware support needed | BIOS **or** UEFI, from the same 8 MB file |
| What you give up | the ability to network-boot one node *without* wiping its disk. Re-provisioning is `openstack server rebuild`, which is what OVB does too |

<details>
<summary>The five options we considered, and why the other four lost</summary>

| Option | Verdict |
|---|---|
| **iPXE as the node's root disk** | ✅ **what we use.** Found last, on 4 Aug 2026, and it is the simplest of the five |
| Hope the firmware PXEs anyway | ❌ **tested and failed here.** Digital Labs' OVMF has no network boot option at all: an empty-disk instance drops straight to the EFI Shell. Costs five minutes to check on another cloud |
| iPXE ISO as a permanent second boot device (`boot_index=1`, `device_type=cdrom`) | Sound — Nova's code path was traced — but needs a Cinder volume per node, and became unnecessary. Untested |
| **Nova rescue mode** (`server rescue --image <ipxe>`) | Works and is proven on this cloud, and was the plan until 4 Aug 2026. Far more machinery: microversion 2.87, `hw_rescue_bus` guessed per cloud, a rescued instance cannot be stopped, and disk ordering shifts. **Still required for [appendix A](appendix-a-redfish-sushy.md)** |
| Ironic | Wrong layer entirely — Ironic *is* a provisioning system, and we are testing a different one. Also not available to us as a tenant |

The tests that chose between them, with captured consoles, are in [**appendix F**](appendix-f-network-boot-investigation.md); the argument and the reversal triggers are in [`DECISION-LOG.md`](DECISION-LOG.md) DL-002; how the question came to be asked is in [`INVESTIGATION-network-boot.md`](INVESTIGATION-network-boot.md).

</details>

### Whichever mechanism you use, it is a stand-in for one Redfish call

This is the part that does *not* get thrown away, and it is why appendix A exists:

> **A BMC's "set boot device to PXE, then reset" is the operation we are imitating.** sushy-tools — OpenStack's own Redfish BMC emulator — implements exactly that on its Nova driver *by putting the instance into rescue mode with an iPXE image*. So rescue is not our invention, and it happens underneath any Redfish-driven workflow whether we chose it in the main path or not.

| What you want | This tutorial's command | Redfish equivalent ([appendix A](appendix-a-redfish-sushy.md)) | On the PTR |
|---|---|---|---|
| network-boot next | *nothing* — the node PXEs whenever its disk is not yet Talos | `BootSourceOverrideTarget = Pxe` then `Reset` | the same Redfish call, to a real BMC |
| re-provision from scratch | `openstack server rebuild --image tw-ipxe-disk tw-cp1` | `BootSourceOverrideTarget = Pxe` then `Reset` | the same Redfish call |
| boot from disk | *nothing* — Talos overwrote iPXE when it installed | `BootSourceOverrideTarget = Hdd` then `Reset` | the same Redfish call |
| power on / off / cycle | `openstack server start` / `stop` / `reboot` | `Reset` with `On`/`ForceOff`/`ForceRestart` | the same Redfish call |

⚠ **Two of those rows are empty, and that is the measure of the decision.** The mechanism we chose removes the two commands that used to be §7's and §10's whole reason for existing. The cost is that "network-boot this node without destroying it" is no longer expressible — which matters for a diagnostic netboot on real hardware, and not at all here.

Appendix A closes the loop by running sushy-tools against this very project, so Magellan can discover the nodes over Redfish and OpenCHAMI can power them — at which point the only remaining difference from the PTR is that the BMCs are emulated. **It needs tenant rescue to work**, so [appendix F's §7.5](appendix-f-network-boot-investigation.md#step-75--dry-run-the-pxe-button) stays worth running once if you intend to do it.

One consequence you will meet later, and the only one left of the three that rescue used to impose:

- **Talos must find its install disk by description, not by name** (§8 selects by size rather than hardcoding `/dev/vda`). Under rescue this was because adding boot media shifted the guest's disk ordering. Under the root-disk mechanism it matters for a sharper reason: installing to the wrong disk leaves iPXE bootable and the node reinstalls for ever.

## What else changes from the libvirt lab

Beyond the two decisions, the differences are mechanical:

| | libvirt lab | This tutorial |
|---|---|---|
| CPU architecture | aarch64 (Apple Silicon) | **x86_64** — the PTR is Intel Xeon and AMD EPYC |
| Serial console | `ttyAMA0,115200` | `ttyS0,115200` |
| Node MACs | invented, passed to `virt-install` | invented, pinned onto **Neutron ports** (§3) |
| Node IPs on the wire | CoreDHCP only | CoreDHCP only — but Neutron's own DHCP must be **switched off**, and its anti-spoofing rules disabled, or CoreDHCP's replies are silently dropped (§3) |
| Identity | Unix group + `LIBVIRT_DEFAULT_URI` | **Keystone** application credentials + `clouds.yaml` (§1) |
| Power control | `virsh start` / `destroy` | `openstack server start` / `stop`, or Redfish (appendix A) |
| Blast radius | your own laptop | **a shared production cloud** — hence §1 |

That last row is the one that changes how you work, not just what you type. The libvirt lab could be destroyed and rebuilt with no consequences to anyone. This cluster lives on hypervisors that also carry other people's jobs. §1 is about keeping those two facts apart, and it is the next thing you should read.

## Why Talos, and why Kubernetes at all

The PTR's job is **inference**, and the target stack (from the TechWatch design) is Kubernetes all the way down: a bare-metal Kubernetes control plane, device plugins for NVIDIA / AMD / Intel Gaudi accelerators, KServe and KubeRay operators, and vLLM as the engine. So the compute nodes need to run Kubernetes, and something has to install Kubernetes on them.

**Talos Linux** is an operating system that is *only* a Kubernetes node. No shell, no SSH, no package manager, no console login — you administer it entirely through an API with `talosctl`. That sounds austere until you notice it removes almost everything that makes cluster nodes drift apart from each other, which is the same instinct that makes HPC clusters boot diskless images. LANL were keen to test Talos with OpenCHAMI; Jake proposed it; it is what we use.

Talos is different from the libvirt lab's Rocky compute image in ways worth knowing up front:

| Lab's Rocky diskless image | Talos |
|---|---|
| built with OpenCHAMI `image-builder` into a SquashFS | prebuilt `vmlinuz` + `initramfs.xz`, downloaded — **no image build at all** |
| stateless, rebuilt in RAM every boot | **installs to disk** and boots from it thereafter |
| configured by cloud-init | configured by a declarative **machine config**, fetched via a kernel argument |
| console login, SSH, `dnf`, a shell | none of those. `talosctl` and `kubectl`, nothing else |
| needs nothing but the head node | **needs the internet** to pull its installer and Kubernetes images (§5.12 makes the head a NAT router) |

What stays the same is the OpenCHAMI plumbing: SMD is still the source of truth, and **BSS still hands each MAC a kernel, an initramfs and a kernel command line**. That is generic PXE, and Talos is a first-class PXE citizen.

## Where this is going

The end goal is not a demo. It is a rig you can plug hardware into, tweak, and measure: heterogeneous accelerators (RTX Pro 6000, MI210, Gaudi3), different inference engines, different schedulers. §§11–16 build the software half of that; §16 and [appendix B](appendix-b-lineage.md) say precisely what will have to change when the hardware half arrives.

Next: [§1 — Safety, access and reconnaissance](01-safety-and-access.md)
