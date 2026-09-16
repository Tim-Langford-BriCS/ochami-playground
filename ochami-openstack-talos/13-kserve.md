# §13 — KServe

*(Time: ~20 minutes. On the head node, committing to the Flux repository from §12. Everything here goes in Git — no `kubectl apply`.)*

## Concepts

**What KServe is for.** You can serve a model with a plain `Deployment` and a `Service`. What you *cannot* do that way is: scale it on request load, roll out a new version safely, expose a consistent inference API across different engines, or describe "serve this model" as a single object your platform understands. KServe provides a control plane for exactly that:

| KServe object | What it is |
|---|---|
| **`ServingRuntime`** / `ClusterServingRuntime` | a reusable description of *an engine*: the container image, its arguments, which model formats it accepts. Install once, use many times |
| **`InferenceService`** | "serve *this model* using a matching runtime", plus scaling and routing. The object users actually write |
| **`LLMInferenceService`** | a newer, LLM-specific CRD built on the llm-d architecture: prefill/decode disaggregation, KV-cache-aware routing, multi-node serving. **Ships in separate charts and is not installed here** — see the checkpoint |

The separation is the value: an `InferenceService` names a model and a format, and the platform picks the engine. When §16 adds GPU nodes, the *runtime* changes and the `InferenceService` barely does.

### Deployment mode — and why we avoid Knative

KServe can run in two modes, and this is the most consequential choice in the section:

| | **Standard** (a.k.a. RawDeployment) | Serverless (Knative) |
|---|---|---|
| Builds on | plain `Deployment`, `Service`, `HPA` | Knative Serving (KPA, Activator, queue-proxy) |
| Scale to zero | no | yes |
| Extra components | none beyond a Gateway | Knative + its networking layer |
| Cold start | none — pods stay up | first request waits for a pod |
| Fit here | **chosen** | wrong for us |

We use **Standard** for three reasons. It removes an entire distributed system from the stack, which matters when the point of the exercise is to understand the layers. Scale-to-zero is actively unhelpful for LLM serving, where a cold start means re-loading gigabytes of weights. And on the PTR, nodes are dedicated to inference — there is nothing to give the capacity back to.

🔀 **Deviation from most KServe tutorials**, which install the Knative-based "serverless" mode by default. If you follow upstream docs and things look different, check which mode they assume.

### The prerequisites, already done

