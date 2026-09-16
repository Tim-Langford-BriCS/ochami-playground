# §16 — Heterogeneous hardware

*(Mostly reading and design, with a few commands you can run today. This is the section that connects the POC to the point of the project — and the one to have open when the PTR hardware is powered on.)*

## Concepts

TechWatch exists to evaluate **heterogeneous** inference hardware. The procured compute is deliberately diverse:

| Node | Accelerator | Per node | Est. tok/s (Llama-3 8B) | £/tok/s |
|---|---|---|---|---|
| 1 × Dell XE7740 | **Intel Gaudi3** | 4 × Gaudi3, 4 × 128 GB HBM | ~24,200 | ~£0.46 |
| 2 × Dell XE7745 | **NVIDIA RTX Pro 6000 Blackwell** | 4 × 96 GB VRAM | ~8,990 each | ~£0.95 |
| 2 × Dell R760XA | **AMD MI210** | 2 × 64 GB HBM | ~1,400 each | ~£4 |
| 3 × Dell R770 | none (Xeon 6760P) | — | ~100 each | ~£70 |

Plus ARM processors and SlingShot-400 networking arriving in 2026/27. Four accelerator vendors, two CPU vendors, two interconnects — and one Kubernetes cluster over the top.

Our OpenStack POC has **none** of this. What it *can* do is establish the mechanisms, so that adding hardware is a configuration change rather than a research project. There are four mechanisms, and they stack:

```
  4. Scheduling      ← Ray resources, node selectors, taints/tolerations
  3. Advertisement   ← device plugin: "this node has 4 × nvidia.com/gpu"
  2. Drivers         ← Talos system extensions, baked into the boot image
  1. The image       ← Talos Image Factory schematic → the assets BSS serves
```

Layer 1 is the interesting one, because it loops all the way back to §8.

## Step 16.1 — Layer 1–2: Talos system extensions

Talos has no package manager, so **you cannot install a driver on a running node**. Drivers arrive as *system extensions* baked into the boot image. That means: to add GPU support, you change the image the node network-boots — which is to say, you change what §8.4 uploads and §9 points BSS at.

This is a feature, not a limitation. The node's entire software state is described by one immutable artifact, and OpenCHAMI already owns the mechanism for serving it.

A **schematic** declares what goes in the image:

```yaml
# nvidia-schematic.yaml — do not apply today; this is the §16 shape.
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/nonfree-kmod-nvidia-production   # the kernel module
      - siderolabs/nvidia-container-toolkit-production
  extraKernelArgs:
    - talos.platform=metal
```

Register it and get an ID:

```
head$ curl -X POST --data-binary @nvidia-schematic.yaml https://factory.talos.dev/schematics
{"id":"<SCHEMATIC_ID>"}
```

Then — and this is the part that matters — **the assets you fetch in §8.4 change, and nothing else does**:

```
head$ curl -sL "https://factory.talos.dev/image/<SCHEMATIC_ID>/${TW_TALOS_VERSION}/kernel-amd64" \
        -o /tmp/vmlinuz-nvidia
head$ curl -sL "https://factory.talos.dev/image/<SCHEMATIC_ID>/${TW_TALOS_VERSION}/initramfs-amd64.xz" \
        -o /tmp/initramfs-nvidia.xz
head$ s3cmd put /tmp/vmlinuz-nvidia     s3://boot-images/talos/vmlinuz-nvidia-amd64
head$ s3cmd put /tmp/initramfs-nvidia.xz s3://boot-images/talos/initramfs-nvidia-amd64.xz
```

And the installer image in the machine config must match the schematic, so the extensions survive the install to disk:

```yaml
machine:
  install:
    image: factory.talos.dev/installer/<SCHEMATIC_ID>:v1.13.0
```

⚠ **The installer image and the boot assets must come from the same schematic.** Boot a Factory kernel but install the stock installer and the extensions vanish on first reboot — a genuinely confusing failure, because the node works until it restarts.

**Then a new BSS payload, and OpenCHAMI does the rest.** This is where §§6, 9 and this section join up: node *groups* in SMD become hardware classes, and each gets its own boot payload.

