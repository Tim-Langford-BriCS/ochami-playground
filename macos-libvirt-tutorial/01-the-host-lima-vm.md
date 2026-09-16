# §1 — The host: a Lima VM with nested virtualization

*(Upstream equivalent: the guide's assumed "Linux host with libvirt". Time:
~5 minutes, or longer on the first run while the Rocky image downloads.)*

## Concepts

**Lima** manages Linux VMs on macOS. Each VM is described by one YAML file;
`limactl create` bakes that file into an *instance*, and `limactl shell`
drops you inside it. Lima can use two backends ("drivers"): QEMU (software
device emulation, portable, slower) and **vz** — Apple's native
Virtualization.framework, which is what we use.

**Nested virtualization** is the feature this whole tutorial hangs on: our
Lima VM must itself run hardware-accelerated VMs (the head and compute
nodes). On Apple Silicon that requires an **M3 or newer** chip, and it
exposes `/dev/kvm` inside the guest — the same interface KVM provides on
real Linux servers, which is why everything downstream behaves exactly like
the upstream guide's Linux host.

**Rocky Linux 9** is the guest OS because it's what OpenCHAMI's packaging
targets (the release RPM and its quadlets are built for EL9).

## Step 1.1 — Create a working directory on the Mac

Somewhere to keep the one file that lives on the Mac side:

```
mac$ mkdir -p ~/ochami-tutorial && cd ~/ochami-tutorial
```

## Step 1.2 — Write the Lima VM definition

Create `ochami-host.yaml` with exactly this content. Read the comments —
they are the explanation:

```yaml
# ochami-host.yaml — the tutorial's "Linux host with libvirt".

# Apple's Virtualization.framework, not QEMU: native speed, and the only
# Lima backend that supports nested virtualization on Apple Silicon.
vmType: vz

# The whole lab is ARM64 (Apple Silicon), end to end.
arch: aarch64

# THE critical line. Without it the guest has no /dev/kvm and §4/§10
# cannot run VMs. Requires an M3 or newer Mac. Lima bakes this in when the
# instance is CREATED - adding it later to an existing instance does nothing
# (you would have to delete and re-create).
nestedVirtualization: true

# Rocky 9 "GenericCloud" image: a pre-installed disk image designed to be
# personalised by cloud-init on first boot (Lima acts as its cloud-init
# datasource - the same mechanism our compute nodes will use later, §9).
images:
- location: "https://dl.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud.latest.aarch64.qcow2"
  arch: aarch64

# Sized to hold a 4 GiB head VM + a 3 GiB compute VM + image builds.
cpus: 8
memory: "16GiB"
disk: "80GiB"

# No macOS folders are shared into the VM: we treat it like a remote
# server, and everything it needs is created inside it.
mounts: []

# Lima ships a containerd runtime we don't want - the head node will run
# Podman, and the host runs plain libvirt.
containerd:
  system: false
  user: false

# Wait for the guest's first-boot cloud-init to finish before `limactl
# start` returns, so we never race a half-initialised VM. Exit code 2 means
# "finished with warnings", which Rocky images routinely emit - accept it.
probes:
- description: "cloud-init to be completed"
  script: |
    #!/bin/bash
    set -eux -o pipefail
    if ! timeout 30s bash -c "until sudo cloud-init status --wait; [ \$? -eq 0 -o \$? -eq 2 ]; do sleep 3; done"; then
      echo >&2 "cloud-init did not finish"
      exit 1
    fi
  hint: |
    cloud-init has not finished inside the guest; check
    "limactl shell ochami-host sudo cloud-init status --long".
```

## Step 1.3 — Create and start the VM

```
mac$ limactl create --name ochami-host --tty=false ochami-host.yaml
mac$ limactl start ochami-host
```

`create` downloads the Rocky image (~500 MB) the first time and prepares the
instance; `start` boots it and blocks until the readiness probe passes.
`--tty=false` just suppresses an interactive "review the config?" prompt.

## Step 1.4 — Look around

```
mac$ limactl shell ochami-host
```

You're now "on the Linux host" — from here on, prompts shown as `host$`.
Everything in §§2–3 happens here, and Lima's only remaining job is to exist.

## ✅ Checkpoint

```
host$ cat /etc/rocky-release
Rocky Linux release 9.8 (Blue Onyx)

host$ ls -l /dev/kvm
crw-rw-rw-. 1 root kvm 10, 232 Jul 10 15:55 /dev/kvm

host$ nproc; free -g | head -2
8
               total        used        free ...
Mem:              15           0          15 ...
```

**`/dev/kvm` present is the make-or-break check.** If it's missing, your
guest kernel will also have logged `kvm [1]: HYP mode not available`
(`sudo dmesg | grep -i kvm`): either the Mac is older than M3, or
`nestedVirtualization: true` wasn't in the YAML at *create* time — fix the
file, then `limactl delete ochami-host` and repeat step 1.3.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `/dev/kvm` missing | see checkpoint note above — delete and re-create, never just restart |
| image download crawls | the Rocky CDN can be slow; see §11 for using a local mirror or Lima's cache |
| probe timeout on first boot | slow first-boot updates; `limactl shell ochami-host sudo cloud-init status --long` to watch |

Next: [§2 — Preparing the host](02-host-preparation.md)
