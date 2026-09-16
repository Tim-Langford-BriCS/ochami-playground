# §10 — Booting the Talos cluster

*(Time: ~30–40 minutes, most of it Talos pulling images on first boot. Two `openstack` commands on the **devbox**; everything else on the **head**. This is the payoff.)*

This is the first section that needs **both** shells at once. Open them now and confirm each one is the shell you think it is — a `reboot --hard` typed on the head, or a `talosctl` typed on the devbox, is the confusing kind of failure:

```
devbox$ cd ~/tw && source tw-vars-env.sh
devbox$ echo "${TW_PREFIX}"
tw

head$ source ~/tw-head-env.sh
head$ echo "${TW_CP_IP} ${TW_HEAD_PROV_IP}"
172.16.0.1 172.16.0.254
```

## Concepts

Everything is now in place. The boot chain, end to end:

1. The instance powers on and boots its **root disk**, which is iPXE (§7).
2. iPXE does DHCP; **CoreDHCP** leases the SMD-mapped IP and points at BSS (§5, §6).
3. iPXE chains to **BSS**, which returns §9's Talos script.
4. iPXE fetches Talos `vmlinuz` + `initramfs.xz` from the head's S3 (§8) and boots them **into RAM**.
5. With no OS on disk, Talos enters **maintenance mode**, then fetches its machine config from the `talos.config` URL.
6. Talos pulls its **installer** image — this needs §5.12's NAT — selects the disk by size (§8.6), **overwrites iPXE with itself**, and reboots into Talos.

Steps 2–6 are ordinary OpenCHAMI, identical to what will happen on the PTR. Step 1 is the only cloud-specific part, and it is not a command — it is just what happens when the instance powers on.

**There is no "stop network-booting" step, and that is the whole design.** Under every other mechanism this section had a step 7 — `unrescue`, or moving a MAC into a `sanboot` payload — because the iPXE media survived the install and something had to remember which nodes were done. Here Talos writes over the media it booted from. The node stops network-booting because there is nothing left to network-boot *from*.

⚠ **Which makes this a one-way trip, on purpose.** The moment Talos installs, the iPXE image on that root disk is gone. To network-boot the node again you put it back with `openstack server rebuild` (§10.7). There is no `unrescue` to forget, and equally no way to "just have one more look" at the installer.

📌 **Your nodes are already sitting at the start of this chain.** §7 created them and they booted iPXE, but BSS had no payload for them yet. Where they stopped depends on when you fixed §5.9b:

| If §5.9b was already applied at §7 | If you fixed it afterwards |
|---|---|
| the node is still in iPXE, re-asking BSS every few seconds | the node fell out of iPXE and is parked at `Shell>` |
| it would pick up §9's payload on its own eventually | it will never retry — it is not running iPXE any more |

Either way you reboot, and for the same reason: it is instant, deterministic, and gives you one clean boot to read rather than a log with two attempts in it. **Both states leave one iPXE banner in the console log** — that is the baseline §10.2 asks you for.

## Step 10.1 — Boot the control-plane node

```
devbox$ openstack server reboot --hard ${TW_PREFIX}-cp1
```

⚠ **`--hard` matters here.** A soft reboot asks the guest operating system to shut down politely, over ACPI. There is no operating system on this node — only iPXE, or a firmware prompt, and neither will answer. `--hard` resets the instance the way the power button would.

Watch it. The console log is your only window until the Talos API comes up — there is no shell to log into and no SSH:

```
devbox$ watch -n 10 "openstack console log show ${TW_PREFIX}-cp1 --lines 30"
```

You are looking for this progression, over roughly 5–10 minutes. The first six lines are the ones §7's checkpoint already showed you, and they should look exactly the same — **except one**:

```
iPXE 2.0.0+ (ga1992) -- Open Source Network Boot Firmware -- https://ipxe.org
net0: 52:54:00:be:ef:01 using virtio-net on 0000:03:00.0 (Ethernet) [open]
Configuring (net0 52:54:00:be:ef:01)...... ok
net0: 172.16.0.1/255.255.255.0 gw 172.16.0.254
Filename: http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01
http://172.16.0.254:8081/boot/v1/bootscript... ok
bootscript : 549 bytes [script]                       ← NOT 127. see below
http://172.16.0.254:7070/boot-images/talos/vmlinuz-amd64... ok
http://172.16.0.254:7070/boot-images/talos/initramfs-amd64.xz... ok
[    0.000000] Linux version …
…
[talos] task startAllServices …
[talos] machine is running in maintenance mode
[talos] downloading config from http://172.16.0.254:7070/…/controlplane.yaml
[talos] using disk match expression: …
[talos] downloading installer image ghcr.io/siderolabs/installer:v1.13.0
[talos] installing Talos to disk /dev/vda
[talos] … installation successful, rebooting
⟨captured on first run⟩
```

