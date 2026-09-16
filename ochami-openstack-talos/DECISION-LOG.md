# Decision log — OpenCHAMI on OpenStack with Talos

*(Reading and argument, no commands to run. This is the "why", kept separately from the "how".)*

The tutorial states its decisions in [§0](00-introduction.md) and argues the alternatives in [appendix C](appendix-c-alternatives.md). This log is different from both: it records decisions **that are still open, or that were taken under conditions we expect to change**, together with the evidence, the cost of reversing them, and the experiment that would settle them.

A decision belongs here if any of the following are true:

- it is provisional and something specific would change it;
- it is unpopular with someone on the project and the objection deserves recording rather than settling;
- it is a workaround for a property of the *substrate*, and will therefore evaporate when TechWatch hardware arrives.

| | Decision | Status | Revisit when |
|---|---|---|---|
| **DL-001** | Substrate shape: one instance per node ("flat"), not nested KVM | **Forced** — nested virt disabled cloud-wide | the Januscape mitigation is lifted |
| **DL-002** | ~~Nova rescue with an iPXE image~~ → **`ipxe.usb` as the node's root disk** (option G) | **Settled 10 Aug 2026 — the mechanism is confirmed end to end.** Option A failed; option **G passed first time**, reached BSS, and §10 then showed all three nodes install Talos over the iPXE image and boot from disk through firmware on a plain reboot. Rescue is demoted to appendix A's dependency | nothing outstanding. Reopen only if the PTR's firmware behaves differently from Nova's OVMF |
| **DL-003** | OpenCHAMI is the source of truth for node config, not Nova metadata | Held deliberately | only if the goal changes from "test OpenCHAMI" to "get inference running fast" |
| **DL-004** | How SMD gets populated on the PTR — static metadata, or Redfish discovery — and whose naming scheme the xnames follow | **Open — not ours to decide alone** | StackHPC's design for the PTR environment is shared |
| **DL-005** | Is 30 GB of node disk enough to reach the actual goal — a vLLM endpoint you can talk to? | **Open, but measurable now.** Probably yes with the 0.5 B model §14 already uses. No longer urgent: a **worker** can be re-flavoured after §§11–13 because those live in etcd, so take kubelet's `imagefs` readings and ask James with figures | §14 runs once and reports what the stack really consumes |
| **DL-006** | Live with installed nodes having **no serial console**, rather than building an Image Factory schematic to get one back | **Accepted for the POC, 7 Aug 2026.** Under systemd-boot the cmdline is baked into the UKI, so all three obvious fixes are no-ops. §16 needs a schematic anyway | at §16, where the fix costs nothing — or sooner, if a node installs and then can't be reached by `talosctl` |
| **DL-007** | Expose the KServe Gateway as a **NodePort**, rather than installing MetalLB or the OpenStack cloud-controller-manager | **Accepted for the POC, 15 Aug 2026.** The cluster has no `LoadBalancer` implementation at all; NodePort adds no component and the head node is already on the node network | anything but the head node needs to call the model endpoint, or a name in DNS has to point at it |

---

## DL-001 — Substrate shape: flat, not nested

**Decision.** Every node is its own Nova instance. No libvirt anywhere inside the cloud. ([§0, decision 1](00-introduction.md).)

**Why it is not a free choice.** The alternative — a big instance running libvirt/KVM, with the head node and compute nodes as VMs inside it — is what *both* prior art does:

