# OpenCHAMI + Talos + Kubernetes inference on OpenStack — step by step

A hands-on tutorial that builds a complete **OpenCHAMI**-managed cluster inside an **OpenStack** project, network-boots **Talos Linux** nodes on it to form a **Kubernetes** cluster, and drives that cluster with **FluxCD** to serve an LLM over an OpenAI-compatible API via **KServe**, **vLLM** and **KubeRay**.

This is **Step −1** of the BriCS TechWatch project: rehearse the entire inference stack on Digital Labs OpenStack while the PTR hardware is being racked, so that Step 0/1 on real metal is a repeat rather than a first attempt.

Every step gives the **full command or config file**, then explains **what it does and why it's done that way**. By the end you will have touched, by hand: Keystone application credentials, Neutron networks and MAC-pinned ports, Nova instances that network-boot from an iPXE root disk, Glance images, the OpenCHAMI microservices (SMD, BSS, CoreSMD, cloud-init), DHCP/TFTP/PXE/iPXE, Talos machine configs, Kubernetes bring-up, GitOps with Flux, and CPU-only LLM inference.

## What you will build

```
Digital Labs OpenStack — project techwatch-proto  (pinned to one hypervisor)
│
├── tw-ext          Neutron network, DHCP on, routed         ← §3  SSH + downloads
├── tw-prov         Neutron network, NO DHCP, NO router      ← §3  the provisioning wire
│
├── tw-head         Rocky 9 instance, 2 ports                ← §4
│     ├── OpenCHAMI control plane (SMD, BSS, CoreSMD, …)     ← §5
│     ├── Versity S3 :7070 + OCI registry :5000              ← §5
│     └── NAT router  tw-prov → tw-ext                       ← §5
│
├── tw-cp1          network-boots Talos → k8s control plane   ← §§7-10
└── tw-w1 … tw-wN   network-boot Talos → k8s workers          ← §§7-10
      │
      └── Kubernetes ← §11 ─ FluxCD ← §12 ─ KServe ← §13 ─ vLLM ← §14 ─ KubeRay ← §15
```

## Prerequisites

