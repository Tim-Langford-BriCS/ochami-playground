# 011 — vLLM crash-loops because Kubernetes gives every pod a 64 MiB `/dev/shm`

| | |
|---|---|
| **Status** | **Fixed** — applied 15 Aug 2026, and the model has served through the Gateway since |
| **Hit at** | §14.2, the first `InferenceService`. Eleven restarts before the cause was found |
| **Observed** | 2026-08-15, `nid0003`, Digital Labs. vLLM `v0.27.1` CPU image, KServe 0.20 |
| **Severity** | **Blocks §14.** Nothing serves |
| **Cause** | **Ours, by omission.** A default nobody sets and everybody inherits |

## TL;DR

vLLM runs its API server and its inference engine as **two separate processes**, which pass work between them through a **shared-memory ring buffer**. That buffer lives in `/dev/shm`. Kubernetes gives every pod a `/dev/shm` of **64 MiB**; vLLM asks for **160 MiB**, does not get it, and exits.

```
RuntimeError: Insufficient space in /dev/shm: 160 MiB required, 64 MiB free.
Increase /dev/shm (e.g. --shm-size or --ipc=host).
```

**Fix:** mount a memory-backed `emptyDir` at `/dev/shm` in the `ServingRuntime`. Four lines of YAML.

## The terminology

**Shared memory.** Two processes normally cannot see each other's memory — that isolation is what makes processes safe. *Shared memory* is the deliberate exception: a region both can read and write, so they can exchange data without copying it through a pipe or a socket. It is the fastest form of inter-process communication there is, which is why anything moving tensors around reaches for it.

**`/dev/shm`.** On Linux, shared memory is exposed as a filesystem. Allocating shared memory means creating a file in `/dev/shm`; its size limit is the mount's size limit. `df -h /dev/shm` shows it like any other filesystem, because it is one — a `tmpfs`, which is a filesystem that lives in RAM.

**`tmpfs`.** A filesystem backed by memory rather than a disk. Fast, and gone when the machine (or container) stops.

**Why 64 MiB.** Docker chose that default many years ago; Kubernetes inherited it, and it is not configurable through a pod field. **Every container you have ever run has had a 64 MiB `/dev/shm` unless someone changed it.** Fine for almost everything, and much too small for machine-learning workloads — PyTorch dataloaders hit the same wall, usually as a much more confusing error than vLLM's.

**`emptyDir` with `medium: Memory`.** Kubernetes' way of providing a `tmpfs`. Mount one over `/dev/shm` and you replace the 64 MiB default with whatever size you specify. It is charged against the **pod's memory limit**, not the node's disk.

**Ring buffer.** A fixed-size queue that wraps around. Because it never grows, its size must be decided in advance — which is why vLLM asks for a specific number rather than allocating as it goes.

## The symptom

```
head$ kubectl -n inference get pods -o wide
NAME                                READY   STATUS             RESTARTS         AGE   IP            NODE
qwen05b-predictor-75ddf9ff8-2csjc   0/1     CrashLoopBackOff   11 (2m34s ago)   45m   10.244.2.17   nid0003
```

```
head$ kubectl -n inference describe pod $POD | sed -n '/kserve-container/,/Events/p'
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Sat, 15 Aug 2026 15:14:22 +0000
      Finished:     Sat, 15 Aug 2026 15:15:03 +0000
    Restart Count:  11
```

```
  Warning  Unhealthy  9m33s (x59 over 42m)  kubelet  Readiness probe failed:
    dial tcp 10.244.2.17:8000: connect: connection refused
```

⚠ **The readiness-probe warnings are noise, and they are the loudest thing in the events.** `connection refused` on `:8000` is the *consequence* of the container being dead, not a clue about why. Fifty-nine of them will scroll past the one line that matters.

📌 **The container ran for 41 seconds before dying.** That is long enough to look like a real startup — the image pulled, the process began, weights were located. Compare with a bad argument, which dies in under a second.