- **HPE vTDS** (`vtds-core` + `vtds-application-openchami`), which Stig Telfer demonstrated on Digital Labs OpenStack at the OpenCHAMI Developer Summit: an OpenStack instance is a "blade", hosting one management VM and several compute VMs.
- **Tenks** (OpenStack's own): KVM plus VirtualBMC on a single host, made to look like IPMI-managed servers.
- **Our own libvirt lab** ([`../ochami-macos-libvirt-talos`](../ochami-macos-libvirt-talos/README.md)), where a Lima VM plays the part of the nesting host.

All three need **nested virtualisation**, which is switched off across the Digital Labs hypervisors to mitigate the Januscape kernel vulnerability. The upstream patched kernel currently breaks the DOCA OFED offloaded networking BC5 depends on, and the explicit decision was to apply the mitigation everywhere rather than carve out an exception for the prototyping hypervisor — "I do not see any advantages of excluding nodes just in case something is needed" — even though excluding one hypervisor was on the table and technically straightforward.

⚠ **This is a policy decision, not a technical one, and it is the single highest-leverage thing that could change.** If the prototyping hypervisor kept nested virt, the correct move would be to run **the existing libvirt-talos tutorial, unmodified, inside one Nova instance**. That tutorial is already written, already worked once, and — crucially — has none of the problems in DL-002, because inside your own libvirt you set `--boot uefi,hd,network` and the firmware does the right thing. The stated hope was that this is temporary: "I hope that this will be a short term issue, and the patched kernel will be available with network offload in the near future, so we can just patch all hypervisors and have nested virtualisation enabled."

**Cost of reversing:** low, and it gets *lower* the more of the flat tutorial we finish. §§5–19 — the entire OpenCHAMI, Talos, Kubernetes, Flux and inference stack — are substrate-independent. Only §§3, 4, 7 and 10 are OpenStack-shaped, and the nested design replaces them with the libvirt lab's §§3–4 that already exist.

**What the flat model buys, and it is not nothing.** It is *closer to the PTR*: on real metal there is no nesting either, each node is a separate machine on a shared provisioning wire, and the head node has to reach them over a real network rather than a host bridge. The nested model hides exactly the class of problem (§3's port security, Neutron DHCP, MAC pinning) that will reappear on hardware in a different form.

🔀 **A middle option nobody has costed: nested *without* KVM.** libvirt can run `<domain type='qemu'>` under pure TCG emulation with no `/dev/kvm` and no nested-virt requirement at all. That is fast enough to prove a *boot chain* — DHCP, TFTP, iPXE, BSS, kernel fetch — and far too slow to run Kubernetes, let alone vLLM. It is not a substitute, but it would let the provisioning half be developed on any hypervisor while the inference half runs on flat instances. Untested. Recorded because it is cheap to try and nobody has.

---

## DL-002 — How a node network-boots

This is the decision the log exists for.

### DL-002.1 The problem, stated precisely

**OpenStack cannot be told to put a NIC in a guest's boot order.** This is not a gap in our knowledge of the API; it is the documented state of Nova:

- Nova's own [*Boot an instance using PXE*](https://docs.openstack.org/nova/latest/user/boot-instance-using-PXE.html) documents exactly one mechanism: **rescue mode with an iPXE image**. Nothing about boot order, firmware settings, or diskless network boot.
- Asked directly on `openstack-discuss` in 2021 how to spawn an instance that PXE boots, Nova core reviewer Sean Mooney's answer was that although "the seabios image, depending on your host usually has pxe support built in", OpenStack does not enable network boot, and the iPXE ISO is "the most easy way". Native support would need "a neutron extension to mark ports as bootable which nova would read" — i.e. it does not exist.
- The blueprints that would have added it (`pxe-boot-instance`, `libvirt-empty-vm-boot-pxe`) were never delivered.
- **OVB** (`openstack-virtual-baremetal`), the canonical "use OpenStack instances as bare-metal deployment targets" project, needs either an out-of-tree **Nova patch** on the compute nodes or an `ipxe-boot` image that instances are **rebuilt to** before each deployment. It also documents that "without the Nova PXE boot patch, OVB is not compatible with any workflows that write to the root disk before deployment."

Underneath, the reason is mechanical. QEMU decides boot order from the `bootindex` property on each device; libvirt renders a guest's boot configuration into per-device `bootindex`; and **Nova only ever assigns a `bootindex` to storage** — root disk, extra block devices, CD-ROMs. Never to a network interface. QEMU's own documentation is blunt about the consequence: the `bootindex` property "is especially important for booting via the network", and if it is not specified "the network bootloader won't be considered and network boot will fail."

#### DL-002.1a Verified in Nova's source, not only in its documentation

*(Re-checked **4 Aug 2026** against Nova **master, 33.1.0.dev** — the "doubly confirm" pass, because everything above is documentation, mailing list and inference, and none of it is the code.)*

Three commands settle it. They need no cloud, no credentials and about a minute, and anyone can repeat them:

**Check 1 — a NIC has no field for a boot order.**

```
$ curl -fsSL https://opendev.org/openstack/nova/raw/branch/master/nova/virt/libvirt/config.py \
    | grep -n "boot_order"
1228:        self.boot_order = None
1386:        if self.boot_order:
1387:            dev.append(etree.Element("boot", order=self.boot_order))
1451:                self.boot_order = c.get('order')
```

Every hit is inside [`LibvirtConfigGuestDisk`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1183), which opens at line 1183. [`LibvirtConfigGuestInterface`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1884) — the class that renders `<interface>` — opens at line 1884, declares some 37 attributes, and `boot_order` is not among them. **The object Nova builds a NIC out of has no field for the libvirt element that would make the NIC bootable.**

**Check 2 — `network` is not a boot device Nova can name.** Nova's other route to a boot order is the `<os>` element, and it is fed from exactly one table:

```
$ curl -fsSL https://opendev.org/openstack/nova/raw/branch/master/nova/virt/libvirt/blockinfo.py \
    | grep -n "BOOT_DEV_FOR_TYPE ="
92:BOOT_DEV_FOR_TYPE = {'disk': 'hd', 'cdrom': 'cdrom', 'floppy': 'fd',
```

Three values, all storage. [`driver.py:7413`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py#L7413) sets `guest.os_boot_dev = blockinfo.get_boot_order(disk_info)`, and [`get_boot_order`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L733) draws its candidates only from block-device-mapping entries that carry a `boot_index`. There is no code path that puts `network` in that list.

**Check 3 — nothing is in flight.** A third blueprint exists beyond the two named above: [`boot-order-for-instance`](https://blueprints.launchpad.net/nova/+spec/boot-order-for-instance), which proposed precisely `nova boot --nic bootindex=N` and "allowing instances to boot from network sources without requiring traditional image/snapshot/volume resources". Registered October 2014, **Not started**, definition **New**, no series goal. Three dead blueprints across twelve years.

⚠ **Why this is worth more than the documentation was.** The failure is in **XML generation, below the API**. So no compute microversion, image property, flavor extra spec, policy change or admin favour can reach it — which is worth knowing *before* asking StackHPC whether something can be enabled for us. It also means the answer will not quietly change under us in a future release without a blueprint landing first.

🔀 **Why the libvirt lab does not have this problem.** `virt-install --boot uefi,hd,network` puts the NIC in the boot order explicitly. Disk first, network as fallback: on the empty first boot the firmware falls through to PXE; after Talos installs, the disk is bootable and wins, so the node does not re-PXE into a reinstall loop. That single flag is the entire thing we are working around, and there is no Nova equivalent of it.

### DL-002.2 The options

Six, including the two the tutorial currently mentions in passing. "Cost to test" assumes the cluster is otherwise at §7.

| | Mechanism | Controllable? | Needs | Cost to test | Confidence |
|---|---|---|---|---|---|
| **A** | Firmware PXEs unaided from an empty disk | no | nothing | **~5 min** | unknown — empirical |
| **B** | iPXE ISO as a **permanent second boot device** (`boot_index=1`, `device_type=cdrom`) | no | Cinder, instance rebuild | ~30 min | good — documented, **and the code path is now traced in master** (DL-002.2b) |
| **C** | Boot **from** the iPXE ISO as the root image | no (loops) | BSS per-node state | ~20 min | high — this is OVB's path |
| **D** | **Nova rescue** with an iPXE image ← *current choice* | **yes** | microversion 2.87, `hw_rescue_*` | done, works | proven on this cloud |
| **E** | Nested KVM (vTDS / Tenks / our libvirt lab) | yes, fully | nested virt (DL-001) | blocked | proven by others |
| **F** | Don't network-boot at all — Talos image + config-drive | n/a | nothing | ~30 min | high, but see DL-003 |

**A — hope the firmware does it.** §7.2 already tests this and calls it "the free probe". Two things make it worth taking more seriously than the tutorial currently does:

1. It gives **exact libvirt-lab parity**. If it works, OpenCHAMI's `coresmd` serves the iPXE binary over TFTP itself — it bundles x86 UEFI, ARM EFI and legacy x86 iPXE — so `tw-ipxe` in Glance, the `hw_rescue_bus` guesswork, the rescue state and both helper scripts all disappear. The boot chain becomes the same one the libvirt lab proved, byte for byte.
2. It is **much more likely under UEFI than BIOS**. With SeaBIOS and a boot order containing only the disk, an empty disk gets you `No bootable device` and a halt. OVMF is different: with no usable boot option it enumerates what it can see, which is why `Start PXE over IPv4` is such a familiar sight on UEFI guests whose disk is not bootable. It is *not guaranteed* — it depends on the OVMF build and how strictly QEMU's boot order is applied — but it is a five-minute question, and nobody has asked it yet with `hw_firmware_type=uefi` deliberately set on the blank image.

**B — a permanent iPXE CD-ROM, second in the boot order.** This is the closest thing Nova *can* be told to do to `--boot uefi,hd,network`, and it appears to have been overlooked. Nova's [block device mapping](https://docs.openstack.org/nova/latest/user/block-device-mapping.html) supports `boot_index` ("the order in which a hypervisor will try devices"), `device_type=cdrom`, and explicitly notes that "some hypervisors will support booting from multiple devices, but only if they are of different types - eg a disk and CD-ROM." So:

```
devbox$ openstack volume create --image ${TW_PREFIX}-ipxe --size 1 ${TW_PREFIX}-ipxe-cp1
devbox$ openstack server create ${TW_PREFIX}-cp1 \
    --image ${TW_PREFIX}-blank --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node1-prov \
    --block-device uuid=<ipxe-volume-id>,source_type=volume,destination_type=volume,device_type=cdrom,boot_index=1,delete_on_termination=false
```

Boot order becomes disk(0) → iPXE CD(1). Empty disk fails, iPXE runs, BSS answers, Talos installs; on the next boot the disk is bootable and wins. **No rescue, no reinstall loop, no BSS state, and — unlike A — it works under BIOS as well as UEFI, because both devices are genuinely in the firmware's boot order.**

Costs and unknowns, honestly:

- Nova forbids `source=image, destination=local` for anything but the root device, so the ISO has to become a **Cinder volume**. That is one 1 GB volume per node (a volume attaches to one instance; read-only multiattach is not worth the risk), so three volumes and some quota.
- Whether the libvirt driver honours `device_type=cdrom` on a volume BDM *on this cloud* is unverified. Nova's half of that is now traced in DL-002.2b; the deployment's half still is not.
- **Boot order is fixed at create time.** There is no `openstack server set --boot-order`. Adopting B means deleting and recreating the node instances, and it means you cannot flip a single node to network-boot on demand — which is the one thing D is good at.

**C — boot from the iPXE ISO as the root image.** Setting `disk_format=iso` on a Glance image makes Nova attach it read-only as a CD-ROM *and* give the instance a blank disk from the flavor — the documented ISO-installer behaviour. So the node PXEs on every power cycle, and after Talos installs it PXEs again and reinstalls, forever, unless BSS starts answering "boot from your own disk" (`sanboot`, or `exit` back to the firmware). §0 rejects this because it "makes 'is this node installed?' a piece of state BSS has to hold".

⚠ **That objection is weaker than it looks, and worth re-arguing.** Per-MAC mutable boot payloads are precisely what BSS *is*; `coresmd` already ships a `bootloop` plugin for corralling unknown nodes; and real HPC sites that install to local disk do exactly this flip. OVB's unpatched path is this option, with `server rebuild` as the "PXE button". The genuine cost is that a bug in the flip wipes a node, which is a bad failure mode to build in early.

**D — Nova rescue.** What the tutorial does now. Fully recorded in DL-002.4 below.

**E — nested.** See DL-001. Removes the entire problem class.

**F — skip network boot.** Upload a Talos OpenStack-platform image to Glance and boot it directly; Talos reads its machine config from the config-drive (`openstack/latest/user_data`). Or boot the Talos ISO, let it sit in maintenance mode, and `talosctl apply-config --insecure`. Both give a working Talos Kubernetes cluster on OpenStack in an afternoon, and neither involves OpenCHAMI at all — which is why it is DL-003 and not a real option here.

#### DL-002.2b Option B's code path, traced (4 Aug 2026)

The same verification pass that killed the NIC (DL-002.1a) *raised* B from "good, by documentation" to "traced end to end in master". Three links in the chain, all in [`blockinfo.py`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py):

| Step | Evidence in master | Line |
|---|---|---|
| A volume BDM's `device_type` becomes the device's type | `bdm_type = bdm.get('device_type') or dev_type` | [372](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L372) |
| `cdrom` is an accepted device type | `SUPPORTED_DEVICE_TYPES = ('disk', 'cdrom', 'floppy', 'lun')` | [106](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L106) |
| `cdrom` maps to a boot device Nova *can* name | `BOOT_DEV_FOR_TYPE = {'disk': 'hd', 'cdrom': 'cdrom', …}` | [92](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L92) |

So a blank root disk at `boot_index=0` plus an iPXE volume at `boot_index=1,device_type=cdrom` should reach libvirt as:

```xml
<os>
  <boot dev='hd'/>
  <boot dev='cdrom'/>
</os>
```

which is `--boot hd,cdrom` — **the same *shape* of instruction as the libvirt lab's `--boot uefi,hd,network`, one device short.** That is as close as Nova can be brought to the flag this whole decision is working around, and it is no longer an inference from prose.

⚠ **What is still unverified is the cloud, not Nova.** Three things can still fail on `techwatch-proto` specifically: Cinder refusing to produce a bootable volume from a 1 MB ISO; this deployment's `openstackclient` being too old to express `device_type`/`boot_index` (see §7.2b); and the firmware declining to fall through from a present-but-empty disk to the CD — the same OVMF/SeaBIOS behaviour question as option A, one layer down. Test 2 is now a test of *this deployment*, not of upstream.

#### DL-002.2d Option G — iPXE as the node's root disk, and Test 1's result

**Recorded 4 Aug 2026, immediately after experiment 1 was run.** Two things happened at once: option A died on this cloud, and a seventh option appeared that is simpler than every option above it.

**Experiment 1 (option A): FAIL, informatively.** A UEFI instance with `hw_firmware_type=uefi`, `hw_machine_type=q35` and a 1 MB blank root disk produced:

```
BdsDxe: failed to load Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0): Not Found
BdsDxe: loading  Boot0002 "EFI Internal Shell"
UEFI Interactive Shell v2.2 / EDK II / UEFI v2.70
Shell>
```

Three conclusions, in descending order of how much they matter:

1. **Option A is dead on `techwatch-proto`.** OVMF went from a failed `Boot0001` directly to `Boot0002`, the internal Shell — which sits *last* in the boot order. There was no network boot option between them, so this OVMF build has no PXE capability to fall through to. The expectation in DL-002.2 that "`Start PXE over IPv4` is such a familiar sight on UEFI guests" did not hold here.
2. **But boot-option fall-through works**: the firmware tried an option, found it unbootable, and moved to the next unaided. That is the *only* firmware behaviour options B and G require.
3. `tw-blank` behaves as designed — enumerated as `UEFI Misc Device` / `BLK0`, and not bootable.

**Option G — make iPXE the root disk.** `boot.ipxe.org` publishes `ipxe.usb` (8 MB) as well as `ipxe.iso`, and inspection of the artifact (4 Aug 2026) shows it is a **hybrid bootable disk image**: MBR + SYSLINUX + `ipxe.lkrn` for BIOS, plus a FAT16 partition labelled `iPXE` containing `/EFI/BOOT/BOOTX64.EFI` (and `BOOTIA32`, `BOOTAA64`, `BOOTARM`, two RISC-V variants) for UEFI. `\EFI\BOOT\BOOTX64.EFI` is UEFI's removable-media fallback path — precisely the path whose absence dropped the probe into the Shell.

| | Option C (rejected) | **Option G** |
|---|---|---|
| iPXE arrives as | a read-only **CD** (`disk_format=iso`) plus a separate blank disk | the **root disk itself** (`ipxe.usb`, `disk_format=raw`) |
| After Talos installs | the CD is still bootable → **re-provisions forever** unless BSS flips to `sanboot` | Talos **overwrote the iPXE bootloader**; the disk now boots Talos |
| "Is this node installed?" lives in | BSS | the node's own disk, as on real hardware |
| Needs | Cinder volume per node, extra BSS payload, a state transition | **nothing** — no Cinder, no `boot_index`, no `device_type`, no microversion, no rescue policy |
| The "PXE button" | `server rebuild` | `server rebuild` — same, and it is [OVB's](https://openstack-virtual-baremetal.readthedocs.io/en/latest/host-cloud/prepare.html) mechanism |
| Firmware support | UEFI + BIOS | UEFI + BIOS, from one artifact |

**The loop that killed C terminates by construction here, because the thing being installed destroys the installer's bootloader.** That is the same self-terminating property `--boot uefi,hd,network` has in the libvirt lab, arrived at from the other side — and it is why option C's objection does not transfer.

⚠ **The hazard is narrow and must be written down.** If Talos ever installs to a disk *other than* the one holding iPXE, option C's reinstall loop returns in full. One disk per node makes it impossible; the moment a Cinder volume is attached for container images, §8's `diskSelector` has to be checked against the root disk before anything is power-cycled.

✅ **Tested the same afternoon: option G works, first attempt.** See experiment 1c in DL-002.6 for the capture and the specifics. The FAT16-vs-ESP worry did not materialise; the `mtools` recipe in §7.2c stays as a fallback for stricter firmware. **This is now the decision**, subject to one confirmation in §10: that Talos's install genuinely displaces the iPXE bootloader so the node boots from disk on the next cycle.

Slotting into DL-002.2's table:

| | Mechanism | Controllable? | Needs | Cost to test | Confidence |
|---|---|---|---|---|---|
| **G** | **`ipxe.usb` as the node's root image** | no, but self-terminating | nothing | **~10 min** | good — artifact verified, firmware behaviour empirical |

#### DL-002.2e Downstream work this decision creates

Choosing G is cheap; *un-writing* rescue from the rest of the tutorial is not. Recorded here so it is visible rather than discovered section by section. As of 4 Aug 2026:

| Where | What it needs | State |
|---|---|---|
| [§7.3](07-node-instances-and-ipxe.md#step-73--create-the-node-instances) | the node instances themselves, created from `tw-ipxe-disk` — §7's actual deliverable. Under G `server create` *is* the PXE button, so creating them boots them | **done — built and booted to BSS, 4 Aug 2026** |
| [§10](10-boot-the-cluster.md) | was written end to end around rescue: `pxeboot.sh` / `diskboot.sh`, a seven-step sequence whose steps 1 and 7 are `rescue`/`unrescue`, and the ⚠ about Talos rebooting *while still rescued*. All of it **got simpler** — the install-time reboot lands on Talos because Talos overwrote the bootloader, so the timing hazard and "never leave a node rescued" both disappeared. Rewritten to six steps with no rescue | **done — executed end to end 7–10 Aug 2026.** Three nodes installed and joined; §10.7's plain reboot confirmed the node boots from disk through firmware, which was the last part of G taken on trust |
| [§8](08-talos-assets-and-config.md) | `diskSelector` mattered before because rescue media renumbered the disks; under G it matters for a different and sharper reason — installing to the wrong disk leaves iPXE bootable and reinstalls forever | **review** |
| [§18](18-teardown.md) | image cleanup named `tw-ipxe` explicitly; now enumerates by prefix so it cannot miss `tw-ipxe-disk` | **done** |
| `templates/` | `pxeboot.sh` and `diskboot.sh` wrap rescue. G's equivalent is `server rebuild --image tw-ipxe-disk`, which is destructive, so it wants a different name and a confirmation prompt | **pending** |
| [`diagrams/07-boot-chain.svg`](diagrams/07-boot-chain.svg) | a fourth amber entry, and no exit step for it | **pending — alt text carries the correction** |
| `../ochami-openstack-talos-iac/` | the node-instance module assumes rescue | **pending** |
| [Appendix A](appendix-a-redfish-sushy.md), [appendix D](appendix-d-smoke-test.md) | unchanged in substance — both still need rescue to work, so experiment 3 (§7.5) stays worth running once | **review** |

⚠ **Rescue does not get deleted, and that is the point of DL-002.3.** It stops being the main path; it stays documented because sushy-tools implements Redfish PXE with it, so anything Redfish-driven does rescue underneath whether we chose it or not.

#### DL-002.2c One supported knob nobody had noticed: `hw_boot_menu`

Found in the same pass, and it changes nothing about the decision while being genuinely useful:

```
$ curl -fsSL https://opendev.org/openstack/nova/raw/branch/master/nova/virt/libvirt/driver.py \
    | grep -n "boot_menu"
7381:            if image_meta.properties.get('hw_boot_menu') is None:
7382:                guest.os_bootmenu = strutils.bool_from_string(
7383:                    flavor.extra_specs.get('hw:boot_menu', 'no'))
7385:                guest.os_bootmenu = image_meta.properties.hw_boot_menu
```

`os_bootmenu` renders `<bootmenu enable='yes'/>` ([`config.py:3250`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L3250)), so the image property [`hw_boot_menu`](https://docs.openstack.org/glance/latest/admin/useful-image-properties.html) — flavor equivalent `hw:boot_menu` — gives the guest an **interactive firmware boot menu** at the console.

**It is not a seventh option.** It needs a human at a noVNC console on every single boot, so it can never be §10's "PXE button", and it cannot be scripted or driven over Redfish. What it *is*, is a 60-second diagnostic that splits a failure the tutorial currently cannot split:

| Boot menu shows | Meaning |
|---|---|
| a network / PXE / `UEFI PXEv4` entry | the NIC **has** a boot ROM and the firmware **can** see it — options A and B failed on *ordering*, and manual selection proves the rest of the chain works |
| no network entry at all | the guest NIC has no boot ROM in this deployment — A and B are dead here for a different reason, and rescue (D) is the only path |

Recorded because that distinction decides whether it is worth arguing with the cloud operator or not. Used in [§7.2](appendix-f-network-boot-investigation.md#step-72--test-1-does-an-instance-network-boot-on-its-own) as the diagnostic after Test 1 fails.

### DL-002.3 What is actually being objected to

The concern raised on this project is that rescue mode is a hack, and that a hack at the centre of the tutorial is a bad thing to teach and a bad thing to carry. That is right, and it should not be argued away. But it is worth separating two claims:

| Claim | Assessment |
|---|---|
| "Rescue mode is a cloud-specific detour that we will throw away" | **Half true.** The *mechanism* is thrown away. The *operation* is not: "select boot device, then reset" is what you do to real hardware for the rest of the machine's life |
| "It is our invention" | **False.** sushy-tools — OpenStack's own Redfish BMC emulator, used across OpenStack CI — implements `BootSourceOverrideTarget=Pxe` on the Nova driver by putting the instance into rescue mode with an iPXE image (`SUSHY_EMULATOR_OS_RESCUE_PXE_BOOT`), and implements Redfish virtual media the same way (`SUSHY_EMULATOR_OS_VMEDIA_USE_RESCUE`). If we ever drive these nodes over Redfish, rescue is what happens underneath whether we chose it or not |
| "It adds failure modes" | **True, and this is the real cost.** `hw_rescue_bus` has to be guessed per cloud; a rescued instance cannot be stopped, paused or suspended; the disk order shifts, which is why §8 selects Talos's install disk by size; and it needs compute API microversion 2.87 |
| "It makes the tutorial harder to follow" | **True.** §7 is the longest section with no upstream equivalent, and a reader has to understand rescue semantics before understanding anything about OpenCHAMI |
| "It might not be a problem on TechWatch hardware" | **Certain, not just likely.** See DL-002.5 |

The honest summary: rescue is the *most controllable* option and the *least simple* one, and controllability is worth less than §0 implies — because **the libvirt lab we are trying to reproduce does not have it either.** `--boot uefi,hd,network` gives no control over when a node PXEs. If parity with the libvirt lab is the goal, options A and B are parity and D is over-delivery.

### DL-002.4 The rescue method, recorded in full

Recorded here so that it can be demoted or deleted from the main path without the knowledge being lost.

**Setup.** iPXE's prebuilt `ipxe.iso` boots under both BIOS and UEFI, so one artifact suffices:

```
devbox$ curl -fLO https://boot.ipxe.org/ipxe.iso
devbox$ openstack image create ${TW_PREFIX}-ipxe \
    --disk-format iso --container-format bare \
    --file ipxe.iso --private \
    --property hw_rescue_device=cdrom \
    --property hw_rescue_bus=scsi \
    --property hw_firmware_type=${TW_FIRMWARE}
```

**Network-boot a node** (the "PXE button"):

```
devbox$ openstack --os-compute-api-version 2.87 server rescue \
    --image ${TW_PREFIX}-ipxe ${TW_PREFIX}-cp1
devbox$ openstack server show ${TW_PREFIX}-cp1 -c status -f value    # RESCUE
```

**Return it to its own disk:**

```
devbox$ openstack server unrescue ${TW_PREFIX}-cp1                  # → ACTIVE
```

**Why microversion 2.87 and the two image properties.** Two rescue modes exist. *Legacy* rescue renumbers the guest's disks — the rescue image becomes the first disk — and cannot rescue a volume-backed instance at all. *Stable device* rescue keeps every disk attached in its original order and adds the rescue media alongside; it requires API microversion 2.87 and is switched on by `hw_rescue_device`/`hw_rescue_bus` on the rescue image. Talos has to find and write to the node's *own* disk while booted from rescue media, so disk ordering is load-bearing.

**`hw_rescue_bus` is the value that needs fiddling per cloud.** Nova accepts `scsi`, `virtio`, `ide`, `usb`; which work depends on the machine type. On `q35` there is **no IDE bus at all**, so `ide` — which Nova's docs offer as a fallback — fails there. Order to try: `scsi`, then `usb`, then `ide` (only on `pc`), then `virtio` paired with `hw_rescue_device=disk` and iPXE's `ipxe.usb` rather than the ISO.

**Constraints that leak into other sections:**

| Constraint | Where it surfaces |
|---|---|
| A rescued instance cannot be stopped, paused or suspended | §10's power sequences always `unrescue` before `stop`. sushy-tools does this internally too |
| Rescue media shifts what the guest sees as disk 0 | §8 selects Talos's install disk **by size**, never `/dev/vda` |
| Volume-backed instances need stable-device rescue | rules out legacy rescue if we ever move nodes to Cinder roots |
| Rescue may be disabled for tenants on some clouds | it is not on Digital Labs; it would be the reason to fall back to option C |

**Verified working on `techwatch-proto`** as of the current run: `hw_rescue_bus=scsi`, `hw_firmware_type` as found on the Rocky image, stable-device rescue at microversion 2.87.

### DL-002.5 What happens to all of this on real hardware

The whole of DL-002 is a property of the substrate, and it does not survive contact with the PTR. A Dell or HPE server has a BMC; you set the boot order once in firmware, or you set `BootSourceOverrideTarget` over Redfish, and the question never arises again.

| What you want | Flat OpenStack (D) | Redfish, via sushy-tools ([appendix A](appendix-a-redfish-sushy.md)) | TechWatch metal |
|---|---|---|---|
| network-boot next | `server rescue --image tw-ipxe` | `BootSourceOverrideTarget=Pxe` + `Reset` | the same Redfish call, to a real BMC |
| boot from disk | `server unrescue` | `BootSourceOverrideTarget=Hdd` + `Reset` | the same Redfish call |
| power on/off/cycle | `server start`/`stop`/`reboot` | `Reset` `On`/`ForceOff`/`ForceRestart` | the same Redfish call |

So the cost of getting this "wrong" is bounded: it is confined to §§7 and 10 plus one Glance image, and it is the one part of the tutorial guaranteed to be replaced. That is an argument for **choosing the simplest option that works, not the most faithful one** — the fidelity we are buying is fidelity to something we will not be using.

### DL-002.6 The experiments that would settle this

In order. Stop at the first that succeeds; each is independent of the rest of the cluster.

**0. Re-confirm upstream, with no cloud at all. (~1 minute, done 4 Aug 2026)**

The three `curl | grep` checks in DL-002.1a, plus the two in DL-002.2b and DL-002.2c. They need no credentials and no quota, they are the only checks here that test *Nova* rather than *this deployment*, and they are worth repeating on any future OpenStack release before anyone re-litigates this decision. Result on master (33.1.0.dev): **no NIC boot order, no `network` boot device, no blueprint in flight; option B's path intact.**

**1. Does a UEFI instance with an empty disk PXE on its own? (~5 minutes)**

```
devbox$ openstack image set ${TW_PREFIX}-blank \
    --property hw_firmware_type=uefi --property hw_machine_type=q35
devbox$ openstack server create ${TW_PREFIX}-probe \
    --image ${TW_PREFIX}-blank --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node5-prov --wait
devbox$ sleep 30 && openstack console log show ${TW_PREFIX}-probe --lines 80
devbox$ openstack server delete ${TW_PREFIX}-probe --wait
```

Looking for `Start PXE over IPv4`, `PXE`, `iPXE`, or DHCP attempts. `No bootable device`, a UEFI Shell prompt, or a boot-manager menu means no. **Worth repeating with `hw_firmware_type=bios` for completeness** — if BIOS guests PXE here, that is a surprise worth knowing about.

⚠ Run this *before* §5 exists if you like: the probe only needs the port and the flavor. Without CoreDHCP running you will see the DHCP attempt time out, which still answers the question. With §5 up you get the stronger result — a `172.16.0.x` lease from SMD.

**1b. If experiment 1 fails: can the firmware see the NIC at all? (~1 minute, and it decides who you argue with)**

Per DL-002.2c, turn on the interactive boot menu and look at a graphical console:

```
devbox$ openstack image set ${TW_PREFIX}-blank --property hw_boot_menu=true
devbox$ openstack server reboot --hard ${TW_PREFIX}-probe
devbox$ openstack console url show ${TW_PREFIX}-probe     # open in a browser, press Esc/F12
```

A network or `UEFI PXEv4` entry in the menu means the boot ROM is present and only the *ordering* is against us — so options A and B failed for a reason that a cloud-side change (firmware build, machine type) could plausibly fix, and manually selecting it proves §§5–9 end to end without any of §7's apparatus. No network entry means the NIC has no boot ROM here, and rescue is the only path. Unset the property afterwards; it must not be left on the image the node instances use.

**1c. Does `ipxe.usb` boot as the node's root disk? (~10 minutes — do this before experiment 2)**

Option G, per DL-002.2d. `curl -fLO https://boot.ipxe.org/ipxe.usb`, upload it as a `raw` private image with `hw_firmware_type` set, boot one probe on `tw-node5-prov` from it, and read the console. `iPXE 1.x.x+ …` followed by a `172.16.0.5` lease is a pass and ends the search. Full commands in [§7.2c](appendix-f-network-boot-investigation.md#step-72c--test-4-ipxe-as-the-nodes-own-root-disk).

**Status: PASSED, 4 Aug 2026, first attempt.** `iPXE 2.0.0+` booted from the root disk, `net0: 52:54:00:be:ef:05` took the lease `172.16.0.5` from CoreDHCP, and `http://172.16.0.254:8081/boot/v1/bootscript?mac=…` returned a 127-byte script. Full capture in [§7.2c](appendix-f-network-boot-investigation.md#-the-result-on-techwatch-proto-4-aug-2026--test-4-passed). **Experiment 2 was therefore never run** — no Cinder volume was ever created — and experiment 3 (rescue) is now needed only for [appendix A](appendix-a-redfish-sushy.md).

Notable specifics for anyone reproducing it:

- OVMF accepted `\EFI\BOOT\BOOTX64.EFI` from the stock artifact's **FAT16 partition typed `0x04`** (`FS0: … HD(4,MBR,0x00000000,0x20,0x3FE0)`). The ESP-rebuild fallback was not needed.
- The one remaining failure was BSS's no-boot-params fallback script chaining to **`https:///apis/bss/…` with an empty hostname** — iPXE `0x3e11618e`, "DNS name does not exist". §9 supersedes that script, so it blocks nothing, but the fallback cannot retry as configured. Filed for `issues/`.
- `OS-EXT-SRV-ATTR:host` printed `None` again, as [§4](04-head-node-instance.md) predicts. Use `hostId` equality against `tw-head` instead.

**2. Does the cloud accept an iPXE CD-ROM as a second boot device? (~30 minutes)**

Build one node with option B's `--block-device` line, boot it, and read the console. Three outcomes: the firmware falls through disk → CD and iPXE runs (adopt B); the instance builds but ignores the CD-ROM (the libvirt driver is not honouring `device_type`); or the create is rejected (Nova or the cloud disallows it — record the exact error).

**3. If both fail, keep D — but demote it.** Move §7's rescue apparatus behind a short "how your cloud network-boots" decision point, with A, B and D as three documented paths, and let the reader pick based on what the probe said. That is a smaller edit than it sounds: §§8–19 do not care.

**4. Independently: ask about nested virt.** DL-001 is worth one message to `jcwomack` — not to reopen a settled mitigation, but to establish whether the *patched-kernel* timeline is close enough to plan around. If nested virt returns this quarter, the libvirt-talos tutorial runs inside one instance and DL-002 becomes a footnote.

### DL-002.7 Provisional recommendation

1. **Run experiment 1 today.** It is five minutes and it may delete an entire section of the tutorial.
2. **If it fails, run experiment 2.** Option B is the mechanism that most deserves a try and has had none; it is the only one that reproduces `--boot uefi,hd,network` semantics deterministically on any firmware.
3. **Keep D documented either way** — not as a compromise, but because sushy-tools uses it, so appendix A depends on it existing regardless of what the main path does.
4. **Do not adopt C** unless rescue turns out to be forbidden for tenants. Its failure mode is a wiped node.
5. **Treat the answer as disposable.** Per DL-002.5, this decision has an expiry date stamped on it: the arrival of hardware with real BMCs.

---

## DL-003 — OpenCHAMI, not Nova, configures the nodes

**Decision.** The node instances get no SSH key, no user-data, no floating IP and no config-drive-delivered machine config. Talos's configuration arrives via the `talos.config` kernel argument, which BSS supplies. ([§7.3](07-node-instances-and-ipxe.md).)

**The alternative is genuinely tempting and should be named.** Talos publishes an OpenStack platform image; upload it to Glance, pass the machine config as Nova `user_data`, and Talos reads it from the config-drive at `openstack/latest/user_data`. Or boot the Talos ISO and `talosctl apply-config --insecure` to a node sitting in maintenance mode. Either gets a Talos Kubernetes cluster on OpenStack in an afternoon, with no PXE, no BSS, no CoreDHCP, no MAC pinning, no port-security surgery — and therefore none of DL-002.

**Why we don't.** If Nova's metadata service configures the node, OpenCHAMI stops being the source of truth and the exercise proves nothing about OpenCHAMI. The point of step −1 is to rehearse the provisioning chain that will run on TechWatch hardware, and that chain is MAC → SMD → BSS → kernel arguments.

⚠ **But note the split it makes available, because it is a real risk-reduction option.** The project has two goals that are only loosely coupled: *prove the OpenCHAMI provisioning chain* (§§5–10) and *prove the inference stack* (§§11–16). Option F satisfies the second without the first. If the inference work becomes urgent — an MVP demo, a blog post, a funder deadline — building §§11–16 on a Nova-booted Talos cluster while §§5–10 are still being debugged is a legitimate parallelisation, not a cop-out. It should be a conscious decision with a note in the run log, not something that happens by accident because PXE was annoying.

---

## DL-004 — How SMD gets populated on the PTR, and under whose naming scheme

**Status: open, and only partly ours to settle.** Recorded on **4 Aug 2026** so that the assumptions baked into [§6](06-node-inventory.md) are visible rather than implied.

**What §6 assumes.** Static discovery: a hand-written `nodes.yaml`, loaded with `ochami discover static`, with invented xnames of the shape `x1000c0s0b0n0` and MACs we pinned ourselves in §3.4. §6 presents this as a *deviation* from normal OpenCHAMI practice, and [appendix A](appendix-a-redfish-sushy.md) exists to close the gap by emulating BMCs so Magellan can do real Redfish discovery.

**The standard model, which stays documented either way.** On a normal OpenCHAMI cluster, Magellan sweeps the management network, talks Redfish to each BMC, and SMD is populated from the hardware's own answers. This is how OpenCHAMI is designed to be used, it is what the upstream documentation and most write-ups describe, and a reader needs it to make sense of why SMD is shaped the way it is. **Nothing here removes that explanation** — see §6's concepts section and appendix A.

**What has changed.** The current working expectation is that the PTR will **probably not use Redfish**, and that SMD will instead be fed from **statically configured metadata** — a maintained or generated file, much like §6's. If that is what happens:

- §6's "deviation" is not a deviation at all; it is a rehearsal, and a closer one than appendix A.
- Appendix A becomes valuable for *understanding* Redfish and OpenCHAMI's power-control path, not as preparation for a thing we will do.
- The [three-way contract](diagrams/06-three-way-contract.svg) gets *more* important, not less: static metadata is exactly the situation where nothing validates the copies, and the companion IaC generating all three from one `nodes.yaml` goes from a nicety to the main defence.

⚠ **This is an expectation, not a decision, and it may not hold.** It should not be hardened into the tutorial — both paths stay documented until someone confirms which one the PTR runs. The cost of being wrong in either direction is low (each path is already written), which is precisely why we keep both rather than betting.

**Naming conventions are a separate unknown, and the reason is structural.** **StackHPC operate the OpenStack deployment** — this one, and the PTR, which is the same estate with TechWatch hardware added rather than a new cluster. That estate also carries BC5, Ceph disk arrays and other services ([§1](01-safety-and-access.md)). So the PTR environment is *built and named by people who are not us*, to suit a system whose other tenants matter more than we do, and their design — how nodes are identified, whether xnames are used at all, what the components are called — has not been shared with us. So:

- Every xname, hostname and group name in this tutorial (`x1000c0s0b0n0`, `tw-cp1`, `talos-controlplane`) is **ours, and provisional**. They were chosen to be the right *shape*, not to predict anything.
- Do not build tooling that assumes the `x1000c0s0…` prefix means something. The [companion IaC](../ochami-openstack-talos-iac/) should keep the naming scheme in one place, as data, for exactly this reason.
- 🔀 This is the same shape of unknown as DL-001: a property of a substrate somebody else controls, which will resolve when their design lands rather than through anything we can test.

**What would settle it.** StackHPC's design documentation for the PTR environment, or a direct answer to two questions: *will Magellan/Redfish discovery be used against the PTR BMCs, or will SMD be populated statically?* and *what identifies a node?* Until then, treat §6's values as placeholders of the correct format.

⚠ **Ask early rather than late.** Both questions are cheap to answer for whoever knows and expensive to guess wrong at, and they are the sort of thing that gets settled implicitly by whatever the first person builds. The [companion IaC](../ochami-openstack-talos-iac/) is where a wrong guess would be most expensive, because a naming scheme spreads through generated Neutron ports, SMD records and BSS payloads at once — which is the [three-way contract](diagrams/06-three-way-contract.svg) again, one level up.

---

## DL-005 — Is 30 GB of node disk enough for the inference goal?

**Status: open, and it is a question for the project rather than a decision for the tutorial.** Recorded **4 Aug 2026**, at [§7's pre-flight](07-node-instances-and-ipxe.md), because that is where the number first becomes visible and it would otherwise be discovered at §14 with a built cluster in the way.

**Why it matters more than a quota line.** The end goal of step −1 is not "a Kubernetes cluster" — it is **a working vLLM inference endpoint, ideally something you can talk to like a chatbot**. Everything in §§0–13 is scaffolding for that. So "can a node hold the thing that serves tokens?" is the question the whole exercise turns on, and it is worth asking out loud rather than assuming.

**What is measured.**

| | Value | Source |
|---|---|---|
| `techwatch-proto-cp` disk | **30 GB** | `openstack flavor show`, 4 Aug 2026 |
| `techwatch-proto-worker` disk | **30 GB** | same |
| TechWatch design allowance | 50 GB for Talos + Kubernetes, 50–100 GB for images and weights | the design slides |
| What §14 actually serves | `Qwen/Qwen2.5-0.5B-Instruct`, **~1 GB of weights** | [§14](14-vllm-inference.md) |

**The current expectation: 30 GB is probably fine, and the weights are not the problem.** A rough accounting for a worker — Talos ~2 GB, containerd plus kubelet and CNI images a few GB, the **vLLM CPU image** (the big one, and the number nobody has measured yet), KServe's storage initialiser, and ~1 GB of weights. That should land comfortably inside 30 GB. The risk is not running out of disk; it is **kubelet's image-filesystem eviction threshold**, which fires at 15% free by default and will start garbage-collecting images — or evicting the pod — before the disk is anywhere near full.

**What to ask James.** Two questions, and the second only matters if the answer to the first is "not much":

1. **Is there headroom to give this project a worker flavor with a bigger disk** — say 60–80 GB — or is 30 GB what the quota supports? There is a [runbook for creating project flavors](runbooks/create-project-flavors.md), so the mechanism exists; this is about whether the space does.
2. **If not, is the smallest-model chatbot the agreed target?** It is a perfectly good one: a 0.5 B model answering `/v1/chat/completions` through KServe proves the entire chain end to end, and §14 is already written against exactly that. Swapping to Gemma-2B or Llama-3-8B later is a model name and a Hugging Face token (§12.4's SOPS work), not a re-architecture — but it does need the disk.

📌 **Measure before asking — the deadline this entry originally claimed does not exist.** It said to ask before §11, on the grounds that a flavor change means deleting and recreating the nodes. Root disk size *is* fixed at create time (DL-002), but the conclusion was wrong: everything §§11–13 install lives in **etcd**, not on a worker's disk. A worker can be drained, rebuilt with a new flavor and rejoined afterwards, and §10.7 established that rebuild is a routine ten-minute operation. The expensive node to recreate is the control-plane, which holds etcd — and it is not the one caching model weights.

So the order is: **get the numbers off the running cluster, then ask James a question with figures in it.** Baseline, on the head:

```
head$ kubectl get nodes -o custom-columns=\
'NODE:.metadata.name,CAPACITY:.status.capacity.ephemeral-storage,ALLOCATABLE:.status.allocatable.ephemeral-storage'

head$ kubectl get --raw "/api/v1/nodes/nid0002/proxy/stats/summary" \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)["node"]
for k,v in (("nodefs",d["fs"]),("imagefs",d["runtime"]["imageFs"])):
    print(f"{k:8} {v[\"usedBytes\"]/2**30:6.2f} GiB used, {v[\"availableBytes\"]/2**30:6.2f} GiB free of {v[\"capacityBytes\"]/2**30:6.2f} GiB")'
```

`imagefs` is the figure that decides this: it is what kubelet garbage-collects and evicts against. Take the reading **now**, once more after §13 (KServe and its storage initialiser), and again after §14 — the delta across those three is the real answer, and it is a number rather than an opinion.

**Options, if 30 GB turns out to be tight.** In increasing order of disruption:

| Option | Cost | Note |
|---|---|---|
| Keep the 0.5 B model | none | already what §14 does. **The default, and it satisfies the goal** |
| Prune aggressively — one model version per node, `imagePullPolicy: IfNotPresent` | none | worth doing regardless |
| Attach a Cinder volume per worker and move containerd's image store to it | quota, and a Talos patch | the volume must **not** become Talos's install target — see DL-002's hazard |
| A larger worker flavor, then recreate the nodes | an ask, and a rebuild of §7 | cleanest if the answer to question 1 is yes |

**What would settle it.** A measured number: after §14 runs once, `talosctl -n <worker> df` (or the kubelet's `imagefs` figures) says exactly how much of the 30 GB the real stack consumes. **Record that in this entry when you have it** — it converts this from a question into a fact, and it is the number the IaC and any future flavor request should be built on.

---

## DL-006 — Installed nodes have no serial console

**Status: accepted for the POC, revisit at §16. Observed on `tw-cp1`, 7 Aug 2026.**

**The observation.** `openstack console log show` works perfectly through the network boot — iPXE, DHCP, BSS, the kernel fetch, the install — and then stops for ever at `kexec_core: Starting new kernel`. The node is healthy; `talosctl version` answers. The window is simply gone.

**Why.** §9 puts `console=ttyS0,115200` on the command line **BSS serves**, which governs the boot Talos performs *from the network*. The installed system boots a UKI whose command line is embedded at image-build time — `talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on …` — and nothing from BSS carries over. Since Talos 1.10, UEFI installs use **systemd-boot**, and there the cmdline is not computed on the host at all.

**Three fixes that do not work**, all tried:

| Attempt | Result |
|---|---|
| `machine.install.extraKernelArgs: [console=ttyS0,115200]` | **ignored** under systemd-boot — [Sidero's bootloader page](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/bare-metal-platforms/bootloader) states it outright, and [talos#10339](https://github.com/siderolabs/talos/issues/10339) exists to document and warn about exactly this no-op |
| the same, alongside `gen config`'s default `grubUseUKICmdline: true` | rejected by `talosctl validate`: *"install.extraKernelArgs and install.grubUseUKICmdline can't be used together"*. The flag is GRUB-only ([talos#12019](https://github.com/siderolabs/talos/issues/12019)) |
| `grubUseUKICmdline: false` | irrelevant — the node is not running GRUB. `GRUB: BOOT partition not found` is in the install log |

**What would work.** An [Image Factory](https://docs.siderolabs.com/talos/v1.13/learn-more/image-factory) schematic with `customization.extraKernelArgs: [console=ttyS0,115200]`, used as `machine.install.image` so the installed UKI carries it. §8.4 already documents where Factory fits and gives the URL shapes.

**Decision: don't, yet.** Three reasons.

1. **The loss is narrow.** Every failure mode in §§7–10 happens during the *network* boot, where the console still works. What goes dark is an installed node — and an installed node is one `talosctl` reaches.
2. **It buys an external dependency for the node.** The node would pull its installer from `factory.talos.dev` through the head's NAT rather than from `ghcr.io`. Not a large change, but it is one more thing between a node and a successful install.
3. **§16 needs a schematic anyway**, for accelerator drivers. Adding the console argument to *that* schematic is free. Doing it twice is not.

**Revisit if:** a node installs and then fails to reach `talosctl`, and you find yourself with no way to see why — which is the one scenario this decision is trading away. Or at §16, where the cost drops to zero.

---

## DL-007 — The model endpoint is a NodePort, not a load balancer

**Status: accepted for the POC, 15 Aug 2026. Observed on `tw-head`, §13.3.**

**The constraint.** This cluster has no way to satisfy a `Service` of type `LoadBalancer`. There is no OpenStack cloud-controller-manager and no MetalLB, so such a Service sits at `EXTERNAL-IP <pending>` indefinitely. Nothing needed one until §13, because §§11–12 install controllers rather than anything externally reachable.

Envoy Gateway [defaults its proxy Service to `LoadBalancer`](https://github.com/envoyproxy/gateway/blob/v1.2.4/api/v1alpha1/shared_types.go#L271), so left alone the first `Gateway` produces a healthy Envoy pod with **no address** — and `InferenceService` URLs that point nowhere.

**The three options, and why NodePort.**

| Option | What it costs | What it gives |
|---|---|---|
| **NodePort** *(chosen)* | an arbitrary port in `30000–32767`, which changes if the Service is recreated | nothing to install. Envoy Gateway [puts the node IPs in `status.addresses`](https://github.com/envoyproxy/gateway/blob/v1.2.4/internal/gatewayapi/status/gateway.go#L74-L76), and the head node is already on `172.16.0.0/24` |
| **MetalLB** in L2 mode | another controller, an address pool carved out of `172.16.0.0/24`, and ARP announcement to reason about | a real, stable VIP. `status.addresses` works exactly as upstream documents |
| **OpenStack CCM** | credentials in the cluster, and Octavia must exist in the cloud | the "proper" cloud-native answer, and irrelevant to the PTR, which is bare metal |

The deciding argument is that **the only client is the head node**, which sits on the same L2 as the workers. A VIP buys stability we have no consumer for, and the OpenStack CCM optimises for a substrate we are explicitly leaving.

**What it costs us, stated plainly.** The endpoint is `<any node IP>:<arbitrary port>`. That is fine for `curl` and for §14's success criterion, and unacceptable for anything with real clients: you cannot put it in DNS, it is not stable across a Service recreation, and it leaks the node topology into whatever configuration references it. §14 therefore reads both halves out of the cluster rather than hard-coding either.

**Decision: NodePort for the POC, MetalLB on the PTR.** The migration is one field — `envoyService.type` on the `EnvoyProxy` — plus an address pool. The `Gateway`, the `HTTPRoute`s and every `InferenceService` are unchanged, because Gateway API's whole point is that the routing layer does not know how the address was obtained.

**Revisit if:** anything other than the head node needs to reach a model endpoint, a hostname has to resolve to it, or §16 brings clients that cannot be told an arbitrary port. Any one of those makes MetalLB worth its footprint.

---

---

## References

**Nova and the boot-order problem**

- [Boot an instance using PXE](https://docs.openstack.org/nova/latest/user/boot-instance-using-PXE.html) — rescue mode is the only documented mechanism
- [Block Device Mapping in Nova](https://docs.openstack.org/nova/latest/user/block-device-mapping.html) — `boot_index`, `device_type`, and multi-device boot
- [`[nova] Spawning instance that will do PXE booting`](https://lists.openstack.org/pipermail/openstack-discuss/2021-December/026191.html) — Nova core's answer, December 2021
- [Nova blueprint `pxe-boot-instance`](https://blueprints.launchpad.net/nova/+spec/pxe-boot-instance) and [`libvirt-empty-vm-boot-pxe`](https://blueprints.launchpad.net/nova/+spec/libvirt-empty-vm-boot-pxe) — never delivered
- [Nova blueprint `boot-order-for-instance`](https://blueprints.launchpad.net/nova/+spec/boot-order-for-instance) — proposed `nova boot --nic bootindex=N`; registered Oct 2014, Not started
- [QEMU `bootindex` documentation](https://github.com/qemu/qemu/blob/master/docs/system/bootindex.rst) — why a device with no `bootindex` is not tried
- [OpenStack wiki: BootFromISO](https://wiki.openstack.org/wiki/BootFromISO) — `disk_format=iso` gives a CD-ROM plus a blank flavor-sized disk
- [Glance — useful image properties](https://docs.openstack.org/glance/latest/admin/useful-image-properties.html) — `hw_firmware_type`, `hw_rescue_device`, `hw_rescue_bus`, `hw_boot_menu`

**Nova source, as checked on 4 Aug 2026 (master, 33.1.0.dev)**

These are the primary evidence for DL-002.1a, DL-002.2b and DL-002.2c. Line numbers are as-of that date and will drift; the `grep` commands in those subsections will not.

- [`nova/virt/libvirt/config.py`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py) — [`LibvirtConfigGuestDisk`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1183) holds `boot_order` ([1228](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1228), rendered at [1386](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1386)); [`LibvirtConfigGuestInterface`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1884) does not; [`<bootmenu>`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L3250) and [`<boot dev=…>`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L3244)
- [`nova/virt/libvirt/blockinfo.py`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py) — [`BOOT_DEV_FOR_TYPE`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L92), [`SUPPORTED_DEVICE_TYPES`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L106), [`device_type` → device type](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L372), [`get_boot_order()`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L733), [`get_rescue_device()`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L747)
- [`nova/virt/libvirt/driver.py`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py) — [`hw_boot_menu` / `hw:boot_menu`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py#L7381), [`os_boot_dev` from the block device mapping](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py#L7413), [the rescue disk getting `boot_order='1'`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py#L6294)

**Prior art**

- [OVB — Preparing the host cloud](https://openstack-virtual-baremetal.readthedocs.io/en/latest/host-cloud/prepare.html) and [troubleshooting](https://openstack-virtual-baremetal.readthedocs.io/en/latest/troubleshooting.html) — the Nova patch, and the `ipxe-boot` image
- [sushy-tools dynamic emulator](https://docs.openstack.org/sushy-tools/latest/user/dynamic-emulator.html) — `SUSHY_EMULATOR_OS_RESCUE_PXE_BOOT`, `SUSHY_EMULATOR_OS_VMEDIA_USE_RESCUE`
- Stig Telfer, *Virtual Multi-Node Testing with OpenStack*, OpenCHAMI Developer Summit @ UCL 2026 — vTDS, Tenks, and the nested model. Local copy in `tutorials/tmp/2026-07-24-openchami-on-openstack/`
- [`Cray-HPE/vtds-core`](https://github.com/Cray-HPE/vtds-core), [`vtds-application-openchami`](https://github.com/Cray-HPE/vtds-application-openchami)
- [Tenks](https://docs.openstack.org/tenks/latest/)

**Ours**

- [§0 — the two decisions as the tutorial states them](00-introduction.md)
- [§6 — static discovery, and the three-way contract it creates](06-node-inventory.md)
- [§7 — the rescue mechanism in practice](07-node-instances-and-ipxe.md)
- [Appendix A — the Redfish/sushy-tools automation of §7](appendix-a-redfish-sushy.md)
- [Appendix C — alternatives, argued](appendix-c-alternatives.md)
- [The libvirt lab this tutorial descends from](../ochami-macos-libvirt-talos/README.md), whose §4 is DL-002 solved by one `virt-install` flag
