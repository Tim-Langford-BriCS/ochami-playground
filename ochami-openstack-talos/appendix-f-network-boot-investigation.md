# Appendix F — How we established the way a node network-boots

*(**This was §7 until 4 Aug 2026.** It is kept close to verbatim, because it is the evidence: four candidate mechanisms, the tests that chose between them, the captured consoles, and instructions for the three mechanisms that lost. The runnable path it produced is now [§7](07-node-instances-and-ipxe.md), which is short.)*

## Read this first

**You do not need this appendix to build the cluster.** [§7](07-node-instances-and-ipxe.md) tells you what to do and why in about a page. Come here for one of four reasons:

| Why you are here | Start at |
|---|---|
| **Your cloud is not Digital Labs** and you need to establish its behaviour yourself | [the test table](#which-tests-to-run), then Test 1 |
| You want to **check our work** — that Nova really cannot network-boot, and that we did not miss an easier option | [§7.2's result](#-the-result-on-techwatch-proto-4-aug-2026--test-1-failed-informatively), [§7.2c's result](#-the-result-on-techwatch-proto-4-aug-2026--test-4-passed), and [References](#references) |
| Tenant `server rescue` is **forbidden** on your cloud, or you need rescue for [appendix A](appendix-a-redfish-sushy.md) | [§7.3](#step-73--upload-ipxe-to-glance-as-a-rescue-image) and [§7.5](#step-75--dry-run-the-pxe-button) |
| You are writing the **IaC** and need to know which knobs are load-bearing | [§7.4](#step-74--create-the-node-instances) and [DL-002.2e](DECISION-LOG.md#dl-0022e-downstream-work-this-decision-creates) |

⚠ **The step numbering is the old §7's, deliberately preserved** — `7.2`, `7.2b`, `7.2c`, `7.3` … — so that every deep link written before the split still resolves, and so that the run log, the decision log and `issues/003` still name the same things. Read "§7.2c" here as "appendix F's Test 4". Where this appendix says "this section", it means the old §7.

**The one-line answer it arrived at:** OpenStack cannot be told to network-boot an instance, so we make **iPXE the node's root disk** — after which the entire OpenCHAMI chain runs unmodified, and Talos overwrites the iPXE bootloader when it installs, so the node stops network-booting by itself. The plain-language version of that, and the only version most readers need, is in [§7's Concepts](07-node-instances-and-ipxe.md#in-plain-terms--what-we-fake-and-what-we-dont).

## Concepts

§0's decision 2 in one sentence, **as it stood before this investigation**: OpenStack has no "boot from network" option, so we make an instance network-boot by putting it into Nova rescue mode with an iPXE image.

📌 **Superseded on 4 Aug 2026 — the answer turned out to be simpler than that sentence.** We put iPXE **on the node's own root disk** instead. What follows is how we got there.

Here is the chain we are about to build, with the OpenStack-specific part highlighted — three candidate ways in at the top, one identical chain in the middle, three ways back out at the bottom:

![Nova only ever assigns a boot index to storage, so there is no way to put a NIC in a guest's boot order; every option in this section is a way of getting something other than the NIC to start the network boot. Three candidates are tested in order: a UEFI guest with an empty disk whose firmware enumerates the NIC itself (§7.2), a blank root disk at boot_index 0 with the iPXE ISO as a CD-ROM volume at boot_index 1 (§7.2b), or Nova stable device rescue with an iPXE image (§7.5). Whichever works, everything after it is identical and unmodified: iPXE starts, CoreDHCP answers with the address SMD holds for that MAC and points at BSS, iPXE fetches the boot script BSS holds for that MAC, downloads the Talos kernel and initramfs from the head node's S3 store and boots them into RAM, enters maintenance mode and fetches its machine config from the talos.config URL, then selects its install disk by size rather than by device name and writes itself to it. Each mechanism has its own way back to disk boot in §10: reboot, nothing at all, unrescue, or repointing the BSS payload at an iPXE sanboot script. On real hardware all of this is one Redfish call setting BootSourceOverrideTarget to Pxe, followed by a reset. Not drawn, because it was found after this diagram and is now the mechanism actually used on this cloud: a fourth way in, where iPXE itself is the node's root disk (§7.2c) — needing no rescue, no CD-ROM and no boot order — and no corresponding way back out, because Talos overwrites the iPXE bootloader when it installs.](diagrams/07-boot-chain.svg)

Everything between the two `openstack` commands is ordinary, unmodified OpenCHAMI. Those two commands are the hand-cranked version of a Redfish BMC's "set boot device = PXE / = HDD, then reset" — see the table in §0 and [appendix A](appendix-a-redfish-sushy.md).

<details>
<summary>The same chain as a single vertical line, if you prefer it text-only</summary>

```
openstack server rescue --image tw-ipxe  tw-cp1      ← §7.5  the "PXE button"
        │
        ▼
  instance reboots, firmware boots the iPXE media
        │
        ▼
  iPXE does DHCP on tw-prov  ─────────────► CoreDHCP (§5.7) leases 172.16.0.1
        │                                    and points at BSS
        ▼
  iPXE chains to BSS  ────────────────────► boot script for this MAC (§9)
        │
        ▼
  downloads Talos vmlinuz + initramfs from S3 (§8), boots them
        │
        ▼
  Talos installs to the node's own disk, then:
        │
        ▼
openstack server unrescue tw-cp1                     ← §10   "boot from disk"
```

That is the **rescue** path specifically — the one the rest of this section is written against. Substitute `openstack server create … --block-device …device_type=cdrom,boot_index=1` at the top and nothing at the bottom for Test 2, or nothing at the top and `openstack server reboot` at the bottom for Test 1.

</details>

### Why rescue, and not the obvious alternatives

| Approach | Why not |
|---|---|
| Boot the node **from** the iPXE image, with a blank volume for Talos | Works, but the instance boots iPXE on *every* power cycle, so after Talos installs, the node network-boots and reinstalls forever. Fixable (BSS can answer `sanboot` once a node is provisioned) but it makes "is this node installed?" a piece of state BSS has to hold. Kept as the §7.7 fallback |
| Ironic | It is a provisioning system with its own PXE stack — the wrong layer to test OpenCHAMI on, and not available to tenants here |
| Rely on the firmware trying the network unaided | Sometimes works! We test it in §7.2 because it costs nothing. But it gives no control over *when* a node PXEs, which is precisely what we need in §10 |

✅ **Settled on `techwatch-proto`, 4 Aug 2026 — read this before the decision apparatus below.** Test 1 **failed** (this cloud's OVMF has no network boot option at all) and **Test 4 passed on the first attempt**: `ipxe.usb` as the node's root disk boots iPXE, gets the SMD-held lease from CoreDHCP, and reaches BSS. So on this cloud the mechanism is [§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk), and **§7.2b, §7.3, §7.5 and §7.6 are not on the path** — no `tw-ipxe`, no rescue, no `hw_rescue_bus`, no Cinder volumes, no helper scripts. They stay written because rescue is what [appendix A](appendix-a-redfish-sushy.md) needs, and because your cloud may answer differently. **If you are reproducing this on Digital Labs, skip to [§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk), then [§7.4](#step-74--create-the-node-instances).**

### Which tests to run

🛑 **Before you build anything in this section, run the two tests in §7.2 and §7.2b.** Rescue mode works and is proven on this cloud, but it is the *most complicated* of three options and the argument for it is weaker than the table above implies — the libvirt lab this tutorial reproduces has no "control over *when* a node PXEs" either, because `--boot uefi,hd,network` PXEs whenever the disk is not bootable. Either test succeeding removes rescue from the main path entirely, along with `tw-ipxe`, the `hw_rescue_bus` guesswork and §7.6's helper scripts. Together they cost about half an hour.

| | What it tests | Where | Cost |
|---|---|---|---|
| **Test 1** | does a **UEFI** instance with an empty disk PXE unaided? | [§7.2](#step-72--test-1-does-an-instance-network-boot-on-its-own) | ~5 min |
| **Test 4** | is **iPXE itself** the node's root disk? (found last, simplest of all — **do this second**) | [§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk) | ~10 min |
| **Test 2** | will Nova give us **disk-then-iPXE** as a fixed boot order? | [§7.2b](#step-72b--test-2-ipxe-as-a-permanent-second-boot-device) | ~30 min |
| **Test 3** | does rescue work here? (the fallback, and what appendix A needs) | [§7.5](#step-75--dry-run-the-pxe-button) | ~10 min |

⚠ **The numbering is chronological, not an order of preference — run them 1, 4, 2, 3.** Test 4 was found after Tests 1–3 were written and is the cheapest and least invasive of the four; it is numbered last only so that nobody's run log or commit message silently changes meaning.

Full reasoning, evidence and the reversal triggers are in [`DECISION-LOG.md`](DECISION-LOG.md) (DL-002) and [`INVESTIGATION-network-boot.md`](INVESTIGATION-network-boot.md). The short version: **Nova cannot be told to put a NIC in a guest's boot order** — it only ever assigns a `bootindex` to storage — so all three options are ways of getting something *other than the NIC* to start the network boot.

📌 **You do not have to take that on trust, and it is worth not taking on trust.** Re-checked against Nova master on 4 Aug 2026, and reduced to three `curl | grep` commands that need no cloud, no credentials and about a minute — [DL-002.1a](DECISION-LOG.md#dl-0021a-verified-in-novas-source-not-only-in-its-documentation). In brief: the class that renders a `<interface>` has no `boot_order` field at all, and the only boot devices Nova can name are `hd`, `cdrom` and `fd`. **The limitation is in XML generation, below the API** — so no microversion, image property, flavor extra spec or policy change can reach it, which is worth knowing before asking your cloud operator to enable something. All the files and line numbers are under [References](#references) at the bottom of this page.

### Two rescue modes, and we want the newer one

| | Legacy rescue | **Stable device rescue** |
|---|---|---|
| Command | `openstack server rescue --image …` | `openstack --os-compute-api-version 2.87 server rescue --image …` |
| Enabled by | nothing | `hw_rescue_device` / `hw_rescue_bus` properties on the **rescue image** |
| The instance's own disks | renumbered — the rescue image becomes the first disk | **kept attached in their original order**, rescue media added alongside |
| Volume-backed instances | **not supported** | supported |
| Available since | always | Ussuri (21.0.0) |

We use stable device rescue. Talos needs to find and write to the node's *own* disk while booted from the rescue media, so "disks keep their order" is not a nicety.

⚠ **A rescued instance cannot be stopped, paused or suspended.** Nova refuses, because those operations would lose the state needed to unrescue. So the power sequence in §10 is always *unrescue first, then stop* — never the other way round. (sushy-tools does exactly this internally: ask a rescued node to power off over Redfish and it silently unrescues first.)

## Step 7.1 — Get the iPXE media

[iPXE](https://ipxe.org) is open-source boot firmware: a small program that does DHCP, then fetches and runs a boot script over HTTP. It is what OpenCHAMI's boot chain expects to be talking to.

`boot.ipxe.org` publishes exactly two prebuilt artifacts, and **which one you want depends on which mechanism your cloud gave you.** Both are bootable under legacy BIOS *and* UEFI, so neither choice depends on what §1.5 said about `hw_firmware_type`:

| Artifact | What it is | Wanted by |
|---|---|---|
| **`ipxe.usb`** (8 MB) | a bootable **disk** image — MBR + SYSLINUX for BIOS, and a FAT partition holding `EFI/BOOT/BOOTX64.EFI` for UEFI | **[§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk) — the mechanism on this cloud** |
| `ipxe.iso` (9 MB) | an El Torito **CD** image | §7.2b's Cinder volumes, and §7.3's rescue image |

```
devbox$ curl -fLO https://boot.ipxe.org/ipxe.usb        # for §7.2c
devbox$ curl -fLO https://boot.ipxe.org/ipxe.iso        # only for §7.2b or rescue
devbox$ ls -l ipxe.usb ipxe.iso
```

⚠ **The `.usb` name is about *shape*, not about USB.** It is a raw disk image with a partition table, which is why Nova can serve it as a root disk and why you can equally write it to a memory stick. Nothing in §7.2c involves a USB device.

> **Why not build it?** A custom build lets you embed a script (e.g. "chain straight to `http://172.16.0.254:8081/boot/v1/bootscript`" without waiting for DHCP options). We don't need that: CoreDHCP already hands out the boot-script URL, which is the whole point of §5.7's `coresmd` plugin. Stock iPXE keeps this tutorial honest — the same firmware behaviour a real server would have. If you later want an embedded script, iPXE's `EMBED=` build option is the mechanism, and the IaC has a place for it.

⚠ **Verify what you downloaded, and know that it carries a script.** iPXE does not publish signatures for the prebuilt binaries, and `ipxe.usb` contains a 120-byte `autoexec.ipxe` of its own — harmless (it offers `Ctrl-B` for two seconds, then `autoboot`), but it *does* run, and you can see it do so in §7.2c's capture. For a throwaway POC on an isolated wire this is acceptable; for the PTR, build iPXE from source in CI and record the hash. Note this in your run log as a known gap — it is the kind of supply-chain detail that matters more on production hardware than here.

## Step 7.2 — Test 1: does an instance network-boot on its own?

Five minutes, and a positive result deletes most of this section. We need a "blank" image — an instance with nothing bootable on its root disk, whose firmware will then fall through to the network.

```
devbox$ truncate -s 1M blank.raw
devbox$ openstack image create ${TW_PREFIX}-blank \
    --disk-format raw --container-format bare \
    --file blank.raw --private
```

**Ask for UEFI explicitly, and this is the point of the test.** With legacy BIOS the guest's boot order contains the disk and nothing else, so an empty disk gets you `No bootable device` and a halt. UEFI firmware behaves differently: with no usable boot option it enumerates what it can see, which is why `Start PXE over IPv4` is such a familiar sight on UEFI guests whose disk is not bootable. So set the properties rather than inheriting whatever §1.5 found on the Rocky image:

```
devbox$ openstack image set ${TW_PREFIX}-blank \
    --property hw_firmware_type=uefi \
    --property hw_machine_type=q35
```

Boot one node instance from it, on the provisioning port, and watch the console:

```
devbox$ openstack server create ${TW_PREFIX}-probe \
    --image ${TW_PREFIX}-blank \
    --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node5-prov \
    --wait

devbox$ sleep 30 && openstack console log show ${TW_PREFIX}-probe --lines 80
```

| Console shows | Meaning | What to do |
|---|---|---|
| `Start PXE over IPv4`, `PXE`, `iPXE`, or DHCP attempts | 🎉 **the firmware network-boots unaided** | **Stop and re-plan: you have libvirt-lab parity.** See the box below |
| `No bootable device`, a halt | firmware will not try the network | repeat with `hw_firmware_type=bios` for the record, then go to §7.2b |
| UEFI Shell prompt (`Shell>`) or a boot-manager menu | UEFI ran out of options without trying the network | as above — go to **[§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk) first**, then §7.2b |
| instance `ERROR` | flavor/image mismatch, or raw images not accepted | see common failures |

✅ **If Test 1 succeeded, this is the best available outcome and you should take it.** OpenCHAMI's `coresmd` serves the iPXE binary over TFTP itself — it bundles x86 UEFI, ARM EFI and legacy x86 builds — so the chain becomes DHCP → TFTP → iPXE → BSS, exactly the one the libvirt lab proved, with no OpenStack involvement at all. Concretely: **skip §7.3 (no `tw-ipxe` needed), skip §7.5, skip §7.6's helper scripts, and in §10 power-cycle with `openstack server reboot` instead of rescuing.** Nothing in §§8–19 changes. Record the result in your run log and note it against DL-002 in [`DECISION-LOG.md`](DECISION-LOG.md), because the IaC needs to know.

⚠ **You can run this test before §5 exists.** It only needs the port and the flavor. Without CoreDHCP running you will watch the DHCP attempt time out — which still answers the question, because the question is whether the firmware *tries*. With §5 and §6 done you get the stronger result: a `172.16.0.x` lease that SMD chose — **specifically `172.16.0.5`**, because the probe borrows `tw-node5-prov`, which §6 mapped to `tw-w4` at `.5`. Any other address, and especially anything in `.200–.250`, means CoreDHCP did not recognise the MAC.

### 📓 The result on `techwatch-proto`, 4 Aug 2026 — Test 1 failed, informatively

Recorded because the *shape* of the failure decides what to do next, and because this is the only captured console in the section that is not a placeholder:

```
BdsDxe: failed to load Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0): Not Found
BdsDxe: loading Boot0002 "EFI Internal Shell" from Fv(…)/FvFile(…)
BdsDxe: starting Boot0002 "EFI Internal Shell" from Fv(…)/FvFile(…)
UEFI Interactive Shell v2.2
EDK II  /  UEFI v2.70 (EDK II, 0x00010000)
Mapping table
     BLK0: Alias(s):
          PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0)
Shell>
```

Three separate findings, all useful:

1. **Option A is dead here.** OVMF went from a failed `Boot0001` straight to `Boot0002`, the internal Shell. The Shell is normally *last* in the boot order, so there was no network boot option anywhere between them — this OVMF build has no PXE boot option to fall through to. Nothing in §7 can change that; it is a property of the deployment's firmware.
2. **Fall-through itself works.** The firmware tried a boot option, found it unbootable, and moved on to the next one *by itself*. That is the only behaviour options B (§7.2b) and the root-disk option (§7.2c) need, and it is now observed rather than assumed.
3. **The empty disk was enumerated and rejected**, as `UEFI Misc Device` at `PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0)`, mapped as `BLK0`. So `tw-blank` does exactly its job: present, visible, not bootable.

⚠ **A UEFI Shell prompt is an idling instance, not a crashed one.** It sits there until deleted, and it is holding `tw-node5-prov`. Delete it when you have what you need.

### If Test 1 failed and the console did *not* make the reason obvious

The captured log above happens to answer it — the firmware's own boot options are printed. When it does not (BIOS guests print nothing comparable), one supported knob settles it: the image property `hw_boot_menu` (flavor equivalent `hw:boot_menu`), which renders libvirt's `<bootmenu enable='yes'/>` and gives the guest an interactive firmware boot menu:

```
devbox$ openstack image set ${TW_PREFIX}-blank --property hw_boot_menu=true
devbox$ openstack server reboot --hard ${TW_PREFIX}-probe
devbox$ openstack console url show ${TW_PREFIX}-probe
```

Open that URL in a browser and press `Esc` or `F12` while the instance is starting. (This is one of the few places in the tutorial that needs the *graphical* console rather than `console log show` — a boot menu is drawn on the video device, and may not appear in the serial log at all.)

| Boot menu shows | Meaning | What to do |
|---|---|---|
| a network entry — `UEFI PXEv4`, `iPXE`, `Network boot` | the boot ROM **is** there and the firmware **can** see it; only the *ordering* is against us | select it by hand — that proves DHCP → BSS → Talos end to end with none of §7's apparatus. Then continue, because a menu is not a mechanism |
| no network entry anywhere in the menu | this firmware has no network boot capability at all | **option A is dead here, and only option A.** Continue to §7.2c and §7.2b |

⚠ **Do not read this diagnostic as a verdict on §7.2c or §7.2b.** Both of those put **iPXE itself** on a *storage* device — a disk image or a CD-ROM — and iPXE brings its own network drivers and its own DHCP client. Neither one needs the firmware to have a network stack, a PXE option ROM, or any opinion about the NIC. All they need is for the firmware to boot storage and to move on when a boot option fails, which the capture above shows it doing. This diagnostic tells you whether option A was ever possible; it tells you nothing about the two options that follow.

⚠ **Unset it again before §7.4.** A boot menu on the node instances' own image means every node waits at a prompt on every boot, which will look exactly like a broken PXE chain in §10:

```
devbox$ openstack image unset ${TW_PREFIX}-blank --property hw_boot_menu
```

Either way, clean up the probe and free the port:

```
devbox$ openstack server delete ${TW_PREFIX}-probe --wait
```

⚠ **We keep `tw-blank`.** It is the image the node instances boot from in §7.4, because a node's root disk should start empty — Talos is going to overwrite it anyway, and an empty disk makes "has this node been provisioned?" visible.

🛑 **If you set `hw_firmware_type=uefi` above and keep it, it applies to every node instance booted from `tw-blank`** — under Test 4 that is none of them, because nodes boot `tw-ipxe-disk` instead and carry *its* firmware property; under the other paths it is all of them, and it must then agree with §7.3's rescue image and with the `console=` kernel argument in §9. If Test 1 failed and your cloud's Rocky image is BIOS, put `tw-blank` back to match rather than running a mixed estate: `openstack image unset ${TW_PREFIX}-blank --property hw_firmware_type --property hw_machine_type`.

## Step 7.2b — Test 2: iPXE as a permanent second boot device

🛑 **Do [§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk) before this one.** It was found after this section was written, it takes a third of the time, and it needs no Cinder volume, no `boot_index`, no `device_type` and no particular client version. Come back here only if it fails.

Run this only if Test 1 failed. It asks a different question: **Nova cannot put the NIC in the boot order, but can it give us two storage devices in a known order?** If yes, we get `--boot uefi,hd,network` semantics without rescue — blank disk first, iPXE CD-ROM second. The empty disk fails, iPXE runs, Talos installs, and from the next boot onwards the disk is bootable and wins. No reinstall loop, no BSS state, no rescue.

The mechanism is documented: Nova's block device mapping takes a `boot_index` — "the order in which a hypervisor will try devices" — accepts `device_type=cdrom`, and states that "some hypervisors will support booting from multiple devices, but only if they are of different types - eg a disk and CD-ROM."

📌 **And it is more than documented — the code path was traced in Nova master on 4 Aug 2026** ([DL-002.2b](DECISION-LOG.md#dl-0022b-option-bs-code-path-traced-4-aug-2026)). A volume BDM's `device_type` becomes the device's type, `cdrom` is an accepted type, and `cdrom` maps to a boot device Nova can name — so the two `--block-device` arguments below should reach libvirt as `<boot dev='hd'/><boot dev='cdrom'/>`, which is `--boot hd,cdrom`: the same *shape* of instruction as the libvirt lab's `--boot uefi,hd,network`, one device short. **What this test is really testing is your cloud, not Nova** — Cinder's willingness to make a bootable volume from a 1 MB ISO, your client's ability to express the mapping, and whether the firmware falls through from an empty disk to the CD.

You need the iPXE media first, so do [§7.1](#step-71--get-the-ipxe-media) and [§7.3](#step-73--upload-ipxe-to-glance-as-a-rescue-image) now, then come back. (§7.3's `hw_rescue_*` properties are harmless here — they only matter to rescue.)

⚠ **Nova forbids `source=image, destination=local` for anything but the root device**, so the ISO has to become a Cinder volume. One per node — a volume attaches to one instance, and read-only multiattach is not worth the risk. `ipxe.iso` is about 1 MB; 1 GB is the usual Cinder minimum.

```
devbox$ openstack volume create --image ${TW_PREFIX}-ipxe --size 1 ${TW_PREFIX}-ipxe-probe
devbox$ openstack volume show ${TW_PREFIX}-ipxe-probe -c id -c status -f value
```

Then build one probe node with the CD-ROM second in the boot order:

```
devbox$ IPXE_VOL=$(openstack volume show ${TW_PREFIX}-ipxe-probe -c id -f value)
devbox$ openstack server create ${TW_PREFIX}-probe2 \
    --image ${TW_PREFIX}-blank \
    --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node5-prov \
    --block-device uuid=${IPXE_VOL},source_type=volume,destination_type=volume,device_type=cdrom,boot_index=1,delete_on_termination=false \
    --wait

devbox$ sleep 45 && openstack console log show ${TW_PREFIX}-probe2 --lines 80
```

⚠ **`--block-device` with `key=value` pairs needs a reasonably modern `openstackclient`.** If yours rejects the flag, check with `openstack --version` and `openstack help server create | grep -A3 block-device`; older clients want `--block-device-mapping <dev>=<uuid>:volume:1:false`, which cannot express `device_type` or `boot_index` and therefore **cannot run this test at all**. Upgrade the client in your venv rather than trying to work around it — the test is meaningless without those two keys.

| Outcome | Meaning | What to do |
|---|---|---|
| the console reaches `iPXE 1.x.x+ -- Open Source Network Boot Firmware` | 🎉 **adopt this as the mechanism** | see the box below |
| instance builds, but the console halts at `No bootable device` | the libvirt driver ignored `device_type=cdrom`, or the volume is not bootable as a CD | fall back to rescue (§7.5) |
| `openstack server create` is rejected | Nova or this cloud disallows the mapping — **record the exact error**, it is the useful artifact | fall back to rescue (§7.5) |
| iPXE runs but re-runs on every reboot even after §10 | the boot indexes are inverted, or the disk never became bootable | check `openstack server show ${TW_PREFIX}-probe2 -c volumes_attached`; if the order is right, this is a Talos install problem, not a boot-order one (§10) |

✅ **If Test 2 succeeded**, §7.4 creates each node with its own iPXE volume and the `--block-device` line above (there is a ready-made variant in §7.4), and you then **skip §7.5 and §7.6** and power-cycle rather than rescue in §10. `tw-ipxe` stays — it is the source of the volumes.

⚠ **Two honest costs.** Boot order is fixed at instance-create time — there is no `openstack server set --boot-order` — so adopting this later means deleting and recreating the node instances, and you lose the one thing rescue is genuinely good at: flipping a single node to network-boot on demand without touching anything else. Weigh that against never having to think about rescue semantics again. And you are now carrying one small Cinder volume per node, which counts against quota and must be cleaned up in §18.

Clean up:

```
devbox$ openstack server delete ${TW_PREFIX}-probe2 --wait
devbox$ openstack volume delete ${TW_PREFIX}-ipxe-probe
```

📓 **Record both test results in your run log before moving on**, whichever way they went. This is the single most cloud-specific finding in the tutorial, the IaC branches on it, and it is the first thing anyone reproducing this will ask.

## Step 7.2c — Test 4: iPXE as the node's own root disk

*(Found on **4 Aug 2026**, after Test 1 failed on `techwatch-proto` and after §7.2b had been written. It is numbered `7.2c` only because it was discovered last — **run it before Test 2**, because if it works you need no Cinder volume, no `boot_index`, no `device_type`, no microversion and no rescue policy.)*

Everything else in this section is a way of attaching iPXE as *extra* media beside a disk. This one makes iPXE **the disk**, and it works because `boot.ipxe.org` publishes two artifacts where this tutorial had only ever used one:

| Artifact | What it actually is | Needs |
|---|---|---|
| `ipxe.iso` (9 MB) | an El Torito **CD image** | a CD-ROM device — hence rescue (§7.5) or a Cinder volume (§7.2b) |
| **`ipxe.usb` (8 MB)** | a bootable **disk image**: MBR + SYSLINUX for BIOS, *and* a FAT partition containing `EFI/BOOT/BOOTX64.EFI` for UEFI | **nothing** — Nova boots root disks by default |

**Verify that rather than believing the filename.** Two commands, no cloud needed:

```
devbox$ curl -fLO https://boot.ipxe.org/ipxe.usb
devbox$ file ipxe.usb
ipxe.usb: DOS/MBR boot sector; partition 4 : ID=0x4, active, start-CHS (0x0,1,1),
          end-CHS (0x7,63,32), startsector 32, 16352 sectors

devbox$ strings -a ipxe.usb | grep -E 'BOOTX64|BOOTAA64|LDLINUX'
```

The FAT16 partition at sector 32 is labelled `iPXE` and contains, as checked on 4 Aug 2026:

```
/EFI/BOOT/BOOTX64.EFI     1156096      ← x86-64 UEFI
/EFI/BOOT/BOOTIA32.EFI    1051136
/EFI/BOOT/BOOTAA64.EFI    1191424      ← arm64, for §16 and the PTR
/EFI/BOOT/BOOTARM.EFI      882688
/EFI/BOOT/BOOTRISCV*.EFI               ← two of them
/ipxe.lkrn, /ldlinux.sys, /syslinux.cfg, /autoexec.ipxe   ← the BIOS half
```

**Why this works on exactly the firmware that just refused to PXE.** `\EFI\BOOT\BOOTX64.EFI` on a FAT filesystem is UEFI's *removable-media fallback* — the path firmware tries when it has no better boot option. §7.2's probe fell into the EFI Shell because nothing on the machine offered that file. Give the root disk that file and the same OVMF boots it, with no boot order to configure, because a root disk is the one thing Nova always makes bootable.

```
devbox$ openstack image create ${TW_PREFIX}-ipxe-disk \
    --disk-format raw --container-format bare \
    --file ipxe.usb --private \
    --property hw_firmware_type=${TW_FIRMWARE} \
    --property hw_machine_type=q35

devbox$ openstack server create ${TW_PREFIX}-probe3 \
    --image ${TW_PREFIX}-ipxe-disk \
    --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node5-prov \
    --wait

devbox$ sleep 30 && openstack console log show ${TW_PREFIX}-probe3 --lines 60
```

| Console shows | Meaning | What to do |
|---|---|---|
| `iPXE 1.x.x+ -- Open Source Network Boot Firmware`, then `Configuring (net0 …)` and a `172.16.0.5` lease | 🎉 **adopt this. It is the simplest mechanism available** | see the box below |
| iPXE starts but the DHCP configure step fails | the boot half works; this is now a §5 problem, not a §7 one — see common failures |
| `No bootable device`, or the EFI Shell again | the firmware would not boot a FAT16 partition typed `0x04` rather than `0xEF`. Not fatal — rebuild the artifact as a proper ESP (below), or fall through to §7.2b |
| `SYSLINUX …` then iPXE, on a BIOS guest | the BIOS half booted. Also a pass |

### ✅ The result on `techwatch-proto`, 4 Aug 2026 — Test 4 passed

This is the mechanism. Captured from `openstack console log show tw-probe3`, escape codes stripped:

```
BdsDxe: loading  Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0)
iPXE initialising devices...
file:autoexec.ipxe... Not found (https://ipxe.org/7f4de18e)
file:/autoexec.ipxe... ok

iPXE 2.0.0+ (ga1992) -- Open Source Network Boot Firmware -- https://ipxe.org
Features: DNS HTTP HTTPS iSCSI TFTP VLAN SRP AoE EFI Menu

net0: 52:54:00:be:ef:05 using virtio-net on 0000:03:00.0 (Ethernet) [open]
  [Link:up, TX:0 TXE:0 RX:0 RXE:0]
Configuring (net0 52:54:00:be:ef:05)...... ok
net0: 172.16.0.5/255.255.255.0 gw 172.16.0.254
Next server: 172.16.0.254
Filename: http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:05
http://172.16.0.254:8081/boot/v1/bootscript... ok
bootscript : 127 bytes [script]
```

**Everything in that capture is a checkpoint from somewhere else in the tutorial, reached at once:**

| Line | Proves | Was supposed to be proved in |
|---|---|---|
| `starting Boot0001 "UEFI Misc Device"` | the firmware boots `ipxe.usb` as a plain root disk | §7.2c, this test |
| `iPXE 2.0.0+` | iPXE is running with no rescue, no CD-ROM, no Cinder | §7.5's checkpoint |
| `net0: 52:54:00:be:ef:05` | the MAC-pinned port from §3.4 is the guest's NIC | §3.4 |
| `Configuring … ok`, `172.16.0.5` | **CoreDHCP answered**, and with the address SMD holds for this MAC — so Neutron DHCP is off, port security is off, and §6's inventory loaded | §3.2, §3.3, §5.7, §6 |
| `Filename: http://172.16.0.254:8081/boot/v1/bootscript?mac=…` | `coresmd` handed out the BSS URL rather than a bootloop lease | §5.7 |
| `bootscript … 127 bytes [script]` | **BSS answered** | §9 |

Two details worth keeping:

- **The FAT16 partition was accepted as-is.** The shell's mapping table showed `FS0: … HD(4,MBR,0x00000000,0x20,0x3FE0)` — OVMF offered `\EFI\BOOT\BOOTX64.EFI` from a partition typed `0x04`, not `0xEF`. The `mtools` ESP recipe above was not needed on this cloud. Try the stock artifact first anywhere else, too.
- **iPXE is 2.0.0+, not 1.x.** Expected-output blocks elsewhere in this tutorial say `iPXE 1.x.x+`; read them as "whatever `boot.ipxe.org` is shipping". The `file:/autoexec.ipxe... ok` line before the banner is the stock artifact's own 120-byte script, which does nothing but offer `Ctrl-B` for two seconds and then `autoboot` — worth knowing you are running it, since §7.1's supply-chain warning applies to `ipxe.usb` exactly as it did to `ipxe.iso`.

⚠ **What comes *after* `bootscript : 127 bytes` on a cluster where §9 has not been done yet:**

```
https:///apis/bss/boot/v1/bootscript... Error 0x3e11618e (https://ipxe.org/3e11618e)
Could not boot image: Error 0x3e11618e
BdsDxe: failed to start Boot0001 … Not Found
BdsDxe: loading Boot0002 "EFI Internal Shell"
Shell>
```

**This is the expected failure — with one detail that is not.** BSS has no boot parameters for this MAC yet, so it returns its fallback script, and that script chains to `https:///apis/bss/boot/v1/bootscript` — **with no hostname**. iPXE error `0x3e11618e` is "DNS name does not exist" (`net/udp/dns.c`), which is exactly what an empty host produces. §9 replaces this script with a real one, so it does not block anything; but the fallback is meant to be a retry loop for nodes BSS does not know yet, and as configured here it cannot retry. **Written up as [`issues/003`](issues/003-bss-ipxe-server-unexpanded-system-url.md)** — BSS was handed the literal string `${SYSTEM_URL}` as its own advertised hostname, and the same line is the `:boot_retry` tail of every *working* boot script too. The node then drops to the EFI Shell and idles — harmless, but it holds its port until deleted.

✅ **If Test 4 succeeded**, §7.4 creates each node with `--image ${TW_PREFIX}-ipxe-disk` instead of `--image ${TW_PREFIX}-blank` and changes nothing else. **Skip §7.2b, §7.3, §7.5 and §7.6.** In §10 the "PXE button" is `openstack server rebuild --image ${TW_PREFIX}-ipxe-disk <node>` — which is [OVB's](https://openstack-virtual-baremetal.readthedocs.io/en/latest/host-cloud/prepare.html) mechanism, not an invention of ours.

**Why this is not the reinstall loop [DL-002](DECISION-LOG.md) rejects as option C.** Option C boots iPXE from a read-only **CD** that stays bootable forever, so every power cycle re-provisions and BSS has to hold "is this node installed?". Here iPXE lives on the **root disk that Talos is about to install onto**. Talos overwrites it, and from the next boot the disk boots Talos. *The loop terminates by construction, because the thing being installed destroys the installer's bootloader.* That is the same self-terminating property `--boot uefi,hd,network` has in the libvirt lab, reached from the other direction.

⚠ **Three honest costs, and one real hazard.**

- The node's root disk no longer *starts* empty, so "has this node been provisioned?" stops being "is the disk blank?" and becomes "does it still boot iPXE?". `tw-blank` remains useful for §7.2 only.
- Re-provisioning is `server rebuild`, which **wipes the root disk**. That is what re-provisioning means, but there is no non-destructive way to network-boot one node for a look around — the one thing rescue is genuinely better at.
- 🛑 **The hazard: if Talos ever installs to a disk other than the one holding iPXE, you get option C's loop after all** — iPXE survives, wins the boot again, and reinstalls on every cycle. With one disk per node this cannot happen. If you attach a Cinder volume for container images (see §7.4's disk-size warning), make sure §8's `diskSelector` still resolves to the *root* disk, and check it before you power-cycle.
- Rescue still has to work for [appendix A](appendix-a-redfish-sushy.md), so run §7.5 once anyway if you intend to do it.

<details>
<summary>If the firmware refused the FAT16 partition — rebuild it as a proper ESP</summary>

`ipxe.usb`'s partition is type `0x04` (FAT16), not `0xEF` (EFI System Partition). EDK II normally offers `\EFI\BOOT\BOOTX64.EFI` from any FAT filesystem it can see, which is why this is worth trying as-is — but if your firmware is stricter, build the image yourself. On the devbox, with `mtools` and `parted`:

```
devbox$ sudo dnf install -y mtools parted
devbox$ curl -fLO https://boot.ipxe.org/ipxe.usb
devbox$ truncate -s 16M esp.raw
devbox$ parted -s esp.raw mklabel gpt \
    mkpart ESP fat32 1MiB 15MiB set 1 esp on
devbox$ mformat -i esp.raw@@1M -F ::
devbox$ mcopy -i ipxe.usb@@16384 -s ::/EFI ./            # lift EFI/ out of ipxe.usb
devbox$ mmd   -i esp.raw@@1M ::/EFI ::/EFI/BOOT
devbox$ mcopy -i esp.raw@@1M EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/
devbox$ openstack image create ${TW_PREFIX}-ipxe-disk --disk-format raw \
    --container-format bare --file esp.raw --private \
    --property hw_firmware_type=uefi --property hw_machine_type=q35
```

This is UEFI-only by construction, so record it as such — a BIOS node would need `ipxe.usb` unmodified.

</details>

Clean up:

```
devbox$ openstack server delete ${TW_PREFIX}-probe3 --wait
```

📓 **Record this result in the run log next to Tests 1 and 2.** If it passes it is the mechanism, and it is the cheapest finding in the section.

## Step 7.3 — Upload iPXE to Glance as a rescue image

⏭ **Skip this step entirely if Test 1 (§7.2) or Test 4 ([§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk)) succeeded** — under Test 1 the firmware network-boots on its own and `coresmd`'s TFTP server provides the iPXE binary; under Test 4 the iPXE binary is the node's root disk and `tw-ipxe-disk` replaces this image entirely. **On this cloud, Test 4 succeeded, so this step is not on the path.** You need `tw-ipxe` only for Test 2's Cinder volumes, for rescue, or for [appendix A](appendix-a-redfish-sushy.md).

```
devbox$ openstack image create ${TW_PREFIX}-ipxe \
    --disk-format iso --container-format bare \
    --file ipxe.iso --private \
    --property hw_rescue_device=cdrom \
    --property hw_rescue_bus=scsi \
    --property hw_firmware_type=${TW_FIRMWARE}
```

Property by property:

- **`hw_rescue_device=cdrom`** — the media is an ISO, so present it as a CD-ROM.
- **`hw_rescue_bus=scsi`** — which bus to attach it to. This is the value most likely to need changing for your cloud, so it gets its own note below.
- **`hw_firmware_type`** — matches what §1.5 found on the Rocky image. It must agree with the node instances' firmware, or the rescue media won't be bootable by the firmware that's running.
- **`--disk-format iso`** — Glance needs to know this is an ISO, not a disk.
- **`--private`** — visible only to our project. Never `--public`: that would publish it cloud-wide, which is not ours to do.

⚠ **`hw_rescue_bus` is the value to fiddle with.** Nova accepts `scsi`, `virtio`, `ide` and `usb`, and which ones work depends on the machine type your cloud uses. On the modern `q35` machine type **there is no IDE bus at all**, so `ide` — which the Nova documentation suggests as a fallback — will fail there. Try in this order:

| `hw_rescue_bus` | When it works |
|---|---|
| `scsi` | usually; needs a virtio-scsi controller, which q35 guests normally have |
| `usb` | Nova's own recommended default; a USB CD-ROM. Try this second |
| `ide` | only on the older `pc` machine type |
| `virtio` | virtio has no CD-ROM concept — pair it with `hw_rescue_device=disk` instead of `cdrom`, and note that iPXE's `ipxe.usb` is the better artifact for a disk-style attachment |

Change it with `openstack image set ${TW_PREFIX}-ipxe --property hw_rescue_bus=usb` and retry §7.5. Record what worked in your run log — the IaC needs to know.

## Step 7.4 — Create the node instances

One instance per node, each on its pre-created MAC-pinned port from §3.4, each booting from the blank image so its disk starts empty.

🛑 **This is the point of no return for the boot-device decision.** Boot order can only be set at create time, so which of §7.2/§7.2b/§7.5 you are on changes the command below. Pick from this table and use the matching variant:

| Test result | Create command | Then |
|---|---|---|
| **Test 1 passed** — firmware PXEs unaided | the plain command below | skip §7.5, §7.6; power-cycle in §10 |
| **Test 4 passed** — iPXE is the root disk | the plain command below, with `--image ${TW_PREFIX}-ipxe-disk` in place of `--image ${TW_PREFIX}-blank` | skip §7.2b, §7.3, §7.5, §7.6; `server rebuild` is the PXE button in §10 |
| **Test 2 passed** — iPXE CD-ROM at `boot_index=1` | the plain command **plus** the `--block-device` line in the variant below | skip §7.5, §7.6; power-cycle in §10 |
| **both failed** — rescue is the mechanism | the plain command below | §7.5 onwards as written |

Start with the Kubernetes control-plane node:

```
devbox$ openstack server create ${TW_PREFIX}-cp1 \
    --image ${TW_PREFIX}-blank \
    --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node1-prov \
    --wait
```

Then the workers — as many as quota allows. Two is enough to prove scheduling:

```
devbox$ for i in 2 3; do
    openstack server create ${TW_PREFIX}-w$((i-1)) \
      --image ${TW_PREFIX}-blank \
      --flavor ${TW_FLAVOR_WORKER} \
      --port ${TW_PREFIX}-node${i}-prov \
      --wait
  done
```

### Variant — if Test 2 (§7.2b) is the mechanism

Each node gets its own 1 GB iPXE CD-ROM volume, second in the boot order. Create the volumes first, then the instances:

```
devbox$ for n in cp1 w1 w2; do
    openstack volume create --image ${TW_PREFIX}-ipxe --size 1 ${TW_PREFIX}-ipxe-$n
  done

devbox$ for spec in "cp1 1 ${TW_FLAVOR_CP}" \
                    "w1  2 ${TW_FLAVOR_WORKER}" \
                    "w2  3 ${TW_FLAVOR_WORKER}"; do
    read -r name idx flavor <<< "$spec"
    vol=$(openstack volume show ${TW_PREFIX}-ipxe-$name -c id -f value)
    openstack server create ${TW_PREFIX}-$name \
      --image ${TW_PREFIX}-blank \
      --flavor $flavor \
      --port ${TW_PREFIX}-node${idx}-prov \
      --block-device uuid=${vol},source_type=volume,destination_type=volume,device_type=cdrom,boot_index=1,delete_on_termination=false \
      --wait
  done
```

⚠ **`delete_on_termination=false` is deliberate.** Deleting and recreating a node instance is routine in §10; having its iPXE volume survive means you do not rebuild it every time. The cost is that §18's teardown must delete the three volumes explicitly — add them to your run log's cleanup list now, while you are thinking about it.

Note what these instances **do not** have:

- **No floating IP and no external network.** They sit only on the provisioning wire, exactly like real compute nodes on a management VLAN. Their only route out is the head node's NAT (§5.12). You reach them through the head, never directly.
- **No SSH key.** Talos has no SSH.
- **No user-data.** Talos ignores cloud-init entirely; its configuration arrives via the `talos.config` kernel argument (§8), which is BSS's job. This is deliberate: if we let Nova's metadata configure the node, OpenCHAMI would stop being the source of truth and the whole exercise would prove nothing.

🔀 **Deviation from the libvirt lab.** The lab's `virt-install` gave nodes `--disk size=10` and `--boot uefi,hd,network` — one command that both created the disk and set a boot order of "disk first, network as fallback". Neither half has a Nova equivalent: the root disk comes from the flavor, and boot order is what this entire section is working around.

⚠ **Disk size comes from the flavor, and Talos needs room.** Talos itself is small, but the node also holds container images: the Kubernetes control plane on `cp1`, and on workers the vLLM image (several GB) plus model weights. The TechWatch design allows 50 GB for Talos + Kubernetes and 50–100 GB for images and weights. If your worker flavor's disk is under ~40 GB, §14 will fail on disk pressure; attach a Cinder volume and point Talos's ephemeral partition at it, or pick a bigger flavor.

Also note the ordering constraint: **do not rescue anything yet.** §§8 and 9 have to publish the Talos assets and the BSS boot payloads first, or a node will network-boot, ask BSS what to do, and be told nothing.

🛑 **If Test 4 is your mechanism, that constraint moves — `server create` *is* the rescue.** With iPXE on the root disk there is no separate "make it network-boot" step: an instance PXEs the moment it exists. So on a first run, **do §8 and §9 before this step**, and come back. Nothing breaks if you create the nodes early — they fetch BSS's empty fallback script, fail, and idle at the EFI Shell, exactly as `tw-probe3` did in §7.2c — but you then have to `openstack server reboot --hard` each one after §9, and a node idling at a firmware prompt looks identical to a node that is genuinely broken. Creating them once, after BSS has something to say, means the first boot you ever watch is the real one.

## Step 7.5 — Dry-run the PXE button

⏭ **Skip if Test 1, Test 2 or Test 4 succeeded** — on this cloud that means skip it now — **but come back and run it once anyway, later, if you intend to do [appendix A](appendix-a-redfish-sushy.md).** sushy-tools implements Redfish `BootSourceOverrideTarget=Pxe` on its Nova driver *by putting the instance into rescue mode with an iPXE image*, so appendix A needs rescue to work on this cloud regardless of what the main path uses. Better to find out now than after installing the emulators.

You can safely test that rescue *boots iPXE* before BSS has anything to say. The node will get as far as asking, fail to be told anything useful, and stop — which proves the OpenStack half of the chain in isolation.

```
devbox$ openstack --os-compute-api-version 2.87 server rescue \
    --image ${TW_PREFIX}-ipxe ${TW_PREFIX}-cp1

devbox$ openstack server show ${TW_PREFIX}-cp1 -c status -f value
RESCUE

devbox$ sleep 45 && openstack console log show ${TW_PREFIX}-cp1 --lines 60
```

✅ **Checkpoint — the important one in this section**

```
⟨captured on first run⟩

Expect to see, in roughly this order:
  iPXE 1.x.x+ -- Open Source Network Boot Firmware -- https://ipxe.org
  Features: DNS HTTP iSCSI TFTP ...
  net0: 52:54:00:be:ef:01 using virtio-net ...
  Configuring (net0 52:54:00:be:ef:01)...... ok
  net0: 172.16.0.1/255.255.255.0 gw 172.16.0.254
```

That last line is worth more than anything else in this tutorial so far. It proves, all at once:

- Nova rescue boots the iPXE media (§7.3's properties are right);
- the instance is on the provisioning wire with the MAC we pinned (§3.4);
- **CoreDHCP answered** — Neutron's DHCP is genuinely off and port security is genuinely disabled (§3.2, §3.3);
- and it answered with `172.16.0.1`, the address SMD holds for this MAC (§6) — not a `172.16.0.200`-range bootloop lease.

If the address is in the `.200–.250` range, CoreDHCP does not recognise the MAC: either §6 didn't load, or the coresmd cache is stale or broken. Go back to §6's checkpoint before doing anything else.

After iPXE gets its lease it will try to fetch a boot script and fail — expected, that's §9. Put the node back:

```
devbox$ openstack server unrescue ${TW_PREFIX}-cp1
devbox$ openstack server show ${TW_PREFIX}-cp1 -c status -f value
ACTIVE
```

## Step 7.6 — Two small helper scripts

⏭ **Not on the path if Test 4 succeeded** — these two wrap `server rescue` / `server unrescue`, and option G uses neither. Its equivalent is a single command, `openstack server rebuild --image ${TW_PREFIX}-ipxe-disk <node>`, and there is deliberately no `diskboot.sh` counterpart because returning to disk boot is just a reboot — Talos overwrote the iPXE bootloader when it installed. If you want the pair anyway for symmetry with [appendix A](appendix-a-redfish-sushy.md), write them as below and add a rebuild variant; the [templates](templates/) carry the rescue versions only, and 🛑 **a rebuild wipes the root disk, so a `pxeboot.sh` built on it is a re-provision command, not a "have a look around" command.** Name it accordingly.

You will run these sequences a lot in §10 and whenever you re-provision. Write them once:

```
devbox$ cat > ~/tw/pxeboot.sh << 'EOF'
#!/usr/bin/env bash
# pxeboot.sh <instance> — make an instance network-boot now.
# The manual equivalent of Redfish: BootSourceOverrideTarget=Pxe + Reset.
set -euo pipefail
: "${TW_PREFIX:?source ~/tw/tw-env.sh first}"
node="$1"
status=$(openstack server show "$node" -c status -f value)
[ "$status" = RESCUE ] && openstack server unrescue "$node" && sleep 5
openstack --os-compute-api-version 2.87 server rescue \
    --image "${TW_PREFIX}-ipxe" "$node"
echo "$node is network-booting; watch with:"
echo "  openstack console log show $node --lines 60"
EOF

devbox$ cat > ~/tw/diskboot.sh << 'EOF'
#!/usr/bin/env bash
# diskboot.sh <instance> — return an instance to booting from its own disk.
# The manual equivalent of Redfish: BootSourceOverrideTarget=Hdd + Reset.
set -euo pipefail
node="$1"
status=$(openstack server show "$node" -c status -f value)
if [ "$status" = RESCUE ]; then
  openstack server unrescue "$node"
else
  echo "$node is $status, not RESCUE — nothing to do"
fi
EOF

devbox$ chmod +x ~/tw/pxeboot.sh ~/tw/diskboot.sh
```

Both are in [`templates/`](templates/). They are deliberately thin: the point is that "network-boot this machine" really is one API call, which is why appendix A can replace them with a Redfish endpoint without changing anything else.

## Step 7.7 — Fallback, if rescue is unavailable

⏭ **Superseded by [§7.2c](#step-72c--test-4-ipxe-as-the-nodes-own-root-disk) — try that first.** This fallback and option G are the same idea (boot iPXE from storage the node always has) with one decisive difference: here iPXE is a *read-only* image beside a separate blank volume, so it stays bootable forever and BSS must hold "is this node installed?"; in §7.2c iPXE is the disk Talos installs onto, so the loop ends by itself. If tenant rescue is forbidden on your cloud, §7.2c is the answer, and this section is what to read only if §7.2c *also* fails.

If §7.5 failed with a **policy** error (`Policy doesn't allow os_compute_api:os-rescue to be performed`), your cloud does not let tenants rescue instances. Ask your admin whether it can be enabled — it is a per-instance, reversible operation and a reasonable thing for a prototyping project to have.

If the answer is no, use this instead: **boot the node from iPXE permanently, and let BSS decide.**

```
devbox$ openstack server create ${TW_PREFIX}-cp1 \
    --image ${TW_PREFIX}-ipxe \
    --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node1-prov \
    --block-device source_type=blank,destination_type=volume,volume_size=40,boot_index=-1,delete_on_termination=true \
    --wait
```

The instance boots iPXE every time; a blank 40 GB Cinder volume is attached for Talos to install onto. The consequence is that **BSS becomes stateful**: after a node is installed, its boot payload must change from "boot Talos" to "boot from your own disk", which in iPXE is:

```
#!ipxe
sanboot --no-describe --drive 0x80
```

So §9 gains a third payload and §10 gains a step: after Talos installs, repoint that node's BSS entry at the `sanboot` script. Re-provisioning means pointing it back at the Talos script.

| | Rescue (§7.5) | iPXE-always (this fallback) |
|---|---|---|
| "Is this node installed?" lives in | Nova (rescued or not) | BSS (which payload is set) |
| Maps onto Redfish | directly — this *is* what sushy-tools does | not really; a real BMC has boot-order control |
| Extra moving parts | none | one more BSS payload, and a state transition to remember |
| Talos install target | the instance's own root disk | an attached Cinder volume |

Prefer rescue. Document which one you used, because §10, appendix A and the IaC all branch on it.

## ✅ Checkpoint for the section

```
devbox$ openstack server list -c Name -c Status -c Networks
⟨captured on first run — expect tw-head (ACTIVE, both networks) and
  tw-cp1/tw-w1/tw-w2 (ACTIVE, tw-prov only)⟩

devbox$ openstack image list --private -c Name -f value
⟨expect tw-blank and tw-ipxe-disk; also tw-ipxe if you went the rescue route⟩

devbox$ openstack server show ${TW_PREFIX}-cp1 -c hostId -c flavor -f value
⟨hostId must match tw-head's, and the flavor must carry
  extra_specs.trait:CUSTOM_TECHWATCH_PROTO='required'⟩

devbox$ for n in head cp1 w1 w2; do
    printf '%-8s %s\n' $n "$(openstack server show ${TW_PREFIX}-$n -c hostId -f value)"
  done
⟨all four identical — that is your one hypervisor⟩
```

⚠ **Not `OS-EXT-SRV-ATTR:host` — it prints `None` for a project member.** Confirmed again on 4 Aug 2026: the field is behind an admin-only Nova policy ([§1.6](01-safety-and-access.md), [§4](04-head-node-instance.md)), so the client renders it `None` and you learn nothing. `hostId` is the member-visible substitute: an opaque per-project hash of the host, useless for *naming* the hypervisor but exactly right for asking "is this on the same host as everything else?". The flavor's trait is what does the actual pinning, so check that it is still there.

## Common failures

| Symptom | Cause / fix |
|---|---|
| §7.2: `Invalid image metadata` or the instance ERRORs after setting `hw_firmware_type=uefi` | this cloud has no UEFI firmware for guests, or restricts `hw_machine_type`. Unset both properties and go to §7.2b — Test 1 cannot be run here |
| §7.2: console log is empty | the instance halted before writing anything, or the console device disagrees with the firmware. Wait 60 s and retry; if still empty, try `--lines 200`, then treat it as a fail |
| §7.2: Test 1 failed and you cannot tell whether the firmware refused or the NIC has no boot ROM | run the `hw_boot_menu` diagnostic above — one image property, one hard reboot, one look at the graphical console |
| §7.2: nodes sit at a boot prompt on every boot in §10 | `hw_boot_menu` was left set on `tw-blank`: `openstack image unset ${TW_PREFIX}-blank --property hw_boot_menu` |
| §7.2b: `Block Device Mapping is Invalid` | Nova rejected the mapping — most often `device_type=cdrom` on a volume, or a `boot_index` clash. Record the message verbatim; it is the finding. Fall back to rescue |
| §7.2b: `Volume … did not finish being created` | Cinder could not convert the ISO, or there is no volume quota. `openstack volume show` for the fault, and `openstack quota show` for the limits |
| §7.2b: instance builds but the CD-ROM is absent from the guest | the libvirt driver silently dropped `device_type`. Confirm with `openstack server show -c volumes_attached`; if the volume *is* attached but not booted, the boot order was not honoured — fall back to rescue |
| `Policy doesn't allow os_compute_api:os-rescue` | tenant rescue disabled — §7.7 fallback |
| Rescue succeeds but the console shows the old OS or `No bootable device` | the rescue media wasn't bootable by this firmware: check `hw_firmware_type` matches, then work down the `hw_rescue_bus` table in §7.3 |
| `Invalid image metadata: hw_rescue_bus` | your Nova is older than Ussuri, or the value isn't accepted — drop to legacy rescue (`openstack server rescue`, no microversion) and expect disk renumbering, which §8's `diskSelector` already protects you from |
| iPXE starts but `Configuring (net0 …)` fails / times out | CoreDHCP isn't answering. In order: is `coresmd-coredhcp` active? Is `enable_dhcp` false on the subnet? Is `port_security_enabled` false on the node's port? Is the MAC in SMD? |
| iPXE gets a `172.16.0.2xx` address | bootloop lease — the MAC is unknown to SMD. §6 |
| `https:///apis/bss/boot/v1/bootscript... Error 0x3e11618e` after BSS answers | BSS is advertising `${SYSTEM_URL}` as its own hostname, so its retry URL has no host — [`issues/003`](issues/003-bss-ipxe-server-unexpanded-system-url.md). Expected before §9, and it blocks nothing; fix it before you rely on any retry path |
| `openstack server stop` fails on a node | it's in RESCUE; `unrescue` first (see the ⚠ above) |
| Instance `ERROR` with `Invalid disk_format 'raw'` on `tw-blank` | some clouds restrict tenant image formats — try `--disk-format qcow2` with a 1 MB qcow2 made by `qemu-img create -f qcow2 blank.qcow2 1M` |
| `No valid host was found` | quota or capacity; or the worker flavor lacks the isolation trait / asks for NUMA or hugepage properties the host can't satisfy (§1.5). Reduce the number of workers; do **not** change availability zone or swap to an untraited flavor to route around it |

## References

Everything this section's design rests on, so that a reader can check it rather than believe it. The claim being defended is the one in Concepts: **Nova cannot put a NIC in a guest's boot order.**

**OpenStack documentation**

- [Nova — Boot an instance using PXE](https://docs.openstack.org/nova/latest/user/boot-instance-using-PXE.html) — rescue mode with an iPXE image, and nothing else
- [Nova — Block device mapping](https://docs.openstack.org/nova/latest/user/block-device-mapping.html) — `boot_index`, `device_type`, "only if they are of different types - eg a disk and CD-ROM"
- [Nova — Rescue an instance](https://docs.openstack.org/nova/latest/user/rescue.html) and [compute API microversion history](https://docs.openstack.org/nova/latest/reference/api-microversion-history.html) — 2.87 and stable device rescue
- [Glance — useful image properties](https://docs.openstack.org/glance/latest/admin/useful-image-properties.html) — `hw_firmware_type`, `hw_machine_type`, `hw_rescue_device`, `hw_rescue_bus`, `hw_boot_menu`
- [sushy-tools — dynamic emulator](https://docs.openstack.org/sushy-tools/latest/user/dynamic-emulator.html) — `SUSHY_EMULATOR_OS_RESCUE_PXE_BOOT`, why [appendix A](appendix-a-redfish-sushy.md) needs rescue to work here regardless

**Why it cannot be done, from the horse's mouth**

- [`[nova] Spawning instance that will do PXE booting`](https://lists.openstack.org/pipermail/openstack-discuss/2021-December/026191.html) — Nova core reviewer's answer, December 2021: native support would need "a neutron extension to mark ports as bootable which nova would read"
- Three blueprints, none delivered: [`pxe-boot-instance`](https://blueprints.launchpad.net/nova/+spec/pxe-boot-instance), [`libvirt-empty-vm-boot-pxe`](https://blueprints.launchpad.net/nova/+spec/libvirt-empty-vm-boot-pxe), [`boot-order-for-instance`](https://blueprints.launchpad.net/nova/+spec/boot-order-for-instance) (which proposed exactly `nova boot --nic bootindex=N`; registered 2014, Not started)
- [QEMU — managing device boot order with `bootindex`](https://www.qemu.org/docs/master/system/bootindex.html) — a device with no `bootindex` "won't be considered and network boot will fail"
- [libvirt — domain XML boot elements](https://libvirt.org/formatdomain.html#bios-bootloader) — the `<boot order='…'/>` element Nova never emits on an `<interface>`
- [OVB — preparing the host cloud](https://openstack-virtual-baremetal.readthedocs.io/en/latest/host-cloud/prepare.html) — the canonical "instances as bare metal" project needs an out-of-tree Nova patch or per-deployment image rebuilds

**Nova source, checked 4 Aug 2026 against master (33.1.0.dev)**

The `curl | grep` commands that produce these are in [DL-002.1a](DECISION-LOG.md#dl-0021a-verified-in-novas-source-not-only-in-its-documentation); prefer them to the line numbers, which drift.

| What | Where |
|---|---|
| `boot_order` exists on the **disk** config class | [`config.py:1228`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1228), rendered at [1386](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1386) |
| …and **not** on the interface config class | [`config.py:1884`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L1884) — read the attribute list |
| The only boot devices Nova can name: `hd`, `cdrom`, `fd` | [`blockinfo.py:92`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L92) |
| …fed only from block devices carrying a `boot_index` | [`get_boot_order()`, blockinfo.py:733](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L733), called at [`driver.py:7413`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py#L7413) |
| `device_type=cdrom` on a volume survives to the guest (Test 2) | [`blockinfo.py:372`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L372), [`:106`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L106) |
| `hw_boot_menu` / `hw:boot_menu` → `<bootmenu enable='yes'/>` | [`driver.py:7381`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py#L7381), [`config.py:3250`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/config.py#L3250) |
| Rescue media is given `boot_order='1'` — i.e. rescue *is* a storage `bootindex` | [`driver.py:6294`](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/driver.py#L6294) |
| `hw_rescue_device` / `hw_rescue_bus` validation (§7.3's table) | [`get_rescue_device()`, blockinfo.py:747](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L747), [`SUPPORTED_DEVICE_BUSES`, :96](https://opendev.org/openstack/nova/src/branch/master/nova/virt/libvirt/blockinfo.py#L96) |

**In this tutorial**

- [`DECISION-LOG.md`](DECISION-LOG.md) — DL-002, the whole argument, the six options, and the revisit triggers
- [`INVESTIGATION-network-boot.md`](INVESTIGATION-network-boot.md) — how the question came to be asked, and what the prior art does
- [Appendix A](appendix-a-redfish-sushy.md) — the Redfish/sushy-tools version of §7.6's two scripts
- [Appendix C](appendix-c-alternatives.md) — the alternatives, argued
- [The libvirt lab](../ochami-macos-libvirt-talos/README.md) — where all of this is one `virt-install --boot uefi,hd,network`

---

Back to the runnable path: **[§7 — Node instances and network boot](07-node-instances-and-ipxe.md)**, then [§8 — Talos assets and machine config](08-talos-assets-and-config.md).
