# Appendix D — The ten-minute smoke test

Do this **before §3**, as soon as you have working credentials.

It costs one throwaway instance and about ten minutes, and it answers five questions that otherwise surface much later, when you have a half-built cluster in the way:

| Question | Answered in | Without this test you find out during |
|---|---|---|
| Do my credentials work at all? | D.1 | §1.4 (fine) |
| Can I use the flavor an admin made for me? | D.2 | §4 |
| Can a `member` boot an instance in this project? | D.3 | §4 |
| **Does BIOS or UEFI firmware boot?** | D.4 | §7, after building the wrong iPXE artifact |
| **Does the firmware try to network-boot unaided?** | D.4b | §7.2 — and it may make most of §7 unnecessary |
| **Does Nova policy let me `server rescue`?** | D.5 | not needed for §7 any more — only for [appendix A](appendix-a-redfish-sushy.md) |
| **Does Neutron let me pin a MAC address?** | D.6 | §3, and it invalidates §6 and §9 too |

The last four are the ones worth the trouble. §§3/6/9 rest on MAC pinning and on disabling port security — policy decisions your cloud makes, documented nowhere you can read, and with fallbacks much cheaper to choose now than to retrofit. D.4b is the one that can *delete* work rather than add it. D.5 is now optional: §7 no longer needs rescue, but appendix A does.

Everything here is deleted again in D.7.

## D.1 — Credentials

```
devbox$ source ~/tw/tw-env.sh
devbox$ openstack token issue -c project_id -c expires -f value
```

Expect our project ID. If you get `Cloud … was not found`, `OS_CLOUD` and `clouds.yaml` disagree — §1.4 has the fix. Nothing below will work until this line does; the CLI fails at config load, before it even looks at your arguments, so every later error would be a phantom.

## D.2 — Can I see and use the flavor?

A private flavor granted to your project with `--project` appears in your ordinary flavor list. That grant *is* the access:

```
devbox$ openstack flavor list
devbox$ openstack flavor show techwatch-proto-test-flavor \
          -c name -c vcpus -c ram -c disk -c properties -c 'os-flavor-access:is_public'
```

✅ **Checkpoint** — three things to read off it:

- The flavor is **listed**. If `flavor list` doesn't show it but `flavor show` does, you can see it but may not have been granted access — ask.
- `os-flavor-access:is_public` is `False`, and you can still see it. That combination is what proves the project grant took effect.
- `properties` contains `trait:CUSTOM_TECHWATCH_PROTO='required'`.

⚠ **If `properties` is empty**, Nova policy hides flavor extra specs from your credential. That is not a failure — but it means you cannot self-verify the isolation trait, so §1.6's admin-side placement check becomes mandatory rather than a nice-to-have. Note which it was in your run log; the IaC's `flavor_trait_check` output reports the same distinction.

## D.3 — Boot one throwaway instance

You need a network. If an admin already made `techwatch-proto-test-net` in our project, reuse it; otherwise make a disposable one:

```
devbox$ openstack network list
```

> 🛑 **Do not delete `techwatch-proto-test-*` resources if a colleague created them.** §1's rule applies: you did not create them, so they are not yours to remove, even inside our own project. Ask before tidying.

If you need your own:

```
devbox$ openstack network create tw-smoke-net
devbox$ openstack subnet create --network tw-smoke-net \
          --subnet-range 192.168.199.0/24 tw-smoke-subnet
```

This is an ordinary DHCP-enabled network — **not** the provisioning wire. §3 builds that one, with DHCP off and port security off, for real reasons. Do not reuse this one for it.

Then the smallest possible instance:

```
devbox$ openstack server create \
          --flavor techwatch-proto-test-flavor \
          --image 'Rocky-9.6' \
          --network tw-smoke-net \
          --wait \
          tw-smoke
```

Mind the quoting on `--image`: an unquoted name that gets split by the shell produces a baffling error about extra positional arguments rather than a clean "no such image".

✅ **Checkpoint**

```
devbox$ openstack server show tw-smoke -c status -c flavor -c addresses -c 'OS-EXT-STS:vm_state'
```

`status` must be `ACTIVE`. That single word means the trait matched a host, the NUMA and hugepage properties were satisfiable, and a `member` credential is allowed to boot here — three answers for one command.

🛑 **If it is `ERROR`**, read the reason before changing anything:

```
devbox$ openstack server show tw-smoke -c fault -f value
```

`No valid host was found` here means either the host has no free *dedicated* cores or 1 GB pages left (capacity — ask), or the flavor asks for a topology this host cannot provide (a flavor question — ask). It does **not** mean try a different AZ or a flavor without the trait. See §1.5.