Five of those lines are load-bearing checkpoints:

| Line | Proves |
|---|---|
| `net0: 172.16.0.1/…gw 172.16.0.254` | §3 (no Neutron DHCP, no port security), §5.7 (CoreDHCP), §6 (SMD) |
| `bootscript : 549 bytes` — **anything but `127`** | §9's payload is what BSS served. **127 bytes is the empty retry script**, the same one §7 got before §9 existed, and it means this MAC still has no boot parameters. The exact size depends on your URLs; the distinction that matters is 127 vs several hundred |
| `downloading config from …controlplane.yaml` | §8.7 (published, public-read) and §9 (BSS gave the right role) |
| `using disk match expression:` **naming the node's real disk** | §8.6's selector resolved. Expect `/dev/vda` on virtio; the device name doesn't matter, a name appearing does. If this says `no disks matched the expression`, stop — see Common failures |
| `downloading installer image ghcr.io/…` **and getting past it** | §5.12's NAT and §8.6's nameservers |

⚠ **The byte count is the cheapest early warning in this section.** A 127-byte script sleeps 30 seconds and asks again, for ever, and the console then looks like a node that is *nearly* working. If you see it, go back to §9's checkpoint and re-run `bss boot params set` for that MAC before anything else.

⚠ **Stuck at `downloading installer` forever** is the classic failure and it is always one of two things: the head isn't forwarding/masquerading (§5.12 — and check port security is off on the head's provisioning port), or DNS can't resolve `ghcr.io` (§8.6's nameserver patch didn't apply). Test the first from the head:

```
head$ sudo nft list chain ip nat postrouting      # or: sudo firewall-cmd --query-masquerade
head$ sysctl net.ipv4.ip_forward
```

## Step 10.2 — Confirm it came back as Talos, not as iPXE

**No new state to create here — this step is a check.** Talos rebooted itself at the end of §10.1, and this is where you find out whether §8.6's `wipe: true` did its job.

The evidence is in the log you already have. Read it **before** bootstrapping, because the failure it rules out is silent and costs a rebuild:

```
devbox$ openstack console log show ${TW_PREFIX}-cp1 \
          | grep -E 'GRUB:|sd-boot|Unsigned PE|kexec_core'
[talos] GRUB: BOOT partition not found, skipping probing
[talos] sd-boot: found UKI files: [Talos-v1.13.0.efi]
[talos] found sd-boot bootloader on "/dev/vda"
PEFILE: Unsigned PE binary
kexec_core: Starting new kernel
⟨captured 7 Aug 2026 on tw-cp1⟩
```

| Line | Meaning |
|---|---|
| `GRUB: BOOT partition not found` **and** `found sd-boot bootloader on "/dev/vda"` | ✅ the disk holds Talos's UKI and nothing else. `wipe: true` did its job — there is no iPXE ESP left for the firmware's removable-media fallback to find. (systemd-boot rather than GRUB is simply what Talos ≥ 1.10 installs on UEFI) |
| either of those naming a disk that is **not** the one iPXE was on | 🛑 Talos installed to the wrong disk. iPXE survives, wins the next boot, and the node reinstalls for ever. Fix §8.6's selector, re-publish (§8.7), `openstack server rebuild` |
| `PEFILE: Unsigned PE binary` | harmless. Talos tried to `kexec` the UKI directly, the kernel declined to load an unsigned PE, and it fell back to extracting the kernel and initrd from the UKI — the line after it says so |

⚠ **`kexec_core: Starting new kernel` means this reboot never touched the firmware.** Talos jumps straight into the installed kernel; BIOS/UEFI, the boot order and the disk's bootloader are all bypassed. So counting iPXE banners across this transition proves nothing either way — **the firmware path is still untested at this point**, and the first thing that genuinely exercises it is §10.7's plain `openstack server reboot`. If you want the reinstall loop ruled out today rather than discovered at teardown, do §10.7's soft-reboot test now, before §10.4.

