# §2 — Preparing the host

*(Upstream: guide §1.2 "Install required packages". Time: ~5 minutes.)*

## Concepts

The host needs two toolsets:

- **The virtualisation stack** — `libvirt` (the VM management daemon and
  its `virsh` CLI), `qemu-kvm` (the hypervisor userspace that libvirt
  drives), `virt-install` (creates VMs from the command line), and
  `edk2-aarch64` (UEFI firmware images for ARM guests — the aarch64
  equivalent of the x86 `edk2-ovmf` package the upstream guide installs;
  ARM VMs *only* boot via UEFI, and PXE booting happens in that firmware).
- **Support tools** — `genisoimage` (builds the cloud-init seed ISO in §4),
  `wget`/`curl` for fetching images, `jq` for picking through JSON API
  output.

## Step 2.1 — Install the packages

```
host$ sudo dnf install -y \
    edk2-aarch64 \
    genisoimage \
    guestfs-tools \
    jq \
    libvirt \
    qemu-kvm \
    virt-install \
    wget
```

(`guestfs-tools` brings `virt-customize` and friends — not strictly
required, but invaluable when you want to poke at VM disk images while
debugging.)

## Step 2.2 — Start libvirt

```
host$ sudo systemctl enable --now libvirtd
```

`libvirtd` is the daemon that owns every network and VM we create from
here on; `enable --now` starts it and makes it start on boot.

Now let your login user talk to that daemon **without `sudo`**:

```
host$ sudo usermod -aG libvirt "$USER"
```

The system libvirt daemon (`qemu:///system`) is guarded by polkit: out of
the box the `org.libvirt.unix.manage` action is `auth_admin_keep`, so an
*unprivileged* `virsh` triggers a **"System policy prevents management of
local virtualized systems"** password prompt. libvirt ships a polkit rule
that grants members of the `libvirt` group passwordless access, so adding
yourself to that group is the clean fix — otherwise you'd have to prefix
every `virsh` in this tutorial with `sudo`.

⚠ **Group membership only applies to a *new* login session.** Log out and
back in (`exit`, then `limactl shell ochami-host` again). Under Lima there
is one extra wrinkle: it keeps a single multiplexed SSH connection alive,
so even a fresh `limactl shell` can reuse the old session's groups. If
`id` still doesn't list `libvirt`, either cycle the VM
(`limactl stop ochami-host && limactl start ochami-host`) or, from inside
the VM, run `newgrp libvirt` to adopt the group in your current shell.
Verify with `id -nG | grep libvirt`.

Finally, tell libvirt which daemon "plain" commands should talk to:

```
host$ echo 'export LIBVIRT_DEFAULT_URI=qemu:///system' >> ~/.bashrc
host$ export LIBVIRT_DEFAULT_URI=qemu:///system
```

**Verify it took — this one check prevents a whole class of confusing
errors later:**

```
host$ virsh uri
qemu:///system
```

If that prints `qemu:///session` instead, the variable isn't set in *this*
shell — re-run the `export` above (the `>> ~/.bashrc` line only affects
*new* login shells).

⚠ **This step is not optional if you want to drop `sudo`.** libvirt has two
daemons: the system-wide `qemu:///system` (where we build the cluster) and a
throwaway per-user `qemu:///session`. `virsh`/`virt-install` choose based on
who runs them — as **root** (i.e. behind `sudo`) they default to
`qemu:///system`, but as **your unprivileged user** they default to
`qemu:///session`. The failure is sneaky: against the session daemon a
`net-define` *succeeds* (it records the definition in your private daemon),
but `net-start` then fails with **`error creating bridge interface …:
Operation not permitted`** — because the session daemon runs as *you* and
can't create a system bridge. Meanwhile a bare `virsh net-list` just looks
empty. Setting `LIBVIRT_DEFAULT_URI` pins every command to the system
daemon, which is why the rest of this tutorial writes `virsh …` and
`virt-install …` with neither `sudo` nor `--connect`.

> **Why this style, not `sudo`?** Running as an unprivileged user in the
> `libvirt` group is libvirt's *standard* mode — and it's a small rehearsal
> of how you'll drive AWS or OpenStack, where you never `sudo` but instead
> act as a scoped identity pointed at an API endpoint. [Appendix C](appendix-c-access-models.md)
> compares the two styles and maps them onto the cloud, which matters for
> the eventual PTR/OpenStack deployment.

## Step 2.3 — Put SELinux in permissive mode

```
host$ sudo setenforce 0
host$ sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

🔀 **Deviation.** The upstream guide's kickstart *disables* SELinux on the
head node outright (`selinux --disabled`), and the tutorial's cloud
template makes container contexts permissive to work around a JetStream2
quirk. We take the middle road on the host: **permissive** logs every
would-be denial (so you can still learn from `/var/log/audit/audit.log`)
without letting a policy surprise break the lab. A production system would
instead craft proper policies for the qemu/libvirt paths involved.

## ✅ Checkpoint

```
host$ virsh list --all
 Id   Name   State
--------------------

host$ ls /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw
/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw

host$ getenforce
Permissive
```

An empty VM list (not an error) proves libvirtd is answering — and that
you reached it as your own user, no `sudo`. If this still prompts you for a
password, your shell hasn't picked up the `libvirt` group yet; if it errors
or shows nothing where you expect the system daemon, `LIBVIRT_DEFAULT_URI`
isn't set in this shell — see the two ⚠ notes in Step 2.2. The
`QEMU_EFI-pflash.raw` file is the UEFI firmware every VM in this tutorial
boots with — remember the path, you'll type it in §4 and §10.

Next: [§3 — The two networks](03-networks.md)
