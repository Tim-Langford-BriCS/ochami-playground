# §11 — Cluster foundations

*(Time: ~20 minutes. On the head node, with `KUBECONFIG` and `TALOSCONFIG` set from §10. From here on we are doing Kubernetes, not OpenCHAMI — but §16 comes back to the hardware.)*

```
head$ echo "$TALOSCONFIG $KUBECONFIG" && kubectl get nodes
```

Both should be set already — §10.3's `~/tw-head-talos-env.sh` is sourced by `tw-head-env.sh` in every shell. If they are empty, you skipped that step; go back and write the file rather than exporting by hand, because §§12–17 all assume it.

## Concepts

A Talos cluster arrives with less than you might expect, and more than a from-scratch kubeadm cluster. **Included**: a CNI (flannel by default), CoreDNS, `kube-proxy`, and the control-plane components. **Not included**: any storage class, metrics, ingress, or CRDs. §§13–15 need three of those four, so we install them here.

Every choice in this section has a "what happens on the PTR" answer, because these are the components most likely to differ between a cloud POC and real hardware. They are called out as we go.

## Step 11.1 — Check what you already have

```
head$ kubectl get nodes -o wide
head$ kubectl get pods -A
head$ kubectl get storageclass
```

Expect: nodes `Ready`, `kube-system` healthy, and **no storage classes at all**:

```
head$ kubectl get storageclass
No resources found
```

That last one is not a fault — Talos deliberately ships no storage driver, because the right one depends entirely on where it is running. `kubectl get nodes -o wide` is worth reading properly while you are here, because it is the first place the whole stack is visible on one line: `Talos (v1.13.0)`, `6.18.24-talos (amd64)`, `containerd://2.2.3`, and `INTERNAL-IP` on the `172.16.0.x` provisioning wire with `EXTERNAL-IP` correctly `<none>`.

```
head$ kubectl cluster-info
head$ talosctl -n 172.16.0.1 get staticpods
```

## Step 11.2 — Storage

Nothing in §§13–15 strictly needs a PersistentVolume — vLLM can cache model weights in an `emptyDir`. But then every pod restart re-downloads several GB through the head's NAT, which gets tiresome quickly. A local storage class fixes that.

**Three options, and why we pick the middle one:**

| Option | Verdict |
|---|---|
| **Cinder CSI** — OpenStack's own driver; PVCs become real Cinder volumes | Tempting and genuinely good on a cloud. Rejected: it needs OpenStack credentials *inside* the cluster, and it does not exist on the PTR. We would be building on something that has to be ripped out |
| **local-path-provisioner** (Rancher) — PVCs become directories on the node | **What we use.** Trivial, no credentials, and behaves *identically* on PTR metal, where nodes have 3.84–7.68 TB of local NVMe. Not replicated, which is fine for a model cache |
| **Longhorn / OpenEBS replicated** | The eventual answer for anything needing durability. Overkill now, and Longhorn on Talos needs system extensions (`iscsi-tools`) — a §16 topic |

```
head$ kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
```

⚠ **Talos gotcha, part one — the default path is read-only.** local-path-provisioner defaults to `/opt/local-path-provisioner`, and on Talos almost the entire filesystem is immutable. Only `/var` is writable.

🛑 **Talos gotcha, part two — repointing at `/var` is not enough on its own.** The provisioner does not create directories itself; it launches a short-lived *helper pod* on the target node whose `data` volume is a `hostPath` with `type: DirectoryOrCreate`. The **kubelet** performs that `mkdir`, and on Talos the kubelet runs in its own mount namespace with only a curated set of paths from `/var` bind-mounted into it. A path it cannot write is a path it cannot create, so declare the directory as a kubelet mount *first* — on every node that will host a volume:

```
head$ cat > /tmp/lpp-mount.yaml << 'EOF'
machine:
  kubelet:
    extraMounts:
      - destination: /var/local-path-provisioner
        type: bind
        source: /var/local-path-provisioner
        options: [bind, rshared, rw]
EOF
head$ for n in 172.16.0.1 172.16.0.2 172.16.0.3; do talosctl -n $n patch machineconfig --patch-file /tmp/lpp-mount.yaml; done
patched MachineConfigs.config.talos.dev/v1alpha1 at the node 172.16.0.1
Applied configuration without a reboot
⟨… once per node⟩
```

`Applied configuration without a reboot` is what you want — this restarts the kubelet only. Talos creates the source directory for you; `talosctl -n 172.16.0.2 ls /var | grep local-path` confirms it. Give the nodes a few seconds to return to `Ready`.

Only now repoint the provisioner at that path:

