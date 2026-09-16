# Is the cluster healthy, and where is the model endpoint?

**The first thing you run after being away.** Six layers sit between an OpenStack instance and a model answering a question, and each can be broken while every layer below it looks perfect. This is how to find out which one, in about a minute, and how to get the variables you need to talk to the thing.

| I want to… | Go to |
|---|---|
| Check everything, quickly | [The 60-second sweep](#the-60-second-sweep) |
| Get `GW`, `GWPORT`, `HOST` back | [Getting the endpoint](#getting-the-endpoint) |
| Ask the model something | [Talking to the model](#talking-to-the-model) |
| Find which layer is broken | [Layer by layer](#layer-by-layer) |
| Look up a symptom | [Error table](#error-table) |

⚠ **Check the certificate first if the rig has been idle.** The OpenCHAMI TLS certificate lives 24 hours and it is the most common thing to be quietly broken on a machine nobody has touched — [the certificate runbook](openchami-certificate.md). It does not affect Kubernetes, so a healthy cluster tells you nothing about it.

---

## The 60-second sweep

```
head$ source ~/tw-head-env.sh
head$ kubectl get nodes
head$ kubectl get pods -A --field-selector=status.phase!=Running
head$ flux get kustomizations
head$ kubectl -n kserve get gateway,pods
head$ kubectl -n inference get inferenceservice,pods
head$ tw_infer
```

**How to read each line, in the order that matters:**

| Command | Healthy | What a failure means |
|---|---|---|
| `get nodes` | three `Ready`, one control-plane | the layer everything else sits on |
| `get pods -A --field-selector=…!=Running` | **no output at all** | anything listed is a pod not running. `Completed` jobs also show — read the names |
| `flux get kustomizations` | all `True`, same revision | Git and the cluster have diverged, or a manifest is broken |
| `get gateway` | `PROGRAMMED True` **and a non-empty `ADDRESS`** | both columns matter, and `True` with a blank address is a real state |
| `get inferenceservice` | `READY True` | the model, as KServe sees it |
| `tw_infer` | three values printed | the endpoint you actually type into `curl` |

📌 **`--field-selector=status.phase!=Running` is the useful shape of "show me pods".** `kubectl get pods -A` on a working cluster is forty lines you will not read; this is empty when all is well, so anything at all is a signal.

⚠ **The empty result is the assertion.** Get into the habit of expecting no output — a command that prints nothing when healthy is worth ten that print something you have to scan.

---

## Getting the endpoint

```
head$ tw_infer
MODEL=qwen05b  endpoint=http://172.16.0.3:30791  Host: qwen05b-inference.example.com
```

That exports `GW`, `GWPORT`, `HOST` and `MODEL`. It runs automatically on login from [`~/tw-head-inference-env.sh`](../templates/tw-head-inference-env.sh) (§14.3a); call it by hand after anything that might have moved the endpoint.

**For a different model:**

```
head$ tw_infer <inferenceservice> <namespace>
```

🛑 **Do not write these three into a file as fixed values.** They are *discovered*, not chosen, and each changes on its own: `GWPORT` is reassigned if the Envoy Service is recreated, `GW` follows the node set, `HOST` is per-model. Frozen values are worse than no values, because you will trust them.

**If `tw_infer` reports an empty variable**, it tells you which — and the three have nothing to do with each other:

| Empty | Means | Check |
|---|---|---|
| `GW` | the Gateway has no address | `kubectl -n kserve get gateway` — is the Envoy Service still `NodePort`? |
| `GWPORT` | no Envoy Service found | `kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway`. ⚠ It lives in **`envoy-gateway-system`**, not `kserve` |
| `HOST` | no HTTPRoute | `kubectl -n inference get httproute` — KServe creates it, so this means KServe is unhappy |

🛑 **An empty variable does not produce an error, it produces a fast nothing.** `curl http://:/v1/…` exits in about eight milliseconds with no output, which reads as an extremely quick success. Always check the three are populated before believing a result:

```
head$ echo "GW=$GW  GWPORT=$GWPORT  HOST=$HOST"
```

---

## Talking to the model

```
head$ tw_ask "In two sentences, what is OpenCHAMI for?" 80
```

**Time it** when you want the throughput number rather than the answer:

```
head$ time tw_ask "Say hello." 8
```

Tokens divided by `real` is your tokens per second. On CPU expect single digits; that is the point of §16.

**Three tests, in increasing scope.** Use them in this order when something is wrong, because each one clears a layer:

```
head$ kubectl -n inference port-forward svc/qwen05b-predictor 8000:80 &
head$ curl -s http://localhost:8000/v1/models | jq .          # 1. the model itself
head$ curl -s -i -m 30 http://${GW}:${GWPORT}/v1/models -H "Host: ${HOST}" | head -6
                                                              # 2. routing, no generation
head$ tw_ask "Say hello." 8                                   # 3. routing plus generation
```

| Which fails first | Where the fault is |
|---|---|
| 1 | the model or the pod. Nothing to do with the Gateway |
| 2 | routing: `Host` header, HTTPRoute, Gateway, or the NodePort |
| 3, when 2 passed | generation — usually the **timeout**, if a short request works and a long one does not |

⚠ **`jq: parse error: Invalid numeric literal` means the body was not JSON**, so you are reading a proxy's error page rather than the model's answer. Drop the `| jq`, add `-i`, and read the status line — `tw_ask_raw` does exactly that.

---

## Layer by layer

When the sweep says something is wrong, work **bottom-up**. A failure at any layer makes everything above it look broken too.

| # | Layer | Check | Section |
|---|---|---|---|
| 1 | OpenStack instances | `openstack server list` *(from the devbox)* | §4, §7 |
| 2 | OpenCHAMI + certificate | `sudo podman ps`, then [the certificate runbook](openchami-certificate.md) | §5 |
| 3 | Talos | `talosctl -n 172.16.0.1 health` | §10 |
| 4 | Kubernetes | `kubectl get nodes`, `kubectl -n kube-system get pods` | §10, §11 |
| 5 | Flux | `flux check`, `flux get kustomizations` | §12 |
| 6 | KServe + Gateway | `kubectl -n kserve get pods,gateway` | §13 |
| 7 | The model | `kubectl -n inference get inferenceservice,pods` | §14 |

📌 **Layers 1–3 do not use the certificate; layer 2 is the only consumer.** So a dead certificate breaks node *provisioning* while leaving a running Kubernetes cluster entirely healthy. That asymmetry is why [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) went unnoticed for six days.

**Flux is the layer that hides drift**, because it reports on what it applied rather than what is running:

```
head$ flux get kustomizations
head$ flux get helmreleases -A
head$ flux logs --level=error --since=1h
```

⚠ **A Kustomization can be `True` while doing nothing at all.** An empty `resources:` list is valid, applies cleanly, and reports success — so "Flux is happy" and "your manifest is in the cluster" are different claims. Check the object, not the reconciliation:

```
head$ kubectl -n inference get inferenceservice qwen05b
```

---

## Error table

| What you see | What it means | What to do |
|---|---|---|
| `curl` returns in ~8 ms with no output | `GW` or `GWPORT` is empty — the URL was `http://:/…` | `tw_infer` |
| `404` from Envoy | missing or wrong `Host` header | `tw_infer`, then check `HOST` is the `qwen05b` route, not `qwen05b-predictor` |
| `jq: parse error: Invalid numeric literal` | the body is a proxy error page, not JSON | `tw_ask_raw` and read the status line |
| Short prompts work, long ones do not | Envoy route timeout | §13.3's `BackendTrafficPolicy` — [§13](../13-kserve.md) |
| `Gateway` `PROGRAMMED True`, `ADDRESS` empty | the Envoy Service is `LoadBalancer` with nothing to fulfil it | [DL-007](../DECISION-LOG.md#dl-007--the-model-endpoint-is-a-nodeport-not-a-load-balancer) |
| `kubectl` → `connection to the server localhost:8080 was refused` | `KUBECONFIG` unset | `source ~/tw-head-env.sh` — and see the shell check below, because a login shell should never need this |
| `talosctl` → `failed to determine endpoints` | `TALOSCONFIG` unset | the same fix; the two travel together |
| `InferenceService` `READY False`, no pods | `defaultDeploymentMode` is `Knative` | [§13's checkpoint](../13-kserve.md) |
| Pod `CrashLoopBackOff` after ~40 s | usually `/dev/shm` | [issue 011](../issues/011-vllm-dev-shm-too-small.md) |
| `Init:OOMKilled` | storage-initializer memory limit | [§13.2](../13-kserve.md) |
| `x509: certificate has expired` anywhere | the 24-hour OpenCHAMI certificate | [certificate runbook](openchami-certificate.md) |
| Everything looks fine, nothing works | check you are on the VPN and the tunnel is up | [update-tunnel-ip](update-tunnel-ip.md) |

### Before blaming the cluster, check the shell

Half the entries above are an **empty variable wearing a cluster failure's clothes**. One line separates the two, and it tests all three layers the head's environment is built from:

```
head$ echo "$TW_CLUSTER_FQDN | $KUBECONFIG | $(type -t tw_ask)"
⟨captured on first run — expect the FQDN, a kubeconfig path, and "function"⟩
```

| Empty field | Layer that did not load | Written by |
|---|---|---|
| `TW_CLUSTER_FQDN` | `~/tw-head-vars-env.sh` | §5.1, generated on the devbox |
| `KUBECONFIG` | `~/tw-head-talos-env.sh` | §10.3 |
| `tw_ask` not a function | `~/tw-head-inference-env.sh` | §14.3a |

All three empty means `~/tw-head-env.sh` — the entry point — is not being sourced at all: check the `[ -f ~/tw-head-env.sh ] && . ~/tw-head-env.sh` line is still in `~/.bashrc`, and that `ls ~/tw-head-*-env.sh` shows no pre-rename filenames (`head-env.sh`, `talos-env.sh`, `tw-inference-env.sh` — see [`notes/todo-004`](../notes/todo-004-env-file-naming.md)).

⚠ **Run it in a shell you have just logged into.** A shell you have been working in has the variables set from earlier commands, so it passes regardless of whether `.bashrc` is right — which is exactly the state that looks fine today and breaks tomorrow.

📌 **Non-interactive shells are a separate test**, and the one that fails silently:

```
head$ ssh localhost 'echo "[$KUBECONFIG]"'
```

Anything printed before the `[` is a bug: `scp` and `rsync` read that same stream and fail with `protocol error`, naming neither `.bashrc` nor the file that printed.

---

## The habits

⚠ **Check the empty variable before you check the cluster.** More of this tutorial's time went on unset shell variables than on anything genuinely broken — `TW_HEAD_FIP`, `KUBECONFIG`, `GW`. All three fail in ways that name a service rather than a variable.

📌 **Work bottom-up when something is wrong, top-down when nothing is.** The sweep at the top runs highest-first because you are usually confirming health; the layer table runs lowest-first because a broken foundation makes six healthy layers look ill.

⚠ **"The controller is running" is never the assertion.** Reaching for the deepest observable consequence is what separates a check that works from one that reassures: `kubectl top` returning *numbers*, not metrics-server being `Running`; `notAfter` moving, not the timer firing; a model *answering*, not a pod being `Ready`.

## Related

- [Surveying a host for inference](inference-host-survey.md) — before you deploy, rather than after
- [The OpenCHAMI TLS certificate](openchami-certificate.md) — the one thing that breaks on a clock
- [`templates/tw-head-inference-env.sh`](../templates/tw-head-inference-env.sh) — `tw_infer`, `tw_ask`, `tw_ask_raw`
- [issue 011](../issues/011-vllm-dev-shm-too-small.md) — how the §14 debugging went wrong, and why