## The cause, in one line of traceback

```
head$ kubectl -n inference logs $POD -c kserve-container --previous --tail=80
(EngineCore pid=62)   File "…/vllm/v1/executor/multiproc_executor.py", line 151, in _init_executor
(EngineCore pid=62)     self.rpc_broadcast_mq = MessageQueue(
(EngineCore pid=62)   File "…/vllm/distributed/device_communicators/shm_broadcast.py", line 491, in __init__
(EngineCore pid=62)     self.buffer = ShmRingBuffer(n_local_reader, max_chunk_bytes, max_chunks)
(EngineCore pid=62)   File "…/vllm/distributed/device_communicators/shm_broadcast.py", line 244, in check_shm_free_space
(EngineCore pid=62)     raise RuntimeError(
(EngineCore pid=62) RuntimeError: Insufficient space in /dev/shm: 160 MiB required, 64 MiB free.
  Increase /dev/shm (e.g. --shm-size or --ipc=host).
(APIServer pid=1) RuntimeError: Engine core initialization failed. See root cause above.
  Failed core proc(s): {'EngineCore': 1}
```

**Read the two process prefixes.** `EngineCore pid=62` raised the real error; `APIServer pid=1` reported that its child failed. **PID 1 is what Kubernetes watches**, so the exit code and the last visible message belong to the process that only knew something else had died. `See root cause above` is doing a lot of work in that sentence.

🛑 **`--tail` must be large enough to reach past the second traceback.** The `APIServer` stack is ~50 lines and sits *below* the `EngineCore` one. A `--tail=30` shows you only the process reporting the failure, never the process that had it. We found this with `--tail=80` — by accident, from a mistyped `--tail=8080`.

## The investigation, including two wrong turns

Worth recording, because both wrong answers were plausible and one was expensive.

### Wrong turn 1 — "the CPU lacks AVX-512"

The nodes are **AMD EPYC 7713**, which is Zen 3 and has no AVX-512:

```
head$ talosctl -n 172.16.0.2 read /proc/cpuinfo | grep -m1 ^flags | tr ' ' '\n' \
      | grep -E '^(avx|sse4|f16c)' | sort -u
avx
avx2
f16c
sse4_1
sse4_2
sse4a
```

That is true, it is documented that vLLM's CPU image prefers AVX-512 ([vllm#18660](https://github.com/vllm-project/vllm/issues/18660)), and it fits a crash-looping pod neatly. An entire issue was drafted around it.

**What killed the hypothesis, in one command:**

```
head$ grep -m1 'model name' /proc/cpuinfo
model name      : AMD EPYC 7713 64-Core Processor
head$ grep -c avx512 /proc/cpuinfo
0
```

The **head node is the same processor**, with the same absence of AVX-512 — and `vllm serve --help` had already run there successfully in §14.1a. Importing vLLM loads its compiled extension, so if that extension needed AVX-512, the help text could never have printed.

⚠ **The evidence that refuted it was already on screen, twenty minutes earlier.** We ran a successful command on the head, then built a theory that the same command could not have succeeded. **When you form a hypothesis, check it against what you have already seen, not only against what you can go and measure.**

### Wrong turn 2 — "exit code 1 means the dtype was rejected"

Once AVX-512 was ruled out, `--dtype=bfloat16` was the next suspect: `avx512_bf16` is absent too, and a rejected dtype would raise a clean Python error and exit 1. Also plausible, also wrong.

📌 **Exit code 1 was a genuine clue, just not that one.** It said "a program decided to stop", which eliminated SIGILL (132) and OOM (137) — both real possibilities that the traceback would otherwise have had to compete with. **Exit codes narrow the field; they do not name the culprit.**

### What actually settled it

Reading the log. Not the events, not the exit code, not the CPU flags — the traceback, far enough back to reach the child process. Every earlier step was inference from surroundings; this was the program saying what was wrong, with the required and available sizes both printed.

