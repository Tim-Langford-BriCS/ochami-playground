# 004 — Talos cluster discovery reaches `discovery.talos.dev` on the public internet

| | |
|---|---|
| **Status** | **Open — noted, not analysed.** Nothing is broken and nothing on the tutorial's path depends on it. Parked deliberately; the analysis below is what was cheap to establish on the day, not a finished investigation. |
| **Hit at** | §10's checkpoint — `talosctl get members` worked when it had no business working |
| **Observed** | 2026-08-10, `tw-cp1`/`w1`/`w2`, Talos v1.13.0, Kubernetes v1.36.0, Digital Labs |
| **Severity** | Low here. Would matter on an air-gapped or egress-restricted deployment, where it shows as an empty list on a healthy cluster |

## What was seen

`talosctl -n 172.16.0.1 get members` returned all three nodes — on a provisioning wire with no route off it, where the head node holds the only floating IP:

```
head$ talosctl -n ${TW_CP_IP} get members
NODE         NAMESPACE   TYPE     ID        VERSION   HOSTNAME   MACHINE TYPE   OS                ADDRESSES
172.16.0.1   cluster     Member   nid0001   1         nid0001    controlplane   Talos (v1.13.0)   ["172.16.0.1"]
172.16.0.1   cluster     Member   nid0002   1         nid0002    worker         Talos (v1.13.0)   ["172.16.0.2"]
172.16.0.1   cluster     Member   nid0003   1         nid0003    worker         Talos (v1.13.0)   ["172.16.0.3"]
```

The prediction had been that it would be empty. It isn't, and the reason is in the generated machine config:

```
head$ grep -A8 '  discovery:' ~/talos/controlplane.yaml
    discovery:
        enabled: true
        registries:
            kubernetes:
                disabled: true
            service: {}
```

An empty `service: {}` means the **default** endpoint, `https://discovery.talos.dev` — a service Sidero Labs runs. The nodes reach it through §5.12's NAT on the head, the same path they use to pull `ghcr.io/siderolabs/installer`. So this tutorial has an outbound-internet dependency for the compute nodes that §§8–10 never declared.

## Why it is not urgent

**Not a disclosure problem.** Talos encrypts the payload on the node before it leaves — affiliate data with AES-GCM, endpoints separately — under a key derived from the cluster secret. [Sidero's documentation](https://docs.siderolabs.com/talos/v1.11/configure-your-talos-cluster/system-configuration/discovery) states the service cannot decrypt what it stores; only nodes of the same cluster can. What the operator can see is metadata: an opaque cluster ID, a member count, check-in times.

**Nothing on our path needs it.** Kubelets register with the API server directly, so `kubectl get nodes` is unaffected. `talosctl health` has the `--server=false` form given in §10.4. What discovery feeds is `get members` and, per upstream, **KubeSpan** (not used — the wire is already flat L2) and **KubePrism**, the per-node API-server load balancer on `localhost:7445`.

## ⚠ The one trap worth recognising now

**Do not "fix" this by inverting the two registry lines.** Turning the in-cluster `kubernetes` registry on and the external `service` registry off is the obvious move and it is dead: upstream deprecated that registry, and it is **incompatible with Kubernetes 1.32 and later in the default configuration**. This cluster runs **v1.36.0**. The change would appear to apply and then quietly not work.

**`cluster.discovery.enabled: false` is also not free.** KubePrism has been enabled by default since Talos 1.6, and Talos points kubelet, `kube-scheduler` and `kube-controller-manager` at it. Upstream says it "does not function correctly" without discovery. Upstream also warns that bootstrap and recovery get slower and failures harder to diagnose.

So the air-gapped answer is neither of the two one-line changes; it is **self-hosting** the service — `cluster.discovery.registries.service.endpoint`, image [`siderolabs/discovery-service`](https://github.com/siderolabs/discovery-service) — which is a service to run on the head and a certificate to issue for it.

## Left alone for the POC

Changing it means regenerating machine configs, and §8.6 records that the install patches apply once — so a config change here means recreating the cluster, for no gain on a substrate that has egress anyway.

## What deeper analysis would need to answer

1. **Do PTR compute nodes get outbound internet?** This is the same question §8's `ghcr.io` pulls and [DL-006](../DECISION-LOG.md#dl-006--installed-nodes-have-no-serial-console)'s Image Factory route both need. Worth asking StackHPC once, not three times.
2. **What actually degrades without discovery?** Upstream's "does not function correctly" for KubePrism is not specific. Measurable by disabling discovery on a throwaway cluster and watching `kube-scheduler`'s connection to `localhost:7445`.
3. **Is self-hosting worth it, or is disabling honest?** If the PTR cluster is single-control-plane and flat, KubePrism may be buying nothing worth a service and a certificate.
4. **Should the tutorial declare node egress up front?** §§8–10 assume it three times over — installer pull, image pull, discovery — and say so nowhere. That is arguably the real defect here.

## Where it is referenced

| Place | What it says |
|---|---|
| [§10](../10-boot-the-cluster.md) checkpoint | one note: an air-gapped cluster shows an empty member list while being perfectly healthy, so trust `kubectl get nodes` |
| [§10.4](../10-boot-the-cluster.md) | distinguishes the two failure modes of `talosctl health` — `:6443 connection refused` is the API server still starting, not this |