🛑 **And that line is the last one you will ever see from this node.** The installed system's kernel command line comes from the UKI and does not include `console=ttyS0,115200`, so nothing more reaches Nova's serial log — not the Talos dashboard, not a panic, nothing. This is expected, it is not fixable from the machine config, and §8.7's console note plus [DL-006](DECISION-LOG.md#dl-006--installed-nodes-have-no-serial-console) explain why. **From here on, `talosctl` is your only window into a node** — which is the next step.

📌 **The console log is truncated on `reboot --hard`, not appended to.** Nova recreates the domain and libvirt reopens the serial log with `append='off'`, so what you are reading is *only* this boot — §7's 127-byte bootscript is not in it. Convenient, and the opposite of what most logs do.

## Step 10.3 — Point `talosctl` at the node

On the head, where the `talosconfig` from §8.5 lives:

```
head$ cd ~/talos
head$ export TALOSCONFIG=$PWD/talosconfig
head$ talosctl config endpoint ${TW_CP_IP}
head$ talosctl config node ${TW_CP_IP}
```

Both are `172.16.0.1` — the control-plane node's SMD-mapped address, the same one §8.5 baked into the cluster endpoint. `endpoint` is the node `talosctl` *connects to*; `node` is the node it *acts on*. They are the same machine here and will not be once there is more than one control plane.

🛑 **Do this now, or it will bite you three times.** `TALOSCONFIG` and `KUBECONFIG` are shell variables, and every `ssh` back to the head loses them — while §§11–17 assume both are set. The symptoms don't say "unset variable"; they look like a broken cluster:

| Symptom | Actually |
|---|---|
| `talosctl` → `error constructing client: failed to determine endpoints` | `TALOSCONFIG` unset |
| `kubectl` → `The connection to the server localhost:8080 was refused` | `KUBECONFIG` unset — `localhost:8080` is kubectl's default when it has no config |

Write the companion file §5's `tw-head-env.sh` is already looking for, and it is handled for every shell from now on. **Writing the file is the whole installation** — there is no hook to add and no `.bashrc` to edit, because the entry point already names this file:

```
head$ cat > ~/tw-head-talos-env.sh << 'EOF'
# Talos + Kubernetes client context. Created in §10; sourced by tw-head-env.sh.
export TALOSCONFIG=$HOME/talos/talosconfig
export KUBECONFIG=$HOME/talos/kubeconfig
EOF
head$ source ~/tw-head-env.sh
head$ echo "$TALOSCONFIG"
/home/rocky/talos/talosconfig
```

`kubeconfig` doesn't exist until §10.6 and naming it early is harmless — an unset file only matters when `kubectl` runs. **The quoted `<< 'EOF'` is required here**: `$HOME` must survive into the file and be expanded when it is *sourced*, not now.

📌 **If you added those exports to `~/.bashrc` by hand, remove them** — `sed -i '/talos\/talosconfig/d;/talos\/kubeconfig/d' ~/.bashrc`. One source of truth, and this one survives `tw-head-vars-env.sh` being regenerated from the devbox, because it is a separate file from the generated one.

What *does* persist without any of this is `talosctl config endpoint` and `… node` — those are written into the `talosconfig` **file**, so you never repeat them, no matter how many times you reconnect.

Wait for the API to answer — a minute or two after the reboot:

```
head$ talosctl version
⟨captured on first run — expect BOTH a Client and a Server version⟩
```

A `Server` section means the Talos API (`:50000`) is up on the node. If it never answers, `talosctl -n 172.16.0.1 dmesg` or the console log will say why.

## Step 10.4 — Bootstrap etcd

🛑 **Exactly once, on this one control-plane node.** Running `bootstrap` twice, or on a worker, corrupts etcd and means starting the cluster over.

```
head$ talosctl bootstrap
```

Then watch the Kubernetes control plane assemble itself (2–5 minutes, pulling `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`):

```
head$ talosctl health --nodes ${TW_CP_IP}
⟨captured on first run — a sequence of checks ending in "healthy"⟩
```