```
head$ kubectl -n local-path-storage patch configmap local-path-config --type merge -p '
{"data":{"config.json":"{\"nodePathMap\":[{\"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\"paths\":[\"/var/local-path-provisioner\"]}]}"}}'
head$ kubectl -n local-path-storage rollout restart deploy/local-path-provisioner
```

📌 **Why `/var/local-path-provisioner` and not `/var/mnt/…`.** `/var/mnt` looks like the obvious home for storage and is writable when you inspect it with `talosctl` — but it is Talos's mount point for *declared user volumes*, and it is read-only inside the kubelet's namespace. The result is a fault that reports nothing: the helper pod sits in `ContainerCreating`, gets deleted 120 s later, and the PVC stays `Pending` for ever. [Issue 007](issues/007-local-path-var-mnt-read-only-kubelet.md) is the full account of chasing that one.

Make it the default so later manifests don't have to name it:

```
head$ kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

📌 **Two `PodSecurity` warnings are expected here, and they are warnings.** Applying the manifest and restarting the deployment both print `would violate PodSecurity "restricted:latest"` about `allowPrivilegeEscalation`, capabilities, `runAsNonRoot` and `seccompProfile`. Nothing is being blocked — that is the cluster-wide *warn* level reporting on a namespace with no enforcement label, and the deployment is created regardless. local-path-provisioner genuinely needs to write to the host filesystem, which is the whole point of it. On a cluster where you enforce `restricted` by namespace, this one wants an exemption.

✅ **Prove it end to end**, which needs a *consumer* — a PVC on its own proves nothing:

```
head$ kubectl apply -f - << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
head$ kubectl get pvc smoke
NAME    STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
smoke   Pending                                      local-path     13s
```

🛑 **`Pending` here is not a transient state — it is permanent, and it is correct.** local-path's `volumeBindingMode` is `WaitForFirstConsumer`, so nothing is provisioned until a pod actually mounts the claim. Waiting longer will not change it, and a `Pending` PVC therefore proves **nothing at all** about whether the two patches above worked. That is the failure this step exists to catch, so give it something to consume:

```
head$ kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: smoke
spec:
  containers:
  - name: c
    image: busybox
    command: ["sh","-c","echo ok > /d/f; sleep 600"]
    volumeMounts:
    - {name: v, mountPath: /d}
  volumes:
  - name: v
    persistentVolumeClaim: {claimName: smoke}
EOF
head$ kubectl get pvc smoke
NAME    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
smoke   Bound    pvc-e372aa11-dc71-440c-bc7f-2470026b82dd   1Gi        RWO            local-path     83s
head$ kubectl exec smoke -- cat /d/f
ok
```

`Bound` plus `ok` is the assertion worth making: the provisioner created a directory on a real node, and a container wrote a file into it and read it back. Confirm the third leg on the node the pod landed on — `kubectl get pod smoke -o wide` names it:

```
head$ talosctl -n 172.16.0.2 ls /var/local-path-provisioner
NODE         NAME
172.16.0.2   .
172.16.0.2   pvc-e372aa11-dc71-440c-bc7f-2470026b82dd_default_smoke
```

The other nodes show only `.`, which is correct — local-path is *local*, and the volume exists on exactly one node. That is the property to keep in mind when a pod that mounts it is later rescheduled.

If either patch had been missed, the pod would instead sit in `ContainerCreating`: a missed configmap patch gives a read-only filesystem error against `/opt` in the provisioner log, and a missed `extraMounts` gives `MountVolume.SetUp failed for volume "data" : mkdir …: read-only file system` — but only in the helper pod's events, which are deleted before you are likely to read them.

```
head$ kubectl delete pod smoke && kubectl delete pvc smoke
```

Deleting the pod first matters — a PVC with a live consumer will not delete, it will hang in `Terminating`.

## Step 11.3 — metrics-server

Needed for `kubectl top` and for any HorizontalPodAutoscaler, which KServe uses to scale an `InferenceService`:

```
head$ kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

⚠ **Talos gotcha — it will sit at `0/1` without one of two fixes.** metrics-server scrapes each kubelet over TLS and verifies the certificate. Talos's kubelet self-signs one that carries **no SANs at all**, so verification fails on every node:

```
head$ kubectl -n kube-system get deploy metrics-server
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
metrics-server   0/1     1            0           8m46s

head$ kubectl -n kube-system logs deploy/metrics-server --tail=20
E0813 18:34:34.728939  1 scraper.go:149] "Failed to scrape node" err="Get \"https://172.16.0.1:10250/metrics/resource\":
    tls: failed to verify certificate: x509: cannot validate certificate for 172.16.0.1
    because it doesn't contain any IP SANs" node="nid0001"
I0813 18:34:39.274720  1 server.go:192] "Failed probe" probe="metric-storage-ready" err="no metrics to serve"
```