```
head$ cat << EOF | sudo tee /etc/openchami/data/boot/bss/talos-worker-nvidia.yaml
---
kernel: 'http://${TW_OBJ}/boot-images/talos/vmlinuz-nvidia-amd64'
initrd: 'http://${TW_OBJ}/boot-images/talos/initramfs-nvidia-amd64.xz'
params: 'talos.platform=metal slab_nomerge pti=on console=tty0 console=${TW_CONSOLE} talos.config=http://${TW_OBJ}/boot-images/talos/worker-nvidia.yaml'
macs:
  - <the RTX nodes' MACs>
EOF
head$ ochami bss boot params set -f yaml -d @/etc/openchami/data/boot/bss/talos-worker-nvidia.yaml
```

**That is the whole heterogeneous-provisioning story**: one boot payload per hardware class, keyed by MAC, served by the same BSS. Nothing about OpenCHAMI changes; you add rows. It is also why §6's `groups:` field was worth setting — `talos-worker-nvidia`, `talos-worker-amd`, `talos-worker-gaudi` become the natural way to address each class.

| Vendor | Talos extension | Notes |
|---|---|---|
| NVIDIA | `nonfree-kmod-nvidia-production` + `nvidia-container-toolkit-production` | best-supported path; production and LTS variants exist — match your kernel |
| AMD | `amdgpu` / ROCm driver support | ROCm userspace comes from the container image, not the extension |
| Intel Gaudi | vendor stack (`habanalabs`) | **the least-travelled path on Talos.** Raise it with Intel and the Talos community early — verify feasibility before committing the Gaudi node to a Talos cluster |

🛑 **Do this evaluation before the hardware arrives.** If a Gaudi driver cannot be delivered as a Talos extension, that node may need a conventional OS — which is fine (OpenCHAMI provisions Rocky perfectly well; that is what the libvirt lab did) but it changes the cluster design. This is the single biggest open technical risk in the software plan.

## Step 16.2 — Layer 3: device plugins

A driver in the kernel is not enough — Kubernetes has to be *told* the hardware exists. That is a **device plugin**: a DaemonSet that advertises an extended resource, so pods can request `nvidia.com/gpu: 1` and the scheduler places them correctly.

| Hardware | Plugin | Advertises |
|---|---|---|
| NVIDIA | NVIDIA GPU Operator, or the standalone `k8s-device-plugin` | `nvidia.com/gpu` |
| AMD | ROCm `k8s-device-plugin` | `amd.com/gpu` |
| Intel Gaudi | Habana device plugin | `habana.ai/gaudi` |

⚠ **On Talos, use the standalone device plugin, not the GPU Operator's driver mode.** The GPU Operator's main job is compiling and loading drivers on the host — which Talos will not permit, and does not need, because the extension already did it. Install the operator with driver installation *disabled*, or just use the plugin DaemonSet.

Through Flux, this is one more file in `infrastructure/controllers/`, gated to the nodes that have the hardware:

```yaml
# infrastructure/controllers/nvidia-device-plugin.yaml — the §16 shape
      nodeSelector:
        techwatch.bris.ac.uk/accelerator: nvidia-rtx-pro-6000
```

## Step 16.3 — Layer 4: labels, taints and scheduling

**Label nodes by what they are.** Something must set these labels; the choices are the Talos machine config (declarative, per hardware class — preferred, since you already have one config per class), or the Node Feature Discovery operator (automatic, more machinery).

```yaml
machine:
  nodeLabels:
    techwatch.bris.ac.uk/accelerator: nvidia-rtx-pro-6000
    techwatch.bris.ac.uk/accelerator-count: "4"
    techwatch.bris.ac.uk/cpu-vendor: amd
    techwatch.bris.ac.uk/interconnect: roce
```

**Taint the expensive nodes**, so a CPU-only workload cannot squat on a Gaudi3:

```yaml
machine:
  nodeTaints:
    - key: techwatch.bris.ac.uk/accelerator
      value: intel-gaudi3
      effect: NoSchedule
```

Then only workloads that explicitly tolerate it land there. This is the difference between an expensive cluster and an expensive *and* idle cluster.

You can rehearse the whole of layer 4 **today**, with no accelerators — the mechanism is identical, only the resource is fake:

