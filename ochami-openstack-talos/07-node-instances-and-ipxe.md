# §7 — Node instances and network boot

*(Time: ~20 minutes, all on the devbox. **This is the one section with no upstream equivalent** — it exists entirely because clouds don't network-boot. It is short; establishing *why* it is this short took a day, and that work is in [appendix F](appendix-f-network-boot-investigation.md).)*

```
devbox$ cd ~/tw && source ~/tw/tw-env.sh
```

**Before you start**, three things this section assumes. Thirty seconds now, or a confusing failure in §7.3:

```
devbox$ echo "$TW_PREFIX | $TW_FIRMWARE | $TW_FLAVOR_CP | $TW_FLAVOR_WORKER"
tw | bios | techwatch-proto-cp | techwatch-proto-worker

devbox$ for i in 1 2 3; do
    openstack port show ${TW_PREFIX}-node${i}-prov -c name -c status -c device_id -f value
  done
⟨each: an empty device_id, the name, and DOWN⟩

devbox$ openstack flavor show ${TW_FLAVOR_WORKER} -c disk -f value
Failed to get access projects list for flavor 'techwatch-proto-worker': ForbiddenException: 403 …
30
```

**You need admin to read a flavor's *full* record** — the `403` above is Nova refusing to tell a member which projects a private flavor is shared with. The disk, RAM and vCPU figures come back regardless, so the number above is usable; elevate only if you want the access list or you are auditing what the project actually owns:

```
devbox$ tw_admin                                    # 15-minute elevation
 ADMIN  devbox$ openstack flavor show ${TW_FLAVOR_WORKER}
 ADMIN  devbox$ openstack flavor list -c Name -c RAM -c Disk -c VCPUs
 ADMIN  devbox$ tw_member                           # drop straight back
```

🛑 **Do not stay elevated**, and do not run `tofu` or `ansible` in an elevated shell — `tw_admin` says so itself. See [§1.6](01-safety-and-access.md) and [`runbooks/manage-application-credentials.md`](runbooks/manage-application-credentials.md).

⚠ **`TW_FIRMWARE` describes the *head node's* image, not the nodes'.** §1.5 reads it off the pre-existing Rocky image, so `bios` here means Glance has no `hw_firmware_type` on that image and Nova defaults to BIOS. **It is not the value to put on the node image** — §7.2 pins that explicitly, and the two are allowed to differ because nothing couples them. (The variable that §9's `console=` uses is `TW_CONSOLE`, which is a separate thing.)

📌 **The 403 from `flavor show` is noise, and the value still prints.** A project member may read a flavor but not list which projects it is shared with, so `openstack flavor show` reports the `os-flavor-access` failure and then gives you the fields anyway. Do not elevate to admin for this; the `30` is the answer.

⚠ **A port with a non-empty `device_id` is still attached to something** — most likely a probe instance from [appendix F](appendix-f-network-boot-investigation.md). Delete that instance before continuing.

📌 **Observed here on 4 Aug 2026: 30 GB of disk on both the worker and the control-plane flavor** — against a TechWatch design that allows 50 GB for Talos + Kubernetes and 50–100 GB for images and weights. **It is very probably enough for what this tutorial actually does**, because §14 serves `Qwen2.5-0.5B-Instruct` at about 1 GB of weights; the space goes on the vLLM CPU container image, not the model. Nothing to do now, and nothing to change in §7 — but it is an open question with someone else's answer in it, so it is recorded as [DL-005](DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) rather than left as a warning nobody owns. Put the number in your run log while you are looking at it.

## Concepts

§0's decision 2, in one sentence: **OpenStack cannot be told to boot an instance from the network, so we make iPXE the node's root disk.** That's it. Everything after iPXE starts is ordinary, unmodified OpenCHAMI.

### In plain terms — what we fake, and what we don't

**How a real server network-boots.** The firmware knows how to use the network card. At power-on it does DHCP, downloads a small bootloader over the wire, and runs it. That bootloader asks a server what operating system to boot, downloads it and starts it. Nothing comes off the machine's own disk; the node's whole identity arrives over the network.

**What a cloud cannot do.** That very first step is the one Nova has no way to express. It boots an instance from an image or from a volume, and there is no way to say "try the network card first" — Nova only ever assigns a boot order to *storage*, and the limitation is in how it generates the guest's XML, below the API, so no microversion, image property or policy change reaches it. On Digital Labs it is worse than a missing API: the guest firmware has no network-boot support at all, so even asking nicely gets you nothing.

**So we stop trying to fetch the bootloader over the network, and hand it to the machine locally.** `ipxe.usb` is literally the image you would write to a USB stick to make any computer network-boot. We give it to Nova as the instance's **root disk**. The firmware sees an ordinary bootable disk — the one thing Nova is always happy to boot — and runs it. iPXE starts, and from that moment everything proceeds as it would on real hardware.

**Only the first 8 MB is local. Everything that matters still comes over the network:**

| Step | Where it comes from | On real hardware |
|---|---|---|
| iPXE itself | **the local disk** ← the only faked part | fetched from the NIC's boot ROM over TFTP |
| "who am I, what is my address?" | **the network** — CoreDHCP answers with the address SMD holds for that MAC | identical |
| "what should I boot?" | **the network** — BSS, over HTTP, keyed on the MAC | identical |
| kernel and initramfs | **the network** — the head node's S3 store (§8) | identical |
| the machine config | **the network** — a `talos.config` URL in the kernel arguments (§9) | identical |

So we never PXE-boot in the strict sense, and we don't need to. What matters is that **iPXE runs and then asks OpenCHAMI who it is and what to boot**, and that entire conversation is unmodified. The part we fake is precisely the part a real server does with one Redfish call — "set boot device to PXE, then reset" — which is why it is disposable the moment hardware with real BMCs arrives. See the table in §0 and [appendix A](appendix-a-redfish-sushy.md).

**And the awkward part solves itself.** The "USB stick" *is* the disk Talos installs onto. Talos overwrites it, so from the next boot the node boots Talos from its own disk and never network-boots again unless we ask it to. Every other mechanism needs extra machinery to stop a node reinstalling itself on every power cycle — a CD-ROM or a rescue image cannot be overwritten, so something has to remember which nodes are provisioned. Here, nothing has to remember anything.

### The chain you are about to build

![Nova only ever assigns a boot index to storage, so it cannot put a NIC in a guest's boot order — and the limitation is in how it generates the guest's XML, below the API, so no microversion or image property reaches it. The way round it is to make iPXE itself the storage device, which takes three commands: download ipxe.usb, an 8 MB hybrid disk image carrying an MBR bootloader for BIOS and EFI/BOOT/BOOTX64.EFI for UEFI (§7.1); upload it to Glance as a private raw image (§7.2); and create each node from that image on its MAC-pinned port (§7.3), which is itself the PXE button. The firmware then boots what looks to it like an ordinary disk, and from that point the six-step chain is unmodified OpenCHAMI: iPXE starts; CoreDHCP answers with the address SMD holds for that MAC and the lease carries the BSS URL; iPXE fetches the boot script BSS holds for that MAC; the Talos kernel and initramfs come from the head node's S3 store and boot into RAM; Talos enters maintenance mode and fetches its machine config from the talos.config kernel argument; and finally Talos selects its install disk by size rather than device name and writes itself to the root disk, overwriting the iPXE bootloader. That last step is what stops the node network-booting again, with no state held anywhere — so there is no way-back command: the next boot is Talos from disk, re-provisioning is openstack server rebuild, and the single capability given up is network-booting a node without destroying its disk. On real hardware all of it is one Redfish call setting BootSourceOverrideTarget to Pxe, followed by a reset.](diagrams/07-node-boot-chain.svg)

⚠ **There is no "boot from disk again" command at the bottom of that chain, and that is the point.** The install destroys the installer's own bootloader. Compare the libvirt lab's `virt-install --boot uefi,hd,network`, which self-terminates for the same reason from the other direction.

<details>
<summary>The same chain as a single vertical line, if you prefer it text-only</summary>

```
openstack server create --image tw-ipxe-disk  tw-cp1      ← §7.3  the whole trick
        │
        ▼
  firmware boots the root disk: EFI/BOOT/BOOTX64.EFI = iPXE
        │
        ▼
  iPXE does DHCP on tw-prov  ─────────────► CoreDHCP (§5.7) leases 172.16.0.1
        │                                    and points at BSS
        ▼
  iPXE fetches its boot script  ──────────► BSS (§9), keyed on the MAC
        │
        ▼
  downloads Talos vmlinuz + initramfs from S3 (§8), boots them
        │
        ▼
  Talos installs to the node's own disk — overwriting iPXE — and reboots
        │
        ▼
  the node now boots Talos from disk, by itself, for ever            ← §10
```

Everything from the second line down is identical on real hardware; the first line is the whole of the deviation. In §10 the equivalent of "network-boot this node again" is `openstack server rebuild --image tw-ipxe-disk`, which restores the bootloader by wiping the disk.

</details>

<details>
<summary>Three other mechanisms exist, and one of them may be what your cloud needs</summary>

We tested four ways to make a Nova instance network-boot. Only the root-disk one is on this path; the others are fully written up, with the tests that chose between them, in [**appendix F**](appendix-f-network-boot-investigation.md).

| Mechanism | Verdict | Where |
|---|---|---|
| **iPXE as the root disk** | ✅ **what this section does.** Needs nothing: no Cinder, no boot order, no rescue policy, no microversion | here |
| Hope the firmware network-boots unaided | ❌ tested and failed on Digital Labs — this OVMF has no network boot option at all. Costs 5 minutes to check on your cloud | [F, Test 1](appendix-f-network-boot-investigation.md#step-72--test-1-does-an-instance-network-boot-on-its-own) |
| iPXE ISO as a permanent second boot device (`boot_index=1`, `device_type=cdrom`) | untested — became unnecessary. Needs a Cinder volume per node | [F, Test 2](appendix-f-network-boot-investigation.md#step-72b--test-2-ipxe-as-a-permanent-second-boot-device) |
| Nova rescue mode with an iPXE image | works, proven, and *far* more complicated. **Still needed for [appendix A](appendix-a-redfish-sushy.md)**, because sushy-tools implements Redfish PXE this way | [F, §7.3 and §7.5](appendix-f-network-boot-investigation.md#step-73--upload-ipxe-to-glance-as-a-rescue-image) |

**Go to appendix F if** your cloud is not Digital Labs, if the checkpoint below fails, or if you want to check our work rather than take it on trust. Everything in §§8–19 is identical whichever mechanism you end up on.

</details>

## Step 7.1 — Get the iPXE disk image

[iPXE](https://ipxe.org) is open-source boot firmware: a small program that does DHCP, then fetches and runs a boot script over HTTP. It is what OpenCHAMI's boot chain expects to be talking to.

`boot.ipxe.org` publishes two prebuilt artifacts. We want **`ipxe.usb`**, which is a bootable *disk* image — the other one, `ipxe.iso`, is a CD image and needs a CD-ROM device we have no way to give it.

```
devbox$ curl -fLO https://boot.ipxe.org/ipxe.usb
devbox$ ls -l ipxe.usb
-rw-rw-r-- 1 tl5297 tl5297 8388608 Aug  4 17:50 ipxe.usb
```

Check it is what it claims, because the whole section rests on this one file being bootable two different ways:

```
devbox$ file ipxe.usb
ipxe.usb: DOS/MBR boot sector; partition 4 : ID=0x4, active, start-CHS (0x0,1,1),
          end-CHS (0x7,63,32), startsector 32, 16352 sectors

devbox$ strings -a ipxe.usb | grep -E 'BOOTX64|BOOTAA64|LDLINUX'
LDLINUX SYS'
LDLINUX C32'
BOOTAA64EFI
BOOTX64 EFI
```

- `DOS/MBR boot sector` + `LDLINUX` — the **BIOS** half: an MBR bootloader and SYSLINUX.
- `BOOTX64 EFI` — the **UEFI** half: `\EFI\BOOT\BOOTX64.EFI` inside the FAT partition at sector 32. That path is UEFI's removable-media fallback, which is exactly why the firmware will boot it.
- `BOOTAA64EFI` — the same artifact covers arm64, which matters for §16 and for the PTR.

So one file works under either firmware, and you do not need to know what §1.5 found for `hw_firmware_type` to proceed.

⚠ **The `.usb` name describes the image's *shape*, not a USB device.** It is a raw disk image with a partition table; nothing here plugs anything in.

⚠ **Verify what you downloaded, and know that it carries a script.** iPXE publishes no signatures for the prebuilt binaries, and `ipxe.usb` contains a 120-byte `autoexec.ipxe` of its own — harmless (it offers `Ctrl-B` for two seconds, then `autoboot`) but it *does* run, and you will see it in the console log below. Acceptable for a throwaway POC on an isolated wire; for the PTR, build iPXE from source in CI and record the hash. Note it in your run log as a known gap.

## Step 7.2 — Upload it to Glance

⚠ **Run this once.** Glance allows two images to share a name, and Nova then cannot resolve `--image tw-ipxe-disk` in §7.3. If you have already created it — appendix F's Test 4 uses the same image — skip to the checkpoint below rather than creating a second one.

```
devbox$ openstack image create ${TW_PREFIX}-ipxe-disk \
    --disk-format raw --container-format bare \
    --file ipxe.usb --private \
    --property hw_firmware_type=uefi \
    --property hw_machine_type=q35
```

- **`--disk-format raw`** — it is a disk image, byte for byte. Nova expands it to the flavor's disk size and the extra space is simply unpartitioned, which is where Talos will install.
- **`hw_firmware_type=uefi`, written out rather than taken from `$TW_FIRMWARE`.** That variable records what the *head node's* Rocky image uses (§1.5) and has no authority over an image we build ourselves. UEFI is the right choice here because the mechanism *is* UEFI's removable-media fallback — `\EFI\BOOT\BOOTX64.EFI` — and because it is what was proven on this cloud. **If your cloud has no UEFI firmware for guests**, `hw_firmware_type=bios` works with the same file, via its MBR and SYSLINUX half; untested here, so record the result if you try it.
- **`hw_machine_type=q35`** — the modern machine type, and the one UEFI expects.
- **`--private`** — visible only to our project. Never `--public`: that would publish it cloud-wide, which is not ours to do.

✅ **Checkpoint**

```
devbox$ openstack image show ${TW_PREFIX}-ipxe-disk -c status -c size -c properties -f value
active
8388608
{'hw_firmware_type': 'uefi', 'hw_machine_type': 'q35', ...}
```

## Step 7.3 — Create the node instances

One instance per node, each on its pre-created MAC-pinned port from §3.4. The image is the only unusual thing about these commands.

Start with the Kubernetes control-plane node:

```
devbox$ openstack server create ${TW_PREFIX}-cp1 \
    --image ${TW_PREFIX}-ipxe-disk \
    --flavor ${TW_FLAVOR_CP} \
    --port ${TW_PREFIX}-node1-prov \
    --wait
```

Then the workers — as many as quota allows. Two is enough to prove scheduling, and they are written out rather than looped so that the port each one takes is visible:

```
devbox$ openstack server create ${TW_PREFIX}-w1 \
    --image ${TW_PREFIX}-ipxe-disk \
    --flavor ${TW_FLAVOR_WORKER} \
    --port ${TW_PREFIX}-node2-prov \
    --wait

devbox$ openstack server create ${TW_PREFIX}-w2 \
    --image ${TW_PREFIX}-ipxe-disk \
    --flavor ${TW_FLAVOR_WORKER} \
    --port ${TW_PREFIX}-node3-prov \
    --wait
```

⚠ **The port numbers and the node names do not line up, and that is deliberate.** §3.4 created `node1`–`node5` before roles existed; §6 then assigned roles and the control plane took `node1`. So the mapping is:

| Instance | Port | MAC | Address SMD holds |
|---|---|---|---|
| `tw-cp1` | `tw-node1-prov` | `52:54:00:be:ef:01` | `172.16.0.1` |
| `tw-w1` | `tw-node2-prov` | `52:54:00:be:ef:02` | `172.16.0.2` |
| `tw-w2` | `tw-node3-prov` | `52:54:00:be:ef:03` | `172.16.0.3` |

Get this wrong and the node still boots — it just comes up in the *other* role, because §9 keys the boot script on the MAC and not on the name you typed. That failure is silent until §10, which is why the commands above are spelled out.

📌 **Each node network-boots the moment it exists.** There is no separate "make it PXE" step — that is the whole benefit of this mechanism, and it changes the ordering slightly: creating the nodes *before* §§8–9 means they will boot, ask BSS what to do, be told nothing useful, and stop. That is expected and harmless, and the checkpoint below turns it into something worth having. After §9 you give them a `openstack server reboot --hard` and the real boot happens (§10). If you would rather see only real boots, do §§8 and 9 first and come back — nothing else in either section depends on these instances existing.

Note what these instances **do not** have:

- **No floating IP and no external network.** They sit only on the provisioning wire, exactly like real compute nodes on a management VLAN. Their only route out is the head node's NAT (§5.12). You reach them through the head, never directly.
- **No SSH key.** Talos has no SSH.
- **No user-data.** Talos ignores cloud-init entirely; its configuration arrives via the `talos.config` kernel argument (§8), which is BSS's job. This is deliberate: if Nova's metadata configured the node, OpenCHAMI would stop being the source of truth and the exercise would prove nothing (DL-003).

⚠ **Disk size comes from the flavor, and the thing that fills it is container images.** Talos itself is small and the model this tutorial serves is smaller — `Qwen2.5-0.5B-Instruct`, ~1 GB — but a node also holds the Kubernetes control plane (on `cp1`) or the vLLM CPU image and KServe's initialiser (on workers), and those are several GB each. **30 GB per node is expected to be enough for §§7–16 as written**, with the caveat that kubelet starts evicting on image-filesystem pressure well before the disk is full. It stops being enough if you swap §14's model for one of the gated multi-billion-parameter ones, or keep several versions on a node at once. If your flavor is much smaller than 30 GB, or you intend to go bigger on models, see [DL-005](DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) for the options.

🛑 **If you do attach a volume, Talos must still install to the *root* disk.** iPXE lives there, and the install overwriting it is what stops the node network-booting for ever. Install anywhere else and iPXE survives, wins the next boot, and the node reinstalls on every cycle. §8's `diskSelector` is where you control this; check it before the first power cycle.

🔀 **Deviation from the libvirt lab.** The lab's `virt-install` gave nodes `--disk size=10` and `--boot uefi,hd,network` — one command that both created the disk and set a boot order of "disk first, network as fallback". Neither half has a Nova equivalent: the root disk comes from the flavor, and the boot order is what this whole section works around.

## ✅ Checkpoint for the section

The instances exist, on the right host, on the right wire:

```
devbox$ openstack server list -c Name -c Status -c Networks
⟨tw-head ACTIVE on both networks; tw-cp1/tw-w1/tw-w2 ACTIVE on tw-prov only,
  at 172.16.0.1, .2 and .3⟩

devbox$ for n in head cp1 w1 w2; do
    printf '%-8s %s\n' $n "$(openstack server show ${TW_PREFIX}-$n -c hostId -f value)"
  done
⟨all four identical — that is your one assigned hypervisor⟩
```

⚠ **Not `OS-EXT-SRV-ATTR:host`** — it is behind an admin-only Nova policy and prints `None` for a project member (§1.6, §4). `hostId` is the member-visible substitute: an opaque per-project hash, useless for naming the hypervisor but exactly right for "is everything on the same one?". The flavor's `trait:CUSTOM_TECHWATCH_PROTO` is what does the actual pinning.

**And the boot chain reached OpenCHAMI.** This is the checkpoint that matters, and it proves five earlier sections at once:

```
devbox$ sleep 30 && openstack console log show ${TW_PREFIX}-cp1 --lines 40
```

```
BdsDxe: loading  Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x2)/Pci(0x0,0x0)
iPXE initialising devices...
file:autoexec.ipxe... Not found (https://ipxe.org/7f4de18e)
file:/autoexec.ipxe... ok

iPXE 2.0.0+ (ga1992) -- Open Source Network Boot Firmware -- https://ipxe.org
Features: DNS HTTP HTTPS iSCSI TFTP VLAN SRP AoE EFI Menu

net0: 52:54:00:be:ef:01 using virtio-net on 0000:03:00.0 (Ethernet) [open]
Configuring (net0 52:54:00:be:ef:01)...... ok
net0: 172.16.0.1/255.255.255.0 gw 172.16.0.254
Next server: 172.16.0.254
Filename: http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01
Root path: 172.16.0.254
Ignoring unsupported root path
http://172.16.0.254:8081/boot/v1/bootscript... ok
bootscript : 127 bytes [script]
```

📌 **`Ignoring unsupported root path` is not an error.** CoreDHCP sends DHCP option 17 (`root-path`), which iSCSI clients use; iPXE has no use for a bare IP there and says so. Every node prints it, on every boot, including the ones that work.

| Line | What it proves |
|---|---|
| `starting Boot0001 "UEFI Misc Device"` | the firmware booted `ipxe.usb` as a plain root disk — §7.1 and §7.2 are right |
| `iPXE 2.0.0+` | iPXE is running, with no rescue, no CD-ROM, no Cinder volume |
| `net0: 52:54:00:be:ef:01` | the MAC we pinned in §3.4 is the guest's NIC |
| `Configuring … ok`, `172.16.0.1` | **CoreDHCP answered**, with the address SMD holds for this MAC. So Neutron's DHCP is genuinely off (§3.2), port security is genuinely off (§3.3), and §6's inventory loaded |
| `Filename: http://172.16.0.254:8081/…` | `coresmd` handed out the BSS URL, not a `172.16.0.2xx` bootloop lease (§5.7) |
| `bootscript … [script]` | **BSS answered** |

That last line is worth more than anything else in the tutorial so far. If you get to it, §§3, 5, 6 and 7 are all correct and §§8–10 are downhill.

**Then check the other two, because `server list` does not prove this.** The addresses it prints are Neutron's own IPAM records; only the console shows what CoreDHCP actually handed out from SMD:

```
devbox$ openstack console log show ${TW_PREFIX}-w1 --lines 20 | grep -E 'net0:|Filename'
devbox$ openstack console log show ${TW_PREFIX}-w2 --lines 20 | grep -E 'net0:|Filename'
```

Want `52:54:00:be:ef:02` → `172.16.0.2` and `…:03` → `172.16.0.3`. A MAC and an address that disagree here mean §6's three-way contract is broken for that port — Neutron and SMD hold different ideas — and it is far cheaper to find now than at §10, when the symptom is a node coming up in the wrong role.

⚠ **Before §9 the boot cannot finish, and what it does instead tells you whether §5.9b took.** BSS has no boot parameters for this MAC yet, so it serves that 127-byte script — which is nothing but "sleep, then ask me again". Two possible endings:

**Expected, with §5.9b applied.** The node loops, quietly, for ever:

```
bootscript : 127 bytes [script]
http://172.16.0.254:8081/boot/v1/bootscript... ok
bootscript : 127 bytes [script]
…
```

The whole 127 bytes is a `sleep` and a `chain` back to the same URL — you can read it yourself with the `curl` in §9's checkpoint.

That is the retry loop working exactly as designed. It costs nothing, it clears the moment §9 gives BSS a real payload, and §10's hard reboot is what picks it up.

**If you skipped §5.9b**, the retry URL has no hostname in it, because BSS is advertising the literal string `${SYSTEM_URL}`, and the node falls out of iPXE altogether:

```
https:///apis/bss/boot/v1/bootscript... Error 0x3e11618e (https://ipxe.org/3e11618e)
BdsDxe: failed to start Boot0001 … Not Found
Shell>
```

That is [`issues/003`](issues/003-bss-ipxe-server-unexpanded-system-url.md), and it is worth going back for even though §9 replaces this particular script — **the same `chain` line is the tail of every *working* boot script**, so a node that fails its real boot has no way back either. Fix it at [§5.9b](05-install-openchami.md), not here. Either way the node idles harmlessly, holding its port.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `No bootable device`, or an `EFI Shell>` prompt with no iPXE banner at all | the firmware would not boot `ipxe.usb`. Check `hw_firmware_type` on the image matches the instance, then see [appendix F, §7.2c](appendix-f-network-boot-investigation.md#step-72c--test-4-ipxe-as-the-nodes-own-root-disk), which carries an `mtools` recipe for rebuilding the artifact as a properly-typed ESP for stricter firmware |
| Instance `ERROR` with `Invalid disk_format 'raw'` | some clouds restrict tenant image formats. `qemu-img convert -f raw -O qcow2 ipxe.usb ipxe.qcow2` and upload that with `--disk-format qcow2` |
| `No valid host was found` | quota or capacity; or the flavor lacks the isolation trait, or asks for NUMA/hugepage properties the host can't satisfy (§1.5). Reduce the number of workers; do **not** change availability zone or swap to an untraited flavor to route around it |
| console log is empty | the instance halted before writing anything, or the console device disagrees with the firmware. Wait 60 s, retry with `--lines 200` |
| iPXE starts but `Configuring (net0 …)` fails or times out | CoreDHCP isn't answering. In order: is `coresmd-coredhcp` active? Is `enable_dhcp` false on the subnet? Is `port_security_enabled` false on the node's port? Is the MAC in SMD? |
| iPXE gets a `172.16.0.2xx` address | bootloop lease — the MAC is unknown to SMD. §6 |
| `https:///apis/bss/…  Error 0x3e11618e` | expected before §9 — [`issues/003`](issues/003-bss-ipxe-server-unexpanded-system-url.md) |
| Node installs Talos, then network-boots and reinstalls for ever | Talos installed to a disk other than the one holding iPXE. §8's `diskSelector` |
| `openstack server create` rejects `--port` | the port is already attached to something — most likely a probe from appendix F. `openstack port show <port> -c device_id` |
| `More than one Image exists with the name 'tw-ipxe-disk'` | §7.2 was run twice. List the IDs with `openstack image list --private -c ID -c Name`, then `openstack image delete <id>` for the surplus one — by ID, since the name is ambiguous |
| `Invalid image metadata` / instance `ERROR` after setting `hw_firmware_type=uefi` | this cloud has no UEFI firmware for guests, or restricts `hw_machine_type`. Recreate the image with `hw_firmware_type=bios` and no `hw_machine_type` — the same `ipxe.usb` boots that way through its MBR half |

## Where the rest of this went

| | |
|---|---|
| [**Appendix F**](appendix-f-network-boot-investigation.md) | the investigation: four mechanisms, the tests that chose between them, the captured consoles, and working instructions for rescue and for the CD-ROM variant. **Go here if your cloud is not Digital Labs** |
| [`DECISION-LOG.md`](DECISION-LOG.md) DL-002 | the argument, the rejected options, the revisit triggers, and the source-level proof that Nova cannot network-boot |
| [`INVESTIGATION-network-boot.md`](INVESTIGATION-network-boot.md) | how the question came to be asked, and what the prior art (vTDS, Tenks, OVB) does instead |
| [Appendix A](appendix-a-redfish-sushy.md) | replacing §10's power commands with real Redfish calls — which needs rescue, so appendix F stays relevant even here |

Next: [§8 — Talos assets and machine config](08-talos-assets-and-config.md)