📌 **If `health` hangs or errors on node discovery**, it is not the cluster — it is the check. `talosctl health` runs *server-side* by default and asks Talos's discovery service (`discovery.talos.dev`, over the internet) who the members are. Name the nodes yourself instead, which needs nothing external:

```
head$ talosctl health --server=false --control-plane-nodes ${TW_CP_IP} --worker-nodes ""
```

The workers are legitimately absent at this point — they don't boot until §10.5.

Note the difference between the two ways this step fails. `dial tcp 172.16.0.1:6443: connect: connection refused` is **not** the discovery problem — that is the API server still starting, and the answer is to wait a couple of minutes and run it again.

## Step 10.5 — Bring up the workers

Workers need no bootstrap: they read `worker.yaml`, find the control-plane endpoint in it, and join. Do them one at a time the first time, so a failure is attributable:

```
devbox$ openstack server reboot --hard ${TW_PREFIX}-w1
devbox$ watch -n 10 "openstack console log show ${TW_PREFIX}-w1 --lines 20"
# … wait for "installation successful", then for the log to stop at
#   "kexec_core: Starting new kernel". That is the end of the console (§8.7).
#   Confirm the worker is really up with talosctl, not by watching:
head$   talosctl -n 172.16.0.2 version
```

Then the second:

```
devbox$ openstack server reboot --hard ${TW_PREFIX}-w2
# … same wait …
```

📌 **For the second worker, skip ahead to §10.6 first and watch Kubernetes instead.** Once the kubeconfig exists, `watch -n 10 "kubectl get nodes"` on the head is a far better progress indicator than the console log — it goes from nothing, to `NotReady`, to `Ready` as the worker joins, and it never freezes the way the console does at `kexec_core`. The console-log route above is written first only because it is the one that works before there is a cluster to ask.

Once you trust the sequence, it parallelises — every worker can be rebooted at once, since BSS serves them all the same payload.

## Step 10.6 — Get the kubeconfig

```
head$ cd ~/talos
head$ talosctl kubeconfig .
head$ kubectl get nodes -o wide
```

`talosctl kubeconfig <dir>` writes `<dir>/kubeconfig`, so running it from `~/talos` puts the file exactly where §10.3's `~/tw-head-talos-env.sh` already points `KUBECONFIG`. No export needed — if you find yourself typing one, `tw-head-talos-env.sh` isn't being sourced and §11 onward will keep breaking.

## ✅ Checkpoint — the one that matters

```
head$ kubectl get nodes
NAME      STATUS   ROLES           AGE     VERSION
nid0001   Ready    control-plane   3d11h   v1.36.0
nid0002   Ready    <none>          3d11h   v1.36.0
nid0003   Ready    <none>          3d10h   v1.36.0
```

⟨captured 10 Aug 2026, three days after the nodes booted — on a fresh run the `AGE` column reads minutes. `v1.36.0` is the Kubernetes version Talos v1.13.0 ships; it is not something you chose.⟩

`Ready` nodes mean the whole chain worked: an instance booted iPXE off its own root disk, CoreDHCP answered from SMD, BSS served the right Talos payload per role, Talos installed itself over that root disk and pulled Kubernetes through the head's NAT, the control plane bootstrapped, and the workers joined.

**You now have a Kubernetes cluster provisioned by OpenCHAMI on OpenStack.** That is Step −1's core objective.

Two more confirmations worth having in your run log:

```
head$ talosctl -n ${TW_CP_IP} get members
NODE         NAMESPACE   TYPE     ID        VERSION   HOSTNAME   MACHINE TYPE   OS                ADDRESSES
172.16.0.1   cluster     Member   nid0001   1         nid0001    controlplane   Talos (v1.13.0)   ["172.16.0.1"]
172.16.0.1   cluster     Member   nid0002   1         nid0002    worker         Talos (v1.13.0)   ["172.16.0.2"]
172.16.0.1   cluster     Member   nid0003   1         nid0003    worker         Talos (v1.13.0)   ["172.16.0.3"]
```

This is Talos's own view of the cluster, assembled independently of Kubernetes, and it confirms three separate things that `kubectl get nodes` cannot:

