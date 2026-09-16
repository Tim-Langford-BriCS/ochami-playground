# Investigation — can we avoid the iPXE / rescue-mode hack?

*(28 July 2026. A one-off investigation, requested part-way through a manual run of this tutorial. Summary and evidence only; the decisions it feeds are in [`DECISION-LOG.md`](DECISION-LOG.md), and the experiments it produced are now inline in [§7.2 and §7.2b](07-node-instances-and-ipxe.md).)*

## The question

Two things were asked, and they turned out to have different answers.

1. **"Does OpenStack need to be aware of the Talos image?"** — a colleague's view was that it does not, because OpenCHAMI provides the image in the end.
2. **"We want something like the libvirt tutorial, but on OpenStack instead of in a Lima VM. Does that let us avoid the iPXE booting issue?"** — with the stated preference that the rescue-mode workaround be avoided if at all possible, on the grounds that it is a hack and may well be unnecessary once TechWatch hardware arrives.

## Answer to (1): yes, with one correction

The Talos image never touches Glance. What OpenStack holds is:

| Artifact | Where it lives | Served by |
|---|---|---|
| Talos `vmlinuz`, `initramfs.xz`, `controlplane.yaml`, `worker.yaml` | the head node's S3 store | **OpenCHAMI** — BSS hands iPXE those URLs (§8, §9) |
| Rocky image | Glance (pre-existing) | OpenStack — head node only |
| `tw-blank`, 1 MB | Glance (§7.2) | OpenStack — the nodes' deliberately empty root disk |
| `tw-ipxe`, `ipxe.iso` | Glance (§7.3) | OpenStack — rescue media only |

So the correction is narrow but load-bearing: **OpenStack does not need to know about the Talos image, but it does have to be involved in selecting the boot device.** That is the whole of the problem, and it is confined to one line of §7 and §10.

## Answer to (2): only if "like the libvirt tutorial" means nested

The phrase has two readings and they diverge sharply.

**Read literally**, the Lima VM in the libvirt lab is a nested-virt host, so the direct translation is one large Nova instance running libvirt, with head and compute nodes as VMs inside it. **That avoids the problem entirely** — inside your own libvirt you write `--boot uefi,hd,network` and the firmware does the right thing. It is also what all the prior art does: HPE's vTDS (an OpenStack instance is a "blade" hosting a management VM plus compute VMs — Stig Telfer's OpenCHAMI Developer Summit talk, local copy in `tutorials/tmp/2026-07-24-openchami-on-openstack/`), StackHPC's Tenks, and our own libvirt lab.

It needs nested virtualisation, which is disabled across the Digital Labs hypervisors for Januscape. Per the Slack thread that was a **policy** decision, not a technical one: excluding the prototyping hypervisor was offered and declined in favour of consistency, with the expectation that it is temporary. See [DL-001](DECISION-LOG.md).

**Read as this tutorial** — one Nova instance per node — the problem cannot be avoided. But rescue mode is not the only way to solve it, and probably not the best one.

## What the research established

### Nova genuinely cannot network-boot an instance

This is firmer than the tutorial's §0 suggests, and worth having on record:

