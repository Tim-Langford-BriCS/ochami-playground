# Appendix C — Alternatives we considered

Every significant choice in this tutorial had at least one credible alternative. This appendix argues them properly, so that a future reader — or a reviewer who disagrees — can see what was weighed rather than guessing. Several of these are worth revisiting: the whole point of the rig is that swapping a layer is cheap.

## 1. How to model a cluster inside OpenStack

### HPE vTDS (Virtual Test and Development System)

[`Cray-HPE/vtds-core`](https://github.com/Cray-HPE/vtds-core) plus [`vtds-application-openchami`](https://github.com/Cray-HPE/vtds-application-openchami). A layered abstraction — Provider / Platform / Cluster / Application — with OpenCHAMI as the reference application, and providers for Google Cloud and OpenStack. Stig Telfer (StackHPC) presented an OpenStack provider proof-of-concept at the OpenCHAMI Developer Summit.

**Why not:** vTDS runs KVM *inside* OpenStack instances — a "blade" hosts a management VM and several compute VMs. That needs **nested virtualisation, which is disabled across the Digital Labs hypervisors** and will stay disabled while the patched kernel breaks BC5's offloaded networking. Stig's own conclusions were also cautionary: imperfect abstraction between layers, manual interventions at several points, hardcoded assumptions (Python 3.10, RSA host keys, root SSH), no other use case than OpenCHAMI, and an explicit warning against taking on the maintenance unilaterally.

**Worth revisiting if:** nested virt returns *and* vTDS gets a refresh. Its layered model is genuinely better for large-scale CI than anything here, and "test automation for driving OpenCHAMI operations" is a real gap in what we have built.

### Tenks

OpenStack's own tool for virtual bare metal: KVM VMs plus VirtualBMC, made to look like IPMI-managed servers to Ironic.

**Why not:** it implements only the provider layer, is limited to a single host, and is aimed at Ironic rather than OpenCHAMI. Its Redfish variant (with sushy-tools) was still under development. But it is the closest thing in the OpenStack world to what we want, and its use of sushy-tools is what pointed us at [appendix A](appendix-a-redfish-sushy.md).

### Ironic

OpenStack's bare-metal service does PXE properly, with real boot interfaces and Redfish drivers.

**Why not:** two reasons. It *is* a provisioning system, so using it to test OpenCHAMI is testing the wrong thing — we would be measuring Ironic's PXE stack, not OpenCHAMI's. And it is not exposed to us as a tenant. (Note that sushy-tools has an **Ironic** driver too, which would be the natural choice if we ever get Ironic bare-metal nodes on the PTR side.)

### What we chose

One Nova instance per node, network boot via Nova rescue with an iPXE image (§0, §7). Fewest moving parts, no nested virt, and — the deciding factor — it maps one-to-one onto Redfish, so the manual steps rehearse the real operation instead of being a cloud-only detour.

## 2. How to network-boot an instance

Argued in full in §7, and **re-argued in [`DECISION-LOG.md`](DECISION-LOG.md) DL-002, which supersedes this table** — the choice is now provisional and settled by two tests at §7.2 and §7.2b. Summarised:

| Option | Verdict |
|---|---|
| Firmware PXE ROM, unaided | tested at §7.2. Much more likely under **UEFI** than the original assessment allowed; if it works, the best outcome available |
| iPXE ISO as a permanent **second boot device** (`boot_index=1`, `device_type=cdrom`) | **not originally considered.** Reproduces libvirt's `--boot uefi,hd,network` deterministically, on BIOS or UEFI, with no rescue and no BSS state. Costs a 1 GB Cinder volume per node, and boot order is fixed at create time. Tested at §7.2b |
| **Nova rescue + iPXE image** | originally chosen, now the fallback. One command each way; identical to what sushy-tools does, so appendix A depends on it either way |
| Boot from iPXE permanently + `sanboot` | the §7.7 fallback if tenant rescue is disallowed. Makes BSS stateful, and a bug in the state flip wipes a node |
| Ironic | above |
| Custom iPXE build with an embedded script | unnecessary — CoreDHCP already supplies the boot-script URL. Left as an option for the IaC |

The deciding consideration, added later: this is the only part of the tutorial *guaranteed* to be replaced when TechWatch hardware arrives, because a real BMC has boot-order control. That argues for the simplest option that works rather than the most faithful one — the fidelity rescue buys is fidelity to a mechanism we will not be using.

## 3. OpenCHAMI deployment method

We used the **release RPM with Podman quadlets** (§5), following the current upstream tutorial. Two other paths exist:

| Alternative | Assessment |
|---|---|
| [`openchami-operator`](https://github.com/OpenCHAMI/openchami-operator) | Runs the OpenCHAMI services *inside* Kubernetes. Elegant, and mentioned at OpenCHAMI office hours as relevant to us. But it inverts the dependency — Kubernetes would have to exist before OpenCHAMI could provision the nodes that run Kubernetes. A bootstrap problem worth solving eventually, not while learning the stack |
| `kube-deploy` / Helm charts | Same inversion, less maturity |
| Dell **Omnia** | Dell proposed helping with OpenCHAMI and Omnia (as deployed at NERSC and CINECA), and are keen to explore a Kubernetes cluster with OpenCHAMI. Genuinely worth pursuing as a comparison — Omnia brings Broadcom tuning for inference workloads, which we will want. Not a substitute for understanding the base stack first |

Quadlets also have a specific pedagogical virtue: `systemctl` and `journalctl` work normally, so debugging §5 uses skills you already have.

## 4. Compute node operating system

**Talos** (chosen). No shell, no SSH, no package manager; API-driven; a Kubernetes node and nothing else.

| Alternative | When it would be better |
|---|---|
| **Rocky diskless SquashFS** (what the libvirt lab built) | If the compute plane needed to run Slurm or OpenPBS alongside Kubernetes, or if you need to log in and poke at a node. Also the fallback if a vendor driver cannot be delivered as a Talos extension — **which is a live risk for Intel Gaudi** (§16.1) |
| Flatcar / Fedora CoreOS | Similar immutable philosophy, but with a shell and a more conventional update model. A reasonable middle ground |
| Ubuntu/Rocky + kubeadm | Maximum flexibility, maximum drift. This is what Talos exists to avoid |

The deciding factors: LANL were keen to test Talos with OpenCHAMI, Jake proposed it, and the immutable model matches how HPC clusters already think about node images.

## 5. Model serving control plane

**KServe in Standard (RawDeployment) mode** (§13).

| Alternative | Assessment |
|---|---|
| **KServe with Knative (Serverless)** | The mode most tutorials install. Rejected: scale-to-zero is actively harmful when a cold start means reloading gigabytes of weights, and it adds a whole distributed system to a stack we are trying to understand |
| **Nothing** — a `Deployment` and a `Service` per model | Genuinely the right answer if you will only ever serve one model. Worth comparing against: it is about 30 lines of YAML |
| **Ray Serve** (§15) | Better when serving logic is a *pipeline* rather than an endpoint, and for multi-node model parallelism. Not either/or — KServe's own multi-node serving uses Ray |
| **llm-d** directly | Prefill/decode disaggregation and KV-cache-aware routing without KServe on top. KServe's `LLMInferenceService` is the managed form of this, and is where KServe is heading — a strong candidate for the next iteration |
| **Seldon Core**, **BentoML** | Mature alternatives. KServe was chosen because the TechWatch design names it and it is the common denominator across the CNCF ecosystem |
| **NVIDIA NIM / Triton** | Excellent on NVIDIA silicon, and a serious candidate for the RTX nodes specifically. Does not span AMD and Gaudi, so it cannot be the only answer for a heterogeneous cluster |

## 6. Inference engine

**vLLM** (§14), on the CPU backend.

| Alternative | Assessment |
|---|---|
| **TGI** | Named in the TechWatch design alongside vLLM; comparable throughput, strong quantisation |
| **llama.cpp / `llama-server`** | **Better than vLLM on CPU** — it is built for it. If §14 is unbearably slow, this is the pragmatic swap. The cost is not exercising the engine the PTR will actually use |
| **Ollama** | llama.cpp with much nicer ergonomics; excellent for a laptop, less suited to a cluster service |
| **TensorRT-LLM** | Fastest on NVIDIA; NVIDIA-only |
| **Intel Gaudi stack** | Required for the XE7740. Its own vLLM fork/plugin — raise with Intel early |

The `ServingRuntime` abstraction means any of these is a new runtime object plus one line in the `InferenceService`. Running two side by side on the same model is the cheapest engine comparison available, and is exactly the kind of experiment the rig is for.

## 7. GitOps

**FluxCD** (§12) over **Argo CD**. Flux is smaller, CLI-driven, has no UI to run or expose (which matters on an isolated wire), and treats Kustomize and Helm as first-class. Argo CD's dashboard is the better choice for a team that wants to *look* at the cluster. Neither is wrong.

## 8. Storage

**local-path-provisioner** (§11.2).

| Alternative | Assessment |
|---|---|
| **Cinder CSI** | The natural cloud answer, and good. Rejected because it needs OpenStack credentials inside the cluster and **does not exist on the PTR** — we would be building on something that must be removed |
| **Longhorn / OpenEBS replicated** | The eventual answer for anything needing durability. Needs the `iscsi-tools` Talos extension, i.e. a §16 image change |
| **NFS** (the PTR's R6715 storage host) | The likely answer for *shared model weights* on the PTR. No POC equivalent |

## 9. Gateway API implementation

**Envoy Gateway** (§11.4) over **Istio**. We want ingress, not a service mesh, and Envoy Gateway is one controller rather than a mesh install. Caveat stated plainly in §11.4: **Istio is the more-travelled path in KServe's own documentation and CI**, so if Envoy Gateway misbehaves, switching is a legitimate move rather than a defeat.

## 10. Scheduling the compute plane

Out of scope here, but named because it is coming. The PTR will likely need to run HPC batch work alongside inference services. Options are **Slurm** or **OpenPBS** on some subset of nodes (explicitly listed as post-MVP in the project plan), or Kubernetes-native batch — Kueue, Volcano, or Ray Jobs. This is the point at which "Talos everywhere" needs re-examining, since Slurm on a shell-less OS is awkward.

## 11. Things we did not need, and why

| Not used | Why |
|---|---|
| **Heat** (OpenStack orchestration) | The team is standardising on OpenTofu, which is portable |
| **Magnum** (Kubernetes as a service) | Would hand us a cluster and skip the entire point |
| **Octavia** (load balancers) | Gateway API handles ingress inside the cluster |
| **Manila** (shared filesystems) | Nothing in this POC needs shared POSIX storage |
| **`nova server rebuild`** | Destroys the disk in place; `rescue` is reversible |
| **OpenCHAMI `image-builder`** | Talos assets are prebuilt. It comes back if a node needs Rocky |
| **cloud-init on the compute nodes** | Talos ignores it. Using it would take OpenCHAMI out of the loop |
| **A `forward` clause in CoreDNS** | §8.4 explains why giving iPXE internet DNS does not help — its TLS stack can't use it |

## Related

- [§19 — Summary](19-summary.md) — the decisions actually taken
- [Appendix B — lineage](appendix-b-lineage.md) — what changes on real hardware
- [Appendix A — virtual BMCs](appendix-a-redfish-sushy.md) — the sushy-tools path in full