Now get an admin to run the placement check from §1.6 — this is the moment it is cheapest, because if isolation isn't working you have learned it with one disposable VM at stake.

## D.4 — BIOS or UEFI? (settles §7.1)

The console log shows which firmware ran, and this decides which iPXE artifact §7 needs:

```
devbox$ openstack console log show tw-smoke | head -40
```

| What you see near the top | Firmware | §7 needs |
|---|---|---|
| `SeaBIOS (version …)` | legacy BIOS | `ipxe.iso` |
| `BdsDxe:` / `UEFI Interactive Shell` / `EDK II` | UEFI (OVMF) | `ipxe.efi` in an ESP image, or `ipxe.iso` — see below |
| nothing at all before the kernel | serial console isn't wired to the firmware; fall back to `openstack image show 'Rocky-9.6' -c properties` and read `hw_firmware_type` | — |

> The prebuilt `ipxe.iso` from boot.ipxe.org is a hybrid image that boots under **both** firmwares, which is why §7 uses it either way. Knowing which you have still matters for diagnosing §7: under UEFI you will see the firmware's own boot manager before iPXE appears, and under BIOS you won't.

Also note whether the log mentions `virtio-scsi` or `ata`/`ide` — it tells you what device name the node's root disk will get, which is why §8.6 selects the install disk by size instead of by name.

## D.4b — Does the firmware network-boot unaided? (the early form of §7.2's Test 1)

The cheapest possible version of the question the whole of §7 exists to answer. **Nova cannot put a NIC in a guest's boot order** — it only ever assigns a `bootindex` to storage — so the only way an instance network-boots without help is if its firmware tries the network of its own accord when it has nothing else to boot. UEFI firmware often does; legacy BIOS with a disk-only boot order does not.

You do not need the provisioning network, CoreDHCP, or anything from §3 to find out. **The question is only whether the firmware *tries*.** A blank image on any network answers it:

```
devbox$ truncate -s 1M blank.raw
devbox$ openstack image create tw-smoke-blank \
    --disk-format raw --container-format bare --file blank.raw --private \
    --property hw_firmware_type=uefi --property hw_machine_type=q35

devbox$ openstack server create tw-smoke-pxe \
    --image tw-smoke-blank --flavor ${TW_FLAVOR_CP} \
    --network techwatch-proto-test-net --wait

devbox$ sleep 30 && openstack console log show tw-smoke-pxe --lines 80
```

| What you see | Meaning | Consequence |
|---|---|---|
| `Start PXE over IPv4`, `PXE`, `iPXE`, or a DHCP attempt | 🎉 the firmware network-boots unaided | **§7 collapses further still**: you do not even need the iPXE root disk, because `coresmd`'s TFTP server can hand over the iPXE binary exactly as in the libvirt lab. Confirm properly once the provisioning wire exists. *This did not happen on Digital Labs — the OVMF build there has no network boot option at all* ([appendix F](appendix-f-network-boot-investigation.md)) |
| `No bootable device`, or a UEFI Shell / boot-manager prompt | firmware will not try the network | §7 needs a mechanism — go on to D.5, and plan to run §7.2b's Test 2 |
| `Invalid image metadata`, or the instance ERRORs | this cloud has no UEFI guest firmware, or restricts `hw_machine_type` | same as above; note the error, it is a real finding |

⚠ **A DHCP attempt that times out still counts as success.** There is no DHCP server on the test network that will answer a PXE client, and that is fine — you are testing the firmware's intent, not the network. The full test with a real lease from SMD is §7.2.

Clean up with the rest in D.7 (`openstack server delete tw-smoke-pxe && openstack image delete tw-smoke-blank`).

The reasoning behind this test, and the two alternatives if it fails, are in [`DECISION-LOG.md`](DECISION-LOG.md) (DL-002).

## D.5 — Is `server rescue` permitted? (optional: needed only for appendix A)

🔀 **This test used to settle §7's core mechanism. It no longer does** — §7 makes iPXE the node's root disk, which needs no rescue policy at all. Run it only if you intend to do [appendix A](appendix-a-redfish-sushy.md), whose Redfish emulation implements `BootSourceOverrideTarget=Pxe` by putting the instance into rescue mode with an iPXE image. If you are not doing appendix A, skip to D.6.

You do not need the iPXE image to test *permission*. Rescue with any bootable image:

```
devbox$ openstack --os-compute-api-version 2.87 server rescue \
          --image 'Rocky-9.6' tw-smoke
devbox$ openstack server show tw-smoke -c status -f value      # RESCUE
devbox$ openstack server unrescue tw-smoke
devbox$ openstack server show tw-smoke -c status -f value      # ACTIVE
```

