# §14 — Serving an LLM with vLLM

*(Time: ~30 minutes, most of it downloading model weights. On the head node, committing to Git. **This section contains the Step −1 success criterion.**)*

## Concepts

**vLLM** is an inference engine. Given model weights and a request, it produces tokens — but the reason it is the default choice rather than a plain PyTorch loop is throughput:

- **PagedAttention** manages the KV cache in fixed-size blocks, like virtual memory pages, instead of one contiguous allocation per sequence. Memory fragmentation was the binding constraint on concurrent requests; this removes it.
- **Continuous batching** admits new requests into a running batch as soon as any sequence finishes, rather than waiting for the whole batch. On a busy server this is worth several times the naive throughput.
- **An OpenAI-compatible API** — `/v1/chat/completions`, `/v1/completions`, `/v1/models`. That is what makes it a drop-in for the application layer in the TechWatch design (LangGraph, CrewAI, internal services): they speak OpenAI, and vLLM answers.

### The reality check: we have no GPUs

The PTR will have RTX Pro 6000, MI210 and Gaudi3 accelerators. Our OpenStack project has none, so **this section runs vLLM on CPU**. Be clear-eyed about what that does and doesn't prove:

| Proves | Does not prove |
|---|---|
| the whole control path: Flux → KServe → runtime → pod → Gateway → HTTP | anything about performance |
| the `InferenceService` abstraction and its scaling | GPU scheduling, device plugins, MIG, or memory sizing |
| an OpenAI-compatible endpoint the application layer can target | multi-GPU or multi-node parallelism |
| that fluent English comes back over HTTP | **that anything it says is true** — see the checkpoint |

For scale: the TechWatch hardware estimates put a Gaudi3 node at ~24,200 tok/s on Llama-3-8B and a *CPU-only* general-compute node at ~100 tok/s. **Ours measured about 8 seconds for a reply capped at 80 tokens** — single-digit tokens per second, on an AMD EPYC 7713 with no AVX-512 at all (see the [host survey runbook](runbooks/inference-host-survey.md)). Be pleased it answers; §16 is where performance becomes a real subject.

vLLM's own documentation is explicit that the CPU backend is for prototyping and not optimised. That is precisely our use for it.

**Model choice.** We use **`Qwen/Qwen2.5-0.5B-Instruct`**:

- ~1 GB of weights, so it downloads and loads in minutes, not hours;
- and — recorded as [DL-005](DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) — **it is this model choice that makes 30 GB nodes viable.** The disk goes on the vLLM CPU image, not on the weights. Before swapping to a gated multi-billion-parameter model, check the node's free image filesystem: kubelet evicts at 15% free, well before the disk is full;
- instruction-tuned, so `/v1/chat/completions` gives sensible output;
- **not gated** on Hugging Face — no access token, so no secret to manage, which keeps §12's "nothing secret in Git" rule intact.

The design slide suggests Gemma-2B or Llama-3-8B. Both are *gated*: they need a Hugging Face token, hence a Kubernetes Secret, hence SOPS (§12.4). Swap to them once the plumbing works — the only change is the model name and the token.

**If 0.5 B is still too slow on CPU**, there is room below it. All of these are Apache 2.0 and ungated, so swapping is a one-line change to `storageUri` with no secret to add — surveyed 10 Aug 2026:

| Model | Params | Weights | Notes |
|---|---|---|---|
| `Qwen/Qwen2.5-0.5B-Instruct` | 0.5 B | ~1 GB | **what this section uses.** The smallest size that reliably holds a conversation |
| `HuggingFaceTB/SmolLM2-360M-Instruct` | 360 M | ~720 MB | the useful floor. Noticeably faster on CPU; summarises and chats, weak at reasoning |
| `HuggingFaceTB/SmolLM2-135M-Instruct` | 135 M | ~270 MB | ~4× faster again, but output frequently fails to cohere. Use to prove the *plumbing*, not to demo |

