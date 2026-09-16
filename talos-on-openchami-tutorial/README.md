# Deploying Talos Linux on OpenCHAMI

A follow-on tutorial that provisions a small **Talos Linux** Kubernetes
cluster — one control-plane node and one or more workers — on the compute
nodes of an OpenCHAMI cluster you have **already built**. It reuses the
OpenCHAMI control plane (SMD, CoreDHCP, BSS, object store) as a generic PXE
provisioning service and swaps the base tutorials' Rocky diskless image for
Talos's own kernel + `initramfs`, delivered by the same BSS boot-script
mechanism.

Like the base tutorials, every step gives the **full command or config
file**, then explains **what it does and why**.

## Prerequisites

**You must have completed one of the base tutorials** and have a running,
verified OpenCHAMI cluster:

- [`../linux-libvirt-tutorial/`](../linux-libvirt-tutorial/) *(x86_64)*, or
- [`../macos-libvirt-tutorial/`](../macos-libvirt-tutorial/) *(aarch64, Apple Silicon)*

Concretely, from finishing either one you have:

| You have | From |
|---|---|
| A head node at `172.16.0.254` running the OpenCHAMI services in containers | base §5 |
| Five nodes in SMD: `compute1`–`compute5`, MACs `52:54:00:be:ef:01`–`05` → IPs `172.16.0.1`–`5` | base §6 |
| CoreDHCP leasing those IPs from SMD and advertising `router`/`dns` = `172.16.0.254` | base §5 |
| BSS serving boot scripts at `http://172.16.0.254:8081/boot/v1/bootscript` | base §5 |
| A public-read `boot-images` bucket on the head's S3/object store, plus a working `s3cmd`/`ochami` client | base §7 |
| The `ochami` CLI and a way to mint a token (`gen_access_token`) on the head | base §5 |

This tutorial **starts where the base tutorials build the compute image**
(their §7) and replaces §§7–10 entirely. You do **not** run their §7
(image-builder), §9 (cloud-init), or §10 (Rocky boot).

> **Stop here if you have not finished a base tutorial.** Nothing below will
> work without the head node, SMD inventory, and object store already up.

## Pick your base tutorial — arch matters

Talos ships architecture-specific assets, and the two base tutorials run on
different architectures and expose the object store on different ports.
Everywhere below you see `<ARCH>`, `<CONSOLE>`, or `<OBJ>`, substitute from
the row that matches the base tutorial you completed:

| You finished | `<ARCH>` | `<CONSOLE>` | `<OBJ>` (object store) |
|---|---|---|---|
| `linux-libvirt-tutorial` | `amd64` | `ttyS0,115200` | `172.16.0.254:9000` |
| `macos-libvirt-tutorial` | `arm64` | `ttyAMA0,115200` | `172.16.0.254:7070` |

Everything else — the node MAC/IP scheme, the `ochami bss boot params set`
workflow, the head IP, and the required Talos kernel arguments — is
identical across both.

## Why Talos is different from the base tutorials' compute image

The base tutorials build a **Rocky 9 diskless image** with OpenCHAMI's
`image-builder`: a SquashFS streamed over HTTP, run from RAM with a tmpfs
overlay, personalised at boot by **cloud-init**. Talos throws almost all of
that out:

| Base tutorial (Rocky diskless) | Talos |
|---|---|
| `image-builder` + `dnf` recipe → SquashFS | Prebuilt `vmlinuz` + `initramfs.xz` from Talos releases; **no image build** |
| Diskless, stateless in RAM | **Installs to a disk**, then boots from it |
| cloud-init (NoCloud over HTTP) for config | Declarative **machine config**, fetched via the `talos.config` kernel arg |
| Console login, SSH, `dnf`, a shell | **No shell, no SSH, no console login** — managed only via the `talosctl` gRPC API + `kubectl` |
| Needs nothing beyond head services at boot | **Needs outbound internet** to pull its installer + Kubernetes images |

What stays the same is the OpenCHAMI plumbing: SMD is still the source of
truth, and **BSS still hands each MAC a kernel + initramfs + kernel command
line** — that is generic PXE, and Talos is a first-class PXE citizen.

## What you will build

```
existing OpenCHAMI head (172.16.0.254)
   ├── object store  ← now also hosts Talos vmlinuz/initramfs + machine configs
   ├── BSS           ← now serves a Talos boot script per MAC
   └── CoreDHCP/SMD  ← unchanged
        │
        ├── compute1 (172.16.0.1)  ← Talos control-plane node
        └── compute2..N            ← Talos worker nodes
                └── together: a working Kubernetes cluster
```

## Contents

| § | File | Replaces base § |
|---|---|---|
| — | [README (this file)](README.md) | — |
| 1 | [Network prerequisite: internet for the compute nodes](01-network-prerequisite.md) | — (new) |
| 2 | [Talos assets and machine config](02-talos-assets-and-config.md) | §7 build + §9 cloud-init |
| 3 | [Boot parameters for Talos](03-boot-parameters.md) | §8 |
| 4 | [Booting the Talos cluster](04-boot-the-cluster.md) | §10 |
| 5 | [Troubleshooting](05-troubleshooting.md) | §11 (Talos-specific) |

Reading order is 1 → 5. Budget **1–2 hours**, most of it waiting for Talos
to pull images on first boot.

## Conventions

Same as the base tutorials:

- Prompts show the machine: `host$` (the libvirt host — your Mac's Lima VM
  or your Linux hypervisor), `head$` (the OpenCHAMI head node). There is no
  `compute$` here — **Talos has no shell**; you drive the nodes with
  `talosctl` from the head.
- ✅ **Checkpoint** blocks show expected output.
- 🔀 **Deviation** boxes mark where we differ from the base tutorials' Rocky
  flow and why.
- ⚠ **Gotcha** boxes are lessons worth reading before you hit them.

Next: [§1 — Network prerequisite](01-network-prerequisite.md)
