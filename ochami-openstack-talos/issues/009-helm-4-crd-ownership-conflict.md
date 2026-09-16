# 009 — Helm 4 will not overwrite CRDs that `kubectl` already owns

| | |
|---|---|
| **Status** | **Fixed.** `helm install --force-conflicts`, and §11.4 now pins the Helm version explicitly |
| **Hit at** | §11.4, `helm install envoy-gateway` — the last command in the section |
| **Observed** | 2026-08-13, `tw-head`, Helm **v4.2.3**, Gateway API v1.2.1 (standard channel), Envoy Gateway chart v1.2.4, Kubernetes v1.36.0, Digital Labs |
| **Severity** | Blocking for §11.4. It fails *after* pulling the chart, which makes it look like a chart problem |
| **Root cause** | §11.4 installed the **latest** Helm in a section that pins everything else. Helm 4 enforces field ownership where Helm 3 quietly did not |

## TL;DR

`kubectl apply` claimed ownership of the Gateway API CRDs. Helm 4 uses server-side apply, where ownership is enforced, so it refuses to overwrite them. The two fields it names are the two that genuinely differ: we installed the **standard** channel, the chart bundles the **experimental** one — same version, `v1.2.1`, wider API surface.

```
head$ helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
        --version v1.2.4 -n envoy-gateway-system --create-namespace \
        --force-conflicts
```

**Stay on Helm 4.** The conflict is a feature doing its job, the fix is one documented flag, and the alternative — pinning Helm 3 — means starting a new build on a superseded major version to avoid an error that was telling us something true.

## The symptom

The chart pulls, then fails:

```
head$ helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
        --version v1.2.4 -n envoy-gateway-system --create-namespace
Pulled: docker.io/envoyproxy/gateway-helm:v1.2.4
Digest: sha256:054d203120c8e1c610c3fde5e37679db6904ef9956bacff477171a1ea6df6eab
Error: INSTALLATION FAILED: failed to install CRD crds/gatewayapi-crds.yaml:
  conflict occurred while applying object /gatewayclasses.gateway.networking.k8s.io
  apiextensions.k8s.io/v1, Kind=CustomResourceDefinition: Apply failed with 2 conflicts:
  conflicts with "kubectl-client-side-apply" using apiextensions.k8s.io/v1:
  - .metadata.annotations.gateway.networking.k8s.io/channel
  - .spec.versions
⟨repeats for gateways, grpcroutes, httproutes, referencegrants⟩
```

📌 **Two things in that error are the whole story, and both are easy to skim past.**

1. `conflicts with "kubectl-client-side-apply"` — that is not a description, it is a **name**. Kubernetes is telling you precisely which other client is holding the fields.
2. The bullet list is not boilerplate. `.metadata.annotations.gateway.networking.k8s.io/channel` is a *content* difference, and it is the actual point of disagreement.

We read past the second one on the day and spent a round trip assuming a version mismatch. There wasn't one.

## Why it happens

Kubernetes records, for every object, **which field is owned by which client**. Each writer identifies itself with a **field manager** name, visible on any object:

```
head$ kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.managedFields[*].manager}'; echo
kubectl-client-side-apply
```

Two clients wrote these CRDs, in two different ways:

| | Who | How it writes | Manager name |
|---|---|---|---|
| §11.4, earlier | `kubectl apply -f standard-install.yaml` | **client-side apply** — kubectl computes the merge locally and PUTs the result | `kubectl-client-side-apply` |
| §11.4, now | `helm install` under Helm 4 | **server-side apply** — the client declares intent and the *server* merges, tracking ownership | `helm` |

Server-side apply is the one that enforces ownership. When Helm declares `.spec.versions`, the API server sees the field belongs to another manager **and that the value being set is different**, so it refuses rather than silently taking it.

⚠ **Identical values would not have conflicted.** SSA only raises a conflict when a second manager tries to set a field to a *different* value; matching values simply produce shared ownership. That is why the error names exactly two fields rather than the whole object — those are the only two where the standard and experimental channels disagree.

## What actually differs: channel, not version

