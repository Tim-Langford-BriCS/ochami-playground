# 008 — metrics-server cannot verify the kubelet's TLS certificate

| | |
|---|---|
| **Status** | **Worked around.** The quick fix is applied and the cluster works. The correct fix is fully specified below and is **deliberately deferred to the end of the tutorial** — see [Debt](#the-debt-come-back-to-this). |
| **Hit at** | §11.3, immediately after `kubectl apply -f .../metrics-server/.../components.yaml` |
| **Observed** | 2026-08-13, `nid0001`–`nid0003`, Talos v1.13.0, Kubernetes v1.36.0, metrics-server from the `latest` release tag, Digital Labs |
| **Severity** | Blocking for §11.3 and for anything that autoscales. `kubectl top` returns nothing and every HorizontalPodAutoscaler stays at `<unknown>` |
| **Expected** | Yes — §11.3 warns about this before you hit it. It is here because the *correct* fix has a second half the tutorial did not spell out |

## TL;DR

metrics-server scrapes each node's kubelet over HTTPS and checks the certificate. Talos's kubelet serves a **self-signed** certificate that names nothing, so the check fails on every node and metrics-server never becomes ready.

Two fixes, and you must pick one:

- **Quick** — tell metrics-server to skip verification: add `--kubelet-insecure-tls`. One command, works immediately, weakens a trust boundary.
- **Correct** — make the kubelet get a real certificate from the cluster CA. This is **two** changes, not one: turn on `rotate-server-certificates` *and* deploy something to approve the resulting certificate requests. Turning on rotation alone leaves you exactly as broken as before, only with a queue of pending requests.

We took the quick fix.

## The symptom

The deployment installs cleanly and then never becomes available:

```
head$ kubectl -n kube-system get deploy metrics-server
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
metrics-server   0/1     1            0           8m46s
```

`READY 0/1` with `UP-TO-DATE 1` means the pod exists and is running — it is failing its *readiness* probe, not crashing. The logs say why:

```
head$ kubectl -n kube-system logs deploy/metrics-server --tail=20
E0813 18:34:34.728939  1 scraper.go:149] "Failed to scrape node" err="Get \"https://172.16.0.1:10250/metrics/resource\":
    tls: failed to verify certificate: x509: cannot validate certificate for 172.16.0.1
    because it doesn't contain any IP SANs" node="nid0001"
I0813 18:34:39.274720  1 server.go:192] "Failed probe" probe="metric-storage-ready" err="no metrics to serve"
```

All three nodes, every 15 seconds, indefinitely.

📌 **Read the two log lines as a pair.** The `E` line is the cause: a scrape failed. The `I` line is the consequence: with no successful scrapes, there are no metrics, so the readiness probe fails and Kubernetes never routes to the pod. Only the first line tells you anything. This shape — a loud consequence repeating over a quieter cause — is worth recognising generally.

## What the error actually means

Three separate facts have to line up here, and it helps to name them separately.

**1. The kubelet is an HTTPS server.** Every node runs a kubelet listening on port `10250`. That endpoint serves the node's own metrics (and is what `kubectl exec` and `kubectl logs` go through). Like any HTTPS server it presents a certificate.

**2. metrics-server verifies that certificate properly.** It is a client making a TLS connection, and it applies the normal rules: the certificate must be signed by a CA it trusts, *and* it must actually name the server being connected to. Since it connects by IP address, the name has to appear as an **IP SAN** — a "Subject Alternative Name" entry of type IP.

**3. Talos's kubelet, by default, signs its own certificate and names nothing in it.**

That third point is what the error string is telling you, and it is worth reading precisely:

> `cannot validate certificate for 172.16.0.1 because it doesn't contain any IP SANs`

Not *"the SAN doesn't match"*. Not *"unknown authority"*. **There are no SANs at all.** The certificate makes no claim about which machine it belongs to.

⚠ **This is why "just trust the CA" is not a fix.** The instinct on an `x509` error is to add a CA bundle so the signature checks out. It would not help. Even with the signer fully trusted, a certificate that names no host cannot be matched to `172.16.0.1`, and Go's TLS stack rejects it on that ground alone. The certificate has to be *reissued* with the node's identity in it — which is what the correct fix below does.

## Why the default is like this

It is not a Talos bug, and it is not an oversight. It is upstream Kubernetes behaving cautiously.

A kubelet can obtain its serving certificate two ways:

| | How | Result |
|---|---|---|
| **Self-signed** (default) | The kubelet generates its own certificate at startup | Works instantly, needs no cluster co-operation, and is trusted by nobody |
| **CA-signed** | The kubelet submits a **CSR** — a Certificate Signing Request — to the Kubernetes API and waits for it to be signed | Trusted cluster-wide, but somebody has to approve it |

The second path is enabled by the kubelet flag `rotate-server-certificates` (it appears in some documentation as the config-file field `serverTLSBootstrap` — same thing).

Now the important part. Kubernetes has a built-in approver inside `kube-controller-manager`, and **it deliberately refuses to approve kubelet *serving* certificates.** It will auto-approve a node's *client* certificate — the one a node uses to prove who it is when talking to the API server — because the node's identity is already established by its bootstrap token.

A serving certificate is a different risk. In it, the node asserts *"I am `nid0002`, and I am reachable at `172.16.0.2`."* Nothing in the request proves that. A compromised or misconfigured node could request a certificate naming a different node's IP and then impersonate it. Upstream's position is that only the cluster operator knows whether such a claim is legitimate, so approval is left to an external controller you choose and configure.

🛑 **So `rotate-server-certificates: true` on its own does not fix anything.** It changes the failure from *"the kubelet serves a useless certificate"* to *"the kubelet serves no certificate and is waiting for one that will never be approved."* Both look identical from metrics-server. You need the flag **and** an approver.

## The diagnostic that tells you where you are

One command distinguishes all three states, and it is the first thing to run:

```
head$ kubectl get csr
```

| Output | What it means | What to do |
|---|---|---|
| `No resources found` | The kubelet is not requesting a certificate at all — rotation is **off**, or the machine-config patch never landed | Verify the patch applied, or take the quick fix |
| Entries `Pending` for `system:node:nid000x` | Rotation is **on**, nothing is approving | Deploy an approver |
| Entries `Approved,Issued` | Both halves are in place | Remove `--kubelet-insecure-tls` and expect it to work |

On this cluster it said `No resources found`, which was informative in a way we did not expect — see the next section.

## ⚠ How we learned the patch had silently not applied

The tutorial's "correct path" command was run twice and failed both times:

```
head$ talosctl patch machineconfig -n 172.16.0.1,172.16.0.2,172.16.0.3 \
        --patch @~/talos/kubelet-certs-patch.yaml
open ~/talos/kubelet-certs-patch.yaml: no such file or directory
```

The file was definitely there — `cat ~/talos/kubelet-certs-patch.yaml` printed it. The cause is pure shell: **the shell expands `~` only at the beginning of a word.** Inside `@~/talos/…` the tilde is just an ordinary character, so `talosctl` was handed a path containing a literal `~` and dutifully failed to open it.

The fix is to put the tilde at the front of its own argument:

```
head$ talosctl patch machineconfig -n 172.16.0.1,172.16.0.2,172.16.0.3 \
        --patch-file ~/talos/kubelet-certs-patch.yaml
```

(`--patch @"$HOME"/talos/…` also works. §11.2's `extraMounts` step already used `--patch-file`, which is why it was never hit there.)

📌 **The lesson is not about tildes.** It is that `kubectl get csr` returning `No resources found` — rather than the `Pending` we predicted — was the evidence that a change we believed had been made had not been made. A command that fails loudly is easy. A configuration change that never happened is only visible if you check its *effect* somewhere else. That is the same lesson as [007](007-local-path-var-mnt-read-only-kubelet.md), reached from the opposite direction.

## Fix A — the quick one (what we did)

Tell metrics-server not to verify the certificate:

```
head$ kubectl -n kube-system patch deploy metrics-server --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
deployment.apps/metrics-server patched

head$ kubectl -n kube-system rollout status deploy/metrics-server
Waiting for deployment "metrics-server" rollout to finish: 1 old replicas are pending termination...
deployment "metrics-server" successfully rolled out

head$ kubectl top nodes
NAME      CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
nid0001   104m         2%       1536Mi          9%
nid0002   149m         1%       581Mi           0%
nid0003   61m          0%       555Mi           0%
```

**What you are giving up.** The connection is still encrypted; what stops is *authentication of the server*. metrics-server will now believe whatever answers on port `10250` at a node's IP. An attacker able to intercept that traffic on the cluster network could feed it false metrics — which matters mainly because HPAs act on those numbers, so fabricated load could drive scaling decisions.

On this substrate that is a small risk: a flat private `172.16.0.0/24` wire with three nodes we control and no other tenants. On the PTR it is not a judgement to inherit by accident.

⚠ **Give it a minute.** `kubectl top nodes` can report `metrics not available` for up to 60 seconds after the rollout completes — metrics-server needs a couple of scrape intervals before it has anything to serve. That is not a failure.

## Fix B — the correct one (deferred)

Two changes, in this order.

**Step 1 — turn on certificate rotation on every node.**

```
head$ cat > ~/talos/kubelet-certs-patch.yaml << 'EOF'
machine:
  kubelet:
    extraArgs:
      rotate-server-certificates: "true"
EOF
head$ talosctl patch machineconfig -n 172.16.0.1,172.16.0.2,172.16.0.3 \
        --patch-file ~/talos/kubelet-certs-patch.yaml
```

Expect `Applied configuration without a reboot` per node — a kubelet argument change restarts the kubelet, it does not restart the machine. *(Inferred from §11.2's `extraMounts` patch, which behaved that way. Not yet observed for this patch.)*

Confirm the kubelets have started asking:

```
head$ kubectl get csr
NAME        AGE   SIGNERNAME                      REQUESTOR              CONDITION
csr-abc12   10s   kubernetes.io/kubelet-serving   system:node:nid0001    Pending
csr-def34   10s   kubernetes.io/kubelet-serving   system:node:nid0002    Pending
csr-gh567   10s   kubernetes.io/kubelet-serving   system:node:nid0003    Pending
```

**`Pending` is the expected intermediate state, not the finished state.** Nothing will approve these on its own, however long you wait.

**Step 2 — deploy an approver.**

A small controller that watches for `kubernetes.io/kubelet-serving` CSRs and approves the ones that pass its rules. The two in common use are [`alex1989hu/kubelet-serving-cert-approver`](https://github.com/alex1989hu/kubelet-serving-cert-approver) and [`postfinance/kubelet-csr-approver`](https://github.com/postfinance/kubelet-csr-approver); Talos's own documentation for metrics-server points at this class of add-on. Pick one, read what it validates before trusting it, and install it into `kube-system`.

The check that it worked:

```
head$ kubectl get csr
⟨CONDITION should move from Pending to Approved,Issued within seconds⟩
```

**Step 3 — remove the workaround and prove the proper path.**

```
head$ kubectl -n kube-system patch deploy metrics-server --type=json -p \
  '[{"op":"remove","path":"/spec/template/spec/containers/0/args/6"}]'
head$ kubectl -n kube-system rollout status deploy/metrics-server
head$ kubectl top nodes
```

⚠ **Check the index before removing.** A JSON-patch `remove` on an array takes a position, not a value, and `--kubelet-insecure-tls` was appended to the end. Read the current list first — `kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}'` — and delete the right one. Getting this wrong removes a different flag and the error you get back will not mention certificates at all.

The final assertion is `kubectl top nodes` returning numbers **with no insecure flag present**. Until you have seen that, the correct path is not proven — only attempted.

## What does not work

| Idea | Why not |
|---|---|
| Give metrics-server the cluster CA bundle so it trusts the signer | The certificate contains no SANs. Trusting the signer does not make an unnamed certificate match an IP address |
| Enable `rotate-server-certificates` and stop there | Leaves CSRs `Pending` forever. Same failure, new mechanism |
| Approve the CSRs by hand with `kubectl certificate approve` | Works, and lasts until they rotate. They rotate. This is a cron job you will forget |
| Scrape by hostname instead of IP to dodge the SAN check | The certificate has *no* SANs of any type, so a DNS name matches no better than an IP |

## Checkpoint

```
head$ kubectl -n kube-system get deploy metrics-server
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
metrics-server   1/1     1            1           ⟨…⟩

head$ kubectl top nodes
⟨three nodes, with numbers⟩
```

`READY 1/1` proves scrapes are succeeding — the readiness probe is driven by having metrics, so it cannot pass on a broken scrape path. `kubectl top nodes` proves the metrics API is registered and serving through the aggregation layer. Both matter: the first is metrics-server's own health, the second is the cluster being able to reach it.

## Common failures

| Symptom | Cause |
|---|---|
| `doesn't contain any IP SANs` | This issue. Apply Fix A or complete Fix B |
| `x509: certificate signed by unknown authority` | A *different* problem — rotation is on and certificates are being issued, but by a CA metrics-server does not trust |
| `kubectl get csr` → `No resources found` after patching | The patch did not apply. Check for the `~` expansion trap above |
| CSRs stuck `Pending` | No approver installed. Fix B step 2 |
| `metrics not available` right after a successful rollout | Not a failure — wait 60 seconds |
| `kubectl top nodes` works but an HPA shows `<unknown>` | Pod metrics, not node metrics. Different path, look at the HPA's target |

## The debt: come back to this

**Do this after §15, before the cluster is treated as a template for the PTR.**

The reason to defer rather than fix now is straightforward: Fix B needs a third-party add-on chosen and reviewed, and §§11.4–15 do not depend on it. The reason not to defer *indefinitely* is that this is a security posture that survives by being invisible — `kubectl top` works, nothing warns, and the flag is one line inside a deployment nobody rereads.

📌 **The trap to avoid: shipping the workaround as if it were the design.** §11.3 and this issue both record it as temporary. If the PTR build is derived from this cluster, `--kubelet-insecure-tls` will come with it silently unless somebody goes looking. Grep for it as part of hardening:

```
head$ kubectl -n kube-system get deploy metrics-server \
        -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep insecure
```

Anything returned is unfinished work.

## Where it is referenced

| Place | What it says |
|---|---|
| [§11.3](../11-cluster-foundations.md) | Both fixes, the `--patch-file` gotcha, and the `kubectl get csr` check before assuming rotation worked |
| [§11](../11-cluster-foundations.md) *Common failures* | The `x509` signature, and the tilde-expansion failure |