✅ **Checkpoint** — `RESCUE`, then `ACTIVE` again. That is the whole mechanism §7 depends on, proven in two commands.

| What you get | Meaning | Consequence |
|---|---|---|
| `RESCUE` then `ACTIVE` | tenant rescue is allowed | appendix A is available to you |
| `Policy doesn't allow os_compute_api:os-rescue to be performed` | rescue is admin-only | nothing on the main path is affected; appendix A is not available without an admin |
| `Cannot 'rescue' instance … while it is in vm_state …` | instance wasn't `ACTIVE` | wait, retry |

⚠ **Because `Rocky-9.6` almost certainly has no `hw_rescue_device` property, this is a *legacy* rescue, not stable-device rescue.** Legacy rescue renumbers the guest's disks. Harmless here — we are testing permission and then throwing the instance away — but it is why [appendix F](appendix-f-network-boot-investigation.md)'s rescue variant has to set `hw_rescue_device` and `hw_rescue_bus`, and one of several reasons §8.6 selects the install disk by size rather than by `/dev/vda`.

⚠ **A rescued instance cannot be stopped, paused or suspended.** If you get stuck, `unrescue` first. Do not reach for `openstack server rebuild` here — it looks similar and destroys the disk. (It *is* the right tool at §10.7, on a node you mean to re-provision.)

## D.6 — Can I pin a MAC address? (settles §3.4)

§3 creates ports with chosen MACs, because SMD's inventory (§6) and BSS's boot payloads (§9) are keyed by MAC. If Neutron refuses tenant-chosen MACs, all three sections change — the IaC handles it cleanly by reading MACs back, but the manual guide's tables have to be filled in from Neutron instead of chosen.

```
devbox$ openstack port create --network tw-smoke-net \
          --mac-address 52:54:00:be:ef:fe tw-smoke-macprobe
devbox$ openstack port show tw-smoke-macprobe -c mac_address -f value
devbox$ openstack port delete tw-smoke-macprobe
```

✅ **Checkpoint** — it prints back `52:54:00:be:ef:fe`.

`52:54:00:…` is inside the locally-administered range and is the prefix our node map uses throughout, with `:fe` reserved here so it can never collide with a real node (`:01`–`:05`).

| What you get | Consequence |
|---|---|
| the MAC you asked for | §3.4 works as written |
| `Unrecognized attribute` / policy denial | use §3.4's documented fallback: create ports without `--mac-address`, then read the assigned MACs back into your node map before §6 |

While you are here, the other §3 unknown is free to check — whether you may disable port security, which the provisioning wire requires:

```
devbox$ openstack port create --network tw-smoke-net --disable-port-security \
          --no-security-group tw-smoke-secprobe
devbox$ openstack port show tw-smoke-secprobe -c port_security_enabled -f value
devbox$ openstack port delete tw-smoke-secprobe
```

Expect `False`. If this is denied, §3.3's `--allowed-address-pair` alternative is the way through, and it is worth reading that section carefully before §5 — without one of the two, CoreDHCP's replies and the head's NAT are both silently dropped.

## D.7 — Clean up

```
devbox$ openstack server delete tw-smoke --wait
devbox$ openstack port list --network tw-smoke-net          # should be empty of tw-smoke-*
devbox$ openstack subnet delete tw-smoke-subnet
devbox$ openstack network delete tw-smoke-net
devbox$ openstack server list                               # nothing of ours left
```

Delete only what **you** created. If you reused a colleague's `techwatch-proto-test-net`, leave it alone.

## Record the answers

Write these into your run log and into `templates/tw-vars-env.sh` — §§3 and 7 both branch on them, and the IaC needs the same facts:

| Finding | Where it lands |
|---|---|
| Flavor names + whether the trait was readable | `TW_FLAVOR_*`, `tofu/terraform.tfvars` |
| BIOS or UEFI | `TW_FIRMWARE`, `var.firmware_type` |
| Firmware network-boots unaided? | which of §7's three paths you are on — see [`DECISION-LOG.md`](DECISION-LOG.md) DL-002 |
| Rescue permitted? | whether [appendix A](appendix-a-redfish-sushy.md) is available |
| MAC pinning permitted? | §3.4 main path vs read-back fallback |
| Port security disable permitted? | §3.3 choice |
| Disk bus seen in the console log | confirms the root-disk device name §8.6 deliberately avoids hardcoding |

Next: [§2 — An OpenStack primer for libvirt people](02-openstack-primer.md)
