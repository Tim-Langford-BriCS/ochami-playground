# §19 — Summary: what we built and decided

## What you built

```
Digital Labs OpenStack, project techwatch-proto, one hypervisor
├── two Neutron networks — one routed, one deliberately silent
├── tw-head        Rocky 9: the OpenCHAMI control plane + S3 + registry + NAT
├── tw-cp1         Talos → Kubernetes control plane
└── tw-w1, tw-w2   Talos → Kubernetes workers
                   └── Flux → KServe (Standard) → vLLM → an LLM on HTTP
                       Flux → KubeRay → a RayCluster
```

An OpenCHAMI-provisioned Kubernetes cluster serving a language model over an OpenAI-compatible API, with every layer above the machines declared in Git. That is TechWatch **Step −1**.

## Every decision, and why

**Architecture**

| Decision | Why | Alternative rejected |
|---|---|---|
| One Nova instance per node, no nesting (§0) | nested virt is disabled cloud-wide at Digital Labs, and the flat model is closer to the PTR anyway | HPE vTDS / StackHPC's approach: KVM inside an instance |
| **iPXE as the node's root disk** (§0, §7) | Nova cannot put a NIC in a guest's boot order at all, so we make iPXE the one thing it will always boot — a disk. Needs no policy, no microversion and no extra volume, and Talos overwrites it on install, so the reinstall loop ends itself | Nova rescue mode (works, proven, far more machinery — [appendix F](appendix-f-network-boot-investigation.md), and still what appendix A needs); iPXE ISO as a second volume; Ironic (wrong layer) |
| `openstack server rebuild` as the re-provisioning verb (§10.7) | puts iPXE back on the root disk, which restarts the whole chain with no state held anywhere | tracking provisioned MACs in BSS with a `sanboot` payload |
| `talos.platform=metal`, not `openstack` (§9) | keeps **OpenCHAMI** as the source of truth. Letting Nova's metadata configure Talos would prove nothing | Talos's native `openstack` platform |
| x86_64 throughout (§8) | matches the PTR's Intel Xeon and AMD EPYC | the libvirt lab's aarch64 |

**OpenStack substrate**

| Decision | Why |
|---|---|
| Provisioning subnet `--no-dhcp --gateway none` (§3.2) | only CoreDHCP may answer DHCP on the wire — the same invariant as the libvirt lab's isolated bridge, and as the PTR's management VLAN |
| Port security **disabled** on the provisioning wire (§3.3) | Neutron's anti-spoofing specifically blocks a VM from serving DHCP and from forwarding foreign source IPs. We need both. Safe because the wire is isolated and ours |
| MAC-pinned Neutron **ports**, created before the instances (§3.4) | OpenCHAMI's whole model is MAC → identity, so MACs must be ours to choose. Also means `server delete` doesn't destroy the contract (§18) |
| Allocation pools that avoid `.200–.250` (§3.2) | leaves CoreDHCP's bootloop range free |
| Nodes get **no** floating IP, no SSH key, no user-data (§7.3) | they are compute nodes on a management VLAN. Everything reaches them through the head |
| Application credentials, `member` role, expiring (§1.2) | can't be pointed at another project; revocable without touching the account |
| Blank Glance image as the nodes' root disk (§7.2) | Talos overwrites it anyway, and an empty disk makes "provisioned or not" visible |

**Talos and Kubernetes**

| Decision | Why |
|---|---|
| Talos, not Rocky, on the compute nodes | the target workload is Kubernetes; Talos removes everything that isn't. LANL were keen to test it with OpenCHAMI |
| `diskSelector` by size **with `wipe: true`** (§8.6) | the install target is the disk iPXE is running from; wiping it is what ends the network-boot loop. `gen config`'s default `disk: /dev/sda` is wrong here and ignored — the selector wins |
| Public-read S3 for boot assets *and* machine configs (§8.3) | a booting node has no credentials, no DNS and no TLS. Acceptable only because the wire is isolated — flagged as production-wrong |
| Public resolvers in the machine config (§8.6) | CoreDNS answers cluster names only, and Talos must reach `ghcr.io`. Fixed in the node, not by widening CoreDNS |
| Head node as NAT router (§5.12) | Talos is not self-contained; it pulls its installer and all of Kubernetes |
| `local-path-provisioner` for storage (§11.2) | works identically on PTR metal, needs no credentials. Cinder CSI would have to be ripped out later |

**Inference stack**