The Envoy Gateway chart carries its own copy of the Gateway API CRDs. At `v1.2.4` that copy is annotated:

```
gateway.networking.k8s.io/bundle-version: v1.2.1
gateway.networking.k8s.io/channel: experimental
```

§11.4 installed `standard-install.yaml` — **same `v1.2.1`, standard channel**. Gateway API publishes two channels from one release:

| Channel | Contains |
|---|---|
| **standard** | The GA resources: `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant` |
| **experimental** | All of the above **plus** `TCPRoute`, `TLSRoute`, `BackendTLSPolicy`, `BackendLBPolicy`, and additional fields on the shared types |

Experimental is a **superset** of standard at the same version. So `--force-conflicts` does not downgrade, upgrade or drift the pin — it widens the installed API surface at `v1.2.1`, which is what Envoy Gateway expects. KServe 0.18 needs v1.2.1 and is indifferent to the channel.

🛑 **This is why "delete the CRDs and let Helm install them" would have been the wrong instinct even though it works.** It happens to produce the same result here *only because* the chart's bundle-version matches our pin. Had the chart bundled v1.3.x, deleting would have silently discarded the version KServe requires, and the failure would have surfaced in §13 as webhook errors with no visible connection to this step. The verification below is what separates the two cases.

## The fix

```
head$ helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
        --version v1.2.4 -n envoy-gateway-system --create-namespace \
        --force-conflicts
head$ kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=5m
```

`--force-conflicts` is documented on `helm install`: *"if set server-side apply will force changes against conflicts."* It makes Helm the field manager for the contested fields and sets them to the chart's values. `--server-side` already defaults to `true` for installs, so it does not need passing.

Observed result:

```
NAME: envoy-gateway
LAST DEPLOYED: Thu Aug 13 19:20:28 2026
NAMESPACE: envoy-gateway-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
```

**Then verify — this is not optional:**

```
head$ kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"  "}{.metadata.annotations.gateway\.networking\.k8s\.io/channel}'; echo
v1.2.1  experimental
```

`channel: experimental` is expected — it flipped from `standard`, which is precisely the change `--force-conflicts` authorised. `bundle-version` **must** still read `v1.2.1`; anything else means the pin is gone.

🛑 **One annotation now lies, and it is the one you are most likely to read.** Dumping the full annotation map still shows:

```
"kubectl.kubernetes.io/last-applied-configuration":
  "{… \"gateway.networking.k8s.io/channel\":\"standard\" …}"
```

That is the snapshot `kubectl apply` wrote when it did client-side apply, and **nothing updates it now that Helm owns the object.** Server-side apply keeps its bookkeeping in `.metadata.managedFields`, not there. So the object's live channel is `experimental` while its `last-applied-configuration` insists on `standard`, indefinitely.

⚠ **`last-applied-configuration` records what someone once applied, not what the object is.** That was true before this issue too — it is just far easier to notice when the two disagree by a whole API channel. Read live fields; treat that annotation as history.

⚠ **A leftover release record can block the retry.** A failed install sometimes leaves one, and the retry then fails with `cannot re-use a name that is still in use` — an error unrelated to the original problem:

```
head$ helm list -n envoy-gateway-system --all
head$ helm uninstall envoy-gateway -n envoy-gateway-system    # only if something is listed
```

### If the flag is not honoured during the CRD phase

`--force-conflicts` is documented for `helm install`, but this failure came from the separate `crds/` installation step and we did not confirm the flag threads through to it. If it does not, make the values match instead — then there is no conflict to force:

```
head$ kubectl apply --server-side --force-conflicts \
        -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
```

then retry the install with no extra flags. This works because SSA is comparing values, not managers.

## What does not work

