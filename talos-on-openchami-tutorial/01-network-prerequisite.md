# §1 — Network prerequisite: internet for the compute nodes

*(Time: ~10 minutes. On the head node. New requirement — the base tutorials
did not need this.)*

## Concepts

**Why this step exists.** The base tutorials' internal network is
deliberately *isolated*: its libvirt definition has no `<forward>` and no
`<ip>`, so it has no NAT and no route off the wire. The Rocky diskless image
never cared — everything it needed (kernel, initramfs, SquashFS, cloud-init)
was served by the head at `172.16.0.254`.

**Talos is not self-contained.** On first boot it must pull:

- its installer image `ghcr.io/siderolabs/installer:<version>` (to write
  itself to disk), and
- all the Kubernetes control-plane and kubelet images
  (`registry.k8s.io`, `ghcr.io/siderolabs/...`).

None of those live on the head. So the compute nodes need a path to the
internet. The good news: **CoreDHCP already tells every node its default
route and DNS are `172.16.0.254`** (the head) — check any lease in the base
tutorials and you'll see `router: 172.16.0.254`. The nodes are *already*
sending off-subnet traffic to the head; the head just isn't forwarding it
yet. We fix that here, on the head only — no libvirt or CoreDHCP change, so
the "only CoreDHCP speaks DHCP on the wire" invariant is preserved.

Two things must work for image pulls: **routing** (this step) and **DNS
resolution** of registry hostnames (handled in §2 by pinning public
nameservers in the Talos machine config, because OpenCHAMI's CoreDNS only
answers cluster names).

🔀 **Deviation.** The base tutorials keep the internal wire fully isolated.
We turn the head into a NAT router for `172.16.0.0/24`. This is the one
place Talos forces a substrate change; everything else is additive.

## Step 1.1 — Identify the head's two interfaces

```
head$ ip -brief addr | grep -E '172\.16\.0\.254|192\.168\.200'
```

You'll see the **internal** interface holding `172.16.0.254/24` and the
**external** interface holding the `192.168.200.x/24` address that already
has internet (it's how the head downloaded packages during setup). Note the
external interface name — call it `<EXT_IF>` below. Confirm the external
path works:

```
head$ ping -c1 1.1.1.1
```

## Step 1.2 — Enable IP forwarding

```
head$ echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-talos-nat.conf
head$ sudo sysctl -p /etc/sysctl.d/99-talos-nat.conf
net.ipv4.ip_forward = 1
```

(The `sysctl.d` drop-in makes it survive reboots; `sysctl -p` applies it
now.)

## Step 1.3 — Masquerade internal traffic out the external interface

**If `firewalld` is running** (Rocky 9 default — check with
`systemctl is-active firewalld`):

```
head$ sudo firewall-cmd --permanent --add-masquerade
head$ sudo firewall-cmd --reload
```

(`--add-masquerade` both enables masquerading and permits forwarding for the
default zone, which is where both interfaces sit in the base setup.)

**If `firewalld` is inactive**, add an nftables masquerade rule directly
(Rocky 9 ships `nft`):

```
head$ sudo nft add table ip nat
head$ sudo nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }'
head$ sudo nft add rule ip nat postrouting ip saddr 172.16.0.0/24 oif "<EXT_IF>" masquerade
```

To persist the nftables rule across reboots, append those three lines to
`/etc/sysconfig/nftables.conf` (or your distro's nftables include) and
`sudo systemctl enable --now nftables`.

## ✅ Checkpoint

You can't test from a compute node yet (none is booted). Instead confirm the
head will route and masquerade for the subnet. Forwarding on:

```
head$ sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 1
```

Masquerade rule present (one of these, matching the method you used):

```
head$ sudo firewall-cmd --query-masquerade        # -> yes
head$ sudo nft list chain ip nat postrouting       # -> shows the masquerade rule
```

The real proof comes in §4: a booting Talos node gets past *"downloading
installer"* only if this step worked. If it stalls there, come back here
(and check §2's nameservers).

## Common failures

| Symptom | Cause / fix |
|---|---|
| §4 node hangs at `downloading installer` / `pulling` forever | forwarding or masquerade not actually applied on the head — re-run 1.2/1.3; confirm `<EXT_IF>` is the *external* NIC |
| node can `ping 1.1.1.1` but not resolve `ghcr.io` | DNS, not routing — that's the §2 `nameservers` fix, not this step |
| head loses its own internet after adding rules | you masqueraded the wrong interface or added a broad DROP — remove the rule and re-add scoped to `172.16.0.0/24` out `<EXT_IF>` |

Next: [§2 — Talos assets and machine config](02-talos-assets-and-config.md)
