# Appendix A — Installing the head node with kickstart

> **Status: upstream-derived, not validated in this lab.** The mainline §4
> cloud-image flow is what we executed and support. This appendix
> reconstructs the guide's kickstart path with the aarch64 corrections it
> needs, for readers who want the bare-metal-style experience — on real
> HPC metal there are no cloud images, and kickstart (or its cousins) is
> how heads get installed.

## What kickstart is

**Kickstart** is the answer file for Anaconda, the RHEL-family **OS
installer** (not the Python/conda distribution of the same name): one
text file that pre-answers every install question — partitioning,
packages, users, post-install scripts — so the install runs unattended.
`virt-install --location <repo-URL>` fetches the installer's kernel/initrd
straight out of a package repository and boots them with
`inst.ks=<url-of-your-file>`; the installer then drives itself.

## The flow

1. Serve a kickstart file over HTTP from the host (a throwaway
   `python3 -m http.server` is fine — the install VM fetches it once):

```
host$ mkdir -p ~/cluster/serve && cd ~/cluster
host$ cat > serve/kickstart.conf << 'EOF'
#version=RHEL9
text

url --url="https://rockylinux.mirrorservice.org/pub/rocky/9/BaseOS/$basearch/os/"
repo --name="appstream" --baseurl="https://rockylinux.mirrorservice.org/pub/rocky/9/AppStream/$basearch/os/" --install

%packages
@^minimal-environment
bash-completion
buildah
kexec-tools
man-pages
podman
tar
tmux
vim
%end

keyboard --xlayouts='us'
lang en_US.UTF-8

network --device=enp1s0 --bootproto=dhcp --ipv6=auto --activate
network --device=enp2s0 --bootproto=static --ip=172.16.0.254 --netmask=255.255.255.0 --ipv6=auto --activate
network --hostname=head

firstboot --enable
skipx

ignoredisk --only-use=vda
clearpart --all --drives=vda
autopart

rootpw --lock
user --groups=wheel --name=rocky --password=rocky

selinux --disabled
firewall --disabled

%addon com_redhat_kdump --enable --reserve-mb='auto'
%end

%post --log=/root/ks-post.log
grubby --update-kernel=ALL --args='console=ttyAMA0,115200n8 systemd.unified_cgroup_hierarchy=1'
grub2-mkconfig -o /etc/grub2.cfg
systemctl enable tmp.mount
dnf install -y epel-release
dnf install -y s3cmd awscli
%end

reboot
EOF
host$ (cd serve && python3 -m http.server 8000 &)
```

2. Kickstart the VM (compare §4.5 — no `--import`, and `--location`
   replaces the disk image):

```
host$ qemu-img create -f qcow2 head.qcow2 40G
host$ virt-install \
    --name head \
    --memory 4096 \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant rocky9 \
    --disk path=$PWD/head.qcow2,format=qcow2,bus=virtio \
    --network network=openchami-net-external,model=virtio,mac=52:54:00:c0:fe:01 \
    --network network=openchami-net-internal,model=virtio,mac=52:54:00:be:ef:ff \
    --location 'https://rockylinux.mirrorservice.org/pub/rocky/9/BaseOS/aarch64/os/' \
    --extra-args 'inst.ks=http://192.168.200.1:8000/kickstart.conf console=ttyAMA0,115200n8' \
    --boot uefi \
    --graphics none \
    --console pty,target_type=serial
```

Watch the whole install on the serial console; the VM reboots into the
installed system when done. Kill the web server afterwards (`kill %1`).

3. Differences from the §4 result to be aware of:
   - the `rocky` user has password `rocky` and *no* SSH key — add yours
     (`ssh-copy-id`) before continuing to §5;
   - interface names will be `enp1s0`/`enp2s0` (no MAC-pinning here), so
     §5.7's CoreDHCP `listen:` must say `"%enp2s0"` instead of `"%eth1"`;
   - SELinux is fully disabled (the guide's choice), not permissive.

## aarch64 / correctness deltas vs the upstream guide's version

| Upstream guide | Here | Why |
|---|---|---|
| `--location .../BaseOS/x86_64/kickstart` | `.../BaseOS/aarch64/os/` | ARM tree; the `os/` repo works as an install source |
| repo URL `https://download.rockylinux.org/stg/rocky/...` | `/pub/` tree on a fast mirror | `/stg/` is Rocky's **staging** area — an upstream bug |
| `console=ttyS0` | `console=ttyAMA0` | ARM serial device |
| `--boot loader=/usr/share/OVMF/OVMF_CODE.secboot.fd,...` | `--boot uefi` | x86 OVMF paths don't exist here; let virt-install pick edk2-aarch64 |
| `--virt-type kvm` | (omitted) | KVM is the default when `/dev/kvm` exists |