⚠ **We spent two hypotheses on evidence that was one command away.** The `--previous` log had failed once with `unable to retrieve container logs`, we accepted that, and started theorising. **A log you failed to retrieve is not a log that does not exist** — the container had simply been garbage-collected, and the next restart made it available again.

## The fix

Give the pod a bigger `/dev/shm`, in the `ServingRuntime`:

```yaml
  containers:
    - name: kserve-container
      …
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi
```

```
head$ cd ~/techwatch-flux
head$ git add -A && git commit -m "Give vLLM a 2Gi /dev/shm" && git push
head$ flux reconcile kustomization infrastructure --with-source
head$ kubectl -n inference delete pod -l serving.kserve.io/inferenceservice=qwen05b
```

🛑 **Deleting the pod is required.** A `ServingRuntime` is a *template*. Changing it does not restart pods that already exist, and KServe does not roll the deployment for you — so `flux reconcile` will report success while the crash-loop continues, which reads as "the fix did not work".

⚠ **`medium: Memory` is charged against the pod's memory limit.** 2 GiB of `/dev/shm` plus `VLLM_CPU_KVCACHE_SPACE=4` plus ~1 GB of weights must fit inside `limits.memory: 12Gi`. It does, with room — but if you raise the KV cache later, this is one of the three things competing for that number.

## What does not work

| Idea | Why not |
|---|---|
| Raise `limits.memory` | The limit is not the constraint. `/dev/shm` is 64 MiB regardless of how much memory the pod may use — it is a separate mount with its own size |
| `--shm-size` or `--ipc=host` | What vLLM's error suggests, because it assumes Docker or podman. Neither exists in a Kubernetes pod spec; the `emptyDir` above is the equivalent |
| An `emptyDir` **without** `medium: Memory` | Gives you the node's disk mounted at `/dev/shm`. It may even work, slowly, and it silently defeats the purpose — shared memory that is not in memory |
| Restart the pod, or wait | The mount size does not change between attempts. Eleven restarts demonstrated this thoroughly |
| Reduce `--max-model-len` or the KV cache | Different pools of memory. The ring buffer's size does not depend on either |
| Set `--dtype=float32` | Unrelated, and untested — the process never got as far as reading the dtype |

## Checkpoint

