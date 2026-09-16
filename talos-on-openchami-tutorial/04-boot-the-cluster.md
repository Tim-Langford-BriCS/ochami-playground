# §4 — Booting the Talos cluster

*(Time: ~20 minutes, most of it Talos pulling images on first boot. VM
creation on the **host** (`host$`); cluster bring-up from the **head**
(`head$`). Replaces base §10.)*

## Concepts

This is the payoff: the OpenCHAMI control plane provisions bare-metal (here,
VM) nodes, and those nodes form a Kubernetes cluster. The boot chain is the
same as the base tutorials up to the kernel — then it diverges:

1. UEFI PXE-boots → **CoreDHCP** leases the SMD-mapped IP and points at iPXE.
2. iPXE chains to **BSS**, which returns §3's Talos script.
3. iPXE fetches Talos `vmlinuz` + `initramfs.xz` and boots them **into RAM**.
4. With no OS on disk yet, Talos enters **maintenance mode**, then fetches
   its machine config from `talos.config` (§2/§3).
5. Talos pulls its **installer** image (needs §1's internet), writes itself
   to `/dev/vda`, and **reboots — now from disk**.
6. The control-plane node runs `kube-apiserver` etc. once bootstrapped;
   workers join it automatically.

🔀 **Two deviations from base §10.** (a) The VM gets a **real disk** — Talos
installs to it (base §10 used `--disk none`). (b) Boot order is **disk
first, network fallback** (`--boot uefi,hd,network`), *not* `--pxe`. On the
empty first boot the firmware falls through to PXE; after install the disk
is bootable and wins — so the node does **not** re-PXE into a reinstall
loop. This is the boot-order requirement the Talos PXE guide calls out.

⚠ **If you already ran base §10**, you have `compute1`(+) VMs holding these
same MACs. Remove them first so the MACs are free:
`host$ for v in compute1 compute2 compute3 compute4 compute5; do virsh destroy $v 2>/dev/null; virsh undefine --nvram $v 2>/dev/null; done`

## Step 4.1 — Create and start the control-plane node

```
host$ virt-install \
    --name talos-cp1 \
    --memory 4096 \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant generic \
    --disk size=10,bus=virtio \
    --network network=openchami-net-internal,model=virtio,mac=52:54:00:be:ef:01 \
    --boot uefi,hd,network \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole
```

Watch it (Talos shows a **dashboard**, not a login — there is no shell):

```
host$ virsh console talos-cp1
```

(Exit with `Ctrl+]`.) You'll see PXE → iPXE → the Talos kernel → a
maintenance-mode banner → config fetch → `downloading installer` → install →
reboot into the dashboard, which then reports the machine and Kubernetes
state. Getting past `downloading installer` is the live proof §1's NAT
works.

> **`--boot uefi,hd,network` rejected by your virt-install?** Some versions
> want the firmware separately. Fall back to `--boot uefi` plus setting the
> boot order once in the UEFI menu (disk before NIC), or add `--boot
> uefi,hd,network,bootmenu.enable=on`. Do **not** use `--pxe` — it forces
> network-first and reinstalls on every reboot.

## Step 4.2 — Point `talosctl` at the node and bootstrap

Configure your client (the `talosconfig` from §2) with the node/endpoint:

```
head$ cd ~/talos
head$ export TALOSCONFIG=$PWD/talosconfig
head$ talosctl config endpoint 172.16.0.1
head$ talosctl config node 172.16.0.1
```

Wait until the Talos API answers (a minute or two after the post-install
reboot), then **bootstrap etcd — exactly once, on this one control-plane
node**:

```
head$ talosctl version                # confirms the API is up (client + server)
head$ talosctl bootstrap
```

⚠ **Run `bootstrap` only once, only here.** Running it again, or on a
worker, corrupts etcd.

## Step 4.3 — Start the worker(s)

Bring up one worker (repeat with the other MACs/names for more). They boot
the same assets but fetch `worker.yaml`, and join the control plane at
`172.16.0.1` on their own:

```
host$ virt-install \
    --name talos-w1 \
    --memory 3072 \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant generic \
    --disk size=10,bus=virtio \
    --network network=openchami-net-internal,model=virtio,mac=52:54:00:be:ef:02 \
    --boot uefi,hd,network \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole
```

## Step 4.4 — Get the kubeconfig and see the cluster

```
head$ talosctl health --nodes 172.16.0.1        # waits for control plane to be healthy
head$ talosctl kubeconfig .                       # writes ./kubeconfig
head$ kubectl --kubeconfig=./kubeconfig get nodes -o wide
```

## ✅ Checkpoint

```
head$ kubectl --kubeconfig=./kubeconfig get nodes
NAME        STATUS   ROLES           AGE   VERSION
talos-cp1   Ready    control-plane   5m    v1.3x.x
talos-w1    Ready    <none>          2m    v1.3x.x
```

`Ready` nodes = the whole chain worked: OpenCHAMI PXE-booted Talos, Talos
installed itself and pulled Kubernetes over §1's NAT, the control plane
bootstrapped, and the worker joined. You now have a real Kubernetes cluster
provisioned by OpenCHAMI. (Node names come from Talos; the k8s node name is
the machine's hostname, not the SMD `compute1` name.)

## Step 4.5 — The reboot difference

```
host$ virsh reboot talos-cp1
```

Unlike the base tutorials' stateless diskless node, Talos **persists to
disk**: it reboots straight off `/dev/vda` back into the same node — etcd,
config and all. To truly re-provision a Talos node you `talosctl reset` it
(wipe) and let it PXE-reinstall, or repoint its BSS payload; a plain reboot
keeps its state. That is the immutable-but-persistent model, distinct from
the base tutorials' rebuild-from-image-every-boot model.

## Common failures → §5

The usual first-boot snags — stuck at `downloading installer` (§1 NAT/DNS),
stuck in maintenance mode (`talos.config` unreachable), or a blank console
(wrong `console=` for your arch) — are mapped in
[§5 — Troubleshooting](05-troubleshooting.md).

Next: [§5 — Troubleshooting](05-troubleshooting.md)