Note it is **not** crashing — `0/1` with the pod running means the readiness probe is failing, because with no successful scrapes there are no metrics to serve. Either tell metrics-server not to verify (quick, fine for a POC) *or* give the kubelet a real certificate (correct, and what you want on the PTR). Full explanation of both in [issue 008](issues/008-kubelet-serving-certs-metrics-server.md).

Quick:

```
head$ kubectl -n kube-system patch deploy metrics-server --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
deployment.apps/metrics-server patched
head$ kubectl -n kube-system rollout status deploy/metrics-server
deployment "metrics-server" successfully rolled out
```

The connection stays encrypted; what stops is metrics-server checking *who* it is talking to. Acceptable on a flat private wire we own — **write it down as debt**, because nothing will warn you about it later.

Correct — patch the Talos machine config instead, so kubelet gets properly signed serving certs:

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

⚠ **Use `--patch-file`, not `--patch @~/...`.** The shell expands `~` only at the *start* of a word, so a tilde sitting inside `@~/talos/…` is passed through literally and talosctl reports `open ~/talos/kubelet-certs-patch.yaml: no such file or directory` — for a file that `cat` will happily print. `--patch-file` puts the tilde at the front of its own argument, where it expands. `@"$HOME"/talos/…` works too.

🛑 **Rotation alone does not finish the job.** Turning on `rotate-server-certificates` makes the kubelet *request* a serving certificate; something still has to approve the CSR, and Talos does not approve this class automatically. Check before assuming it worked:

```
head$ kubectl get csr
```

Read the result carefully — it tells you exactly where you are:

| Output | Meaning |
|---|---|
| `No resources found` | Rotation is **off** — the patch did not apply. Check the tilde trap above |
| `Pending`, signer `kubernetes.io/kubelet-serving` | Rotation is on, nothing is approving. **Still broken**, in a new way |
| `Approved,Issued` | Both halves in place — remove `--kubelet-insecure-tls` and retest |

Kubernetes deliberately refuses to auto-approve kubelet *serving* certificates, because the node is asserting an identity nothing has verified. Completing this path needs a `kubelet-serving-cert-approver` add-on — see [issue 008](issues/008-kubelet-serving-certs-metrics-server.md) and the Talos documentation.

**For this POC, take the quick path above.** Issue 008 records the debt and what to do about it after §15.

```
head$ kubectl top nodes
NAME      CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
nid0001   104m         2%       1536Mi          9%
nid0002   149m         1%       581Mi           0%
nid0003   61m          0%       555Mi           0%
```

⚠ **Allow 60 seconds.** `metrics not available` immediately after a successful rollout is normal — metrics-server needs a scrape interval or two before it has anything to serve. `kubectl -n kube-system get deploy metrics-server` showing `1/1` is the real signal, since its readiness probe only passes once scrapes succeed.

## Step 11.4 — Gateway API and cert-manager

Both are KServe prerequisites (§13), and both are worth understanding independently.

**Gateway API** is the successor to Ingress: a set of CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`) that separate "who runs the load balancer" from "who routes to my service". KServe uses it to expose model endpoints.

```
head$ kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

⚠ **Pin the version.** KServe documents Gateway API **v1.2.1** — the same pin from 0.15 through 0.20, so this is a stable target rather than a guess at a moving one. Newer Gateway API releases have moved fields between `v1beta1` and `v1`; taking `latest` here is a reliable way to get confusing webhook errors in §13.

**cert-manager** issues the webhook certificates KServe's admission controllers need:

```
head$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
head$ kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m
```

(KServe requires cert-manager ≥ 1.15.0; any later 1.x is fine.)

**A Gateway API implementation.** The CRDs above are just definitions — something has to actually run the proxy. Two realistic choices:

| | Envoy Gateway | Istio |
|---|---|---|
| Footprint | one controller, one Envoy per Gateway | a full service mesh unless you install only the gateway |
| KServe testing | supported; less exercised | the most-travelled path in KServe's own docs and CI |
| Worth it here? | **yes** — we want ingress, not a mesh | if you hit trouble, switch to Istio before debugging Envoy Gateway |

Envoy Gateway ships as a Helm chart, so **install `helm` first** — it is not on the head node, and Rocky's repositories do not carry it.

🛑 **Pin the Helm version too.** Everything else in this section is pinned and says why; Helm was the one thing left floating, and a `latest` URL crossed a major version boundary silently. We are on **Helm 4**, deliberately — but written down, not inherited. See [issue 009](issues/009-helm-4-crd-ownership-conflict.md) for what that costs and why it is still the right choice.