Both SmolLM2 sizes are `LlamaForCausalLM`, which vLLM has supported for ever — [confirmed by a vLLM maintainer](https://github.com/vllm-project/vllm/issues/14576) in response to exactly this question, so no runtime change is needed. [Appendix G](appendix-g-model-selection.md) has the wider survey: the gated options, the KV-cache arithmetic, and what changes when the PTR has accelerators.

⚠ **Going smaller does not buy meaningful disk.** The whole span from 135 M to 0.5 B is under a gigabyte of difference, against a vLLM CPU image several times that. If you are short of disk, that is a flavor or an image problem (DL-005), not a model problem — and dropping to 135 M to save space costs you the demo while fixing nothing.

## Step 14.1 — A `ServingRuntime` for vLLM on CPU

KServe ships runtimes aimed at GPUs. We define our own CPU one — which is also a useful exercise, because on the PTR you will define one per accelerator family.

```
head$ cd ~/techwatch-flux
head$ cat > infrastructure/configs/vllm-cpu-runtime.yaml << 'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterServingRuntime
metadata:
  name: vllm-cpu
spec:
  annotations:
    prometheus.kserve.io/port: "8000"
    prometheus.kserve.io/path: "/metrics"
  supportedModelFormats:
    - name: huggingface
      version: "1"
      autoSelect: false        # opt in explicitly; don't shadow the GPU runtimes
      priority: 1
  protocolVersions:
    - v2
    - v1
  containers:
    - name: kserve-container
      # Official vLLM CPU release image. Tag surveyed 15 Aug 2026: v0.27.1,
      # linux/amd64, built 11 Aug 2026, 1.77 GB compressed across 12 layers.
      # Tags: https://gallery.ecr.aws/q9t5s3a7/vllm-cpu-release-repo
      # NO `command:` — the image's entrypoint is ["vllm", "serve"] and the
      # model is a POSITIONAL argument. See §14.1a before changing this.
      image: public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.27.1
      args:
        - /mnt/models               # positional: `vllm serve <model_tag>`
        - --served-model-name={{.Name}}
        - --port=8000
        - --host=0.0.0.0
        - --dtype=bfloat16          # fall back to float32 if the CPU lacks bf16
        - --max-model-len=2048      # keep the KV cache small; CPU RAM is the limit
      env:
        # vLLM's CPU backend needs an explicit KV-cache budget, in GiB. It is
        # taken from ordinary RAM, so it must fit inside the pod's memory limit
        # ALONGSIDE the weights.
        - name: VLLM_CPU_KVCACHE_SPACE
          value: "4"
        # NO VLLM_CPU_OMP_THREADS_BIND. It takes a list of CPU IDs ("0-3"),
        # not "all", and a wrong value kills the engine at startup. A CPU
        # *limit* is a quota, not a pinning — the container still sees every
        # host thread — so any list we hard-coded here would be a guess.
      ports:
        - containerPort: 8000
          protocol: TCP
      volumeMounts:
        # vLLM's API server and its engine are SEPARATE PROCESSES that talk
        # over a shared-memory ring buffer. Kubernetes gives every pod a
        # 64 MiB /dev/shm; vLLM wants 160 MiB and refuses to start without it.
        - name: dshm
          mountPath: /dev/shm
      resources:
        requests:
          cpu: "2"
          memory: 8Gi
        limits:
          cpu: "4"
          memory: 12Gi
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory      # a RAM disk, not the node's filesystem
        sizeLimit: 2Gi
EOF
```

🛑 **The `/dev/shm` mount is not optional, and without it §14.2 crash-loops.** Kubernetes' default 64 MiB is a decade-old inheritance from Docker, and it is far too small for anything that uses shared memory seriously — PyTorch dataloaders hit it too. vLLM asks for 160 MiB and states the number in its error, which is more courtesy than most.

⚠ **`medium: Memory` means this comes out of the pod's RAM, not the node's disk.** The 2 GiB above is charged against the 12 GiB limit alongside the weights and the KV cache. It is generous on purpose — the requirement grows with parallelism — but if you are tight on memory, `512Mi` clears the stated 160 MiB with room to spare.

### Step 14.1a — Interrogate the image before you deploy it

🛑 **Do this on the head node, in thirty seconds, rather than in a `CrashLoopBackOff` after a 1.8 GB pull onto a worker.** vLLM exits non-zero on an unrecognised argument, and that reaches you as a pod that starts and immediately dies with nothing useful in `kubectl describe`. The head runs podman already:

```
head$ sudo podman run --rm public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.27.1 --help 2>&1 | head -12
usage: vllm serve [model_tag] [options]

Launch a local OpenAI-compatible API server to serve LLM
completions via HTTP. Defaults to Qwen/Qwen3-0.6B if no model is specified.
…
```

**That first line is the whole reason this step exists.** `vllm serve [model_tag]` — the model is **positional**, and the image's entrypoint already supplies `vllm serve`. Which is why the runtime above sets `args` and no `command`.

Then confirm every flag you intend to pass actually exists in *this* tag:

```
head$ sudo podman run --rm public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.27.1 \
        --help=all 2>&1 | grep -E '^\s*--(dtype|max-model-len|served-model-name|host|port)\b'
  --host HOST           Host name. (default: None)
  --port PORT           Port number. (default: 8000)
  --dtype {auto,bfloat16,float,float16,float32,half}
  --max-model-len MAX_MODEL_LEN
  --served-model-name SERVED_MODEL_NAME [SERVED_MODEL_NAME ...]
```

📌 **Read the `--dtype` line as the list of things you are allowed to say.** It names every accepted value, so `bfloat16` is confirmed and `float32` is there as the documented fallback — no guessing when the pod rejects one. `auto` would also work here and picks from the model's own config.

⚠ **Anything that does not come back must come out of `args`.** On our run, checking the four flags the section originally used found **two of them gone**:

```
head$ sudo podman run --rm --entrypoint python3 \
        public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.27.1 \
        -m vllm.entrypoints.openai.api_server --help 2>&1 \
      | grep -E 'disable-log-requests|max-model-len|served-model-name|--device'
                     [--max-model-len MAX_MODEL_LEN]
                     [--served-model-name SERVED_MODEL_NAME [SERVED_MODEL_NAME ...]]
                     [--device-ids DEVICE_IDS]
```

| Flag | Verdict |
|---|---|
| `--max-model-len` | present |
| `--served-model-name` | present |
| `--device=cpu` | **gone** — only `--device-ids` matched, which is a different thing. vLLM now selects the platform automatically, and a CPU-only image has exactly one to choose from |
| `--disable-log-requests` | **gone** — request logging became opt-in, so the flag it was the negation of no longer needs a negation |

Both removals are *improvements* upstream, and both would have killed the pod.

📌 **The older `python3 -m vllm.entrypoints.openai.api_server` form still works**, and shares the same argument parser — which is why the grep above finds the same flags. It is not what the image is built around, though, so this section uses the entrypoint.

📌 **1.77 GB compressed is roughly 4–5 GB on disk**, pulled once per node through the head's NAT. That is the number [DL-005](DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) is about, and it dwarfs the ~1 GB of model weights — which is why going to a smaller model does not buy you disk.

🛑 **Environment variables have no `--help`, and that gap is where this section's last failure came from.** An earlier draft set `VLLM_CPU_OMP_THREADS_BIND=all`, which vLLM now parses as a list of CPU IDs:

```
(EngineCore pid=62)   File "…/vllm/utils/cpu_resource_utils.py", line 118, in parse_id_list
(EngineCore pid=62)     result.append(int(part))
(EngineCore pid=62) ValueError: invalid literal for int() with base 10: 'all'
```

⚠ **Flags can be interrogated; environment variables can only be tested.** Every `--flag` in this runtime was checked in advance and every one was fine. The single setting that could not be checked that way is the single setting that was wrong — which is an argument for keeping the environment as small as possible, and for treating each variable as a claim that has to be proved by starting the process.

📌 **The general rule for a `ServingRuntime` inherited from anywhere: the flags will tell you if they are stale, the environment will not.**

Why each of the awkward bits:

- **`/mnt/models` as a bare positional** — `vllm serve` takes the model tag first and everything else as options. This is where KServe's storage initialiser puts the downloaded weights.
- **`--dtype=bfloat16`** — halves memory versus float32. Requires CPU bf16 support; if the pod dies with an unsupported-dtype error, use `float32` and double the memory request.
- **`--max-model-len=2048`** — the KV cache grows with context length, and on CPU it competes with the weights for the same RAM. A long context is what will OOM you, not the model size.
- **`VLLM_CPU_KVCACHE_SPACE`** — CPU-specific and effectively mandatory. It is a *reservation*, so `4` GiB here plus ~1 GB of weights plus overhead is why the memory limit is 12 GiB.
- **`{{.Name}}`** — KServe templates the `InferenceService` name in, so the model name in the API matches the object name.

## Step 14.2 — The `InferenceService`

```
head$ mkdir -p apps/inference
head$ cat > apps/inference/qwen05b.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: inference
---
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen05b
  namespace: inference
  annotations:
    # Belt and braces: §13 set Standard cluster-wide, but being explicit here
    # means this manifest behaves the same on a cluster that didn't.
    serving.kserve.io/deploymentMode: Standard
spec:
  predictor:
    minReplicas: 1          # never scale to zero: reloading weights is expensive
    maxReplicas: 2
    model:
      runtime: vllm-cpu
      modelFormat:
        name: huggingface
      # KServe's HuggingFace storage initialiser downloads the repo into
      # /mnt/models before the runtime container starts.
      storageUri: hf://Qwen/Qwen2.5-0.5B-Instruct
      resources:
        requests:
          cpu: "2"
          memory: 8Gi
        limits:
          cpu: "4"
          memory: 12Gi
EOF
head$ cat > apps/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - inference/qwen05b.yaml
EOF
head$ cat > infrastructure/configs/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kserve-gateway.yaml
  - vllm-cpu-runtime.yaml
EOF
head$ git add -A && git commit -m "Serve Qwen2.5-0.5B-Instruct on vLLM CPU via KServe" && git push
head$ flux reconcile kustomization infrastructure --with-source
head$ flux reconcile kustomization apps --with-source
```

Watch it come up. First start downloads ~1 GB of weights through the head's NAT and then loads them, so give it several minutes:

```
head$ kubectl -n inference get inferenceservice -w
head$ kubectl -n inference get pods
head$ kubectl -n inference logs -l serving.kserve.io/inferenceservice=qwen05b \
        -c kserve-container -f
```

You are waiting for vLLM's own startup banner and then `Application startup complete` / `Uvicorn running on http://0.0.0.0:8000`.

## Step 14.3 — Ask it something

Get the endpoint the Gateway assigned:

```
head$ kubectl -n inference get inferenceservice qwen05b
NAME      URL                                          READY  AGE
qwen05b   http://qwen05b.inference.<gateway-address>   True   6m
```

The simplest reliable test — port-forward straight to the pod, bypassing routing, to establish that the *model* works:

```
head$ kubectl -n inference port-forward \
        svc/qwen05b-predictor 8000:80 &
head$ curl -s http://localhost:8000/v1/models | jq .
```

Then the real thing, **through the Gateway**, which is what an application would do.

⚠ **You need an address *and* a port.** §13.3 exposes the Gateway as a `NodePort`, because this cluster has no `LoadBalancer` implementation — so the address is a node IP and the port is somewhere in `30000–32767`, not 80:

```
head$ GW=$(kubectl -n kserve get gateway kserve-ingress-gateway \
             -o jsonpath='{.status.addresses[0].value}')
head$ GWPORT=$(kubectl get svc -A \
             -l gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway \
             -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}')
head$ echo "${GW}:${GWPORT}"

head$ HOST=$(kubectl -n inference get httproute \
             -o jsonpath='{.items[0].spec.hostnames[0]}')
head$ echo "GW=$GW  GWPORT=$GWPORT  HOST=$HOST"
GW=172.16.0.3  GWPORT=30791  HOST=qwen05b-inference.example.com
```

⚠ **Check all three are populated before going further.** An empty variable produces a confusing failure rather than an obvious one — `http://172.16.0.3:/v1/…` or a request with no `Host` header, neither of which says what is wrong.

⚠ **The `Host:` header is not optional.** KServe routes by hostname, so a request to the Gateway's IP without it gets a 404 from Envoy. The name is a *routing key*, not DNS — nothing resolves `qwen05b-inference.example.com`, and nothing needs to. KServe builds it from its `domainTemplate` (`{{.Name}}-{{.Namespace}}.{{.IngressDomain}}`) and the chart's default domain.

📌 **There are two `HTTPRoute`s and `items[0]` is the right one.** KServe creates `qwen05b` (the top-level service) and `qwen05b-predictor` (the component). Use the first; the second bypasses the routing layer you are trying to test.

Now the request:

```
head$ curl -s http://${GW}:${GWPORT}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -H "Host: ${HOST}" \
    -d '{
      "model": "qwen05b",
      "messages": [
        {"role": "user", "content": "In two sentences, what is OpenCHAMI for?"}
      ],
      "max_tokens": 80,
      "temperature": 0.2
    }' | jq -r '.choices[0].message.content'
```

🛑 **If that returns `parse error: Invalid numeric literal`, you are looking at an Envoy error page, not JSON** — almost certainly §13.3's `BackendTrafficPolicy` is missing and the request hit Envoy's default 15-second timeout mid-generation. Two commands separate a routing fault from a timeout:

```
head$ curl -s -i -m 30 http://${GW}:${GWPORT}/v1/models -H "Host: ${HOST}" | head -6
head$ curl -s -i -m 120 http://${GW}:${GWPORT}/v1/chat/completions \
    -H 'Content-Type: application/json' -H "Host: ${HOST}" \
    -d '{"model":"qwen05b","messages":[{"role":"user","content":"Say hello."}],"max_tokens":8}' | tail -3
```

The first does no generation, so it returns in milliseconds: `200 OK` means **routing is fine**. The second generates eight tokens, which finishes inside 15 seconds: if that works and eighty tokens does not, it is the timeout, not the route. ⚠ **Always drop `| jq` and add `-i` when a response fails to parse** — `jq` can only tell you the body was not JSON, never which layer substituted it.

### Step 14.3a — Make the endpoint survive a logout

🛑 **Those three variables die with the shell, and an empty one fails in a way that looks like success.** Come back tomorrow, run the `curl` from your history, and you get this:

```
head$ time curl -s http://${GW}:${GWPORT}/v1/chat/completions … | jq -r '…'

real    0m0.008s
```

No error, no output, **eight milliseconds**. The URL was `http://:/v1/chat/completions`, which curl rejects instantly. It reads as a very fast success and it is nothing at all.

Write the helpers into a file the shell already picks up:

```
head$ cat > ~/tw-head-inference-env.sh << 'EOF'
tw_infer() {
  local isvc="${1:-qwen05b}" ns="${2:-inference}"
  GW=$(kubectl -n kserve get gateway kserve-ingress-gateway \
         -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  GWPORT=$(kubectl get svc -A \
         -l gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway \
         -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)
  HOST=$(kubectl -n "$ns" get httproute "$isvc" \
         -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)
  MODEL="$isvc"
  export GW GWPORT HOST MODEL
  if [ -z "$GW" ] || [ -z "$GWPORT" ] || [ -z "$HOST" ]; then
    echo "tw_infer: incomplete — GW='${GW}' GWPORT='${GWPORT}' HOST='${HOST}'" >&2
    return 1
  fi
  echo "MODEL=${MODEL}  endpoint=http://${GW}:${GWPORT}  Host: ${HOST}"
}
tw_ask() {
  local prompt="${1:-Say hello.}" max="${2:-64}" payload
  [ -n "$GW" ] && [ -n "$GWPORT" ] && [ -n "$HOST" ] || tw_infer >/dev/null || return 1
  payload=$(jq -n --arg m "$MODEL" --arg p "$prompt" --argjson n "$max" \
    '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$n, temperature:0.2}')
  curl -s "http://${GW}:${GWPORT}/v1/chat/completions" \
       -H 'Content-Type: application/json' -H "Host: ${HOST}" \
       -d "$payload" | jq -r '.choices[0].message.content // .'
}
tw_infer >/dev/null 2>&1 || true
EOF
head$ source ~/tw-head-env.sh
head$ tw_infer
head$ tw_ask "In two sentences, what is OpenCHAMI for?" 80
```

📌 **There is no hook to add.** `~/tw-head-env.sh` — the entry point §5.1 put on the head — already looks for this exact filename, and `~/.bashrc` sources that. Writing the file *is* the installation step, so the helpers reach every shell including the non-interactive `ssh head '…'` that scripts use. The fuller version with comments and a `tw_ask_raw` for debugging is in [`templates/tw-head-inference-env.sh`](templates/tw-head-inference-env.sh).

⚠ **This is the payoff for the entry point being a dispatcher rather than a chain.** An earlier version of this tutorial had §5's file source §10's, and §10's source this one — so installing a helper meant editing a file two sections back, and the only way to know what a login shell actually loaded was to open three files in order. One file naming its dependants is both shorter to install and possible to read.

🛑 **It goes in `~`, next to `tw-head-vars-env.sh` and `tw-head-talos-env.sh` — not in `~/techwatch-flux`.** That directory is the Flux Git repository, and a shell file committed there would be pushed to the GitOps repo where it does not belong. There is no `~/tw` on the head either; that path is the devbox's.

⚠ **These are functions, not fixed exports, and that distinction matters.** `TALOSCONFIG` is a path *you chose*, so §10 can write it down once. These three are **discovered**, and any of them changes without you touching anything: `GWPORT` is reassigned if the Envoy Service is ever recreated, `GW` follows the node set, and `HOST` is per-model. Freezing them would leave you three plausible values that are quietly wrong after a rebuild — worse than having none, because you would trust them.

📌 **`tw_infer` names which variable is empty rather than just failing.** Each of the three has a different cause — no Gateway address, no Envoy Service, no HTTPRoute — and they are three different problems in three different namespaces.

## ✅ Checkpoint — the Step −1 success criterion

Captured 15 Aug 2026, `tw-head`, serving from `nid0003`:

```
head$ tw_infer
MODEL=qwen05b  endpoint=http://172.16.0.3:30791  Host: qwen05b-inference.example.com

head$ time tw_ask "In two sentences, what is OpenCHAMI for?" 80
OpenCHAMI stands for "China Information Security Management System," which is an
open-source platform designed to promote and enhance the security of China's
information systems through collaborative efforts among government agencies,
private enterprises, and academic institutions.

real    0m8.039s
```

🛑 **That answer is completely wrong, and the checkpoint still passes.** OpenCHAMI has nothing to do with China; the model has never encountered the acronym and produced fluent, confident, entirely invented text. **This is the expected behaviour of a 0.5 B model and it is not a fault in anything you built.**

⚠ **The assertion is "coherent English arrived over HTTP", not "the answer is true".** Every layer between an OpenStack instance and this reply is being tested; none of them is a layer that could make the answer correct. If you want a response you can check, ask something the model can actually do — `"Write a haiku about winter"`, or `"Summarise: <two sentences you supply>"`. Reasoning and recall need a bigger model, which needs the accelerators §16 brings.

📌 **Roughly 8 seconds for a request capped at 80 tokens.** For the exact rate, ask the API rather than counting words — vLLM reports it:

```
head$ curl -s http://${GW}:${GWPORT}/v1/chat/completions \
    -H 'Content-Type: application/json' -H "Host: ${HOST}" \
    -d '{"model":"qwen05b","messages":[{"role":"user","content":"Say hello."}],"max_tokens":20}' \
    | jq '.usage'
```

`completion_tokens` divided by the wall-clock time is the number to record. Put it in your run log: it is the "before" figure that gives §16's accelerators something to be measured against, and it is the first honest throughput datum this tutorial has.

**When that returns text, Step −1 is complete.** Trace what it took:

An OpenStack instance booted iPXE off its own root disk → CoreDHCP identified it from SMD → BSS told it to boot Talos → Talos installed itself over that disk and joined Kubernetes → Flux reconciled KServe and a vLLM runtime from Git → KServe pulled a model and stood up a pod → a Gateway routed an OpenAI-compatible request to it → a language model answered.

Every one of those steps has a PTR equivalent, and [appendix B](appendix-b-lineage.md) says which ones change.

Worth recording alongside it:

```
head$ kubectl -n inference get pods -o wide      # which node is serving?
head$ kubectl top pods -n inference              # what is it actually using?
head$ curl -s http://${GW}:${GWPORT}/metrics -H "Host: …" | grep -E 'vllm.*(throughput|latency)'
```

vLLM exports Prometheus metrics on the same port — time-to-first-token, tokens/second, KV cache utilisation. Capture a baseline now: it becomes the "before" number when the accelerators arrive.

## Alternatives worth knowing

| Engine | Why you'd choose it |
|---|---|
| **vLLM** | the default; best throughput story on GPUs, broad model support, and what the TechWatch design names for both NVIDIA and AMD |
| **TGI** (Hugging Face Text Generation Inference) | also named in the design slide; comparable, strong quantisation support |
| **llama.cpp** / `llama-server` | **genuinely better than vLLM on CPU** — it is built for it, with aggressive GGUF quantisation. If §14 is unbearably slow, this is the pragmatic swap, at the cost of not exercising the engine the PTR will use |
| **Ollama** | llama.cpp with excellent ergonomics; ideal for a laptop, less so as a cluster service |
| **TensorRT-LLM / NVIDIA NIM** | fastest on NVIDIA silicon. A §16 candidate for the RTX nodes; NVIDIA-only |
| **Intel Gaudi software stack** | required for the Gaudi3 node. Its own vLLM fork/plugin — a §16 topic, and one to raise with Intel early |

The point of the `ServingRuntime` abstraction is that swapping any of these is a new runtime object plus a one-line change to the `InferenceService`. Try it: adding a second `InferenceService` on a different runtime, serving the same model, is the cheapest possible engine comparison — and it is one commit.

## Common failures

| Symptom | Cause / fix |
|---|---|
| Pod `ImagePullBackOff` | the tag in §14.1 no longer exists, or the node cannot reach `public.ecr.aws` through the head's NAT (§5.12) |
| Pod starts, dies immediately, log names a flag | a vLLM argument was renamed or removed in this tag. §14.1a catches this in thirty seconds on the head |
| `CrashLoopBackOff`, exit code 1, dies after ~40 s | `/dev/shm` is Kubernetes' default 64 MiB and vLLM needs 160 MiB — [issue 011](issues/011-vllm-dev-shm-too-small.md). Check with `--tail=80`; the real error is in the `EngineCore` process, below the `APIServer` traceback |
| `ValueError: invalid literal for int() with base 10: 'all'` | `VLLM_CPU_OMP_THREADS_BIND` takes CPU *IDs*, not `all`. Remove the variable |
| `Init:OOMKilled` on `storage-initializer` | KServe's default limit is 1 GiB against a ~1 GB model. §13.2 sets `kserve.storage.resources.limits.memory: 4Gi` — if you skipped it, this is where it surfaces. Not settable from the `InferenceService` |
| `parse error: Invalid numeric literal` from `jq` | the body is an Envoy error page, not JSON. Almost always §13.3's `BackendTrafficPolicy` is missing and the request hit the default 15 s route timeout |
| Changed the `ServingRuntime`, nothing happened | it is a template. `kubectl -n inference delete pod -l serving.kserve.io/inferenceservice=qwen05b` to build a new pod from it |
| `InferenceService` stuck `Ready=False`, no pods | `defaultDeploymentMode` is `Serverless` — §13's checkpoint |
| Storage-initialiser pod fails, DNS or TLS errors | the node cannot reach `huggingface.co`: the head's NAT (§5.12) or the Talos nameservers (§8.6) |
| Pod OOMKilled while loading | lower `--max-model-len`, lower `VLLM_CPU_KVCACHE_SPACE`, or raise the memory limit. On CPU these three compete for the same RAM |
| `Unsupported dtype bfloat16` | the CPU lacks bf16 — use `--dtype=float32` and double the memory |
| Pod `Pending`, `Insufficient cpu` | the request exceeds any single worker flavor — reduce it, or add a bigger worker (§7.3) |
| `curl` returns 404 from the Gateway | missing or wrong `Host:` header |
| `curl` hangs, then times out | the model is still loading; watch the container logs |
| Answers are gibberish | you used a base model, not an `-Instruct` one, with a chat endpoint |
| Answers are fluent but factually wrong | **not a fault.** A 0.5 B model invents confidently. The checkpoint tests the path, not the truth of the reply |
| Very slow (seconds per token) | expected on CPU. Confirm the pod got its full CPU limit, then see llama.cpp above |

Next: [§15 — Ray and KubeRay](15-kuberay.md)
