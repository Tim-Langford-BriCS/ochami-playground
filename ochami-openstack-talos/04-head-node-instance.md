# §4 — The head node instance

*(Time: ~15 minutes, plus a few minutes' first boot. This creates the machine that will run the entire OpenCHAMI control plane.)*

```
devbox$ cd ~/tw && source ~/tw/tw-env.sh
```

## Concepts

![The path from your laptop to the head node: Lima devbox VM, macOS NAT, the F5 VPN tunnel utun10, the shared external network, tw-router and its floating IP, the routed tw-ext network, and the tw-head instance with its two Neutron ports — one filtered on tw-ext, one with port security disabled on the silent tw-prov wire.](diagrams/04-head-node-path.svg)

*Everything §4 builds, and everything it depends on. The values are from our run on 2 Aug 2026 — yours will differ, the shape will not. [Appendix E](appendix-e-network-map.md) has the same diagram extended through the compute nodes.*

The head node is an ordinary Rocky 9 instance with **two network interfaces** — one on each network from §3 — that will run the whole OpenCHAMI control plane:

| NIC | Network | Address | Purpose |
|---|---|---|---|
| first | `tw-ext` | `192.168.200.x` (DHCP) + a floating IP | SSH in; downloads out |
| second | `tw-prov` | `172.16.0.254` (static) | serves DHCP/TFTP/DNS/boot artifacts to nodes |

`172.16.0.254` matters: every OpenCHAMI config in §§5–9 refers to it. It is *the* cluster head address as far as the compute nodes are concerned.

**cloud-init, without a seed ISO.** In the libvirt lab we hand-built a tiny ISO labelled `cidata` containing `user-data`, `meta-data` and `network-config`, because nothing else was going to feed cloud-init. On OpenStack, **Nova is the cloud-init datasource** — it publishes exactly that data over the metadata service (or a config drive), assembled from what you pass to `server create`. That is why the libvirt lab deliberately chose the cloud-image route over kickstart: it is the mechanism clouds use natively, so it carries over here unchanged.

**How the static IP happens — a pleasant surprise.** We never tell cloud-init that the second NIC is `172.16.0.254`. Nova works it out: it generates the instance's network metadata from the Neutron ports, and because `tw-prov-subnet` has **DHCP disabled** (§3.2), Nova describes that port as a *static* address configuration carrying the port's fixed IP. cloud-init reads it and configures the interface statically. So §3.4's `--fixed-ip …ip-address=172.16.0.254` is not just IPAM bookkeeping — it is how the head gets its provisioning address.

That single fact removes the whole `network-config` file from the libvirt lab.

**Interface names — discover them, don't predict them.** The libvirt lab pinned `eth0`/`eth1` by matching on MAC, so §5's CoreDHCP config could say "listen on `eth1`" and always be right. We expected Rocky 9 on OpenStack to use systemd's predictable naming instead and produce something like `enp3s0`/`enp4s0`.

**It did not.** On Digital Labs the head comes up with plain `eth0` and `eth1` — the Rocky GenericCloud image disables predictable naming, as most cloud images do, because a cloud image cannot know what bus its NICs will be on. That is a happy accident for us: the names match the libvirt lab exactly, so §5.7's CoreDHCP config needs no substitution at all.

Do not rely on that. A different image, or a different cloud, will name them differently and there is no warning when it does — §5's DHCP server simply binds to nothing. §4.6 *reads* the name off the running instance and records it as `TW_PROV_IF`, and §5.7 substitutes whatever you found. That is one line of deviation from the lab, and it is the only robust approach.

## Step 4.1 — An SSH keypair

```
devbox$ ssh-keygen -t ed25519 -N '' -f ~/.ssh/tw_ed25519
devbox$ openstack keypair create --public-key ~/.ssh/tw_ed25519.pub ${TW_PREFIX}-key
```

(`-N ''` = no passphrase; this key exists only for the lifetime of the lab and is in the tutorial's `.gitignore`.) `openstack keypair create` uploads the *public* half to Nova, which injects it into the instance via cloud-init.

## Step 4.2 — Check the head node's flavor

A **flavor** is an instance's hardware specification: how many vCPUs, how much RAM, how large a root disk. You do not describe the hardware machine by machine as you would with `virt-install` — you pick from a list of flavors that a cloud administrator defined, and the flavor is fixed for the life of the instance. §1.5 is where you identified the three this tutorial uses and wrote their names into `tw-vars-env.sh`; here you confirm the head's is what you think it is, before anything is created.

```
devbox$ openstack flavor show ${TW_FLAVOR_HEAD} -c name -c vcpus -c ram -c disk
```

```
+-------+----------------------+
| Field | Value                |
+-------+----------------------+
| name  | techwatch-proto-head |
| vcpus | 4                    |
| ram   | 16384                |
| disk  | 60                   |
+-------+----------------------+
```

Where those numbers come from:

| Field | Ours | Why |
|---|---|---|
| `vcpus` | **4** | the head runs roughly a dozen small containers (§5) plus `talosctl` and `kubectl`. It does no compute of its own — the inference workload lives on the workers — so this is modest by design |
| `ram` | **16384** MB | Postgres, the OpenCHAMI microservices, an OCI registry and an S3 store, none individually large. 8 GB works and leaves nothing spare |
| `disk` | **60** GB | the one number worth being generous with. The head stores the Talos kernel and initramfs, every machine config, and ~18 container images. **40 GB is the floor.** Upstream OpenCHAMI suggests 20 GB, which fills up partway through §5 |

If your head flavor has **less than 40 GB**, that is workable — you add a separate disk for the bulky part — but do nothing about it yet. [§4.7](#step-47--more-room-for-data-only-if-you-need-it) handles it, once the instance exists and you can see the real free space.

**Now the check that matters more.** The same flavor also carries a *placement trait*, and that trait is what confines this project to its own hypervisor (§1.5):

```
devbox$ openstack flavor show ${TW_FLAVOR_HEAD} -c properties -f value 2>/dev/null \
          | tr ',' '\n' | grep "trait:${TW_TRAIT}"
 'trait:CUSTOM_TECHWATCH_PROTO': 'required'
```

That line must appear. Booting from a flavor without it puts your instance on a shared hypervisor alongside other people's work — the exact outcome §1 exists to prevent — and nothing later in the tutorial will warn you. Because a member credential cannot read `OS-EXT-SRV-ATTR:host` (§1.6), this is the strongest check you can make *before* creating anything. If the trait is missing but other properties printed, **stop and ask** rather than proceeding.

> If `properties` comes back empty entirely, Nova policy is hiding extra specs from your credential. That is not a failure; it means you cannot self-verify, so fall back to the admin-side placement check in §1.6 immediately after the instance exists.

⚠ **Check `min_disk` on the image too.** `openstack image show $TW_HEAD_IMAGE -c min_disk` — a flavor whose disk is smaller than the image's `min_disk` is refused at create time.

🔀 **Deviation — you cannot invent a flavor.** In our libvirt lab we wrote `--memory 4096 --vcpus 2` and `qemu-img create … 40G` per VM. Here flavors are cloud-wide and administrator-defined (§2), and these ones additionally carry the CPU-pinning and hugepage properties the Digital Labs hosts require. If the three flavors do not exist yet, that is §1.5's recon step, not this one — and if you hold `admin` and are creating them yourself, [`runbooks/create-project-flavors.md`](runbooks/create-project-flavors.md) is the procedure, including what every property means.

## Step 4.3 — The cloud-init user-data

```
devbox$ cat > ~/tw/head-user-data.yaml << EOF
#cloud-config

# The admin user. 'rocky' is the Rocky cloud image's conventional name and is
# what every 'head\$' command in this tutorial assumes.
users:
  - name: rocky
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/tw_ed25519.pub)

# SELinux permissive, not disabled: containers and quadlets in §5 hit enough
# labelling friction that enforcing gets in the way during bring-up, but
# permissive still logs what WOULD have been denied - which is the information
# you want when hardening this later for the PTR.
write_files:
  - path: /etc/selinux/config
    content: |
      SELINUX=permissive
      SELINUXTYPE=targeted

package_update: true
packages:
  - podman
  - jq
  - git
  - tmux
  - bind-utils
  - nftables

runcmd:
  - setenforce 0 || true
EOF
```

Note the **unquoted** `EOF`: we *want* the shell to substitute `$(cat ~/.ssh/tw_ed25519.pub)` so your public key ends up in the file. Check it did before continuing:

```
devbox$ grep -c 'ssh-ed25519' ~/tw/head-user-data.yaml     # must print 1
```

There is a copy at [`templates/head-user-data.yaml`](templates/head-user-data.yaml).

🔀 **Deviation — no `network-config`, no `meta-data`.** Both were files on the libvirt lab's seed ISO. Nova generates the equivalents: `meta-data` from the instance name and ID, and the network configuration from the Neutron ports, as explained above.

## Step 4.4 — Create the instance

```
devbox$ openstack server create ${TW_PREFIX}-head \
    --image ${TW_HEAD_IMAGE} \
    --flavor ${TW_FLAVOR_HEAD} \
    --key-name ${TW_PREFIX}-key \
    --port ${TW_PREFIX}-head-ext \
    --port ${TW_PREFIX}-head-prov \
    --user-data ~/tw/head-user-data.yaml \
    --config-drive true \
    --wait
```

Flag by flag:

- **`--port` twice, in this order.** Not `--network`. Using the pre-created ports from §3.4 is what pins the MACs and the `.254` address. **Order matters**: the first `--port` becomes the first NIC. Put the external port first so that the default route lands on the routed network.
- **`--user-data`** — the cloud-config from §4.3.
- **`--config-drive true`** — publish the metadata as a small attached disk rather than only via the network service at `169.254.169.254`. Slightly belt-and-braces, but the metadata service is reached over the network, and this head node has an unusual network configuration; a config drive cannot be affected by it.
- **No `--availability-zone`, deliberately.** At Digital Labs the project is pinned by the **placement trait on the flavor**, not by an availability zone or a host aggregate (§1.5) — so `${TW_FLAVOR_HEAD}` is already carrying the isolation. An AZ could not carry it anyway: the zones here are per-rack (`DL-Rack-5`) and a rack holds several hypervisors, so asking for the zone would still leave the scheduler free to choose among them. If yours pins by AZ instead, add `--availability-zone ${TW_AZ}` here and in §7; §1.5 is where you established which it is. Note the failure mode if you add it wrongly: `No valid host was found`, which reads exactly like a capacity or flavor problem.
- **`--wait`** — block until the instance is `ACTIVE`. Without it the command returns while the instance is still `BUILD` (§2's "everything is asynchronous").

🛑 **Now verify placement, before creating anything else** — this is §1.6:

```
devbox$ openstack server show ${TW_PREFIX}-head -c 'OS-EXT-SRV-ATTR:host' -f value
None
```

**`None` is the expected answer at Digital Labs, and it is not a failure.** Which host an instance landed on is gated behind Nova's admin-only `os_compute_api:os-extended-server-attributes` policy. The field is simply absent from the response your credential receives, and the client prints `None` for it — you get no error, because nothing went wrong. Read it as "you are not permitted to look", never as "it is not scheduled anywhere".

What you *can* prove unaided is that the mechanism is intact, which is the failure worth catching:

```
devbox$ openstack server show ${TW_PREFIX}-head -c flavor -f value
devbox$ openstack flavor show "$TW_FLAVOR_HEAD" -c properties -f value 2>/dev/null \
          | tr ',' '\n' | grep trait:
 'trait:CUSTOM_TECHWATCH_PROTO': 'required'
```

The instance names the flavor you intended, and that flavor still requires the trait. **An instance booted from a traited flavor cannot be on an untraited host** — Placement would have refused to schedule it, and `server create` would have failed with `No valid host was found` rather than succeeding in the wrong place. So the two commands above are a genuine proof, just an indirect one.

The direct evidence needs somebody with `admin`, once:

```
admin$ openstack server list --project techwatch-proto --long -c Name -c Host
```

🛑 **If that comes back as a hypervisor other than the one set aside for you, stop**, delete the instance, and tell your cloud admin the isolation is not taking effect — do not continue, because every later instance would land in the same wrong place:

```
devbox$ openstack server delete ${TW_PREFIX}-head      # only if placement is confirmed wrong
```

Do not delete on the strength of `None`. Ask for the admin-side check once, here, and again only if you change flavors.

## Step 4.5 — A floating IP

```
devbox$ openstack floating ip create ${TW_EXT_NET}
devbox$ openstack server add floating ip ${TW_PREFIX}-head <FLOATING_IP>
devbox$ echo "export TW_HEAD_FIP=<FLOATING_IP>" >> ~/tw/tw-vars-env.sh
devbox$ source ~/tw/tw-env.sh
```

A **floating IP** is an address Neutron holds on the external network and maps onto one of your instance's private addresses. The instance never sees it — it keeps its `192.168.200.x` address and the router translates. This is how you reach the head over SSH.

`floating ip create` prints a table; **`floating_ip_address` is the value to pass** to `server add floating ip` (the `id` works too; `name` defaults to the same string as the address, which makes the table look more ambiguous than it is). Expect `status` to read `DOWN` at this point — it becomes `ACTIVE`, and `port_id`/`router_id` fill in, only once you associate it.

⚠ **Look at the address you were given before you try to SSH.** At Digital Labs it is in `10.3.0.0/24` — RFC1918, *not* publicly routable despite the name "floating IP". You reach it over the VPN, and that has a consequence for the security group rule §3.5 already created: with a split tunnel, `curl -s ifconfig.me` reports your ordinary internet egress address, while the head sees your **VPN-assigned tunnel address**. If `TW_ADMIN_CIDR` was filled in from `ifconfig.me`, §4.6's SSH will hang — a silent timeout, not a refusal, because a non-matching security group drops packets rather than rejecting them.

Check it now, while it is cheap:

```
devbox$ echo ${TW_ADMIN_CIDR}
86.x.y.z/32                  ← an ordinary ISP address: wrong for a 10.3.x.y destination
```

🛑 **Find the source address on the machine that actually holds the tunnel — not on the devbox.** The devbox is a VM behind its host's NAT, so `ip route get` there reports an address that is private to the VM and never leaves it:

```
devbox$ ip route get 10.3.0.185
10.3.0.185 via 192.168.5.2 dev eth0 src 192.168.5.15    ← Lima's internal NAT. Not what the head sees.
```

On the **laptop** running the VPN client:

```
mac$ route -n get 10.3.0.185 | grep interface
  interface: utun10
mac$ ifconfig utun10 | grep 'inet '
	inet 10.11.0.49 --> 1.1.1.1 netmask 0xffffffff
```

**`10.11.0.49` is the address to allow** — that one line of `ifconfig` output is the whole answer, and the `route -n get` before it is what tells you *which* of the Mac's several `utun` interfaces to read.

⚠ **The F5 allocates from a pool per session, so this address changes on every reconnect** — we saw `.49`, then `.52` an hour later, then `.54` the next day. You therefore have a choice, made in §1.5: a `/32` of the measured address, which is the tightest scope and which you re-issue each session, or the pool range `10.11.0.0/16`, which survives reconnects and is RFC1918 so it does not widen who can reach port 22. Both are defensible; §1.5 has the comparison.

[runbooks/update-tunnel-ip.md](runbooks/update-tunnel-ip.md) has the measure-then-decide procedure for both, and §17's "`TW_ADMIN_CIDR` is not durable" section is the reasoning behind them. Worth reading now rather than in three weeks when a VPN reconnect locks you out of a healthy cluster. The authoritative confirmation is the head's own `sudo journalctl -u sshd | grep Accepted` once you are in — capture it while SSH works.

## Step 4.6 — SSH in, and record the interface name

First boot takes a minute or two while cloud-init applies the config, installs packages and grows the filesystem. Watch it if you like:

```
devbox$ openstack console log show ${TW_PREFIX}-head --lines 40
```

Then:

```
devbox$ ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}
```

You are now "on the head node" — prompts shown as `head$` from here on.

Find the interface that holds the provisioning address, and record it:

```
head$ ip -brief addr | grep 172.16.0.254
eth1             UP             172.16.0.254/24
```

Back on the devbox, save it — §5.7 needs it:

```
devbox$ echo "export TW_PROV_IF=eth1" >> ~/tw/tw-vars-env.sh       # use YOUR value
devbox$ source ~/tw/tw-env.sh
```

⚠ **If the interface has no address**, cloud-init did not receive a static configuration for it. Check `sudo cloud-init query network` on the head and confirm `tw-prov-subnet` really has `enable_dhcp: false` (§3 checkpoint) — Nova only emits a static address when Neutron says the subnet has no DHCP. As a fallback you can configure it by hand:

```
head$ sudo nmcli con add type ethernet ifname eth1 con-name prov \
        ipv4.method manual ipv4.addresses 172.16.0.254/24 ipv6.method disabled
head$ sudo nmcli con up prov
```

## Step 4.7 — More room for `/data`, only if you need it

> ### 🚦 Run one command, then take one of two branches
>
> ```
> head$ df -h /
> ```
>
> | `Avail` | Branch | What you do |
> |---|---|---|
> | **above 40 GB** | **A — skip** | **Nothing at all.** Go straight to the checkpoint. `/data` will be an ordinary directory that §5.1 creates on the root disk |
> | below 40 GB | B — add a volume | the rest of this step |
>
> Branch A is the common one, and it is the one this tutorial's own flavor produces. **Do not run any command below unless you are in branch B** — the `fstab` line in particular persists and will stop the head booting if the device it names does not exist.

⚠ **Corrected 3 Aug 2026, by measuring a real head node.** An earlier version of this step said §5 puts the boot artifacts, machine configs and ~18 container images under `/data`, needing ~35 GB. **That is wrong, and mounting a volume at `/data` captures almost none of the growth.** Measured on a head node with §5 complete:

```
head$ sudo du -sh /var/lib/containers /var/lib/versitygw /opt/workdir /data | sort -rh
2.1G	/var/lib/containers      ← the ~18 container images really live here
6.2M	/opt/workdir             ← three downloaded RPMs; scratch
8.0K	/var/lib/versitygw       ← the S3 buckets; §8's Talos artifacts land here
0	/data                    ← nothing but an empty oci/ directory
```

Where the space actually goes, and why `/data` stays empty:

| Path | Holds | Grows because |
|---|---|---|
| `/var/lib/containers` | ~18 container images | podman's image store — **the only large consumer** |
| `/var/lib/versitygw/data` | the S3 buckets | bind-mounted to `/data` *inside the versitygw container*, which is what made `/data` look like the right place |
| `/data/oci` | the OCI registry's blobs | stays empty here: we never push to it, because Talos is prebuilt and we run no `image-builder` |

The middle row is the trap. `podman inspect versitygw` shows `bind /var/lib/versitygw/data -> /data`, so the container's `/data` and the host's `/data` are different directories with the same name.

**So the decision is much smaller than it looked.** Total root-disk use with §5 complete was **2.9 GB of 59 GB**. §8 adds a Talos kernel and initramfs under `/var/lib/versitygw` — not yet measured here, but hundreds of megabytes, not tens of gigabytes. A 30 GB root disk is very likely sufficient and this whole step probably unnecessary.

**If you do need more room**, mount the volume at **`/var/lib/containers`** — before §5, since it must be empty — not at `/data`. Substitute that path for `/data` in Branch B below, and stop `podman` first if anything is already running.

### First, where the disk you already have came from

The root disk was not created by anything you typed in this step, which is the usual source of confusion. Two different mechanisms make disks, and only the second one is what the rest of §4.7 is about:

| | The root disk — `vda` | A data volume — `vdb` |
|---|---|---|
| Created by | the **flavor's `disk` field**, at `server create` (§4.4) | `openstack volume create`, explicitly |
| Made of | the Glance image, written onto it by Nova | nothing — it arrives blank |
| Partitions and filesystem | **already there**, inside the cloud image | none; you run `mkfs` yourself |
| Sized how | cloud-init's `growpart` expands it to the flavor's size on first boot | exactly the `--size` you asked for |
| Mounted how | `/` by the image's own `fstab` | you add the `fstab` line yourself |
| Lifetime | deleted with the instance | **independent** — survives it, and keeps costing quota |

So a healthy branch-A head shows one disk, fully grown, with nothing left to do:

```
head$ lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
NAME    SIZE FSTYPE  MOUNTPOINT
sr0     520K iso9660              ← the config drive from §4.4's --config-drive
vda      60G                      ← the flavor's disk
├─vda2  100M vfat    /boot/efi    ← an ESP is present — but see the warning below
├─vda3 1000M xfs     /boot
└─vda4 58.9G xfs     /            ← grown from the image's ~10 GB by cloud-init
```

If that is what you see, **§4.7 is finished.** Everything below concerns a disk you do not have.

⚠ **An `/boot/efi` partition is not proof the instance booted via UEFI, and this line used to claim it was.** Most cloud images are hybrid: they carry an ESP *and* an MBR bootloader, so the partition is there whichever way Nova started the guest. What decides it is the image's `hw_firmware_type` property (§1.5) — absent means Nova defaults to BIOS. One command settles it on the running instance:

```
head$ [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
BIOS
```

⟨captured on `tw-head`, Digital Labs, 4 Aug 2026 — **`BIOS`, on an instance whose disk has a mounted ESP.** The Rocky image really is hybrid, Glance carries no `hw_firmware_type` for it, and Nova defaulted to SeaBIOS. So `TW_FIRMWARE=bios` is right, and the old inference from the partition table was wrong.⟩

📌 **If that disagrees with `TW_FIRMWARE`, do not just flip the variable.** `TW_FIRMWARE` records the *head's* firmware, and nothing later depends on the head and the compute nodes matching — [§7.2](07-node-instances-and-ipxe.md#step-72--upload-it-to-glance) pins the node image's firmware explicitly and says why. This estate is deliberately mixed: the head runs **BIOS** from the Rocky image, and the Talos nodes run **UEFI** from `tw-ipxe-disk`, because the boot mechanism §7 uses *is* a UEFI firmware behaviour. Both write to the same serial console, which is all §9's `console=` argument needs — and [§7's checkpoint](07-node-instances-and-ipxe.md#-checkpoint-for-the-section) shows OVMF's own output arriving in `openstack console log show`, which proves it.

---

### Branch B — adding a Cinder volume

A **Cinder volume** is a virtual disk that exists independently of any instance, which you attach much as you would plug in a drive. Because it has its own lifecycle — it survives the instance being deleted — it is worth checking whether you already have one before making another.

**Look first.** Volumes persist across rebuilds, so a second run of this tutorial should reuse the one it made the first time:

```
devbox$ openstack volume list -c Name -c Size -c Status -c "Attached to"
```

- A volume named `${TW_PREFIX}-head-data` and `available` — **yours, from an earlier run.** Reuse it; skip the create below and skip the `mkfs`, since it already has a filesystem and your data on it.
- Nothing matching — create one.
- 🛑 Something else, unattached, that looks the right size — **leave it alone.** A volume you did not create belongs to another user of this project, and the next command in this step erases it. §1.2's rule holds everywhere: create what you need, delete only what you created.

**Create and attach.** In that order, with the instance already `ACTIVE`:

```
devbox$ openstack volume create --size 40 ${TW_PREFIX}-head-data
devbox$ openstack server add volume ${TW_PREFIX}-head ${TW_PREFIX}-head-data
```

Attaching is what gives the volume a device node inside the guest — normally `/dev/vdb`, the second virtio disk. A fresh volume arrives blank, so it must be formatted and mounted before anything can use it.

🛑 **Prove the device is there before you touch it.** Run `lsblk` again — the attach should have added a `vdb` that was not there before:

```
head$ lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
…
vdb      40G                            ← the volume you just attached: blank, no FSTYPE
```

**No `vdb` means the attach did not land, and you must not continue.** `mkfs` and `mount` would fail visibly, but the `fstab` line persists — and the next reboot would hang waiting for a device that does not exist, then drop the head into emergency mode. Check `openstack server show ${TW_PREFIX}-head -c volumes_attached` and fix the attach first.

Only once `vdb` appears, at the size you created and with an **empty** `FSTYPE`:

```
head$ sudo mkfs.xfs /dev/vdb
head$ echo '/dev/vdb /data xfs defaults,nofail 0 0' | sudo tee -a /etc/fstab
head$ sudo mkdir -p /data && sudo mount /data
head$ df -h /data
```

⚠ **`mkfs` destroys whatever is on the device**, so read `lsblk` rather than assuming. If `vdb` already says `xfs`, this is your volume from a previous run — you want the `fstab` and `mount` lines only.

`nofail` is deliberate: it means a volume that is missing or detached later leaves you with no `/data` rather than with no boot. The `fstab` entry itself is what makes the mount survive a reboot; without it the head comes back with an empty `/data` and §5's services fail confusingly.

Nothing else in the tutorial changes either way: §5.1 creates `/data/oci` and the S3 store's directories whether `/data` is a mount point or a plain directory.

## Step 4.8 — Validate the whole path

§4 succeeds or fails as a *chain*, and a break anywhere in it produces the same symptom: an SSH session that hangs. Walk the diagram at the top of this section one hop at a time, so that when something is wrong you know which hop owns it rather than guessing.

Everything here is read-only. Run it from the devbox, with the member credential.

| # | Hop | Command | What it must show |
|---|---|---|---|
| 1 | the flavor's trait | `openstack flavor show $TW_FLAVOR_HEAD -c properties -f value 2>/dev/null \| tr ',' '\n' \| grep trait:` | `trait:CUSTOM_TECHWATCH_PROTO='required'` — the isolation is intact |
| 2 | the instance | `openstack server show ${TW_PREFIX}-head -c status -c flavor -f value` | `ACTIVE`, and the flavor you intended |
| 3 | placement | **admin only** — `openstack server list --project techwatch-proto --long -c Name -c Host` | the hypervisor set aside for you. Run as a member this returns `ForbiddenException: 403 … os_compute_api:servers:detail:get_all_tenants`, and `server show`'s host field reads `None`. **Both are policy, not failure** (§4.4) — do this check once, elevated, then drop back |
| 4 | the floating IP | `openstack floating ip list -c "Floating IP Address" -c "Fixed IP Address" -c Port` | your address, mapped to a `192.168.200.x` fixed IP, with a port ID — not `None` |
| 5 | the security group | `openstack security group rule list ${TW_PREFIX}-sg-head` | ingress tcp/22 and icmp from **the address the head will actually see** — the tunnel, not `ifconfig.me`. See below |
| 6 | the route to it | `ping -c2 ${TW_HEAD_FIP}` | replies. This proves 1–5 and the icmp rule together |
| 7 | SSH | `ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}` | a shell as `rocky` |
| 8 | both NICs | `head$ ip -brief addr` | one `192.168.200.x`, one `172.16.0.254` — proves §3's port pinning worked |
| 9 | egress | `head$ ping -c1 dl.rockylinux.org` | replies, via `tw-router`'s SNAT. §5 downloads several GB through this |

### The source address, and why three commands disagree

Step 5 is the one that catches people, because three plausible-looking commands give three different answers and only one of them is the address the head sees. On Digital Labs the floating IP is `10.3.0.x` — **RFC1918, reachable only through the VPN** — so:

| Where you ask | What you get | Is it right? |
|---|---|---|
| `curl -s ifconfig.me` on the devbox | your ISP's public address | **No.** With a split tunnel that line carries no `10.3.x.y` traffic at all |
| `ip route get ${TW_HEAD_FIP}` on the devbox | a `192.168.x.x` Lima address | **No.** That is the VM's own NAT; it never leaves the VM |
| `route -n get <FIP>` then `ifconfig <utunN>` **on the laptop** | the F5 tunnel address | **Yes** — this is the machine that actually holds the tunnel |

And the authority, once you are in — capture it while SSH works, not after it stops:

```
head$ sudo journalctl -u sshd | grep Accepted | tail -2
Aug 02 17:03:21 tw-head sshd[19317]: Accepted publickey for rocky from 10.11.0.49 port 5601 ssh2: ED25519 SHA256:…
```

**When this later breaks on its own** — and it will, on the first VPN reconnect — `tw_vpn` tells you whether the tunnel dropped or only your address moved, without leaving the devbox:

```
devbox$ tw_vpn
```

If that source address is not in `TW_ADMIN_CIDR`, fix it with §17's add-then-delete procedure — add the correct rule, confirm SSH still works, *then* remove the stale one. Never widen to `0.0.0.0/0`.

⚠ **An F5 pool address is per-session**, so a `/32` that is correct today is stale after the next reconnect and the symptom will be a timeout against a perfectly healthy cluster. If you are keeping this rig for more than a few days, ask your cloud admin for the VPN pool's CIDR and scope the rule to that instead.

## ✅ Checkpoint

```
head$ cat /etc/rocky-release
Rocky Linux release 9.6 (Blue Onyx)

head$ uname -m
x86_64

head$ ip -brief addr | grep -v -E 'lo|LOOPBACK'
eth0             UP             192.168.200.91/24 fe80::5054:ff:fec0:fe01/64
eth1             UP             172.16.0.254/24 fe80::5054:ff:febe:efff/64

head$ ping -c1 dl.rockylinux.org > /dev/null && echo internet OK
internet OK

head$ getenforce
Permissive

head$ df -h / | tail -1
/dev/vda4        59G  1.7G   58G   3% /
```

*Captured on Digital Labs, 2 Aug 2026. Your interface names and the `192.168.200.x` host part will differ; everything else should match.*

Two NICs with the right addresses proves the whole port-pinning mechanism from §3 worked — and note the MAC suffixes visible in the link-local addresses, `…fec0:fe01` and `…febe:efff`, which are `52:54:00:c0:fe:01` and `52:54:00:be:ef:ff` from §3.4. Internet via the router proves §3.1. `x86_64` confirms we are on the architecture the PTR uses — every asset from §8 onward depends on it. `Permissive`, not `Enforcing`, confirms §4.3's cloud-config was applied, which is the clearest evidence that the config drive was read at all.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `OS-EXT-SRV-ATTR:host` prints `None` | **not a failure.** Admin-only Nova policy; the field is absent from a member's response and the client renders it `None` (§4.4, §1.6). Prove the flavor still carries the trait instead, and ask an admin for the host once |
| `No valid host was found` | quota; the host aggregate has no capacity; or — if your project is pinned by a **placement trait** (§1.5) — no host currently advertises the trait, or the flavor's NUMA/hugepage properties can't be satisfied on it. Check `openstack quota show` and `openstack flavor show "$TW_FLAVOR_HEAD" -c properties`, then ask your admin. **Do not** retry in a different AZ, or with an untraited flavor, to "get around" it — that opts you out of the isolation |
| Instance `ERROR`, `fault` mentions the flavor | flavor disk smaller than the image's `min_disk` — see §4.2 |
| SSH times out | give cloud-init another minute; then check the floating IP is associated, that the group permits your current IP (`openstack security group rule list ${TW_PREFIX}-sg-head`), **and that the group is actually bound to the port** (`openstack port show ${TW_PREFIX}-head-ext -c security_group_ids -f value`) — §3.5 binds it in a step separate from creating it, and an unbound port leaves the head carrying only the project's `default` group, which permits no inbound SSH |
| SSH times out and the rules look right | `TW_ADMIN_CIDR` does not match the source address the head sees — either it moved since §1.5, or it was measured with `curl -s ifconfig.me` on a cloud whose floating IPs are private and reached over a VPN (§1.5). A `/32` is precise but not durable across VPN or DHCP changes. Full check-and-fix in §17 |
| SSH `Permission denied (publickey)` | wrong user (`rocky`, not `root` or `ubuntu`), or the key never made it into `user-data` — re-check the `grep -c 'ssh-ed25519'` in §4.3 |
| Only one interface has an address | expected if `tw-prov-subnet` has DHCP enabled — that is a §3 error; fix the subnet, then use the `nmcli` fallback for this boot |
| `--port` rejected: `Port … is still in use` | the port is attached to another instance (perhaps a deleted-but-not-gone one) — `openstack port show <port> -c device_id` |

Next: [§5 — Installing OpenCHAMI](05-install-openchami.md)