| Decision | Why |
|---|---|
| FluxCD (§12) | the rig's purpose is repeatable experiments; Git is the record of what ran. Also the migration path to a PTR cluster |
| KServe in **Standard** mode, no Knative (§13) | scale-to-zero is actively harmful when a cold start means reloading GB of weights, and the PTR nodes are dedicated |
| Envoy Gateway over Istio (§11.4) | we want ingress, not a service mesh |
| A custom `ServingRuntime` for vLLM CPU (§14.1) | KServe's built-in runtimes assume GPUs; and on the PTR you will define one per accelerator family anyway |
| `Qwen2.5-0.5B-Instruct` (§14) | small, instruction-tuned, and **not gated** — so no Hugging Face token, so no secret in Git |
| KubeRay installed but lightly used (§15) | it is the heterogeneous scheduler in the design; there is nothing heterogeneous to schedule yet |

## What this POC does *not* prove

Be honest about this when reporting:

- **Nothing about performance.** CPU-only, small flavors, a 0.5 B model. §14 captures a baseline precisely so the accelerator numbers have something to beat.
- **Nothing about Redfish, BMC credentials or real power control** — unless you do [appendix A](appendix-a-redfish-sushy.md), which is why it exists.
- **Nothing about firmware.** Real Dell and HPE UEFI, boot order and PXE-on-which-NIC are entirely absent here, and will consume real time.
- **Nothing about the fast fabric.** 100 GbE RoCEv2 and later SlingShot-400 have no analogue in a Neutron network.
- **Nothing about accelerator drivers on Talos** — and Intel Gaudi is the open risk (§16.1).

## Open questions, ranked

1. **Can Intel Gaudi3 drivers be delivered as a Talos system extension?** If not, that node needs a different OS and the cluster design changes. Resolve before the XE7740 is committed. (§16.1)
2. **Does Digital Labs' Nova policy allow tenant `server rescue`?** No longer load-bearing — §7 was rebuilt on the root-disk mechanism on 4 Aug 2026 — but [appendix A](appendix-a-redfish-sushy.md)'s Redfish emulation still implements "boot device = PXE" that way, so answer it before committing to appendix A.
3. **Where does the OpenCHAMI control plane live on the PTR?** An instance (as here) or dedicated bare metal. LANL suggested several control planes in VMs — one per developer — which this POC is already a working example of.
4. **How is the provisioning VLAN protected on real hardware?** There is no `--no-dhcp` flag on a physical switch; the "only CoreDHCP answers" invariant needs a switch configuration and an agreement with the network team.
5. **Shared storage for model weights.** local-path is fine for caches; the PowerVault/NFS host needs a CSI decision, and iSCSI on Talos needs an extension.
6. **Control-plane HA**, **SELinux enforcing**, and **step-ca vs site PKI** — all deferred, all listed in [appendix B](appendix-b-lineage.md).
7. **Does KServe's newer `LLMInferenceService`/llm-d path replace §§13–14?** It is where KServe is heading, and worth a follow-on experiment.

## What to do next

**Immediately after finishing:**

- Fill in every `⟨captured on first run⟩` checkpoint from your run log. **This document is the deliverable**, and its value is that its commands are known to work.
- Record whether `--mac-address` was permitted, whether the firmware was BIOS or UEFI, and which Gateway implementation you used. The IaC needs all three.
- Note the vLLM baseline numbers from §14.

**Then:**

1. [Appendix A](appendix-a-redfish-sushy.md) — virtual BMCs and Magellan. The highest-value remaining work, because dynamic Redfish discovery is the biggest single difference from the PTR.
2. The [companion IaC](../ochami-openstack-talos-iac/) — rebuild the same cluster from OpenTofu and Ansible, and diff it against what you did by hand.
3. Multi-control-plane Kubernetes (3 × `tw-cp`), which the design slide allows for and which changes only §6, §9 and the Talos config.
4. Swap the inference engine — a second `InferenceService` on llama.cpp serving the same model is one commit, and the cheapest possible engine comparison.

## The one-sentence version

We replaced the libvirt lab's Lima substrate with an OpenStack one and its Rocky compute nodes with Talos, and — since Nova cannot network-boot an instance at all — made iPXE the node's root disk so that creating the instance *is* pressing the PXE button — **and the OpenCHAMI layer in the middle never changed.**

## Related

- [Appendix A — virtual BMCs and Redfish discovery](appendix-a-redfish-sushy.md)
- [Appendix B — lineage: upstream → lab → this → PTR](appendix-b-lineage.md)
- [Appendix C — alternatives we considered](appendix-c-alternatives.md)
- [Appendix D — the ten-minute smoke test](appendix-d-smoke-test.md)
- [The libvirt lab](../ochami-macos-libvirt/) and its [Talos follow-on](../ochami-macos-libvirt-talos/)
- [The companion IaC](../ochami-openstack-talos-iac/)