| Idea | Why not |
|---|---|
| Pin Helm 3 instead | Works — Helm 3 skips CRDs that already exist, so the question never arises. **Rejected**: it means starting a fresh build on a superseded major version to avoid a one-flag fix, and it hides a real disagreement rather than resolving it |
| `kubectl delete -f standard-install.yaml`, then let Helm install its copy | Produces the right answer here **by luck** — because the chart's bundle-version happens to match our pin. Discards the pin in general, and fails invisibly when it does not match |
| `--set crds.gatewayAPI.enabled=false` | No such value. `helm show values oci://docker.io/envoyproxy/gateway-helm --version v1.2.4 \| grep -B2 -A8 crds` returns nothing — this chart has no CRD toggle |
| `helm install --skip-crds` | Skips the whole `crds/` directory, which also holds Envoy Gateway's own CRDs (`EnvoyProxy`, `EnvoyPatchPolicy`, …). The controller then fails on missing types instead |
| `kubectl apply --server-side` on the standard channel first | Changes the manager from `kubectl-client-side-apply` to `kubectl`. The values still differ, so the conflict is identical with a different name in it |

## Is Helm 4 a problem for the rest of this tutorial?

Assessed deliberately, because the tempting move was to retreat to Helm 3:

| Change in Helm 4 | Impact here |
|---|---|
| SSA is the default for installs; ownership conflicts become errors | **This issue.** One flag, once |
| `--post-renderer` takes a plugin name, not an executable path | None — not used |
| `--wait` needs `watch` RBAC | None — we are cluster-admin, and use `kubectl rollout status` instead |
| Charts require changes | None. Existing charts carry over untouched |
| Upgrades keep whatever apply mode the install used | Worth knowing at §13, not a problem |
| [helm#31516](https://github.com/helm/helm/issues/31516) — newly created resources are stamped `operation: Update` rather than `Apply` | **The one live caveat.** Those resources conflict on the *next* upgrade and need `--force-conflicts` again. Irritating, not blocking |

**Conclusion: no blockers.** Stay on Helm 4, pinned.

## Checkpoint

```
head$ helm version --short
⟨v4.2.3+g43e8b7f⟩
head$ kubectl -n envoy-gateway-system get deploy envoy-gateway
⟨1/1⟩
head$ kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'; echo
v1.2.1
```

The third command is the one that proves the fix was *correct* rather than merely effective. The first two only show that something installed.

## Common failures

| Symptom | Cause |
|---|---|
| `conflict occurred while applying object … conflicts with "kubectl-client-side-apply"` | This issue. Add `--force-conflicts` |
| `Error: unknown shorthand flag: 'a'` on `helm list -a` | You are on Helm 4 and did not know it. `-a` was Helm 3 shorthand for `--all` |
| `cannot re-use a name that is still in use` on retry | A failed release record survived. `helm uninstall` it first |
| `bundle-version` is not `v1.2.1` after the fix | The pin is gone. Stop; §13 is now at risk |
| The channel still reads `standard` after a successful install | You are reading `last-applied-configuration`, which is stale by design. Read the live annotation |
| Conflicts return on a later `helm upgrade` | helm#31516. Pass `--force-conflicts` again |

## The lessons

⚠ **Pin the tools, not just the payloads.** §11.4 pinned Gateway API, cert-manager and Envoy Gateway, each with a reason — and then installed *whatever Helm was newest* to deploy them with. The unpinned component was the one installing the pinned ones. A package manager is not neutral plumbing: it decides how objects are written, who owns them afterwards, and what happens on disagreement.

⚠ **When a long-established flag stops existing, check the version before debugging anything else.** `helm list -a` had already failed with `unknown shorthand flag: 'a'` minutes earlier. That was the cheap diagnosis and it arrived first.

📌 **A conflict error is evidence, not an obstacle.** The instinct on hitting this was to find a way *past* the error — force it, delete something, downgrade the tool. The error was in fact reporting a real difference between two things we had both installed on purpose, and the two field names it printed said exactly what that difference was. The right first move on an ownership conflict is to ask *what do the two sides actually disagree about* — the answer changes which fix is correct.

## Where it is referenced

| Place | What it says |
|---|---|
| [§11.4](../11-cluster-foundations.md) | Pins the Helm version, requires `--force-conflicts`, explains the channel change, and asserts on `bundle-version` |
| [§11](../11-cluster-foundations.md) *Common failures* | The conflict error, and the `helm list -a` signal that precedes it |