- **`MACHINE TYPE`** — `controlplane` on `nid0001` and `worker` on the other two. That is BSS's per-MAC payload from §9.2 landing correctly: each node fetched `controlplane.yaml` or `worker.yaml` according to which one you registered against its MAC. Get that mapping wrong and you find out here, not from `kubectl`.
- **`ADDRESSES`** — the SMD-mapped `172.16.0.x`, so CoreDHCP answered from SMD rather than handing out a bootloop lease (§6).
- **`HOSTNAME`** — `nid000x`, matching the Kubernetes node names, which is the evidence that the naming comes from the provisioning chain rather than from Kubernetes.

`VERSION` is the resource version of the member record, not a version of anything you installed; `1` means it was written once and has not changed since.

📌 **This table is the one thing here that needs the internet.** Talos assembles it via `discovery.talos.dev`, which the nodes reach through §5.12's NAT — so an air-gapped cluster shows an empty list while being perfectly healthy. Nothing else in this tutorial depends on it, and if it *is* empty, trust `kubectl get nodes`. [Issue 004](issues/004-cluster-discovery-needs-the-internet.md) has the detail, including why the obvious fix is wrong.

```
head$ kubectl get pods -A
NAMESPACE     NAME                              READY   STATUS    RESTARTS        AGE
kube-system   coredns-6dc87b5c58-4fpgp          1/1     Running   0               3d11h
kube-system   coredns-6dc87b5c58-rq2r7          1/1     Running   0               3d11h
kube-system   kube-apiserver-nid0001            1/1     Running   0               3d11h
kube-system   kube-controller-manager-nid0001   1/1     Running   5 (3d11h ago)   3d11h
kube-system   kube-flannel-59d4z                1/1     Running   0               3d11h
kube-system   kube-flannel-8w294                1/1     Running   0               3d11h
kube-system   kube-flannel-km2wl                1/1     Running   0               3d11h
kube-system   kube-proxy-66n59                  1/1     Running   0               3d11h
kube-system   kube-proxy-7cxbl                  1/1     Running   0               3d11h
kube-system   kube-proxy-jmp2p                  1/1     Running   0               3d11h
kube-system   kube-scheduler-nid0001            1/1     Running   5 (3d11h ago)   3d11h
```

Read that as three of everything per-node (`kube-flannel`, `kube-proxy` — DaemonSets), one of everything control-plane (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, suffixed with the node they run on), and two CoreDNS replicas.

📌 **`RESTARTS 5` on the controller-manager and the scheduler is expected, and only on the first bootstrap.** Talos starts all three control-plane static pods together, but the controller-manager and the scheduler cannot do anything until the API server is answering, so they crash-loop for the ~90 seconds it takes to come up. The `(3d11h ago)` means the last restart was at bootstrap and there has been none since — that is the number to look at, not the count. A restart count that is still *climbing* is a real fault; see Common failures.

🛑 **Kubernetes node names are `nid0001`, `nid0002`, … — not `tw-cp1` and `tw-w1`.** This surprises people, and it is worth understanding rather than working around.

The Nova instance name is a label in OpenStack and nothing more; it never reaches the guest. Talos takes its hostname from **DHCP**, and the DHCP server is OpenCHAMI's CoreDHCP, which answers from SMD — so the name Kubernetes ends up with is derived from the node's SMD identity (`x1000c0s0b0n0`, NID 1), not from what you typed at `server create`. **That is the correct behaviour**: OpenCHAMI is the source of truth for node identity, which is the whole premise of this exercise (DL-003). A cluster whose nodes were named after Nova instances would mean Nova had won.

Practical consequences, all of them small:

- `kubectl` commands take `nid0001`; `openstack` commands take `tw-cp1`. Keep the mapping to hand — it is `172.16.0.1` → `nid0001` → `tw-cp1`, in SMD/Kubernetes/Nova order.
- §16's node labelling uses the `nid…` names.
- §10.7's `kubectl drain` and `kubectl delete node` take `nid…`, while the `openstack server rebuild` on the next line takes `tw-…`. That command block deliberately shows both.

## Step 10.7 — The reboot difference, and how to re-provision

This is worth doing once, because it is the thing that distinguishes Talos from the libvirt lab's diskless Rocky nodes.

🛑 **Do the plain reboot before §11, not after.** It is the only step in the whole tutorial that boots a node through its **firmware**. Every boot up to here ended in a `kexec` (§8.7), which jumps straight into the new kernel and bypasses firmware, boot order and the disk bootloader entirely — so until you do this, nothing has proved that an installed node survives a power cycle. That is a poor thing to discover in §14.