```
head$ kubectl get nodes                # tw-w1 and tw-w2 are nid0002 and nid0003
head$ kubectl label node nid0002 techwatch.bris.ac.uk/accelerator=none-cpu-only
head$ kubectl label node nid0003 techwatch.bris.ac.uk/accelerator=pretend-gpu
head$ kubectl taint node nid0003 techwatch.bris.ac.uk/accelerator=pretend-gpu:NoSchedule
```

⚠ **`kubectl` does not know your Nova instance names.** Nodes are `nid0001`, `nid0002`, … because Talos takes its hostname from CoreDHCP, which answers from SMD — see §10's checkpoint. Run `kubectl get nodes` and use what it prints.

Now add a `nodeSelector` and a `toleration` to §14's `InferenceService` and watch it move to `nid0003` — or fail to schedule if you get the toleration wrong. Doing this once here is worth an hour of debugging later:

```yaml
  predictor:
    nodeSelector:
      techwatch.bris.ac.uk/accelerator: pretend-gpu
    tolerations:
      - key: techwatch.bris.ac.uk/accelerator
        operator: Equal
        value: pretend-gpu
        effect: NoSchedule
```

✅ **Checkpoint** — a scheduling constraint that actually bites:

```
head$ kubectl -n inference get pods -o wide
⟨captured on first run — the predictor pod must be on tw-w2, the tainted node⟩

head$ kubectl label node nid0003 techwatch.bris.ac.uk/accelerator=none-cpu-only --overwrite
head$ kubectl -n inference delete pod -l serving.kserve.io/inferenceservice=qwen05b
head$ kubectl -n inference get pods
⟨now Pending, "node(s) didn't match Pod's node affinity" — the mechanism works⟩
```

Undo it before moving on:

```
head$ kubectl taint node nid0003 techwatch.bris.ac.uk/accelerator- 
head$ # then revert the nodeSelector/tolerations commit in Git
```

## Step 16.4 — What else changes on real hardware

Beyond the four layers, things this POC cannot rehearse at all:

| Concern | On the PTR |
|---|---|
| **Discovery** | Magellan over Redfish against real BMCs, not §6's static YAML. [Appendix A](appendix-a-redfish-sushy.md) is the closest rehearsal available — do it |
| **BMC credentials** | real secrets, per chassis, that Magellan and OpenCHAMI need. A genuine design task with no POC equivalent |
| **Power control** | Redfish on/off/cycle replaces `openstack server reboot --hard` and `rebuild`. Same abstraction, real consequences — and real power draw |
| **Firmware** | per-vendor UEFI settings, boot order, secure boot, PXE-on-which-NIC. Dell and HPE differ. Expect this to consume real time |
| **NICs** | 100 GbE Broadcom (RoCEv2/UEC), later SlingShot-400. Which NIC PXE-boots, and whether the fast fabric is even up at provisioning time, are new questions |
| **Storage** | 3.84–7.68 TB local NVMe per node, plus a PowerVault ME5212 over 25 Gb iSCSI and an NFS host. local-path (§11.2) still works for caches; shared model weights want the NFS or a CSI driver — and Longhorn/iSCSI on Talos needs the `iscsi-tools` extension, i.e. back to §16.1 |
| **The provisioning wire** | a real management VLAN on a PowerSwitch S3248T-ON, where **only CoreDHCP may answer DHCP** — the same invariant as §3.2, with much higher stakes and no `--no-dhcp` flag to enforce it |
| **Multiple control planes** | LANL suggested running several OpenCHAMI control planes in VMs, one per developer. This POC is exactly one such VM — so that scaling story is already half-proven |
| **ARM nodes (2026/27)** | a second architecture: `arm64` Talos assets, a second set of images, and every `<ARCH>` in §§8–9 becoming a per-group value. Our libvirt lab was aarch64, so both halves are already documented in this repo |

## What to take from this section

1. **Heterogeneity is a boot-image problem before it is a Kubernetes problem.** The Talos schematic → BSS payload → SMD group chain (§16.1) is the mechanism, and OpenCHAMI needs no changes to support it.
2. **You can rehearse layers 3 and 4 today** with fake labels and taints, and you should (§16.3).
3. **Intel Gaudi on Talos is the open risk.** Resolve it before the XE7740 is committed to the cluster.
4. **Capture a CPU baseline now** (§14's metrics). "×240 faster than CPU" is a much better result when you measured the CPU yourself.

Next: [§17 — Troubleshooting](17-troubleshooting.md)