The end-to-end evidence is captured, in [§14's checkpoint](../14-vllm-inference.md) — 15 Aug 2026, `tw-head`, serving from `nid0003`:

```
head$ tw_infer
MODEL=qwen05b  endpoint=http://172.16.0.3:30791  Host: qwen05b-inference.example.com

head$ time tw_ask "In two sentences, what is OpenCHAMI for?" 80
⟨80 tokens of fluent, confident, entirely invented text — see §14⟩

real    0m8.039s
```

**That is a stronger assertion than a `Running` pod.** The engine could only answer at all because `EngineCore` started, and `EngineCore` could only start because the ring buffer got its 160 MiB. A pod that reaches `1/1` proves the readiness probe passed; a *completion* proves the process that was crashing is doing its job.

Two narrower checks remain uncaptured. They are worth running once, because they isolate the mount from everything downstream of it:

```
head$ kubectl -n inference exec deploy/qwen05b-predictor -c kserve-container -- df -h /dev/shm
⟨captured on first run — expect Size 2.0G, not 64M⟩

head$ kubectl -n inference get pods
⟨captured on first run — expect 1/1 Running with RESTARTS not climbing⟩
```

⚠ **`df -h /dev/shm` is the assertion that the *mount* took effect**, separately from whether vLLM started. If it still says `64M`, the `volumeMounts` entry and the `volumes` entry disagree about the name, or you did not delete the pod. Worth having: a future `ServingRuntime` edit that silently drops the volume would show up here in one command instead of as another crash-loop.

### What broke next, and it was not what was predicted

The `/dev/shm` fix worked — `dshm` in the pod spec, `/dev/shm` mounted, the shm error gone. The pod then crash-looped again on something else:

```
(EngineCore pid=62)   File "…/vllm/utils/ompmultiprocessing.py", line 170, in _parse_omp_threads_bind_env
(EngineCore pid=62)     self.cpu_lists = [cr_utils.parse_id_list(s) for s in omp_cpuids_list]
(EngineCore pid=62)   File "…/vllm/utils/cpu_resource_utils.py", line 118, in parse_id_list
(EngineCore pid=62)     result.append(int(part))
(EngineCore pid=62) ValueError: invalid literal for int() with base 10: 'all'
```

`VLLM_CPU_OMP_THREADS_BIND` now takes a **list of CPU IDs** (`0-3`), and `all` is no longer accepted. **Fix: remove the variable.** A CPU limit is a scheduling quota, not a pinning, so the container still sees every host thread and any list hard-coded here would be a guess.

⚠ **This was predicted in outline and missed in detail.** §14.1a checks every command-line flag against the image before deploying, and all of them passed. It then says the two `VLLM_CPU_*` variables cannot be checked that way because environment variables have no `--help` — and one of those two was the next failure. **Flags can be interrogated; environment variables can only be tested.** The corollary is to keep the environment small, and to treat each variable as a claim that only starting the process can settle.

📌 **`--dtype=bfloat16` was expected to fail before this did, and did not.** `avx512_bf16` is absent on these processors, so it remained the standing prediction through two rounds — and the actual next fault came from somewhere else entirely both times. **A prediction that survives because you never reached it is not a prediction that was right.**

## Common failures

| Symptom | Cause / fix |
|---|---|
| `CrashLoopBackOff`, exit code 1, dies after ~40 s | this issue |
| `unable to retrieve container logs for containerd://…` | the previous container was garbage-collected. Wait for the next restart and retry — the log is not gone for good |
| The traceback names `EngineCore` but shows no cause | `--tail` is too small. The child's error is *below* the parent's stack; use `--tail=80` or more |
| Fixed it, still crash-looping | the `ServingRuntime` is a template. `kubectl delete pod` to force a new one from it |
| `df -h /dev/shm` still says `64M` | the volume name in `volumeMounts` does not match the one in `volumes` |
| Readiness probe `connection refused` on `:8000` | a symptom of the container being dead, not a cause. Look at `Last State`, not at the probe |
| Fixed `/dev/shm`, now `ValueError: invalid literal for int() … 'all'` | a different fault in the same runtime — `VLLM_CPU_OMP_THREADS_BIND` takes CPU IDs. Remove it |
| Two pods with different name hashes, both crash-looping | not a mess. A rolling update that cannot finish, because the new pod never goes `Ready` and so the old one is never retired. It resolves itself when one starts |

## The lesson

⚠ **A container inherits defaults nobody chose and nothing documents.** `/dev/shm` at 64 MiB is a Docker decision from years ago, carried into Kubernetes, invisible in every manifest, and wrong for an entire category of workload. It is not in the pod spec, so no amount of reading your own YAML will reveal it. **When something fails on resources, ask what the *container runtime* gave it, not only what you asked for.**

📌 **When a program prints the number it needs and the number it has, that is the end of the investigation.** vLLM's error names both sizes and the flag to change. We reached it after two hypotheses and eleven restarts because we were reading everything except the log — events, exit codes, CPU flags, upstream issue trackers. **Diagnose from the innermost error outwards, and treat everything else as context.**

⚠ **PID 1's error is rarely the interesting one.** In any multi-process container, the process Kubernetes watches is the one that *reports* the failure; the process that *had* it is a child, and its traceback is further up the log. Set `--tail` accordingly, and look for the process-ID prefixes.

## Related

- [§14 — Serving an LLM with vLLM](../14-vllm-inference.md) — where it is hit, and the runtime that carries the fix
- [issue 007](007-local-path-var-mnt-read-only-kubelet.md) — the other issue caused by an environment default rather than a mistake
- [DL-005](../DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) — the pod's memory budget, which `/dev/shm` now competes for