**A plain reboot keeps everything:**

```
devbox$ openstack server reboot ${TW_PREFIX}-cp1
head$   kubectl get nodes
NAME      STATUS     ROLES           AGE     VERSION
nid0001   NotReady   control-plane   3d11h   v1.36.0
nid0002   Ready      <none>          3d11h   v1.36.0
nid0003   Ready      <none>          3d11h   v1.36.0
```

⟨captured 10 Aug 2026, ~30 s after the reboot. `nid0001` returns to `Ready` a minute or so later; the workers never notice.⟩

Read the `AGE` column: `3d11h`, unchanged. This is the **same node**, not a new one — Nova did not re-image anything and Kubernetes did not re-register it. `kube-apiserver` and the two controllers show a fresh `AGE` of seconds because Talos restarted the static pods; the node object, etcd and the machine config are all as they were.

Two things are worth confirming while it comes back, because both are informative:

```
head$ kubectl get pods -A | grep -v '  0  '
kube-system   coredns-6dc87b5c58-4fpgp          1/1   Running   1 (2m9s ago)    3d11h
kube-system   kube-controller-manager-nid0001   1/1   Running   2 (36s ago)     19s
kube-system   kube-flannel-km2wl                1/1   Running   1 (2m14s ago)   3d11h
kube-system   kube-proxy-jmp2p                  1/1   Running   1 (2m14s ago)   3d11h

head$ talosctl -n ${TW_CP_IP} get members
172.16.0.1   cluster   Member   nid0001   2   nid0001   controlplane   Talos (v1.13.0)   ["172.16.0.1"]
172.16.0.1   cluster   Member   nid0002   1   nid0002   worker         Talos (v1.13.0)   ["172.16.0.2"]
```

Only the pods **on the rebooted node** restarted — one flannel, one kube-proxy, and CoreDNS because a replica happened to be scheduled there. The other two nodes' DaemonSet pods still read `0`. And `nid0001`'s member `VERSION` has gone `1` → `2`: the record was rewritten when the node rejoined, which is the version column doing exactly what it says.

📌 **`kubectl` will say `The connection to the server 172.16.0.1:6443 was refused` for the first minute.** That is the API server on the rebooting node, and it is the *other* meaning of that message — not the missing-`KUBECONFIG` one from §10.3. Note that `talosctl` keeps working throughout, because it talks to Talos on `:50000` rather than to Kubernetes.

Talos **persists to disk**. It reboots straight off its own disk back into the same node — config, etcd and all. The libvirt lab's Rocky nodes rebuilt themselves from an image every boot; Talos does not. That is the immutable-*but-persistent* model, and it is the right one for a Kubernetes node that holds etcd.