- Nova's [*Boot an instance using PXE*](https://docs.openstack.org/nova/latest/user/boot-instance-using-PXE.html) documents **rescue mode with an iPXE image and nothing else** — no boot order, no firmware setting, no diskless network boot.
- Asked directly on `openstack-discuss` in December 2021, Nova core reviewer Sean Mooney said OpenStack does not enable network boot and the iPXE ISO is "the most easy way"; native support would require "a neutron extension to mark ports as bootable which nova would read", which does not exist.
- The two blueprints that would have added it — `pxe-boot-instance` and `libvirt-empty-vm-boot-pxe` — were never delivered.
- Mechanically: QEMU takes boot order from per-device `bootindex`; libvirt renders a guest's boot configuration into `bootindex`; **Nova only ever sets `bootindex` on storage devices, never on a NIC.** QEMU's own documentation notes that `bootindex` "is especially important for booting via the network", and without it "the network bootloader won't be considered and network boot will fail."
- [OVB](https://openstack-virtual-baremetal.readthedocs.io/en/latest/host-cloud/prepare.html), the canonical "use OpenStack instances as bare-metal targets" project, needs either an **out-of-tree Nova patch** on the compute nodes or an `ipxe-boot` image that instances are **rebuilt to** before each deployment.

### Rescue mode is not our invention

sushy-tools — OpenStack's own Redfish BMC emulator, used across OpenStack CI — implements `BootSourceOverrideTarget=Pxe` on its **Nova driver by putting the instance into rescue mode with an iPXE image** (`SUSHY_EMULATOR_OS_RESCUE_PXE_BOOT`), and implements Redfish virtual media the same way (`SUSHY_EMULATOR_OS_VMEDIA_USE_RESCUE`). This confirms [appendix A](appendix-a-redfish-sushy.md) is accurate, and means rescue happens underneath any Redfish-driven workflow whether we choose it in the main path or not.

### But the justification for choosing it was too strong

§0 justifies rescue on **controllability** — you decide when a node PXEs. The libvirt lab we are reproducing does not have that: `--boot uefi,hd,network` PXEs whenever the disk is not bootable. So controllability is over-delivery against the actual target, and it is bought with real costs:

- `hw_rescue_bus` has to be guessed per cloud (`scsi`, `usb`, `ide` — which does not exist on `q35` — or `virtio` with `hw_rescue_device=disk`);
- a rescued instance cannot be stopped, paused or suspended, which shapes every power sequence in §10;
- rescue media shifts the guest's disk ordering, which is why §8 selects Talos's install disk by size;
- it needs compute API microversion 2.87;
- and §7 becomes the longest section in the tutorial with no upstream equivalent, which a reader must get through before learning anything about OpenCHAMI.

It also expires. On TechWatch metal you set boot order once in firmware, or over Redfish, and the question never returns. **The fidelity rescue buys is fidelity to a mechanism we will not be using** — which argues for the simplest thing that works rather than the most faithful.

### Two options that had not been tried

| | Mechanism | Status | Now tested at |
|---|---|---|---|
| **A** | Firmware PXEs unaided from an empty disk under **UEFI** | mentioned in §7.2 as a curiosity; never run with `hw_firmware_type=uefi` set deliberately | **[§7.2](07-node-instances-and-ipxe.md)** |
| **B** | iPXE ISO as a **permanent second boot device** (`boot_index=1`, `device_type=cdrom`) | not previously considered | **[§7.2b](07-node-instances-and-ipxe.md)** |

**A** is a five-minute question with a large payoff. SeaBIOS with a boot order containing only the disk halts at `No bootable device`; OVMF with no usable boot option enumerates what it can see, which is why `Start PXE over IPv4` is such a familiar sight on UEFI guests. If it works, we get exact libvirt-lab parity — OpenCHAMI's `coresmd` serves the iPXE binary over TFTP itself (it bundles x86 UEFI, ARM EFI and legacy x86), so `tw-ipxe`, the `hw_rescue_bus` guesswork, the rescue state and both helper scripts all become unnecessary. It is empirical: it depends on the OVMF build and how strictly QEMU's boot order is applied, and no amount of reading settles it.

**B** is the closest thing Nova *can be told* to do to `--boot uefi,hd,network`. [Nova's block device mapping](https://docs.openstack.org/nova/latest/user/block-device-mapping.html) supports `boot_index` ("the order in which a hypervisor will try devices"), accepts `device_type=cdrom`, and states that "some hypervisors will support booting from multiple devices, but only if they are of different types - eg a disk and CD-ROM." Blank disk at index 0, iPXE CD-ROM at index 1: the empty disk fails, iPXE runs, Talos installs, and from then on the disk wins. **No rescue, no reinstall loop, no BSS state, and it works under BIOS as well as UEFI** because both devices are genuinely in the firmware's boot order. Its costs are a 1 GB Cinder volume per node (Nova forbids `source=image, destination=local` for non-root devices) and that boot order is fixed at create time, so adopting it means recreating the node instances.

## Where this leaves the tutorial

Nothing has been ripped out. The rescue path still works and is still proven on `techwatch-proto`. What changed:

- **§7.2 is now Test 1** — the UEFI empty-disk probe, with the firmware properties set deliberately and a table saying what each console outcome means for the rest of the section.
- **§7.2b is new — Test 2** — the second-boot-device probe, placed before §7.3 and §7.4 because boot order can only be chosen at instance-create time.
- **§7.3 and §7.4** now open with a short decision point naming which of the three paths you are on.
- **[`DECISION-LOG.md`](DECISION-LOG.md)** holds the full argument, the rescue method recorded in full so it can be demoted without losing the knowledge, and the revisit triggers.

## Recommendation

1. Run **Test 1** when you reach §7. Five minutes, and a positive result deletes most of the section.
2. If it fails, run **Test 2**. It is the option that most deserves a try and has had none.
3. Keep rescue documented either way — appendix A depends on it existing regardless of what the main path does.
4. Do **not** adopt the "boot from iPXE permanently as the root image" variant (§7.7) unless tenant rescue turns out to be forbidden. Its failure mode is a re-wiped node.
5. Treat whichever answer we get as disposable. It has an expiry date stamped on it: the arrival of hardware with real BMCs.

## Outcome, 4 Aug 2026 — the question is answered, and not by any of the options above

**Rescue mode is not needed on this cloud.** Test 1 (option A) failed: Digital Labs' OVMF has no network boot option at all, and an empty-disk UEFI instance drops to the EFI Shell. But the verification pass below turned up a seventh option that none of the prior art uses — `boot.ipxe.org` publishes **`ipxe.usb`**, a *disk* image carrying both a BIOS bootloader and `EFI/BOOT/BOOTX64.EFI` — so **iPXE can simply be the node's root disk**. Tested the same afternoon: iPXE 2.0.0+ booted, CoreDHCP gave it the SMD-held `172.16.0.5`, and BSS answered. Test 2 was never run; no Cinder volume was ever created.

The recommendation section below is left as written, because the reasoning that got here is worth more than the answer. Where it says "run Test 1, then Test 2", the record is: Test 1 failed, Test 4 passed, and Test 2 became unnecessary. Details in [DL-002.2d](DECISION-LOG.md#dl-0022d-option-g--ipxe-as-the-nodes-root-disk-and-test-1s-result) and [§7.2c](appendix-f-network-boot-investigation.md#step-72c--test-4-ipxe-as-the-nodes-own-root-disk).

## Addendum — verification pass, 4 Aug 2026

*(Asked for as a "doubly confirm": everything above rests on documentation, a mailing-list reply, dead blueprints and inference about libvirt. None of it was the code. So the code was read.)*

**The conclusion did not move. The confidence did.** Against Nova **master, 33.1.0.dev**:

| Claim as stated above | Status after reading the source |
|---|---|
| Nova only ever assigns a `bootindex` to storage | **Confirmed, and stronger than stated.** `boot_order` is an attribute of `LibvirtConfigGuestDisk` and simply does not exist on `LibvirtConfigGuestInterface`. The object Nova builds a NIC from has no field for the element that would make it bootable |
| There is no way to name the network as a boot device | **Confirmed.** Nova's other route is `<os><boot dev='…'/></os>`, fed from `BOOT_DEV_FOR_TYPE = {'disk': 'hd', 'cdrom': 'cdrom', 'floppy': 'fd', 'lun': 'hd'}`. Three values, all storage |
| Two blueprints were never delivered | **Three.** `boot-order-for-instance` (Oct 2014, Not started) proposed exactly `nova boot --nic bootindex=N` |
| Option **B** is sound "by documentation" | **Upgraded to traced.** `device_type=cdrom` on a volume BDM survives to the guest and maps to `<boot dev='cdrom'/>`, so blank-disk-plus-iPXE-CD should reach libvirt as `--boot hd,cdrom` |

Two things worth adding to the record:

1. **The limitation sits below the API.** It is in XML generation, not in policy, microversions or image metadata — so there is nothing a cloud operator could switch on for us, and nothing that changes in a future release without a blueprint landing first. That is useful when deciding *not* to raise a ticket with StackHPC.
2. **`hw_boot_menu` exists and nobody had noticed it.** A supported image property (flavor equivalent `hw:boot_menu`) that renders `<bootmenu enable='yes'/>`. It is not an option — it needs a human at a console on every boot — but it is a one-minute diagnostic that separates "the firmware won't try the NIC" from "the NIC has no boot ROM", which the console log alone cannot do. Now [§7.2's](appendix-f-network-boot-investigation.md#if-test-1-failed-and-the-console-did-not-make-the-reason-obvious) follow-up when Test 1 fails.

The exact commands, all of which need no cloud and no credentials, are in [DL-002.1a](DECISION-LOG.md#dl-0021a-verified-in-novas-source-not-only-in-its-documentation), [DL-002.2b](DECISION-LOG.md#dl-0022b-option-bs-code-path-traced-4-aug-2026) and DL-002.2c. **Repeat them, rather than trusting this table, before anyone reopens the question on a newer OpenStack.**

## Open actions outside the tutorial

- **Ask about the nested-virt timeline.** Not to reopen a settled mitigation, but to find out whether the patched kernel is close enough to plan around. If nested virt returns, the libvirt-talos tutorial runs inside one Nova instance and all of the above becomes a footnote ([DL-001](DECISION-LOG.md)).
- **Decide consciously about the goal split.** Proving OpenCHAMI's provisioning chain (§§5–10) and proving the inference stack (§§11–16) are only loosely coupled. Talos publishes an OpenStack platform image that reads its config from the config-drive, so §§11–16 *could* be built on a Nova-booted Talos cluster in parallel while §§5–10 are debugged. That proves nothing about OpenCHAMI, so it should be a recorded decision rather than something that happens because PXE was annoying ([DL-003](DECISION-LOG.md)).
- **Update the IaC** (`../ochami-openstack-talos-iac/`) once a path is chosen — `ports.tf` and the node-instance module both assume rescue.

## Sources

- [Nova — Boot an instance using PXE](https://docs.openstack.org/nova/latest/user/boot-instance-using-PXE.html)
- [Nova — Block Device Mapping](https://docs.openstack.org/nova/latest/user/block-device-mapping.html)
- [OpenStack wiki — BootFromISO](https://wiki.openstack.org/wiki/BootFromISO)
- [`[nova] Spawning instance that will do PXE booting`, openstack-discuss, Dec 2021](https://lists.openstack.org/pipermail/openstack-discuss/2021-December/026191.html)
- [QEMU — `bootindex` documentation](https://github.com/qemu/qemu/blob/master/docs/system/bootindex.rst)
- [OVB — Preparing the host cloud](https://openstack-virtual-baremetal.readthedocs.io/en/latest/host-cloud/prepare.html)
- [sushy-tools — dynamic emulator](https://docs.openstack.org/sushy-tools/latest/user/dynamic-emulator.html)
- [`Cray-HPE/vtds-core`](https://github.com/Cray-HPE/vtds-core), [`vtds-application-openchami`](https://github.com/Cray-HPE/vtds-application-openchami), [Tenks](https://docs.openstack.org/tenks/latest/)
- Nova blueprints [`pxe-boot-instance`](https://blueprints.launchpad.net/nova/+spec/pxe-boot-instance), [`libvirt-empty-vm-boot-pxe`](https://blueprints.launchpad.net/nova/+spec/libvirt-empty-vm-boot-pxe), [`boot-order-for-instance`](https://blueprints.launchpad.net/nova/+spec/boot-order-for-instance)
- [Glance — useful image properties](https://docs.openstack.org/glance/latest/admin/useful-image-properties.html) — `hw_boot_menu`, `hw_rescue_*`, `hw_firmware_type`
- Nova master source, read 4 Aug 2026: [`libvirt/config.py`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py), [`libvirt/blockinfo.py`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py), [`libvirt/driver.py`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py) — line-level index in [`DECISION-LOG.md`](DECISION-LOG.md#references) and [§7](appendix-f-network-boot-investigation.md#references)