We install **KServe v0.20.0** (released 6 Aug 2026), whose [installation guide](https://kserve.github.io/website/docs/admin-guide/kubernetes-deployment) asks for exactly three things, all of which §11 left in place:

| KServe wants | We have | From |
|---|---|---|
| Kubernetes **1.32+** | `v1.36.0` | Talos v1.13.0, §10 |
| cert-manager **≥ 1.15.0** | `v1.16.2` | §11.4 |
| Gateway API **v1.2.1** | `v1.2.1`, experimental channel | §11.4, [issue 009](issues/009-helm-4-crd-ownership-conflict.md) |

If you skipped §11.4, go back — KServe's webhooks will not start without cert-manager, and its routing will not work without a `GatewayClass`.

📌 **Gateway API v1.2.1 is still the pinned prerequisite at 0.20**, unchanged since 0.15. That is why §11.4's pin is worth defending rather than floating: it has outlived four KServe releases.

### The one thing §11 did not leave you

⚠ **This cluster has no `LoadBalancer` implementation.** There is no OpenStack cloud-controller-manager and no MetalLB, so a `Service` of type `LoadBalancer` gets an `EXTERNAL-IP` of `<pending>` for ever. Nothing has needed one until now.

Envoy Gateway creates exactly such a Service for every `Gateway`, [defaulting to `LoadBalancer`](https://github.com/envoyproxy/gateway/blob/v1.2.4/api/v1alpha1/shared_types.go#L271). Left alone it would provision an Envoy pod that works perfectly and is unreachable, with no address in the `Gateway` status and therefore nothing for §14's `curl` to aim at. §13.3 deals with this, and it is the reason that step is longer than "create a Gateway".

🛑 **Inferred from the source and the cluster's state, not yet observed.** If your `Gateway` does get an address without the step below, say so in your run log — it would mean something is fulfilling `LoadBalancer` services that we have not accounted for.

## Step 13.1 — A namespace, and a Helm source for KServe

KServe publishes OCI Helm charts. Tell Flux where — and, first, create the namespace everything else here lands in:

```
head$ cd ~/techwatch-flux
head$ cat > infrastructure/controllers/kserve-namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: kserve
EOF
head$ cat > infrastructure/controllers/kserve-source.yaml << 'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: kserve
  namespace: flux-system
spec:
  type: oci
  url: oci://ghcr.io/kserve/charts
  interval: 1h
EOF
```

🛑 **The namespace manifest is not optional.** The `HelmRelease` objects in §13.2 declare `metadata.namespace: kserve`, and so does the `Gateway` in §13.3. Flux's kustomize-controller has to *create those objects* before Helm ever runs, and you cannot create a namespaced object in a namespace that does not exist — the `infrastructure` Kustomization goes `ReconciliationFailed` with `namespaces "kserve" not found`. ⚠ *Predicted from the manifests, not observed: this section was corrected before its first run.*

⚠ **`install.createNamespace: true` does not save you here, and it is worth understanding why.** That setting tells *Helm* to create the **target** namespace when it installs the chart. But Helm only runs once helm-controller has read a `HelmRelease` object, and that object is itself in `kserve`. The chicken precedes the egg by one step. We keep `createNamespace` set anyway — it is correct, it is just not sufficient.

📌 **Order within the directory does not matter; Flux stages the apply.** kustomize-controller applies namespaces and CRDs before everything else, so one `Namespace` manifest anywhere in the kustomization covers every object in it — including §13.3's `Gateway`, which is in a different subdirectory but the same Flux `Kustomization`.

## Step 13.2 — CRDs, then the controller

Two charts, in order, because the controller's own manifests reference its CRDs. `dependsOn` makes helm-controller wait for the first `HelmRelease` to report `Ready` before it starts the second:

```
head$ cat > infrastructure/controllers/kserve.yaml << 'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kserve-crd
  namespace: kserve
spec:
  interval: 1h
  targetNamespace: kserve
  install:
    createNamespace: true
  chart:
    spec:
      chart: kserve-crd
      version: "v0.20.0"
      sourceRef:
        kind: HelmRepository
        name: kserve
        namespace: flux-system
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kserve
  namespace: kserve
spec:
  interval: 1h
  targetNamespace: kserve
  dependsOn:
    - name: kserve-crd
  chart:
    spec:
      chart: kserve-resources
      version: "v0.20.0"
      sourceRef:
        kind: HelmRepository
        name: kserve
        namespace: flux-system
  values:
    kserve:
      storage:
        resources:
          limits:
            # KServe's default is 1Gi, against a model of about the same size.
            # The init container is OOM-killed mid-download — see below.
            memory: 4Gi
      controller:
        # THE important setting: standard Kubernetes resources, no Knative.
        deploymentMode: Standard
        gateway:
          ingressGateway:
            enableGatewayApi: true
            kserveGateway: kserve/kserve-ingress-gateway
EOF
```

Register all three files with Kustomize and push:

```
head$ cat > infrastructure/controllers/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kserve-namespace.yaml
  - kserve-source.yaml
  - kserve.yaml
EOF
head$ ls infrastructure/controllers/
kserve-namespace.yaml  kserve-source.yaml  kserve.yaml  kustomization.yaml
head$ git add -A && git commit -m "Install KServe 0.20 in Standard (no-Knative) mode" && git push
head$ flux reconcile kustomization infrastructure --with-source
```

⚠ **`ls` first, and then count the `create mode` lines in the commit.** Both are free, and either one catches the mistake that is easiest to make here: a `cat > …` heredoc that ran in the wrong directory. The first command in this step is `cd ~/techwatch-flux`, and if you paste from the second one instead you get

```
-bash: infrastructure/controllers/kserve-namespace.yaml: No such file or directory
```

— which scrolls past above a long heredoc body and is easy to miss. `git commit` then prints **one `create mode` line per file Git has never seen**, so three new files must produce three lines:

```
 create mode 100644 infrastructure/controllers/kserve-namespace.yaml
 create mode 100644 infrastructure/controllers/kserve-source.yaml
 create mode 100644 infrastructure/controllers/kserve.yaml
```

🛑 **A missing file listed in `kustomization.yaml` fails in a way that names Kustomize, not the heredoc.** Kustomize refuses to build the whole directory, so `flux reconcile` waits on a reconciliation that can never succeed and looks like a hang. `flux get kustomizations` shows the truth — `accumulateFile "kserve-namespace.yaml"`, `no such file or directory`. The cause is two commands and thirty seconds earlier than the symptom.

⚠ **Pin the chart version.** `v0.20.0` above pairs with Gateway API v1.2.1 from §11.4. KServe is moving quickly toward the GenAI-first `LLMInferenceService` model, and floating on `latest` means a chart upgrade can change CRD schemas under your committed manifests. Bump deliberately, in a commit, so the change is attributable.

📌 **Why 0.20 and not something older and more settled.** It is nine days old at the time of writing, which is a fair objection — but the alternative is worse. `v0.18.0` is what this section originally pinned, and the documentation everyone will reach for is 0.20's, so pinning behind it means following instructions for a different release. Both versions accept the settings used here (`Standard` has been valid since 0.15, `RawDeployment` is the deprecated alias that KServe now [rewrites internally](https://github.com/kserve/kserve/blob/v0.20.0/pkg/constants/constants.go#L559)), so this is a choice about which docs match your cluster, not about which flags work. `v0.19.0` (14 Jun 2026) is the fallback if 0.20 misbehaves.

⚠ **`deploymentMode` in the chart defaults to `Knative`, in every version.** The value is not optional decoration — omit it and you get the serverless path this section spent its Concepts section arguing against, and the failure appears in §14 as an `InferenceService` that never produces a pod.

Watch it arrive:

```
head$ flux get helmreleases -A
head$ kubectl -n kserve get pods -w
```

🛑 **The `storage.resources` override is set here, three sections before it matters.** KServe's storage-initializer downloads the model weights into the pod, and its default memory limit is **1 GiB** — against a model of roughly 1 GB, downloaded in parallel chunks. Leave it and §14's pod loops on `Init:OOMKilled`, several minutes and two sections from anything you can see here.

📌 **Which knob controls that limit is not obvious, and the obvious one is a decoy.** The `inferenceservice-config` ConfigMap carries a `storageInitializer.memoryLimit`, hard-coded to `1Gi` in the chart and not settable through values. It is not what applies: KServe matches the `storageUri` prefix against a **`ClusterStorageContainer`** called `default` — which lists `hf://` among its formats and takes its resources from `kserve.storage.resources`. The ConfigMap value is the fallback for URIs no storage container claims. Confirm which one you actually changed:

```
head$ kubectl get clusterstoragecontainer default \
        -o jsonpath='{.spec.container.resources.limits.memory}'; echo
```

📌 **The CRD chart is enormous, and this is the right way to apply it.** `serving.kserve.io_inferenceservices.yaml` alone is **1.9 MB** — which is why KServe ships CRDs as a separate chart, and why `kubectl apply -f` on it fails with `metadata.annotations: Too long: must have at most 262144 bytes`. Helm does not use that annotation, so through Flux this is a non-event. Worth knowing before someone "helpfully" applies the CRDs by hand — and it is why upstream also publishes a `kserve-crd-minimal` chart with the validation schemas stripped out. We use the full one; if you ever hit a size limit in a more constrained cluster, that is the escape hatch, at the cost of the API server no longer validating your manifests.

## Step 13.3 — The Gateway, and how it gets an address

KServe routes model traffic through a `Gateway` that you provide — this is the first one in the cluster, and the layer §11.4 deliberately left empty. Two objects, because of the `LoadBalancer` problem above:

```
head$ cat > infrastructure/configs/kserve-gateway.yaml << 'EOF'
# Tell Envoy Gateway to expose this Gateway's proxy as a NodePort service
# rather than the default LoadBalancer, which nothing here can fulfil.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: kserve-proxy-nodeport
  namespace: kserve
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: kserve
spec:
  # Must match the GatewayClass from your §11.4 implementation:
  #   Envoy Gateway → "eg"        Istio → "istio"
  gatewayClassName: eg
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: kserve-proxy-nodeport     # same namespace as this Gateway; no namespace field exists
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All        # model InferenceServices live in their own namespaces
---
# Envoy's default route timeout is 15 seconds. Generating tokens on a CPU is
# far slower than that, so without this every non-trivial request is cut off
# mid-generation and the client gets an Envoy error page instead of JSON.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: kserve-inference-timeout
  namespace: kserve
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: kserve-ingress-gateway     # policy and target MUST share a namespace
  timeout:
    http:
      requestTimeout: 600s
EOF
head$ cat > infrastructure/configs/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kserve-gateway.yaml
EOF
head$ wc -l infrastructure/configs/kserve-gateway.yaml infrastructure/configs/kustomization.yaml
 35 infrastructure/configs/kserve-gateway.yaml
  4 infrastructure/configs/kustomization.yaml
head$ git add -A && git commit -m "KServe ingress Gateway, exposed as NodePort" && git push
head$ flux reconcile kustomization infrastructure --with-source
```

🛑 **`4` is the number that matters, and `3` is the failure.** `infrastructure/configs/kustomization.yaml` already exists — §12.4 created it as a placeholder with `resources: []`, which is three lines. The block above **replaces** it. If the second `cat >` does not run, you are left with a valid, empty kustomization: Flux reconciles happily, reports success, and applies nothing at all. The Gateway sits committed in Git doing nothing, and the symptom is

```
Error from server (NotFound): gateways.gateway.networking.k8s.io "kserve-ingress-gateway" not found
```

on an object you can see in the repository.

⚠ **`git commit`'s file count is the cheapest check for this, and it is one line above the push.** This step changes **two** files — one created, one modified:

```
 2 files changed, 39 insertions(+), 1 deletion(-)
 create mode 100644 infrastructure/configs/kserve-gateway.yaml
```

`1 file changed` means the kustomization was not rewritten. 📌 **The general shape: a manifest is inert until something references it, so every new file in a Flux repo is really two edits.** Both the §13.1 and §13.3 failures on our own run were the second edit going missing — once as a file listed but absent, once as a file present but unlisted.

⚠ **`gatewayClassName` must match what you actually installed.** `eg` for Envoy Gateway, `istio` for Istio. Check with `kubectl get gatewayclass`. A wrong value leaves the Gateway `Programmed=False` for ever, and model endpoints simply never get an address.

### Why the `EnvoyProxy`, and why attached here

An `EnvoyProxy` is Envoy Gateway's own CRD for *how the data plane is deployed* — replicas, resources, and the Service in front of it. It can be attached in two places, and the choice matters:

| Attach to | How | Effect |
|---|---|---|
| the **`GatewayClass`** | `spec.parametersRef` | every Gateway of that class inherits it |
| the **`Gateway`** | `spec.infrastructure.parametersRef` | this Gateway only |

We attach to the **`Gateway`**, for a reason that is about ownership rather than taste: the `GatewayClass` was created by hand in §11.4 with `kubectl apply`, and it is *not* in Git. Editing it from a Flux-managed manifest would mean Flux adopting an object `kubectl` already owns — which is [issue 009](issues/009-helm-4-crd-ownership-conflict.md)'s field-ownership conflict, invited deliberately. Attaching to the `Gateway` keeps the whole change inside the file Flux already owns, and leaves §11.4's checkpoint true.

📌 **Envoy Gateway populates the `Gateway` address differently per service type**, which is exactly why this works ([`status/gateway.go`](https://github.com/envoyproxy/gateway/blob/v1.2.4/internal/gatewayapi/status/gateway.go#L50-L76)):

| Service type | `status.addresses` becomes |
|---|---|
| `LoadBalancer` *(default)* | the load balancer's ingress IPs — **empty here**, because nothing assigns one |
| `ClusterIP` | the cluster IP — routable inside the cluster, useless from the head node |
| `NodePort` | **the node IPs** — `172.16.0.x`, which the head node can reach directly |

`NodePort` is the only one of the three that both gets an address and is reachable from where you will be typing `curl`.

📌 **`spec.infrastructure.parametersRef` is in both Gateway API channels at v1.2.1**, so this works whether or not you ended up on experimental after §11.4. Worth stating because it is the kind of field that usually *is* experimental-only, and a reader who checked would reasonably assume they had to.

⚠ **The address is a node IP, but the port is not 80.** A NodePort listener lands somewhere in `30000–32767`, so §14's requests need the port as well as the address. Get both:

```
head$ kubectl -n kserve get gateway kserve-ingress-gateway \
        -o jsonpath='{.status.addresses[0].value}'; echo
head$ kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway \
        -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}'; echo
```

🛑 **Note the `-A` on the second command, and do not "correct" it to `-n kserve`.** The `Gateway` object lives in `kserve`, but the Envoy proxy it provisions — Deployment, Service and pod — is created in **`envoy-gateway-system`**, the controller's own namespace. That is Envoy Gateway's default ["controller namespace" deployment mode](https://gateway.envoyproxy.io/docs/tasks/operations/deployment-mode/): one place for every proxy, whichever namespace asked for it ([`infra.go`](https://github.com/envoyproxy/gateway/blob/v1.2.4/internal/infrastructure/kubernetes/infra.go#L63)). Searching `kserve` for the Service returns nothing and looks like the Gateway failed. `-A` with the owner label is correct under either deployment mode, which is why it is written that way.

📌 **Any node IP works, so the one you get is not special.** A NodePort is opened on *every* node in the cluster; `status.addresses` may list several and `kubectl get gateway` shows only the first. `-o jsonpath='{.status.addresses[*].value}'` gives you the lot. This is worth knowing before someone hard-codes one into a config: the port is the stable half, the address is any node that is up.

🛑 **On the PTR, use MetalLB or the OpenStack cloud-controller-manager instead** — argued as [DL-007](DECISION-LOG.md#dl-007--the-model-endpoint-is-a-nodeport-not-a-load-balancer). NodePort is the right answer for a POC on an isolated wire — no extra component, no address pool to manage, and the head node is already on the node network. It is the wrong answer for anything with real clients, because the port is arbitrary, it changes if the Service is recreated, and there is no stable VIP to put in DNS. Swapping later is one `EnvoyProxy` field plus an address pool; the `Gateway` itself does not change.

### The ten-minute timeout is not padding

🛑 **Envoy times out a route after 15 seconds by default, and inference is not a 15-second workload.** This is the single most confusing failure in §14, because it produces a *partial* success: short requests work, longer ones don't, and the difference is a number you didn't set. Ours returned eight tokens in about a second and failed at eighty.

The symptom is `curl … | jq` reporting

```
parse error: Invalid numeric literal at line 1, column 9
```

— which says nothing about timeouts. It means the body was not JSON, because Envoy replaced vLLM's answer with an error page. ⚠ **Drop the `| jq` and add `-i` the moment a response fails to parse**; you are looking at the wrong layer's output and `jq` cannot tell you that.

📌 **`BackendTrafficPolicy` is Envoy Gateway's own CRD, not Gateway API.** Gateway API can express a per-route timeout via `HTTPRoute.spec.rules[].timeouts.request`, but **KServe generates the `HTTPRoute`** — hand-edit it and KServe puts it back. Attaching a policy to the *Gateway* leaves KServe's objects alone and covers every model that ever routes through it, including ones added later. That is the general shape for anything you want to change about a route you do not own.

⚠ **The policy must live in the same namespace as the object it targets** — `kserve`, here. A policy in the wrong namespace is accepted, reports nothing useful, and does nothing.

**HTTP only, deliberately.** TLS on the model endpoint would mean issuing certificates for a name that only exists on an isolated wire. §11.5's SSH tunnel is the access path. On the PTR, put a real certificate here — cert-manager is already installed for exactly that.

## ✅ Checkpoint

Captured 15 Aug 2026 on `tw-head`:

```
head$ flux get helmreleases -A
NAMESPACE  NAME        REVISION  SUSPENDED  READY  MESSAGE
kserve     kserve      v0.20.0   False      True   Helm install succeeded for release kserve/kserve-kserve.v1 with chart kserve-resources@v0.20.0
kserve     kserve-crd  v0.20.0   False      True   Helm install succeeded for release kserve/kserve-kserve-crd.v1 with chart kserve-crd@v0.20.0

head$ kubectl -n kserve get pods
NAME                                         READY   STATUS    RESTARTS   AGE
kserve-controller-manager-8547c64c57-j2xsq   2/2     Running   0          27m

head$ kubectl get crd | grep kserve
clusterservingruntimes.serving.kserve.io         2026-08-15T11:45:22Z
clusterstoragecontainers.serving.kserve.io       2026-08-15T11:45:22Z
inferencegraphs.serving.kserve.io                2026-08-15T11:45:22Z
inferenceservices.serving.kserve.io              2026-08-15T11:45:23Z
servingruntimes.serving.kserve.io                2026-08-15T11:45:22Z
trainedmodels.serving.kserve.io                  2026-08-15T11:45:22Z

head$ kubectl -n kserve get gateway kserve-ingress-gateway
NAME                     CLASS   ADDRESS      PROGRAMMED   AGE
kserve-ingress-gateway   eg      172.16.0.3   True         2m52s

head$ kubectl -n kserve get configmap inferenceservice-config \
        -o jsonpath='{.data.deploy}' ; echo
{
  "defaultDeploymentMode": "Standard"
}
```

📌 **Six CRDs, and `llminferenceservices` is not among them** — see below. 📌 **`172.16.0.3` is `nid0003`**, a worker node, picked by nothing more meaningful than ordering.

Two of those five are assertions rather than sightings, and they are worth separating from the noise.

⚠ **A non-empty `ADDRESS` is the whole point of §13.3, and `PROGRAMMED True` does not imply it.** Envoy Gateway reports `Programmed` on the state of the proxy *deployment*; the address comes from the Service. Get the `EnvoyProxy` wrong and you can have a perfectly healthy, perfectly unreachable Gateway reporting `True` with a blank address column — which then surfaces in §14 as an empty `${GW}` and a `curl` to `http:///v1/…`. Read both columns.

📌 **`LLMInferenceService` is deliberately absent, and its absence is not a failure.** At 0.20 it ships in its own pair of charts — `kserve-llmisvc-crd` and `kserve-llmisvc-resources` — so nothing installed here provides it. That is the right default for us: it brings the llm-d architecture (prefill/decode disaggregation, cache-aware routing) which needs hardware we do not have until §16. Adding it later is two more `HelmRelease` objects alongside these, not a reinstall.

⚠ **`defaultDeploymentMode` is the value to confirm before §14.** If it says `Knative` (or the deprecated `Serverless`), the Helm values did not apply, and every `InferenceService` will sit waiting for Knative objects that do not exist. The failure gives no hint that it is about a chart value you set two steps ago.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `Kustomization/infrastructure` fails with `namespaces "kserve" not found` | the namespace manifest from §13.1 is missing, mis-spelled, or not listed in `infrastructure/controllers/kustomization.yaml` |
| `flux reconcile` sits at `◎ waiting for Kustomization reconciliation` and never returns | not a hang — it is waiting on a build that cannot succeed. `Ctrl-C` (nothing is mid-flight), then `flux get kustomizations` for the real message |
| `accumulateFile "<name>.yaml": … no such file or directory` | `kustomization.yaml` lists a file that does not exist. Almost always a heredoc that ran before `cd ~/techwatch-flux`. `ls infrastructure/controllers/` |
| Flux reports success, but the object is `NotFound` | the reverse: the file exists and is **not listed** in `kustomization.yaml`, so Kustomize built nothing. `wc -l infrastructure/configs/kustomization.yaml` — `3` means it is still §12.4's empty placeholder |
| `HelmRelease kserve` stuck `dependency 'kserve/kserve-crd' is not ready` | usually transient while the 1.9 MB CRD chart installs. If it persists, `flux logs -n flux-system --kind HelmRelease` — the CRD release is the one to read |
| `Gateway` `PROGRAMMED True` but `ADDRESS` empty | the `EnvoyProxy` is not attached. Check `spec.infrastructure.parametersRef` on the Gateway and that the `EnvoyProxy` is in the **same namespace** — the reference has no namespace field, so a copy in `envoy-gateway-system` is silently not found |
| `Gateway` `PROGRAMMED False`, no Envoy pod | `gatewayClassName` does not match a `GatewayClass` with `ACCEPTED True`. `kubectl get gatewayclass` |
| Envoy Service exists as `LoadBalancer` with `EXTERNAL-IP <pending>` | the `EnvoyProxy` was applied after the Gateway and the Service was not recreated. `kubectl delete svc -A -l gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway` and let the controller rebuild it |
| `kubectl -n kserve get svc` shows no Envoy Service, and no proxy pod | not a failure — the proxy is created in **`envoy-gateway-system`**, not in the Gateway's namespace. Use `-A` with the `owning-gateway-name` label |
| `defaultDeploymentMode` reads `Knative` | the `values:` block did not apply — check indentation under `kserve.controller`, which is three levels deep and the easiest thing here to get wrong |
| Webhook errors mentioning certificates | cert-manager is not `Ready`, or was installed after KServe. `kubectl -n cert-manager get pods`, then `flux reconcile helmrelease kserve -n kserve --force` |
| `flux reconcile` says the source is up to date, but your file is not there | you committed but did not push. `git log origin/main..HEAD` |

## What else could sit here

Named so the choice is visible, and argued properly in [appendix C](appendix-c-alternatives.md):

| Alternative | When it's the better answer |
|---|---|
| **Nothing** — plain `Deployment` + `Service` per model | You are serving one model, for ever. Simplest possible thing; §14 shows the manifest in a box so you can compare |
| **KubeRay / Ray Serve** (§15) | Your serving logic is a *pipeline* (retrieval, re-ranking, multiple models) rather than one endpoint, or you need model parallelism across nodes |
| **llm-d** directly | You want prefill/decode disaggregation and cache-aware routing without KServe's abstraction on top. KServe's `LLMInferenceService` is the managed version of this |
| **Seldon Core / BentoML** | Established alternatives; KServe was chosen because the TechWatch design names it and it is the CNCF-adjacent common denominator |
| **NVIDIA NIM / Triton** | Vendor-optimised and excellent on NVIDIA hardware — a strong §16 candidate for the RTX nodes, but it does not span AMD and Gaudi |

Next: [§14 — Serving an LLM with vLLM](14-vllm-inference.md)
