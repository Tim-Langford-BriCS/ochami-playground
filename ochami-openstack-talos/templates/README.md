# Templates

Every configuration file this tutorial asks you to write, parameterised and commented. Each one repeats the *why* from the section it belongs to, so the file stands alone if you copy it out of here.

Placeholders look like `<THIS>`. Most are resolved by §1.5's reconnaissance and recorded in `tw-vars-env.sh`; the rest are noted in the file itself.

> **Two of these are alternatives, not both.** `techwatch-proto-openrc.sh` and `techwatch-proto-clouds.yaml` are the two authentication paths from §1.4. Using them together is the commonest cause of auth errors that look like cloud faults — openstacksdk *merges* `OS_*` environment variables on top of `clouds.yaml` rather than choosing between them.

## The naming rule

| Pattern | Means |
|---|---|
| `tw-*` | ours, on the **devbox**, in `~/tw/` |
| `tw-head-*` | ours, on the **head node**, in `~/` |
| `*-env.sh` | **source** it. A login shell loads exactly these and nothing else |
| anything else | **run** it — `tw-status.sh`, `pxeboot.sh`, `diskboot.sh` |

So `ls ~/tw/*-env.sh` and `ls ~/tw-head-*-env.sh` are complete inventories of what each machine's shell loads. On the PTR these will sit next to somebody else's files, which is what the prefix is for.

**Each machine has exactly one entry point, and `.bashrc` names only that.** Everything else is discovered by the entry point at load time, so a section that adds a helper adds a *file* — it never edits `.bashrc` and never edits another helper. §§10 and 14 both work this way.

| File | § | What it configures |
|---|---|---|
| [`tw-env.sh`](tw-env.sh) | §1.5 | **The devbox entry point.** Sources `tw-vars-env.sh` then `tw-helpers-env.sh` if they exist, and warns about pre-rename filenames. No values — **always safe to re-copy** |
| [`tw-vars-env.sh`](tw-vars-env.sh) | §1.5, §1.7 | **Start here.** Every value that depends on your cloud, plus the node map. **Yours — never re-copy wholesale once filled in** |
| [`tw-helpers-env.sh`](tw-helpers-env.sh) | §1.7, any | The `tw_*` functions (`tw_help`, `tw_check`, `tw_admin`, …). No values, so **always safe to re-copy wholesale** — that is why it is a separate file from `tw-vars-env.sh` |
| [`tw-head-env.sh`](tw-head-env.sh) | §5.1 | **The head entry point**, copied across with the values file three sections before the first of its dependants exists. Sources `tw-head-vars-env.sh`, `tw-head-talos-env.sh`, `tw-head-inference-env.sh` if present. No values — **always safe to re-copy** |
| *`tw-head-vars-env.sh`* | §5.1, §5.12 | **Not a file here** — it is *generated* on the devbox from your `tw-vars-env.sh` and `scp`'d over, which is the point: the head's values cannot drift from the devbox's because nobody types them twice |
| [`tw-head-talos-env.sh`](tw-head-talos-env.sh) | §10.3 | `TALOSCONFIG` and `KUBECONFIG`, **on the head**. Goes at `~/tw-head-talos-env.sh` and needs no hook — `tw-head-env.sh` is already looking for that name. Copy wholesale; it holds no cloud-specific values |
| [`tw-head-inference-env.sh`](tw-head-inference-env.sh) | §14.3a | `tw_infer`, `tw_ask`, `tw_ask_raw` — the model endpoint, **on the head**. Same: writing the file is the whole installation. Functions rather than values, because the endpoint is *discovered* and moves on its own. Copy wholesale |
| [`tw-status.sh`](tw-status.sh) | any | **"where am I?"** Probes the live project and reports the first section not yet done. **Run, don't source** — hence no `-env.sh`. Strictly read-only; safe at any point, including mid-section |
| [`techwatch-proto-openrc.sh`](techwatch-proto-openrc.sh) | §1.4 | **path A** — the simple way: `source` it, type your password once per shell. ⚠ **The one exception to the naming rule**: it is sourced but is not `tw-…-env.sh`, because Horizon generates it under this name and renaming it would misrepresent what your cloud hands you. It is also the one sourced file that must **never** go in `.bashrc` — it prompts for a password |
| [`techwatch-proto-clouds.yaml`](techwatch-proto-clouds.yaml) | §1.4 | **path B** — `clouds.yaml`, the only path the IaC can use. Also carries the application-credential and admin entries, commented out |
| [`clouds.yaml.example`](clouds.yaml.example) | §1.4 | the same as path B but fully parameterised, for a cloud that isn't Digital Labs |
| [`head-user-data.yaml`](head-user-data.yaml) | §4.3 | cloud-init for the head node instance |
| [`coredhcp.yaml`](coredhcp.yaml) | §5.7 | OpenCHAMI's DHCP server — the heart of the provisioning wire |
| [`Corefile`](Corefile) | §5.8 | OpenCHAMI's DNS, and why not to add a `forward` clause |
| [`nodes.yaml`](nodes.yaml) | §6.1 | the SMD inventory: MAC → IP → xname → group |
| [`pxeboot.sh`](pxeboot.sh) | appendix F, appendix A | ⚠ **not on the main path** — "network-boot this node" via Nova rescue, the manual form of Redfish `Pxe`. §10 needs no such script |
| [`diskboot.sh`](diskboot.sh) | appendix F, appendix A | ⚠ **not on the main path** — "boot from disk", the manual form of Redfish `Hdd`. §10 needs no such script |
| [`talos-patches.yaml`](talos-patches.yaml) | §8.6 | disk selection, nameservers and certificate SANs |
| [`bss-talos-controlplane.yaml`](bss-talos-controlplane.yaml) | §9.1 | BSS boot payload for the Kubernetes control-plane node |
| [`bss-talos-worker.yaml`](bss-talos-worker.yaml) | §9.1 | BSS boot payload for the workers |
| [`sushy-emulator.conf`](sushy-emulator.conf) | appendix A | a virtual Redfish BMC for one node |

## The three files that must agree

`nodes.yaml`, `bss-talos-*.yaml`, and the Neutron ports created from the node map in `tw-vars-env.sh` all carry the same MAC addresses. If they disagree, nodes fail to boot in ways that produce no useful error — see §6's "three-way contract".

```
   tw-vars-env.sh node map ──┬─→ §3.4  openstack port create --mac-address …
                     ├─→ §6.1  nodes.yaml         (MAC → IP → xname)
                     └─→ §9.1  bss-talos-*.yaml   (MAC → role)
```

Keeping them in sync by hand is the single biggest error source in this tutorial, and eliminating it is the main reason the [companion IaC](../../ochami-openstack-talos-iac/) exists: it generates all three from one declaration.

## Not here

The Kubernetes manifests from §§13–15 — KServe's `HelmRelease` and `ClusterServingRuntime`, the `InferenceService`, the `RayCluster` — are deliberately **not** in this directory. From §12 onward the tutorial is GitOps: those files belong in your Flux repository, which is their record. They are given in full inline in the sections, and in reusable form in the [companion IaC's `flux/` tree](../../ochami-openstack-talos-iac/).