| Requirement | Why |
|---|---|
| An OpenStack **project** you own, with `member` role | everything happens inside it; ours is `techwatch-proto` |
| **Network access** to the OpenStack API endpoint (F5 VPN if off-campus) | the `openstack` CLI has to reach Keystone |
| The project **pinned to a hypervisor** (host aggregate) | blast-radius containment — §1. Ask your cloud admin; do not do this yourself |
| Quota for ~4 instances / ~20 vCPU / ~40 GB RAM / ~120 GB disk / 2 networks | §1 tells you how to check, §4/§7 how to trim if you have less |
| [Lima](https://lima-vm.io) on macOS, or any Linux box | to run the `openstack-devbox` client VM — §1.3 |
| A Git repository you can push to (GitHub/GitLab) | FluxCD is GitOps; it needs somewhere to read from — §12 |
| A reasonable network connection | ~10 GB of downloads (images, containers, model weights) |

Nothing is installed on your laptop except the client VM. Everything else lives in the OpenStack project and is removed by §18.

> **You do not need nested virtualisation.** That is a deliberate design choice and §0 explains why at length — it is the single biggest difference between this tutorial and the other published approaches.

## Contents

| § | File | What it covers |
|---|---|---|
| 0 | [Introduction — what we're building and why](00-introduction.md) | OpenCHAMI, the two planes, the boot chain, the two decisions that shape everything |
| 1 | [Safety, access and reconnaissance](01-safety-and-access.md) | blast-radius rules, application credentials, the client VM, read-only recon |
| 2 | [An OpenStack primer for libvirt people](02-openstack-primer.md) | Keystone/Nova/Neutron/Glance/Cinder mapped onto libvirt equivalents |
| 3 | [Networks, subnets and MAC-pinned ports](03-networks-and-ports.md) | the two networks, why the provisioning wire must be silent, port security |
| 4 | [The head node instance](04-head-node-instance.md) | image, flavor, cloud-init, two ports, floating IP, SSH, and a data volume if the flavor's disk is small |
| 5 | [Installing OpenCHAMI](05-install-openchami.md) | quadlets, S3, registry, CoreDHCP/CoreDNS, certificates, NAT |
| 6 | [Telling OpenCHAMI about our nodes](06-node-inventory.md) | SMD as the source of truth; the MAC/IP/xname contract |
| 7 | [Node instances and network boot](07-node-instances-and-ipxe.md) | how you make a cloud VM network-boot at all — iPXE becomes the node's root disk |
| 8 | [Talos assets and machine config](08-talos-assets-and-config.md) | kernel/initramfs to S3, machine configs, disk selection |
| 9 | [Boot parameters](09-boot-parameters.md) | BSS answers, one per node role |
| 10 | [Booting the Talos cluster](10-boot-the-cluster.md) | the payoff: PXE → install → Kubernetes |
| 11 | [Cluster foundations](11-cluster-foundations.md) | CNI, DNS, storage, metrics, Gateway API |
| 12 | [GitOps with FluxCD](12-fluxcd-gitops.md) | why GitOps for an experiment rig; bootstrap; repo layout |
| 13 | [KServe](13-kserve.md) | model serving control plane, without Knative |
| 14 | [Serving an LLM with vLLM](14-vllm-inference.md) | the inference engine; a real completion over HTTP |
| 15 | [Ray and KubeRay](15-kuberay.md) | distributed scheduling for heterogeneous workloads |
| 16 | [Heterogeneous hardware](16-heterogeneous-hardware.md) | device plugins, Talos extensions, what changes on the PTR |
| 17 | [Troubleshooting](17-troubleshooting.md) | symptom → cause, across every layer |
| 18 | [Teardown](18-teardown.md) | give the resources back, and prove you did |
| 19 | [Summary — what we built and decided](19-summary.md) | every decision, and what's still open |
| A | [Appendix: virtual BMCs and Redfish discovery](appendix-a-redfish-sushy.md) | sushy-tools + Magellan: the PTR-fidelity upgrade |
| B | [Appendix: lineage — upstream → lab → this → PTR](appendix-b-lineage.md) | what carries over to real hardware and what doesn't |
| C | [Appendix: alternatives we considered](appendix-c-alternatives.md) | vTDS, Tenks, Ironic, Omnia, Knative, llm-d, Slurm |
| D | [Appendix: the ten-minute smoke test](appendix-d-smoke-test.md) | **do this after §1, before §3** — one throwaway VM settles flavor access, BIOS vs UEFI, and whether MAC pinning and disabling port security are permitted |
| E | [Appendix: the complete network map](appendix-e-network-map.md) | every hop from your laptop to a Talos node, in one diagram — the two networks, both head ports, the MAC contract and the address bands |
| F | [Appendix: how we established the way a node network-boots](appendix-f-network-boot-investigation.md) | **§7's evidence, and §7 as it was until 4 Aug 2026** — four candidate mechanisms, the tests that chose between them, the captured consoles, and working instructions for rescue and the CD-ROM variant. Read it if your cloud is not Digital Labs, or to check our work |
| G | [Appendix: choosing a model to test with](appendix-g-model-selection.md) | sizes, licences, gated vs open, the KV-cache arithmetic, and what changes between a CPU POC and the PTR's accelerators — plus why a smaller model never solves a disk problem |
| — | [`templates/`](templates/README.md) | every config file in this tutorial, parameterised and ready to copy |
| — | [`diagrams/`](diagrams/README.md) | four hand-written SVGs — the two network maps, plus [§6's three-way contract](diagrams/06-three-way-contract.svg) and [appendix F's boot chain](diagrams/07-boot-chain.svg) — and the conventions they follow: colour is the argument, not the decoration |
| — | [`runbooks/`](runbooks/README.md) | repeatable operational tasks, commands first — [updating the VPN tunnel address](runbooks/update-tunnel-ip.md) when SSH starts hanging, [managing application credentials](runbooks/manage-application-credentials.md), [creating the project's flavors](runbooks/create-project-flavors.md) |
| — | [`glossary/`](glossary/README.md) | every component in the system, built up as we meet it — [OpenStack](glossary/openstack.md) (what someone else runs) and [OpenCHAMI](glossary/openchami.md) (what we install) |
| — | [`issues/`](issues/README.md) | faults hit on a real run, with the verbatim error and every solution weighed — [`versitygw-bootstrap` and the OpenStack AZ name](issues/001-versitygw-bootstrap-aws-region.md), [podman's NAT table](issues/002-nftables-table-owned-by-podman.md), [BSS advertising `${SYSTEM_URL}`](issues/003-bss-ipxe-server-unexpanded-system-url.md) |
| — | [Decision log](DECISION-LOG.md) | decisions that are **still open** or taken under conditions we expect to change, with their reversal triggers |
| — | [Investigation: can we avoid the iPXE hack?](INVESTIGATION-network-boot.md) | 28 Jul 2026, with the outcome added 4 Aug — why Nova cannot network-boot, and what the prior art does instead. **Answered:** see [appendix F](appendix-f-network-boot-investigation.md) |

Reading order is 0 → 19, with **[appendix D](appendix-d-smoke-test.md) slotted in between §1 and §2**. **§§0–10 are the spine** — the OpenCHAMI and Talos path — and are worth doing in one or two sittings. §§11–16 build the inference stack on top and can be done later. Budget **a day** for §§0–10 the first time and **half a day** for §§11–16, most of it waiting for downloads.

> **Why an appendix has a fixed place in the reading order.** Three things this tutorial depends on are decisions *your cloud* makes and that no document can tell you: whether tenant `server rescue` is permitted (no longer §7's mechanism — see [appendix F](appendix-f-network-boot-investigation.md) — but still what [appendix A](appendix-a-redfish-sushy.md) needs), whether you may pin a port's MAC address (§§3, 6 and 9 are keyed by MAC), and whether you may disable port security (§5's DHCP and NAT both fail silently without it). Appendix D answers all three with one disposable instance. Each has a documented fallback, but choosing a fallback is far cheaper before you build than after.

## Conventions

- Commands are shown with the prompt of the machine they run on:
  - `devbox$` — the client VM where the `openstack` CLI runs (§1.3). Nothing in this tutorial is typed on your laptop directly.
  - `head$` — inside the OpenCHAMI head instance, over SSH. `talosctl` and `kubectl` also run here, so the whole cluster is driven from one place.
  - There is no `node$`. **Talos has no shell and no SSH** — that is the point of it.
- ⚠ **Do not copy the prompt itself.** `devbox$ ` and `head$ ` are labels saying *which machine to type this on*, not part of the command — paste one by accident and you get `-bash: head$: command not found`. They earn their keep because this build spans three machines and an unlabelled command is ambiguous, but they do make whole-block copying hostile. **Copy from the character after the `$ `**, and where a block contains several commands, run them one at a time so a failure cannot scroll away under the next one's output.
- ✅ **Checkpoint** blocks show the expected output. Where a checkpoint shows `⟨captured on first run⟩` it has not yet been executed against the real Digital Labs cloud — see the fidelity note below.
- 🔀 **Deviation** boxes mark every place we differ from the [upstream OpenCHAMI tutorial](https://openchami.org/docs/tutorial/) or from our own [libvirt lab](../ochami-macos-libvirt/) and say why.
- ⚠ **Gotcha** boxes are lessons paid for in hours — either during our two libvirt reproductions or in the OpenStack literature.
- 🛑 **Stop** boxes mark the handful of points where doing the wrong thing could affect somebody else's workload. There are only a few, and they are all in §1 and §3.
- Placeholders look like `<THIS>` and every one of them is resolved by the recon checklist in §1.4. If you are reading a command with a `<…>` still in it, go back to §1.4.

### Reading `openstack` commands: `-c` and `-f`

Two flags appear on nearly every command in this tutorial, and they are easy to mistake for something else:

| Flag | Means | Not |
|---|---|---|
| `-c` / `--column` | **which column of the output to show.** Repeatable. | a value to search for, and nothing to do with clouds |
| `-f` / `--format` | the output *format*: `table` (default), `value`, `json`, `shell`, `yaml` | a list of fields |
| `--os-cloud` | which `clouds.yaml` entry to authenticate with | — |

So `-c project_id -f value` means "print the `project_id` column, bare, with no table decoration" — ideal for `$(…)` in a script. Passing a *value* to `-c` gets you a list of the columns that do exist:

```
devbox$ openstack token issue -c techwatch-proto -f value
No recognized column names in ['techwatch-proto'].
Recognized columns are ('expires', 'id', 'project_id', 'user_id').
```

That error is genuinely helpful — it is telling you the available column names. The command you wanted is:

```
devbox$ openstack token issue -c project_id -f value
```

Two more traps in the same family: **`-c` takes one column at a time** (repeat the flag: `-c id -c project_id`), and **there is no comma syntax** — `-f id, project_id` is parsed as `-f 'id,'`, which fails as an invalid format.

## Fidelity note — read this before you trust a command

The other two tutorials in this repo were written *while* being executed, so every command and every checkpoint in them is real. **This one is written ahead of its first execution**, for a reason: three OpenStack hypervisors at Digital Labs carry other people's work, and the point of §1 is that we plan the blast radius before we touch the API, not after.

Consequently:

- Everything in §§5, 8, 9 and 10 that concerns **OpenCHAMI and Talos** is ported from tutorials we *did* execute (`ochami-macos-libvirt`, `ochami-macos-libvirt-talos`), with the architecture substitutions flagged. Treat it as reliable.
- **§§1–4 have now been executed** against Digital Labs (2 Aug 2026) and their checkpoints hold real captured output. Where a prediction turned out wrong it has been corrected in place and the correction noted — the interface names in §4's Concepts are the clearest example.
- Everything in §§6 and 7 that concerns **OpenStack** is still derived from upstream documentation and from the specifics of the Digital Labs deployment. Treat it as a careful first draft. §7 in particular has two documented fallbacks because the mechanism it relies on may be disallowed by local Nova policy.
- Checkpoints are marked `⟨captured on first run⟩` until someone fills them in. **Filling them in is part of doing the tutorial.** If a command needs changing, change it here too — this document is meant to end up as the validated record.

The companion Infrastructure-as-Code artifacts in [`../ochami-openstack-talos-iac/`](../ochami-openstack-talos-iac/) automate everything below. Do this by hand first: the IaC is only trustworthy once you know what it is supposed to produce.

Next: [§0 — Introduction](00-introduction.md)