Download the release tarball, check it against the published checksum, and install the single binary it contains:

```
head$ HELM_VER=v4.2.3
head$ curl -fsSLO https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz
head$ curl -fsSLO https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum
head$ sha256sum -c helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum
helm-${HELM_VER}-linux-amd64.tar.gz: OK
head$ tar -xzf helm-${HELM_VER}-linux-amd64.tar.gz
head$ sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
head$ rm -rf linux-amd64 helm-${HELM_VER}-linux-amd64.tar.gz*
head$ helm version --short
v4.2.3+g43e8b7f
```

⚠ **Check the major version matches what this section assumes.** Helm 3 and Helm 4 write to the cluster in genuinely different ways, and the next step behaves differently under each. If `helm version --short` disagrees with `HELM_VER` above, you are reading instructions for a different tool.

🛑 **`sha256sum -c` must print `OK` before you continue.** That line is the entire reason to prefer this over the one-liner below — it is the only step that establishes the bytes you are about to run as root are the bytes upstream published. If it fails, stop; do not retry the download hoping for better luck.

📌 **On `curl … | bash`.** Helm publishes a one-line installer script. It works, and it does verify a checksum internally — but it executes a script fetched from `main` that you never see, it installs whatever is newest, and it is a habit worth not building on a node that holds cluster credentials. The eight lines above take a minute longer, pin the version, and leave you able to say what ran.

⚠ **Check your architecture.** The URLs above say `amd64`. If `uname -m` reports `aarch64`, substitute `arm64` throughout — a mismatched binary fails with `cannot execute binary file`, which does not obviously mean "wrong architecture".

Now the chart. The `--force-conflicts` flag is required and is **not** a workaround for something being wrong — see below:

```
head$ helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
        --version v1.2.4 -n envoy-gateway-system --create-namespace \
        --force-conflicts
head$ kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=5m
```

🛑 **Why the flag is needed, and what it changes.** The chart bundles its own copy of the Gateway API CRDs — the same **v1.2.1** you installed above, but from the **experimental** channel rather than standard. Helm 4 applies with server-side apply, and Kubernetes will not let it overwrite fields that `kubectl apply` already owns. Without the flag you get a wall of `conflict occurred while applying object` errors naming exactly the two fields that differ:

```
- .metadata.annotations.gateway.networking.k8s.io/channel
- .spec.versions
```

Read that as the diagnosis, not as noise: `channel` is the mismatch. `--force-conflicts` hands ownership to Helm and installs the experimental set. That is a **superset** of standard — same version, plus `TCPRoute`, `TLSRoute`, `BackendTLSPolicy`, `BackendLBPolicy` and some extra fields. Envoy Gateway wants them, KServe is unaffected, and the v1.2.1 pin survives intact.

Confirm both halves of that claim — ask for the two fields by name, not the whole annotation map:

```
head$ kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"  "}{.metadata.annotations.gateway\.networking\.k8s\.io/channel}'; echo
v1.2.1  experimental
```

⚠ **`bundle-version` is the assertion that matters.** `channel: experimental` is expected and harmless. A `bundle-version` other than `v1.2.1` means the pin KServe needs is gone, and you will find out in §13 through webhook errors that point nowhere near here.

🛑 **Do not read the channel out of `kubectl.kubernetes.io/last-applied-configuration`.** Dumping the whole annotation map returns several hundred lines, most of it that one annotation — a snapshot written by the original `kubectl apply`, which still says `"channel":"standard"`. It is a fossil of client-side apply and nothing updates it now that Helm owns the object. The live values are the two annotations above; that one is a record of what someone applied once, not of what the object is.

The experimental additions arriving is the other half of the proof:

```
head$ kubectl get crd | grep gateway.networking
⟨the five standard kinds, plus tcproutes, tlsroutes, backendtlspolicies and backendlbpolicies⟩
```

**Finally, declare a `GatewayClass`.** The chart installs the *controller*; it does not create a class, and until one exists the controller has nothing to act on:

```
head$ kubectl get gatewayclass
No resources found
```

A `GatewayClass` is the join between the two halves of Gateway API's split model: it names a `controllerName`, and whichever controller is watching for that exact string claims it. Read the name out of the deployed config rather than copying it from here — if it does not match, the class is simply ignored:

