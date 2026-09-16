# Surveying a host before you deploy an inference stack

**Find out what the hardware actually provides, before choosing an engine or writing a manifest.** Every failure in §§13–14 of this tutorial was an assumption about the environment that nobody had checked: an instruction set, a shared-memory default, a memory limit, a proxy timeout. All four were visible in under a minute.

This runbook is the minute. Commands first; what each answer *decides* is underneath.

| I want to… | Go to |
|---|---|
| Run one command and see everything | [The one-pod survey](#the-one-pod-survey) |
| Work out which engine to use | [Choosing an engine](#choosing-an-engine) |
| Work out which `dtype` and model size | [Sizing the model](#sizing-the-model) |
| Check what the *container* gets, not the node | [Container defaults](#container-defaults-the-invisible-ones) |
| Check what the *cluster* provides | [Cluster capabilities](#cluster-capabilities) |
| Check an image before deploying it | [Interrogating an image](#interrogating-an-image) |
| Work backwards from a failure | [Symptom → the fact you did not check](#symptom--the-fact-you-did-not-check) |

⚠ **Survey the machine the workload will run on.** Not the head node, not your laptop, not "a node". This tutorial wasted an hour on a theory that a successful command on the head node had already disproved — see [issue 011](../issues/011-vllm-dev-shm-too-small.md).

---

## The one-pod survey

Everything below in a single command, answered from *inside a pod*, which is the only vantage point that matters:

```
head$ kubectl run envprobe --rm -i --restart=Never --image=busybox:1.36 -- sh -c '
  echo "== cpu";   grep -m1 "model name" /proc/cpuinfo
  echo "== simd";  grep -m1 ^flags /proc/cpuinfo | tr " " "\n" | grep -E "^(avx|amx|sse4|f16c)" | sort -u | tr "\n" " "; echo
  echo "== cores"; nproc
  echo "== mem";   grep -E "MemTotal|MemAvailable" /proc/meminfo
  echo "== shm";   df -h /dev/shm | tail -1
'
```

⚠ **It lands on whichever node the scheduler picks.** Run it a few times, or pin it, and check **every** node that could host the workload — mixed hardware is exactly the case this is for:

```
head$ kubectl run envprobe --rm -i --restart=Never --image=busybox:1.36 \
        --overrides='{"spec":{"nodeName":"nid0002"}}' -- sh -c 'grep -m1 "model name" /proc/cpuinfo'
```

📌 **`nproc` reports the host's cores, not your CPU limit.** A cgroup quota does not hide CPUs; it throttles you across all of them. Anything that sizes a thread pool from `nproc` will over-subscribe, which is one reason to leave thread-binding settings alone (see [`VLLM_CPU_OMP_THREADS_BIND`](#interrogating-an-image)).

### On Talos, without a pod

```
head$ talosctl -n 172.16.0.2 read /proc/cpuinfo | grep -m1 'model name'
model name      : AMD EPYC 7713 64-Core Processor

head$ talosctl -n 172.16.0.2 read /proc/cpuinfo | grep -m1 ^flags | tr ' ' '\n' \
      | grep -E '^(avx|sse4|f16c)' | sort -u
avx
avx2
f16c
sse4_1
sse4_2
sse4a
```

The blunt version, when you only need yes or no:

```
head$ talosctl -n 172.16.0.2 read /proc/cpuinfo | grep -c avx512
0
```

**Zero means no.** Any number above zero means *some* of the family is present, and you then need the detailed list — AVX-512 is a menu, not a feature.

---

## Choosing an engine

Read the `simd` line and the accelerator check together:

```
head$ kubectl get nodes -o custom-columns=\
'NODE:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory,GPU:.status.capacity.nvidia\.com/gpu'
```

| What you found | What to run | Why |
|---|---|---|
| **NVIDIA GPU** | vLLM (CUDA image), or TensorRT-LLM / NIM | the best-travelled path. NIM is faster and NVIDIA-only |
| **AMD GPU** | vLLM, ROCm build | same `ServingRuntime` shape, different image |
| **Intel Gaudi** | Intel's vLLM fork | its own stack; raise with the vendor early |
| **CPU with `avx512f`** | vLLM CPU image | what the official image is built for |
| **CPU with `avx2` only** | vLLM CPU **works**; llama.cpp is faster | see the note below |
| **CPU without `avx2`** | llama.cpp | vLLM's floor |

⚠ **`avx2`-only does not stop vLLM, despite what the docs imply.** [vLLM's CPU page](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/) calls `avx2` "limited features" and "not recommended", and the CPU image is documented as preferring AVX-512 ([vllm#18660](https://github.com/vllm-project/vllm/issues/18660)). We took that to mean the image would refuse to run on Zen 3, and it was wrong: `v0.27.1` imports, serves and generates on an EPYC 7713 with no `avx512` flag at all. **"Not recommended" is a performance statement, not a compatibility one.** Confirm by running the image's `--help` on the hardware in question — if the compiled extension were incompatible, it could not even print that.

📌 **Choosing llama.cpp is a real option, not a defeat.** It is built for CPU, quantises aggressively, and will beat vLLM on this hardware. The reason this tutorial stays on vLLM is that §16 puts accelerators in, and the point of §14 is to exercise the engine the final system will use. **Pick for where the rig is going, not only for where it is.**

---

## Sizing the model

Four numbers compete for one memory limit. Add them before you write the manifest:

| Consumer | Rough size |
|---|---|
| Model weights | ~2 bytes per parameter at `bfloat16`/`float16`, ~4 at `float32` |
| KV cache | `VLLM_CPU_KVCACHE_SPACE`, in GiB, **reserved up front** |
| `/dev/shm` | whatever you mount — memory-backed, so it counts |
| Runtime overhead | ~1–2 GiB |

Ours: ~1 GB of weights + 4 GiB KV cache + 2 GiB `/dev/shm` + overhead, inside `limits.memory: 12Gi`.

⚠ **`--max-model-len` is what OOMs you, not the parameter count.** The KV cache grows with context length. A 0.5 B model at 32 k context needs far more memory than the same model at 2 k.

**On `dtype`:**

| Finding | Choice |
|---|---|
| `avx512_bf16` present | `bfloat16` — fast, half the memory of float32 |
| No `avx512_bf16` | ⚠ **`bfloat16` still works.** Observed on Zen 3, 15 Aug 2026 — vLLM accepts it and serves. Slower than it would be with hardware bf16 |
| vLLM rejects the dtype | `float32`, and **double the memory allowance** — weights and KV cache both grow |

📌 **Ask the image what it accepts rather than guessing:** `--dtype` prints its own enumeration of valid values, which turns the fallback from advice into something you can see is available.

---

## Container defaults, the invisible ones

🛑 **This is the section people skip, and it caused the longest failure in this tutorial.**

```
head$ kubectl run shmprobe --rm -i --restart=Never --image=busybox:1.36 -- df -h /dev/shm
```

**If that says `64.0M`, every ML workload on this cluster has a problem waiting.** 64 MiB is a Docker default from years ago, inherited by Kubernetes, absent from every manifest, and not settable through a pod field. vLLM needs 160 MiB for the ring buffer between its API server and its engine; PyTorch dataloaders hit the same wall with a much worse error.

The fix, in any pod spec:

```yaml
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi
```

📌 **`medium: Memory` is charged against the pod's memory limit**, so it competes with the weights and the KV cache. Without it you get the node's disk mounted at `/dev/shm`, which may even work — slowly — while silently defeating the point.

**The other defaults worth knowing before they bite:**

| Default | Value | Bites as |
|---|---|---|
| `/dev/shm` | 64 MiB | `Insufficient space in /dev/shm` — [issue 011](../issues/011-vllm-dev-shm-too-small.md) |
| Envoy route timeout | 15 s | short requests succeed, long ones return an error page |
| KServe storage-initializer memory | 1 GiB | `Init:OOMKilled` on a model of about that size |
| Kubelet image-fs eviction | 15% free | pods evicted before the disk is full — [DL-005](../DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) |

⚠ **All four are set by something other than your manifest**, which is why reading your own YAML will never reveal them. **When something fails on resources, ask what the platform gave you, not only what you asked for.**

---

## Cluster capabilities

**Is there a load balancer?** Decides how anything gets reached:

```
head$ kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{" -> "}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}'
```

**Empty output, or entries with no IP, means nothing fulfils `LoadBalancer`.** Use `NodePort` or install MetalLB — [DL-007](../DECISION-LOG.md#dl-007--the-model-endpoint-is-a-nodeport-not-a-load-balancer) argues the trade.

**Storage, metrics, and the Gateway implementation:**

```
head$ kubectl get storageclass
head$ kubectl top nodes
head$ kubectl get gatewayclass
```

`kubectl top` returning **numbers** proves metrics-server's TLS path works; `Running` proves nothing, because it runs perfectly while failing every scrape. `GatewayClass` must show `ACCEPTED True` — a class naming a controller nobody answers to is created quite happily and does nothing.

**Can the nodes reach the model registry?** Weights are pulled by the node, not by you:

```
head$ kubectl run neteg --rm -i --restart=Never --image=busybox:1.36 -- \
        wget -q -T 10 -O /dev/null https://huggingface.co && echo REACHABLE
```

📌 **Test egress from a pod, not from the head node.** They often route differently, and on this tutorial's substrate the nodes reach the internet only through the head's NAT (§5.12).

---

## Interrogating an image

Before deploying, ask the image what it supports. On any host with podman or docker:

```
head$ sudo podman run --rm <image> --help | head -20
head$ sudo podman run --rm <image> --help=all 2>&1 | grep -E '^\s*--(flag1|flag2|flag3)\b'
```

**Every flag you intend to pass should come back.** Anything that does not must come out — engines exit non-zero on unrecognised arguments, and that reaches you as a pod that starts and dies with nothing useful in `kubectl describe`. This found two removed flags in thirty seconds on our run.

Also read the **entrypoint**, which decides whether your `command:` override is right:

```
head$ sudo podman inspect <image> --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'
```

🛑 **Flags can be interrogated. Environment variables cannot.** There is no `--help` for an environment variable, so each one is a claim that only starting the process can settle. Every command-line flag in our runtime was verified in advance and every one was fine; the single setting that could not be checked that way — `VLLM_CPU_OMP_THREADS_BIND=all` — was the one that was wrong. **Keep the environment as small as the engine allows.**

⚠ **Run this on hardware like the workload's, and beware of drawing conclusions from the wrong machine.** `--help` succeeding proves the compiled extension loads *on that CPU*. That is useful evidence — and only about that CPU.

---

## Symptom → the fact you did not check

| Symptom | The environment fact |
|---|---|
| `Illegal instruction`, exit code 132, log stops mid-import | CPU lacks an instruction set the binary was compiled for |
| `Insufficient space in /dev/shm` | container `/dev/shm` default of 64 MiB |
| `Init:OOMKilled` on the storage initializer | its own memory limit, not the pod's |
| `OOMKilled` on the model container, exit 137 | weights + KV cache + `/dev/shm` exceed the limit |
| Short requests work, long ones return non-JSON | proxy route timeout |
| `Gateway` `PROGRAMMED True` but no `ADDRESS` | no `LoadBalancer` implementation |
| Storage initialiser fails with DNS or TLS errors | nodes cannot reach the registry; egress, not credentials |
| Pod `Pending`, `Insufficient cpu` | the request exceeds any single node |
| Pod evicted with plenty of disk left | kubelet's image-fs eviction threshold |

📌 **Read the innermost error, not the outermost.** In a multi-process container the process the platform watches usually only *reports* the failure; the one that had it is a child, further up the log and past a short `--tail`. Set `--tail=80` or more and look for process-ID prefixes.

---

## The habit

⚠ **Ask what an artifact was *compiled for*, not just what it runs on.** A container image carries its dependencies; it does not make its machine code portable. Those get confused routinely, and the confusion is silent until a process dies.

⚠ **Survey before you configure.** Every one of §§13–14's failures was discoverable from the commands on this page, before a single manifest was written. We ran them afterwards, one at a time, each prompted by a failure — which is the same work in the least useful order.

📌 **Write the findings down next to the manifest.** A `ServingRuntime` full of numbers with no record of where they came from is a file nobody can safely change. The comments in §14.1 exist for that reason: each awkward value names the constraint that produced it.

## Where this came from

| Source | What it holds |
|---|---|
| [issue 011](../issues/011-vllm-dev-shm-too-small.md) | `/dev/shm`, the AVX-512 false trail, and how the debugging went wrong |
| [§13 — KServe](../13-kserve.md) | the storage-initializer limit, the Gateway, the route timeout |
| [§14 — vLLM](../14-vllm-inference.md) | the runtime, and interrogating the image first |
| [DL-005](../DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) | node disk against image size |
| [DL-007](../DECISION-LOG.md#dl-007--the-model-endpoint-is-a-nodeport-not-a-load-balancer) | NodePort versus a real load balancer |
| [appendix G](../appendix-g-model-selection.md) | model sizes, KV-cache arithmetic, gated models |
