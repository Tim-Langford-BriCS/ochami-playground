# Runbook — creating the project's flavors

*Operational reference, not a tutorial. Commands first. The reasoning is [§1.5](../01-safety-and-access.md) — the placement trait, why a plain flavor will not schedule, and what each property is for. This file is what you open when you already know why and need to create or replace them.*

| I want to… | Go to |
|---|---|
| Check the cluster fits in our quota | [Check it fits](#check-it-fits-before-you-create-it) |
| Create the three flavors for the first time | [1. Create](#1-create) |
| Confirm they are correct and visible to my member credential | [2. Verify](#2-verify) |
| Change a size, or fix a wrong property | [3. Change one](#3-change-one) |
| Remove flavors at teardown | [4. Delete](#4-delete) |
| Understand an error I just got | [5. Errors](#5-errors-seen-in-practice) |

🛑 **This needs the `admin` role and touches a cloud-wide namespace.** Flavor names live in Nova's global namespace even when the flavor is private, so a mistake here is visible to every project on the cloud. Every command below is `--os-cloud techwatch-admin`, one at a time, and nothing here should ever run from the shell you are doing the tutorial in. If you do not hold `admin`, this is an ask — send whoever does the table in [§1.5](../01-safety-and-access.md) and stop.

---

## What we are creating, and why three

The cluster has three jobs with three different shapes. A single flavor is the wrong answer for all of them:

| Flavor | vCPU | RAM | Disk | Runs | Sized by |
|---|---|---|---|---|---|
| `techwatch-proto-head` | 4 | 16 GB | **60 GB** | the OpenCHAMI head (§4) | **disk.** Holds the S3 artifact store (Talos kernel + initramfs), an OCI registry and ~18 container images. It does no compute |
| `techwatch-proto-cp` | 4 | 16 GB | 30 GB | the Talos control plane (§7) | etcd. Modest, but latency-sensitive |
| `techwatch-proto-worker` | 8 | 64 GB | 30 GB | the Talos workers (§7, §14) | **RAM and memory bandwidth.** vLLM on CPU is entirely memory-bandwidth-bound, so this flavor decides whether §14 is tolerable or glacial |

⚠ **The head's 60 GB is the one dimension not to compromise on.** 30 GB will be tight and can fail partway through §5, at which point you are rebuilding. If you are forced to live with 30, [§4.2](../04-head-node-instance.md) attaches a Cinder volume at `/data` instead — it works, and it adds a moving part.

⚠ **Pinned vCPUs make capacity exclusive.** `hw:cpu_policy=dedicated` means a 128-core hypervisor fits sixteen 8-vCPU instances and no more, however idle they are. Budget instance count against cores, not against load, and check quota before creating a flavor larger than you can boot.

### Check it fits, before you create it

```
devbox$ openstack limits show --absolute        # used alongside max — the useful one
devbox$ openstack quota show -f yaml            # adds the Neutron and Cinder side
```

From the first, the rows that matter are `total_cores` / `total_cores_used`, `total_ram` / `total_ram_used` (**MB, not GB**) and `max_total_instances` / `total_instances_used`. `-1` means unlimited.

What the full cluster costs, against the quota measured on Digital Labs, 2 Aug 2026:

| | Instances | vCPU | RAM | Floating IPs | Ports |
|---|---|---|---|---|---|
| `tw-head` | 1 | 4 | 16 GB | 1 | 2 |
| `tw-cp1` | 1 | 4 | 16 GB | — | 1 |
| `tw-w1`, `tw-w2` | 2 | 16 | 128 GB | — | 2 |
| **Total needed** | **4** | **24** | **160 GB** | 1 | 5 |
| **Project quota** | 20 | 80 | **200 GB** (204800 MB) | 50 | 500 |

**RAM is the binding constraint, and nothing else is close.** The cluster uses 80% of the RAM allowance and 30% of the cores. Concretely: head + cp leave 168 GB, which affords exactly **two** workers — a third would need 224 GB and be refused. That is why §7 boots two of the five nodes §6 registers, and if you ever need a third worker it is a quota ask, not a flavor change.

⚠ **Quota passing does not mean it will schedule.** They are independent gates. Quota is an accounting limit on the project; `hw:cpu_policy=dedicated` and `hw:mem_page_size=1GB` mean the *host's* cores and hugepages are allocated exclusively, so a hypervisor with idle capacity can still refuse you. Both failures read as `No valid host was found`. A member cannot see host capacity — `openstack hypervisor show` is admin-only — so if quota is clearly fine and the boot still fails, work through the three causes in [5. Errors](#5-errors-seen-in-practice).

---

## The property block

Seven properties, copied verbatim onto all three flavors. Only `--vcpus`, `--ram` and `--disk` vary.

| Property | What it does | If you omit it |
|---|---|---|
| `trait:CUSTOM_TECHWATCH_PROTO=required` | **the isolation contract** — see below | the instance can land on any hypervisor in the cloud, silently |
| `hw:cpu_policy=dedicated` | pins vCPUs to physical cores | no valid host: these hosts are configured for pinned CPUs |
| `hw:mem_page_size=1GB` | matches the host's preallocated hugepages | no valid host, same reason |
| `hw:cpu_sockets=2` | guest sees 2 sockets | guest topology only; not load-bearing for scheduling |
| `hw:numa_nodes=N` | guest NUMA topology | see the divisor note below |
| `hw:pci_numa_affinity_policy=preferred` | tolerates a device whose NUMA affinity does not match | stricter placement than we need |
| `hw_rng:allowed=True` | gives the guest a `virtio-rng` device | early boot can block on `/dev/random`. This cluster generates a *lot* of keys at first boot — step-ca's CA (§5), Talos's PKI (§8), etcd's certificates (§10) — so leave it on |

### The trait is the whole point

`trait:CUSTOM_TECHWATCH_PROTO=required` tells Placement to consider only hypervisors whose resource provider carries that trait. At Digital Labs this — not an availability zone, not a host aggregate — is what confines the project to its own hypervisor.

The consequence to keep hold of: **the isolation travels with the flavor, not with the project.** Boot from any other flavor and you have opted out of it, with no error and no warning. Which means:

- Every flavor this project creates carries the trait. There is no such thing as a "quick test flavor without it".
- Never "fix" a `No valid host was found` by dropping properties or adding `--availability-zone`. That is the one change that quietly breaks the isolation. The real causes are exclusive-capacity exhaustion (see above) or a genuine quota limit.
- `openstack flavor show <FLAVOR> -c properties` is a member-runnable check that the mechanism is still intact — worth running if instances ever start landing unexpectedly.

Custom trait names must start with `CUSTOM_` and be upper-case with underscores. The trait must already exist on the resource provider; creating a flavor that requires a trait nobody has applied yields a flavor that can never schedule anywhere.

### `hw:numa_nodes` — the one value to think about

This is the only property not simply copied, and the intuitive answer is wrong. **Read the reference flavor first** — the one already confirmed to schedule onto the right host:

```
devbox$ openstack flavor show techwatch-proto-test-flavor -f yaml
```

On Digital Labs, 2 Aug 2026, that is 8 vCPU / 64 GB / 30 GB with `hw:numa_nodes=8`.

The instinct is that 8 vNUMA nodes across 8 vCPUs is a silly topology and a smaller number must be better. That gets it backwards, because of what a guest NUMA node costs. With `hw:mem_page_size=1GB`, **each guest NUMA node's memory is allocated from a single host NUMA cell's preallocated hugepages** — so fewer nodes means a *larger* demand on each one:

| Flavor | `hw:numa_nodes` | vCPU per node | RAM per node, from one host cell |
|---|---|---|---|
| `techwatch-proto-test-flavor` (proven) | 8 | 1 | 8 GB |
| `techwatch-proto-worker` (8 vCPU / 64 GB) | **8** | 1 | 8 GB |
| the tempting wrong answer for the worker | 2 | 4 | **32 GB** — four times what is known to fit |
| `techwatch-proto-head` / `-cp` (4 vCPU / 16 GB) | **2** | 2 | 8 GB |

So: **match the reference exactly wherever the shape matches it**, and for the smaller flavors pick the node count that keeps the per-node ask at the same 8 GB the reference proves the host will serve. A too-small node count fails as `No valid host was found`, which reads exactly like a capacity or quota problem and sends you hunting in the wrong place.

Two hard constraints to stay inside: `--vcpus` must divide evenly by the node count (Nova refuses otherwise, absent explicit `hw:numa_cpus.N` mapping), and the host must actually have that many NUMA cells — the reference's `8` tells you it has at least eight.

If in doubt, ask whoever tuned the compute nodes. The host's own topology decides what is valid, and this is not a guess worth making.

---

## 1. Create

Get the project ID first, from the **member** credential — it can only ever be scoped to one project, so this cannot be the wrong one:

```
devbox$ PROJ=$(openstack --os-cloud techwatch token issue -c project_id -f value)
devbox$ echo $PROJ
```

Each `--os-cloud techwatch-admin` command prompts for your password. That is the design; do not smooth it away. For a burst of six, [§1.2](../01-safety-and-access.md) has the subshell form and `tw_admin`.

### Head

```
devbox$ openstack --os-cloud techwatch-admin flavor create \
    --vcpus 4 --ram 16384 --disk 60 --private \
    --property hw:cpu_policy=dedicated \
    --property hw:cpu_sockets=2 \
    --property hw:mem_page_size=1GB \
    --property hw:numa_nodes=2 \
    --property hw:pci_numa_affinity_policy=preferred \
    --property hw_rng:allowed=True \
    --property trait:CUSTOM_TECHWATCH_PROTO=required \
    techwatch-proto-head
```

```
devbox$ openstack --os-cloud techwatch-admin flavor set \
    --project $PROJ techwatch-proto-head
```

### Control plane

```
devbox$ openstack --os-cloud techwatch-admin flavor create \
    --vcpus 4 --ram 16384 --disk 30 --private \
    --property hw:cpu_policy=dedicated \
    --property hw:cpu_sockets=2 \
    --property hw:mem_page_size=1GB \
    --property hw:numa_nodes=2 \
    --property hw:pci_numa_affinity_policy=preferred \
    --property hw_rng:allowed=True \
    --property trait:CUSTOM_TECHWATCH_PROTO=required \
    techwatch-proto-cp
```

```
devbox$ openstack --os-cloud techwatch-admin flavor set \
    --project $PROJ techwatch-proto-cp
```

### Worker

```
devbox$ openstack --os-cloud techwatch-admin flavor create \
    --vcpus 8 --ram 65536 --disk 30 --private \
    --property hw:cpu_policy=dedicated \
    --property hw:cpu_sockets=2 \
    --property hw:mem_page_size=1GB \
    --property hw:numa_nodes=8 \
    --property hw:pci_numa_affinity_policy=preferred \
    --property hw_rng:allowed=True \
    --property trait:CUSTOM_TECHWATCH_PROTO=required \
    techwatch-proto-worker
```

```
devbox$ openstack --os-cloud techwatch-admin flavor set \
    --project $PROJ techwatch-proto-worker
```

Then leave the admin identity — `tw_member`, or exit the subshell.

### Two flags that are easy to get wrong

🛑 **`--private` on its own does not restrict the flavor to you — it hides it from everyone including you.** A private flavor is created with an *empty* access list. The `flavor set --project` is what grants your project access, and without it the flavor exists, is invisible to your member credential, and [§4.2](../04-head-node-instance.md) fails with `No flavor with a name or ID of 'techwatch-proto-head' exists` while an admin shell can see it perfectly. Do not skip the second command in each pair.

**`--private` is not optional either.** Without it the flavor is public: every project on the cloud sees it in `openstack flavor list`, and any of them can boot from it — including onto the hypervisor the trait is meant to reserve.

### Naming

The `techwatch-proto-` prefix is not decoration. Flavor **names are cloud-wide**, so an unprefixed `head` or `worker` collides with someone else's, and — more likely — makes the flavor look like a cloud-wide offering to whoever is cleaning up in six months. Prefix with the project name, always.

---

## 2. Verify

The verification that matters is done **as the member**, unelevated, because that is the identity §4 and §7 will actually boot with:

```
devbox$ openstack flavor list | grep techwatch-proto
devbox$ openstack flavor show techwatch-proto-head -c properties -f value 2>/dev/null \
          | tr ',' '\n' | grep trait:
```

The second must print `trait:CUSTOM_TECHWATCH_PROTO='required'`. If it prints nothing, either the property is missing or `properties` is empty because policy hides extra specs from your credential — [§4.2](../04-head-node-instance.md) covers the difference and what to do about each.

### Expect one 403, and do not chase it

`flavor show -f yaml` from a member credential emits a 403 *and then prints the flavor anyway*. Confirmed on Digital Labs, 2 Aug 2026:

```
Failed to get access projects list for flavor 'techwatch-proto-head': ForbiddenException: 403:
Client Error for url: .../flavors/c2fe5d11-.../os-flavor-access,
Policy doesn't allow os_compute_api:os-flavor-access to be performed.
...
access_project_ids: null
os-flavor-access:is_public: false
```

`os-flavor-access` is the admin-only sub-API listing *which projects* may use a private flavor, so a member can never read it, and `access_project_ids` comes back `null` as a result — **`null` here means "not permitted to look", not "nobody has access"**.

The output is more useful than it looks. Both facts are confirmations:

- the flavor **printed at all** from an unelevated shell, so the `flavor set --project` grant landed. A private flavor with no grant is a `404`, not a 403-plus-body;
- the 403 itself proves the shell is holding the member credential and not your admin account.

### Then record them

```
devbox$ sed -i "s|^export TW_FLAVOR_HEAD=.*|export TW_FLAVOR_HEAD='techwatch-proto-head'|;
                s|^export TW_FLAVOR_CP=.*|export TW_FLAVOR_CP='techwatch-proto-cp'|;
                s|^export TW_FLAVOR_WORKER=.*|export TW_FLAVOR_WORKER='techwatch-proto-worker'|" \
                ~/tw/tw-vars-env.sh
devbox$ source ~/tw/tw-env.sh && tw_flavors
```

`tw_flavors` re-runs the trait check across all three ([`templates/tw-helpers-env.sh`](../templates/tw-helpers-env.sh)).

The genuinely conclusive test is the first `server create` in §4.4 landing on the right hypervisor — everything above only proves the flavor is *shaped* correctly.

---

## 3. Change one

**`--vcpus`, `--ram` and `--disk` cannot be changed.** Nova has no flavor-resize API; those three are fixed at creation. To change a size, create a new flavor under a new name and delete the old one:

```
devbox$ openstack --os-cloud techwatch-admin flavor create … techwatch-proto-worker-v2
devbox$ openstack --os-cloud techwatch-admin flavor set --project $PROJ techwatch-proto-worker-v2
devbox$ openstack --os-cloud techwatch-admin flavor delete techwatch-proto-worker
```

Properties *can* be changed, with `flavor set` to add or overwrite one and `flavor unset` to remove one:

```
devbox$ openstack --os-cloud techwatch-admin flavor set \
    --property hw:numa_nodes=8 techwatch-proto-worker

devbox$ openstack --os-cloud techwatch-admin flavor unset \
    --property hw:cpu_sockets techwatch-proto-worker
```

`flavor set --property` overwrites the value if the key is already present and adds it if not — there is no separate "update". It touches only the keys you name; the other six are left alone. **It prints nothing on success**, so verify rather than assume:

```
devbox$ openstack flavor show techwatch-proto-worker -c properties -f value 2>/dev/null \
          | tr ',' '\n' | grep numa
 'hw:numa_nodes': '8'
```

The `2>/dev/null` suppresses the [expected 403](#expect-one-403-and-do-not-chase-it), which goes to stderr and so survives any pipe you put after it.

That first command is the real one from Digital Labs, 2 Aug 2026 — the worker had been created with `hw:numa_nodes=2`, copied from the smaller flavors, which asked for 32 GB of 1 GB hugepages from a single host cell against the 8 GB the reference flavor proves the host serves. Caught before the first boot, so it cost one command; caught afterwards it would have been a `No valid host was found` that looks exactly like a quota problem.

⚠ **A mistyped password fails as `HTTP 401`, not as a password prompt.** Elevated commands prompt every time, and a typo surfaces as `The request you have made requires authentication. (HTTP 401)`. Just run it again. If it fails repeatedly with a password you are sure of, check the VPN before the credential — see [manage-application-credentials](manage-application-credentials.md#5-errors-seen-in-practice).

⚠ **Neither affects an instance that already exists.** Nova embeds a copy of the flavor into the instance at boot, so a running instance keeps the properties it was created with. Changing a flavor changes what *the next* `server create` gets — which makes "I fixed the flavor, why is the instance still wrong?" a normal and confusing hour. Rebuild the instance, or accept the divergence knowingly.

Corollary worth stating: an instance booted from a traited flavor cannot have landed on an untraited host, because Placement would have refused to schedule it. That inference survives the flavor being edited afterwards, since the trait requirement was evaluated at boot.

---

## 4. Delete

Flavors are cheap and outlive the cluster, so there is no need to remove them between runs — §18 leaves them in place deliberately. Delete them when the project genuinely ends:

```
devbox$ openstack --os-cloud techwatch-admin flavor delete techwatch-proto-head
devbox$ openstack --os-cloud techwatch-admin flavor delete techwatch-proto-cp
devbox$ openstack --os-cloud techwatch-admin flavor delete techwatch-proto-worker
```

🛑 **Delete only flavors you created.** The namespace is cloud-wide and `flavor delete` does not ask twice. In particular leave `techwatch-proto-test-flavor` alone — it is a colleague's, and it is also the reference the property block above is copied from.

Deleting a flavor that instances are running from **succeeds** and does not disturb them, because of the embedded copy. It does mean nobody can boot another one, and `server show` will report a flavor that no longer exists — harmless, but it reads like corruption to whoever finds it next.

---

## 5. Errors seen in practice

| Error | Cause | Fix |
|---|---|---|
| `Policy doesn't allow os_compute_api:os-flavor-manage:create to be performed` (403) | creating from a member credential. `--private --project` does not help — `--project` grants *access*, it does not grant *creation* | use `--os-cloud techwatch-admin`, or ask an admin |
| `Policy doesn't allow os_compute_api:os-flavor-access to be performed` (403), **but the flavor prints anyway** | not an error. Member credentials cannot read the access list | ignore it — and read it as [confirmation the grant worked](#2-verify) |
| `No flavor with a name or ID of '…' exists` from an unelevated shell, while admin sees it | `--private` with no `flavor set --project` | run the grant; the access list was empty |
| `No valid host was found` | exclusive capacity exhausted (pinned cores or 1 GB pages); **or `hw:numa_nodes` too low, making the per-node hugepage demand too large to fit one host cell**; or the trait exists on no resource provider | check the [node-count table](#the-property-block) first — it is the cheapest of the three to rule out. 🛑 **never** by removing properties or adding `--availability-zone` |
| Instance lands on an unexpected hypervisor | booted from a flavor without the trait | `flavor show -c properties`. Delete the instance before creating anything else |
| Flavor edited, instance still behaves as before | Nova embedded the flavor at boot | rebuild the instance, or accept it knowingly |
| `The request you have made requires authentication. (HTTP 401)` right after the password prompt | mistyped password. The prompt appears on every elevated command, so this is common | run it again. If it repeats with a password you are sure of, `tw_reach` — a dropped VPN presents as an auth failure |
| `Flavor with name … already exists` | the name is cloud-wide, not project-scoped | pick a distinct, project-prefixed name — do not reuse someone else's |

---

## Related

- [§1.5 — pinning by placement trait, on HPC-tuned hypervisors](../01-safety-and-access.md) — why the trait, why a plain flavor will not schedule, the reference property block
- [§1.2 — the member/admin split](../01-safety-and-access.md) — `tw_admin`, the subshell form, and why not to hold admin in the tutorial shell
- [§4.2 — choosing a flavor, and dealing with the disk](../04-head-node-instance.md) — the pre-boot verification and the Cinder-volume fallback
- [Manage application credentials](manage-application-credentials.md) — the identity this all depends on
- [Nova: flavors](https://docs.openstack.org/nova/latest/user/flavors.html) and [flavor extra specs](https://docs.openstack.org/nova/latest/configuration/extra-specs.html)
