# §9 — Boot parameters

*(Upstream: tutorial Part 2.5. Time: ~10 minutes. On the head node; you need a fresh token.)*

```
head$ source ~/tw-head-env.sh
head$ echo "${TW_ARCH} ${TW_OBJ} ${TW_CONSOLE}"
amd64 172.16.0.254:7070 ttyS0,115200
```

Those three are the ones this section's heredocs interpolate; they come from §5's `tw-head-vars-env.sh`. Confirm they are non-empty before writing any bootscript.

## Concepts

**BSS answers one question:** *"a machine with MAC X is asking how to boot — what do I tell it?"* The answer is three things — a kernel URL, an initrd URL, and a kernel command line — stored per MAC. iPXE asks; BSS replies with a generated iPXE script.

This is the last corner of the three-way contract from §6. Here it is complete:

```
   §3.4  Neutron port    MAC 52:54:00:be:ef:01   ← the instance's NIC
   §6.1  SMD inventory   MAC → 172.16.0.1        ← CoreDHCP leases this
   §9.1  BSS payload     MAC → controlplane.yaml ← this node's role
```

We store **two** payloads because our nodes have two roles:

- `tw-cp1` (`…:be:ef:01`) → **Kubernetes control plane**, fetches `controlplane.yaml`;
- `tw-w1`–`tw-w4` (`…:02`–`…:05`) → **workers**, fetch `worker.yaml`.

Repointing a node between roles later means moving its MAC between payloads and re-running `set`.

### The Talos kernel command line, dissected

| Token | Meaning |
|---|---|
| `talos.platform=metal` | tell Talos it is on bare metal (PXE), not a cloud — **required** |
| `slab_nomerge pti=on` | kernel hardening Talos requires on metal — **required** |
| `console=tty0 console=ttyS0,115200` | serial console, so `openstack console log show` gives you the Talos dashboard |
| `talos.config=http://…/worker.yaml` | where Talos fetches its machine config — this is what replaces cloud-init |

🔀 **Deviation — `talos.platform=metal`, on a cloud.** Talos *does* have an `openstack` platform that reads its configuration from the Nova metadata service, and on any other project that would be the obvious choice. We deliberately don't use it: the entire point of this exercise is that **OpenCHAMI** provisions the nodes. If Nova handed Talos its config, we would have proved nothing about OpenCHAMI and learned nothing that transfers to the PTR. `metal` keeps BSS in the path.

🔀 **Deviation — everything from the Rocky command line is gone.** No `root=live:…`, no `overlayroot=…`, no `cloud-init=…`/`ds=nocloud-net`, no `apparmor=0 selinux=0 nomodeset`. Talos is not a dracut live image; its initramfs *is* the OS.

## Step 9.1 — Write the two payloads

Control-plane node:

```
head$ sudo mkdir -p /etc/openchami/data/boot/bss
head$ cat << EOF | sudo tee /etc/openchami/data/boot/bss/talos-controlplane.yaml
---
kernel: 'http://${TW_OBJ}/boot-images/talos/vmlinuz-${TW_ARCH}'
initrd: 'http://${TW_OBJ}/boot-images/talos/initramfs-${TW_ARCH}.xz'
params: 'talos.platform=metal slab_nomerge pti=on console=tty0 console=${TW_CONSOLE} talos.config=http://${TW_OBJ}/boot-images/talos/controlplane.yaml'
macs:
  - 52:54:00:be:ef:01
EOF
```

Workers:

```
head$ cat << EOF | sudo tee /etc/openchami/data/boot/bss/talos-worker.yaml
---
kernel: 'http://${TW_OBJ}/boot-images/talos/vmlinuz-${TW_ARCH}'
initrd: 'http://${TW_OBJ}/boot-images/talos/initramfs-${TW_ARCH}.xz'
params: 'talos.platform=metal slab_nomerge pti=on console=tty0 console=${TW_CONSOLE} talos.config=http://${TW_OBJ}/boot-images/talos/worker.yaml'
macs:
  - 52:54:00:be:ef:02
  - 52:54:00:be:ef:03
  - 52:54:00:be:ef:04
  - 52:54:00:be:ef:05
EOF
```