```
head$ kubectl -n envoy-gateway-system get cm envoy-gateway-config -o yaml | grep -i controllername
    controllerName: gateway.envoyproxy.io/gatewayclass-controller
head$ echo '{"apiVersion":"gateway.networking.k8s.io/v1","kind":"GatewayClass","metadata":{"name":"eg"},"spec":{"controllerName":"gateway.envoyproxy.io/gatewayclass-controller"}}' | kubectl apply -f -
gatewayclass.gateway.networking.k8s.io/eg created
head$ kubectl get gatewayclass
NAME   CONTROLLER                                      ACCEPTED   AGE
eg     gateway.envoyproxy.io/gatewayclass-controller   True       11s
```

⚠ **`ACCEPTED True` is the assertion, not the object existing.** A `GatewayClass` whose `controllerName` matches nothing is created quite happily and does nothing at all — no error, no event, just a class no controller has claimed. §13 then fails with KServe unable to provision a Gateway, several steps away from the cause.

🛑 **A `GatewayClass` does not serve traffic, and nothing is listening yet.** This is the point people trip on, so it is worth being explicit about the three-layer model:

| Layer | What it is | Who creates it |
|---|---|---|
| **Controller** | The Envoy Gateway deployment, watching for work | the Helm chart, §11.4 |
| **`GatewayClass`** | A named declaration — *"a controller answering to this name will handle Gateways of this class"* | you, just now |
| **`Gateway`** | A request for an actual proxy on actual ports. Creating one makes the controller provision an Envoy pod and a Service | **nobody yet** — KServe, in §13 |

After this step the cluster has a controller with nothing to do and a class nothing references. `kubectl get gateway -A` is empty, no Envoy proxy pod exists, and nothing is listening on port 80 anywhere. All of that is correct. The first `Gateway` arrives in §13.

📌 **Written as one line on purpose.** A YAML heredoc is more readable, but long multi-line pastes get truncated by some terminals — we lost one earlier in this build to `yaml: line 13: found unexpected end of stream`. Piping compact JSON into `kubectl apply -f -` survives a bad paste, because a mangled line fails to parse rather than silently applying half an object.

⚠ **Be honest in your run log about which gateway you used.** If Envoy Gateway gives trouble in §13, swapping to Istio is a legitimate and well-trodden move — `istioctl install --set profile=minimal` plus the Istio `GatewayClass`. Note it, because the IaC and the PTR build should follow whichever actually worked.

## Step 11.5 — Reaching the cluster from your laptop

Everything so far has been driven from the head node, because the provisioning wire has no external route. That gets old, and it means keeping two sets of tools in two places. Tunnel instead: one authenticated SSH connection gives the devbox `kubectl` against the cluster *and* keeps the OpenStack CLI where it already is, so one shell drives both.

The `8080` forward earns its keep later — in §13–15 it is how a model endpoint becomes reachable from a browser. Set it up now; it costs nothing until a `Gateway` exists.

**First, two things this step needs that earlier sections did not.**

⚠ **Load your environment.** `TW_HEAD_FIP` lives in `~/tw/tw-vars-env.sh` (§4.5 appended it) and does not survive a new shell. Without it every command below expands to `rocky@` and fails on a blank hostname:

```
devbox$ source ~/tw/tw-env.sh
TechWatch env loaded (OS_CLOUD=techwatch). Run 'tw_help'.
devbox$ echo $TW_HEAD_FIP        # must not be empty
```

📌 **Read the error before assuming the network is at fault.** An unset variable gives `ssh: Could not resolve hostname : Name or service not known` — note the empty name between `hostname` and `:`. That is a shell problem wearing a DNS problem's clothes.

**Second, install `kubectl` on the devbox.** Everything so far ran it on the head node; the devbox has never needed it. Pin it to the cluster's version — `kubectl` supports one minor version of skew either way, and matching removes the question entirely:

```
devbox$ ARCH=$(uname -m); [ "$ARCH" = x86_64 ] && ARCH=amd64 || ARCH=arm64; echo $ARCH
devbox$ curl -fsSLO https://dl.k8s.io/release/v1.36.0/bin/linux/${ARCH}/kubectl
devbox$ curl -fsSLO https://dl.k8s.io/release/v1.36.0/bin/linux/${ARCH}/kubectl.sha256
devbox$ echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
kubectl: OK
devbox$ sudo install -m 0755 kubectl /usr/local/bin/kubectl
devbox$ rm -f kubectl kubectl.sha256
devbox$ kubectl version --client
Client Version: v1.36.0
Kustomize Version: v5.8.1
```

⚠ **Derive the architecture, do not assume it.** The devbox is a Lima VM, so on an Apple Silicon Mac it is `aarch64` and on an Intel one `x86_64`. A wrong binary fails with `cannot execute binary file`, which does not say "wrong architecture" anywhere in it.