✅ **What this proves, and it is the last unproven link in the chain.** The install in §10.1 really did displace iPXE on `/dev/vda` and leave a bootable system behind it: the firmware found systemd-boot, systemd-boot found the UKI, and the node came back as itself. That was the open question in [DL-002](DECISION-LOG.md#dl-002--how-a-node-network-boots) — option G's whole premise is that the reinstall loop self-terminates because Talos overwrites the iPXE image it booted from — and this is the evidence for it.

Note this is a *soft* reboot, and it works now where §10.1 needed `--hard`: there is a real operating system on the node to answer the ACPI request.

**To genuinely re-provision a node**, put iPXE back on its root disk. That is what `rebuild` does:

```
head$   kubectl drain nid0002 --ignore-daemonsets --delete-emptydir-data
head$   kubectl delete node nid0002
devbox$ openstack server rebuild ${TW_PREFIX}-w1 --image ${TW_PREFIX}-ipxe-disk --wait
```

The instance comes back with an 8 MB iPXE image where Talos used to be, boots it, and walks the whole of §10.1 again by itself — BSS still has its payload, SMD still has its MAC, nothing on the OpenCHAMI side changed. **The console works again for the duration**, because a rebuilt node is network-booting; it goes quiet once more at `kexec_core`. Wait for `installation successful`, then confirm with `talosctl -n 172.16.0.2 version` and `kubectl get nodes`.

⚠ **`rebuild` destroys the root disk, which is exactly what re-provisioning means — and exactly why it is dangerous elsewhere.** On a node it is the correct tool. On the **head node** it would erase OpenCHAMI, the S3 bucket and your machine configs. Check the instance name before pressing return; §1 says the same thing more loudly.

🛑 **Never rebuild or `reset` the control-plane node** while it is the only one. That destroys etcd and the cluster with it. To rebuild the whole cluster, rebuild all three nodes and start again from §10.1 — the OpenCHAMI side needs no changes at all, which is rather the point.

> **Why `rebuild` and not `talosctl reset`?** `reset` wipes Talos's own partitions and reboots — but on a node whose root disk is *only* Talos, that leaves nothing bootable, and no way to network-boot back in. `rebuild` restores the thing that starts the chain. Use `reset` only when you intend to reinstall via `talosctl` from maintenance mode.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `openstack server reboot` appears to do nothing | you omitted `--hard`, and there is no OS to receive the ACPI request (§10.1) |
| iPXE never gets an address | §3 (Neutron DHCP still on, or port security still on) or §5.7 (CoreDHCP not listening on the right interface) |
| iPXE gets a `172.16.0.2xx` address | bootloop lease: MAC unknown to SMD (§6), or the coresmd cache is broken (§5.10's certificate gotcha) |
| iPXE errors fetching the bootscript | BSS down, or the MAC has no payload (§9) |
| `bootscript : 127 bytes`, then a sleep and a retry, for ever | BSS has **no boot parameters** for that MAC — this is the retry loop working as designed (§7's checkpoint shows the same thing). Re-check that §9.2's `bss boot params set` covered this MAC |
| iPXE errors fetching the kernel (`403`) | the `boot-images` bucket isn't public-read (§8.3) |
| Talos stays in **maintenance mode** | `talos.config` URL unreachable or wrong — §8's `206` checkpoint, then §9's bootscript checkpoint |
| `no disks matched the expression` | §8.6's `diskSelector` found nothing ≥ 10 GB. Check the flavor actually gave this node a root disk, then loosen the selector and re-publish |
| Talos stuck at `downloading installer` | NAT/forwarding (§5.12) or DNS (§8.6). The single most common failure |
| Blank console, no output at all | wrong `console=` for the platform — must be `ttyS0,115200` on x86_64 (§9). Fix the payload and re-run `bss boot params set` |
| **Node installs, then network-boots and installs again, for ever** | `wipe` is not `true` in §8.6, so the iPXE EFI partition survived the install. Fix the patch, re-publish (§8.7), then `openstack server rebuild` the node |
| `talosctl version` shows only a Client | the node's API isn't up. Console log first; then check the node actually rebooted from disk |
| `talosctl bootstrap` → `etcd is already bootstrapped` | it ran twice. Harmless if the cluster is healthy; check `talosctl health` |
| `talosctl health` hangs, or fails discovering nodes | server-side health needs `discovery.talos.dev` over the internet. Use the `--server=false` form in §10.4 — the cluster itself is probably fine |
| `talosctl` → `error constructing client: failed to determine endpoints`, even with `-n 172.16.0.1` | `TALOSCONFIG` unset. `-n` names the node to *act on*; the endpoint to *connect to* is read from the talosconfig file, which `talosctl` cannot find. §10.3 |
| `kubectl` → `The connection to the server localhost:8080 was refused` | `KUBECONFIG` unset — the same cause, and the two travel together. Both are fixed for good by §10.3's `~/tw-head-talos-env.sh`, not by exporting one of them |
| `talosctl` → `certificate signed by unknown authority`, or connection refused on `:50000` | wrong `talosconfig`, or `TALOSCONFIG` isn't exported in *this* shell. `echo $TALOSCONFIG` first |
| controller-manager or scheduler `RESTARTS` still **climbing** hours after bootstrap | not the bootstrap crash-loop the checkpoint describes. `talosctl -n 172.16.0.1 logs kube-scheduler` — usually the API server flapping, or the node out of memory |
| Workers never appear in `kubectl get nodes` | they can't reach `https://172.16.0.1:6443` — confirm the worker got its SMD-mapped IP, and that `grep endpoint worker.yaml` points at `172.16.0.1` |
| `kubectl` → `x509: certificate is valid for …, not 172.16.0.1` | §8.6's `certSANs` patch didn't apply — re-patch, re-publish, and rebuild the node |

Next: [§11 — Cluster foundations](11-cluster-foundations.md)