⚠ **The heredocs are unquoted on purpose** so `${TW_OBJ}`, `${TW_ARCH}` and `${TW_CONSOLE}` expand into the files. **Check they did** — an unset variable produces a plausible-looking file with a broken URL, and the failure appears much later as an unhelpful iPXE error:

```
head$ cat /etc/openchami/data/boot/bss/talos-controlplane.yaml
head$ grep -c '172.16.0.254:7070' /etc/openchami/data/boot/bss/*.yaml
/etc/openchami/data/boot/bss/talos-controlplane.yaml:3
/etc/openchami/data/boot/bss/talos-worker.yaml:3
```

Three lines per file carry `${TW_OBJ}` — `kernel:`, `initrd:`, and the `talos.config=` URL inside `params:`. Anything less means an expansion failed.

Copies live in [`templates/bss-talos-controlplane.yaml`](templates/bss-talos-controlplane.yaml) and [`templates/bss-talos-worker.yaml`](templates/bss-talos-worker.yaml).

## Step 9.2 — Load them into BSS

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
head$ ochami bss boot params set -f yaml -d @/etc/openchami/data/boot/bss/talos-controlplane.yaml
head$ ochami bss boot params set -f yaml -d @/etc/openchami/data/boot/bss/talos-worker.yaml
head$ ochami bss boot params get -F yaml
```

Unlike §6's `discover static`, **`bss boot params set` is idempotent** — it replaces. Re-run it freely as you tweak the command line; you will, in §10.

## ✅ Checkpoint — pretend to be each node

Ask BSS what it would tell each MAC. This is the exact HTTP request iPXE makes:

```
head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01" \
        | grep -o 'talos.config=[^ ]*'
talos.config=http://172.16.0.254:7070/boot-images/talos/controlplane.yaml

head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:02" \
        | grep -o 'talos.config=[^ ]*'
talos.config=http://172.16.0.254:7070/boot-images/talos/worker.yaml
```

Different answers for the two MACs = the role split works. Now read a whole script, because this is literally what `tw-cp1` will execute:

```
head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01"
#!ipxe
kernel --name kernel http://172.16.0.254:7070/boot-images/talos/vmlinuz-amd64 initrd=initrd talos.platform=metal slab_nomerge pti=on console=tty0 console=ttyS0,115200 talos.config=http://172.16.0.254:7070/boot-images/talos/controlplane.yaml xname=x1000c0s0b0n0 nid=1 ds=nocloud-net;s=localhost/ || goto boot_retry
initrd --name initrd http://172.16.0.254:7070/boot-images/talos/initramfs-amd64.xz || goto boot_retry
boot || goto boot_retry
:boot_retry
sleep 30
chain http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01&retry=1
```

Three things in there are BSS's, not ours, and all three are harmless:

- **`xname=x1000c0s0b0n0 nid=1`** — BSS's own identity tokens for the node. Talos ignores unknown kernel arguments.
- **`ds=nocloud-net;s=localhost/`** — BSS appends this unconditionally, for the cloud-init consumers it was written for. The deviation note above says we don't use `ds=nocloud-net`, and we don't: *we* never put it on the command line, Talos never reads it, and `talos.platform=metal` is what decides where config comes from. It is BSS boilerplate, not our configuration.
- **`sleep 30` / `chain …&retry=1`** — the retry loop. A node that can't get a usable script sits here for ever rather than failing; §10's Common failures turns that symptom back into a cause.

⚠ **The `xname` is how you check BSS matched the *right* node.** `x1000c0s0b0n0` is `tw-cp1`'s SMD component ID from §6. If a MAC comes back with another node's xname, SMD and BSS disagree and §10 will boot the wrong role.

And close the loop on the three-way contract, all three sources at once. The first command is on the **devbox**, the other two back on the **head** — and that `ssh` costs you `DEMO_ACCESS_TOKEN`, so export it again once you land:

```
devbox$ openstack port list --network ${TW_PREFIX}-prov -c Name -c 'MAC Address' -f value | sort
 fa:16:3e:53:00:d2