**Now the tunnel.** The helpers (§1.5's `tw-helpers-env.sh`) wrap it, so you do not have to keep a terminal hostage:

```
devbox$ tw_tunnel_up
tunnel up:
  localhost:6443  -> 172.16.0.1:6443  Kubernetes API
  localhost:8080  -> 172.16.0.1:80    gateway (nothing listening until §13)
devbox$ tw_tunnel_status
devbox$ tw_tunnel_down            # when you are done
```

📌 **Why a helper rather than the raw command.** The tunnel backgrounds itself and is tracked by an SSH *control socket*, so `tw_tunnel_down` closes exactly this tunnel — not whatever `pkill -f ssh` happens to match. `tw_tunnel_status` reports two things separately, because they fail separately: whether the forward is up, and whether the API answers through it. A live tunnel to a dead control plane looks identical to a dead tunnel unless you ask both questions.

If you would rather see it plainly, or the helpers are not loaded, this is what the helper runs:

```
devbox$ ssh -i ~/.ssh/tw_ed25519 -N \
    -L 6443:172.16.0.1:6443 \
    -L 8080:172.16.0.1:80 \
    rocky@${TW_HEAD_FIP}
```

`-N` means "no command, just forward", so this **blocks and prints nothing**. That is success. Leave it running and open a second terminal for everything below.

🛑 **`Ctrl-C` to get your prompt back kills the tunnel.** This is the single most common way to lose it, and the symptom arrives later — a `kubectl` that worked a minute ago starts refusing. If you are running the raw command, it needs a terminal of its own for as long as you want the tunnel. `tw_tunnel_up` exists precisely so it does not.

⚠ **If it dies when you did *not* interrupt it, stop trusting the foreground form and prove where the process went.** `-f` backgrounds ssh, which removes the terminal as a variable:

```
devbox$ ssh -f -N -o ExitOnForwardFailure=yes -i ~/.ssh/tw_ed25519 \
    -L 6443:172.16.0.1:6443 rocky@${TW_HEAD_FIP}
devbox$ pgrep -af 'ssh.*6443'          # before
devbox$ kubectl get nodes
devbox$ pgrep -af 'ssh.*6443'          # after — gone means something really is killing it
```

Dropping the `8080` forward for the test is deliberate: it is the source of the repeated `channel N: open failed` lines, and removing the noise makes it obvious whether the process itself survived.

⚠ **`channel N: open failed: connect failed: Connection refused` is about port 8080, not the tunnel.** Channels open per *connection*, so this appears when something on the devbox actually uses `localhost:8080` and the head finds nothing listening on `172.16.0.1:80`. Until §13 creates a Gateway that is correct. It says nothing about the 6443 forward, which is the one you care about.

📌 **Where `Connection refused` comes from decides what to check.** These are three different faults that read alike:

| Message | Who refused | Where to look |
|---|---|---|
| `connection to 127.0.0.1:6443 was refused` | Your own machine — **nothing is bound to that port** | The tunnel is not running. `ss -ltnp \| grep 6443` will be empty |
| `channel N: open failed: … Connection refused` | The far end of the forward | Whatever you pointed the forward at is not listening. Normal for 8080 here |
| A hang or timeout, not a refusal | Nobody refused; packets are going nowhere | The VPN, the security group, or the head node |

A refusal on `127.0.0.1` never reaches the network at all, so it cannot be the VPN — which is worth knowing, because "is the F5 up?" is the first thing everyone checks and it is the one thing this rules out.

🛑 **Only the `6443` forward does anything today, and that is expected.** Port 80 on `172.16.0.1` has nothing listening on it yet. §11.4 gave you a `GatewayClass` — a *declaration* that a controller exists and will handle Gateways of that class — but no `Gateway`, and it is the `Gateway` that causes Envoy Gateway to provision an actual proxy with an actual listener. No Gateway, no proxy, no port 80.

So `curl localhost:8080` will fail with `Connection refused` right now. That is not a broken tunnel: SSH happily forwards a local port to a remote address that is not listening, and you only find out when something tries to use it. The forward is in the command from the start so it is there when §13 creates a Gateway and the port becomes live — at which point the same tunnel starts working with no changes.

⚠ **`Connection refused` through a tunnel tells you about the far end, not the tunnel.** If the tunnel itself were broken, SSH would fail to establish it and say so in the first terminal.

Copy the kubeconfig across and repoint it at the tunnel:

```
devbox$ mkdir -p ~/tw
devbox$ scp -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}:~/talos/kubeconfig ~/tw/kubeconfig
kubeconfig                        100% 2279    60.3KB/s   00:00
devbox$ sed -i 's|https://172.16.0.1:6443|https://127.0.0.1:6443|' ~/tw/kubeconfig
devbox$ KUBECONFIG=~/tw/kubeconfig kubectl get nodes
NAME      STATUS   ROLES           AGE     VERSION
nid0001   Ready    control-plane   6d12h   v1.36.0
nid0002   Ready    <none>          6d12h   v1.36.0
nid0003   Ready    <none>          6d12h   v1.36.0
```

📌 **`mkdir -p ~/tw` first.** `scp` to a path whose parent directory does not exist writes a *file* called `tw` instead of failing, and the `sed` then edits something that is not where you think it is.

🛑 **Re-running that `scp` silently undoes the `sed`.** The copy on the head node still says `172.16.0.1:6443`, so a fresh copy overwrites your edit and points `kubectl` back at an address the devbox cannot route to. The symptom is a **hang**, not an error — kubectl waits on a network that is going nowhere — and it arrives at whatever moment you next re-copy, which may be long after you set the tunnel up and will look like the tunnel failing.

The two are easy to tell apart once you know to look:

```
devbox$ grep server: ~/tw/kubeconfig
    server: https://127.0.0.1:6443       # correct — through the tunnel
    server: https://172.16.0.1:6443      # scp overwrote it — re-run the sed
```

⚠ **Check this before blaming the tunnel.** `172.16.0.1` hangs; a missing tunnel *refuses*. Different symptom, different cause, and the `grep` above settles it in one line. If you ever need to re-copy, run the `sed` again immediately — or better, make the pair one command so they cannot come apart.

⚠ **`KUBECONFIG=... kubectl` and `KUBECONFIG=...` on its own line are not the same thing.** The first sets the variable *for that one command*; the second sets a plain shell variable that `kubectl` never sees, because it was never exported. If you want it to persist, either `export KUBECONFIG=~/tw/kubeconfig` or re-source the helpers — from now on `tw-helpers-env.sh` exports it for you, but only once `~/tw/kubeconfig` exists, so the first source after this step is the one that takes effect:

```
devbox$ source ~/tw/tw-env.sh
devbox$ kubectl get nodes
NAME      STATUS   ROLES           AGE     VERSION
nid0001   Ready    control-plane   6d13h   v1.36.0
nid0002   Ready    <none>          6d13h   v1.36.0
nid0003   Ready    <none>          6d12h   v1.36.0
```

📌 **Re-run §11's checkpoint from here.** Every assertion in it works unchanged through the tunnel, and doing so proves the tunnel end to end far better than a single `get nodes` does — a list of nodes comes back from cache-friendly paths, whereas `kubectl top` crosses the aggregation layer to metrics-server and `get crd` pulls a large response. If all five pass from the devbox, §11.5 works.

This works because §8.6's `certSANs` patch put `172.16.0.1` on the API server certificate and the tunnel preserves the SNI/hostname the client asks for. If you get a certificate error, that patch is the thing to check.

🛑 **This is the right way to expose the cluster.** One authenticated SSH path, nothing published. Resist the temptation to give a node a floating IP or to open `tw-sg-api` (§3.5) — a Kubernetes API server reachable from a campus network is a liability, and the whole point of the provisioning wire is that it is unreachable.

## ✅ Checkpoint

```
head$ kubectl get storageclass
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  2d22h

head$ kubectl top nodes
NAME      CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
nid0001   97m          2%       1786Mi          11%
nid0002   58m          0%       649Mi           1%
nid0003   55m          0%       584Mi           0%

head$ kubectl get crd | grep -E 'gateway|cert-manager' | wc -l
24

head$ kubectl get gatewayclass
NAME   CONTROLLER                                      ACCEPTED   AGE
eg     gateway.envoyproxy.io/gatewayclass-controller   True       11s

head$ kubectl get pods -A | grep -v Running | grep -v Completed
NAMESPACE   NAME   READY   STATUS   RESTARTS   AGE
```

What each one proves, since three of them are easy to misread:

| Assertion | Why it is the right check |
|---|---|
| `local-path (default)` | The `(default)` suffix is the annotation from 11.2. Without it a PVC with no `storageClassName` stays `Pending` forever — and §13 creates exactly those |
| `kubectl top nodes` returning **numbers** | Not that metrics-server is `Running`. It runs perfectly while failing every scrape; only real figures prove the TLS path works |
| `24` CRDs | A count, not a list, because the exact number moves between versions. Zero means an install silently did nothing |
| Only the header line | Nothing anywhere in the cluster is unhealthy — including namespaces you did not install into |

## Common failures

| Symptom | Cause / fix |
|---|---|
| local-path pods `CrashLoopBackOff`, read-only filesystem errors | the `/opt` default path — apply the §11.2 configmap patch |
| PVC stuck `Pending` with `WaitForFirstConsumer` | normal for local-path, and **permanent** until a pod mounts it. Not a fault, and not evidence the provisioner works either — §11.2's consumer pod is the actual test |
| `local-path-provisioner` logs `read-only file system` | the `/opt` default path — the §11.2 configmap patch did not apply, or the deployment was not restarted after it |
| PVC `Pending` **with** a consumer pod; provisioner logs `create process timeout after 120 seconds` every 15 min | the kubelet cannot create the directory. §11.2's `extraMounts` patch is missing, or the configmap points somewhere the kubelet cannot write (`/var/mnt/…`). [Issue 007](issues/007-local-path-var-mnt-read-only-kubelet.md) |
| Consumer pod `FailedScheduling`, `running PreBind plugin "VolumeBinding": binding volumes: context deadline exceeded` | the same fault seen from the scheduler's side — a node was chosen, the PV never appeared. Read the **provisioner** log, not the scheduler's |
| `would violate PodSecurity "restricted:latest"` on apply | a warning, not a rejection. Expected; the deployment is created. §11.2 |
| metrics-server `CrashLoopBackOff`, `x509` in the logs | the kubelet TLS issue — §11.3 |
| `talosctl patch`: `open ~/talos/…: no such file or directory`, for a file `cat` can read | `~` inside `@~/…` is not expanded by the shell — use `--patch-file ~/…` |
| `helm: command not found` at §11.4 | helm is not on the head and is not in Rocky's repositories — install it first, §11.4 |
| `INSTALLATION FAILED: … conflicts with "kubectl-client-side-apply"` | Helm 4 enforces field ownership. Add `--force-conflicts` — [issue 009](issues/009-helm-4-crd-ownership-conflict.md) |
| `helm list -a` → `unknown shorthand flag: 'a'` | You are on Helm 4 and expected Helm 3. `-a` was Helm 3 shorthand for `--all` |
| `kubectl get gatewayclass` → `No resources found` after the chart installs | Expected. The chart ships the controller, not a class — create one, §11.4 |
| `GatewayClass` exists but `ACCEPTED` is not `True` | `controllerName` does not match what the controller watches for. Read it from `envoy-gateway-config` |
| `curl localhost:8080` → `Connection refused` through the §11.5 tunnel | Expected until §13. No `Gateway` exists, so no proxy and no listener on port 80 |
| `ssh: Could not resolve hostname : Name or service not known` | `TW_HEAD_FIP` is unset — note the empty name. `source ~/tw/tw-env.sh` |
| `kubectl: command not found` on the devbox | It has only ever been installed on the head. §11.5 installs it |
| `kubectl` still not using the tunnel after `KUBECONFIG=~/tw/kubeconfig` | That set a shell variable without exporting it. `export`, or re-source the helpers |
| `tw_tunnel_up` → `Address already in use` | An earlier tunnel is running outside the helpers. Find and kill it, then retry |
| `kubectl` worked, then `127.0.0.1:6443 was refused` | The tunnel died — usually a `Ctrl-C` in its terminal. Nothing is bound locally; the VPN is not involved |
| `channel N: open failed … Connection refused` while the tunnel runs | The 8080 forward reaching a port with no listener. Expected until §13 |
| `kubectl` **hangs** instead of refusing | Two candidates, in this order: the kubeconfig was re-copied and points at `172.16.0.1` again (`grep server: ~/tw/kubeconfig`), or the listener is bound to a dead connection — `tw_tunnel_down && tw_tunnel_up` |
| The tunnel prints `channel N: read failed … Broken pipe` | The *local* end went away — kubectl finished or was interrupted. Normal per-connection churn, not a fault |
| `cannot re-use a name that is still in use` retrying a helm install | A failed release record survived. `helm uninstall` it first |
| A pasted command hangs with no output | You copied the `head$ ` prompt with it. `head` is a real program and it is waiting on stdin. `Ctrl-C`, paste from after the prompt |
| `kubectl top nodes` → `metrics not available` | give metrics-server 60 s after it becomes Ready |
| Gateway API webhook errors, unknown fields | version mismatch — you installed a Gateway API newer than v1.2.1 |
| `GatewayClass` never becomes `Accepted` | the implementation's controller isn't running: `kubectl -n envoy-gateway-system get pods` |
| Everything `Pending`, `Insufficient cpu/memory` | your worker flavors are too small. Add a worker (§7.3) or use a bigger flavor |

Next: [§12 — GitOps with FluxCD](12-fluxcd-gitops.md)