tw-head-prov 52:54:00:be:ef:ff
tw-node1-prov 52:54:00:be:ef:01
tw-node2-prov 52:54:00:be:ef:02
tw-node3-prov 52:54:00:be:ef:03
tw-node4-prov 52:54:00:be:ef:04
tw-node5-prov 52:54:00:be:ef:05

head$   ochami smd component get | jq -r '.Components[]|select(.Type=="Node")|.ID'
x1000c0s0b0n0
x1000c0s0b1n0
x1000c0s0b2n0
x1000c0s0b3n0
x1000c0s0b4n0

head$   ochami bss boot params get -F json | jq -r '.[].macs[]' | sort
52:54:00:be:ef:01
52:54:00:be:ef:02
52:54:00:be:ef:03
52:54:00:be:ef:04
52:54:00:be:ef:05
```

Five `…:be:ef:01`–`05` node MACs on ports, five node components, five MACs across the two BSS payloads. If any list is short, fix it *now* — every failure mode in §10 traces back to these three lists disagreeing.

The port list's two extra rows — `tw-head-prov` and the unnamed `fa:16:3e:…` — are expected and neither is a node; §6's checkpoint explains both. Count the `be:ef:0…` rows, not the lines.

## Step 9.3 — Not needed here. Skip it.

**On the path this tutorial takes, there is no third payload and nothing to do in this step.** iPXE lives on the node's root disk (§7) and Talos overwrites it during install, so an installed node stops network-booting by itself. BSS is never asked again, and therefore never has to answer "boot from your own disk".

<details>
<summary>If your cloud forced you onto a mechanism where the iPXE media <em>survives</em> the install — a CD-ROM, a rescue image, or a second volume (<a href="appendix-f-network-boot-investigation.md">appendix F</a>) — you need this. Otherwise ignore it.</summary>

When the iPXE media cannot be overwritten, every reboot network-boots again, so BSS has to be able to say "boot from your own disk" once a node is installed. Add a third payload:

```
head$ cat << 'EOF' | sudo tee /etc/openchami/data/boot/bss/talos-installed.yaml
---
# For nodes that have already installed Talos to disk. iPXE hands control to the
# local disk instead of network-booting again.
kernel: ''
initrd: ''
params: ''
script: |
  #!ipxe
  sanboot --no-describe --drive 0x80
macs: []
EOF
```

Then in §10, after a node finishes installing, move its MAC out of `talos-controlplane.yaml`/`talos-worker.yaml` into this payload's `macs:` list and `set` all the affected payloads again. Re-provisioning is the same move in reverse.

⚠ **This makes BSS stateful, and that is exactly what §7's mechanism buys you out of.** Something now has to remember which nodes are provisioned. If you forget to move a MAC, that node silently reinstalls itself on its next reboot — losing etcd on a control-plane node. If you are on this path, write down which MACs are in which payload and check it before every reboot.

</details>

## Common failures

| Symptom | Cause / fix |
|---|---|
| bootscript shows empty `kernel:` or blank params | the heredoc variables were unset — `source ~/tw-head-env.sh`, re-run the `echo` above to confirm all three are non-empty, then rewrite the files |
| `set` fails `401` | token expired — re-run the `gen_access_token` export |
| `ochami` → `Environment variable DEMO_ACCESS_TOKEN unset` | not an expiry — the variable is simply gone, because it lives in one shell and you opened a new one. Any `ssh` back to the head loses it. Re-run the export |
| bootscript returns nothing for a MAC | that MAC isn't in any payload, or isn't in SMD. Check both |
| `curl … :8081` connection refused | BSS isn't running: `systemctl is-active bss`, then §5.10's gotchas |
| Node later boots but stays in maintenance mode | the `talos.config` URL is wrong or not public-read — §8's checkpoint |

Next: [§10 — Booting the Talos cluster](10-boot-the-cluster.md)
