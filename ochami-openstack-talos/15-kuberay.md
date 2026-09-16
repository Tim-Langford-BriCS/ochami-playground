# §15 — Ray and KubeRay

*(Time: ~20 minutes. On the head node, committing to Git. Optional for a working inference endpoint — §14 already gave you one — but it is in the TechWatch design and it is the layer that will matter most once the hardware is heterogeneous.)*

## Concepts

**Ray** is a distributed execution framework. You write Python; Ray schedules it across a cluster, moving objects between processes and machines for you. In the inference world it shows up in three guises:

| Ray piece | What it does |
|---|---|
| **Ray Core** | tasks and actors: the general-purpose distributed scheduler. This is the "heterogeneous workload scheduler" in the TechWatch stack diagram |
| **Ray Serve** | a serving layer built on Core: compose multiple models and Python steps into one deployment graph, each part scaled independently |
| **Ray Data / Train** | batch inference and training, on the same cluster |

**KubeRay** is the Kubernetes operator that runs Ray. It gives you CRDs:

- **`RayCluster`** — a long-lived head pod plus worker pods, autoscaling;
- **`RayJob`** — run a script on a cluster, then tear it down;
- **`RayService`** — a Ray Serve application, managed with zero-downtime updates.

### Why bother, when §14 works?

Three reasons, and only the third matters today:

1. **Serving pipelines, not endpoints.** A real inference service is rarely one model. Retrieval, re-ranking, a guardrail model, a summariser — each with different hardware appetites. KServe gives you one endpoint per model and `InferenceGraph` to chain them; Ray Serve lets you express the whole graph as Python with per-step scaling. For agentic workloads (LangGraph, CrewAI in the design's top layer) that is a better fit.
2. **Model parallelism across nodes.** When a model doesn't fit on one accelerator, vLLM's tensor/pipeline parallelism needs a distributed runtime underneath, and Ray is the one it uses. This is not a 0.5 B model problem; it is very much a Llama-3-70B-on-4×MI210 problem.
3. **Heterogeneous scheduling — the actual reason it's in the design.** Ray schedules on *custom resources*. A task can ask for `{"CPU": 4, "GPU": 1, "accelerator_type:RTX": 1}` and land only where that exists. With Gaudi3, RTX and MI210 nodes in one cluster, "put this workload on the right silicon" becomes a scheduling constraint rather than a manual placement decision. That is the capability TechWatch is buying.

**Ray Serve or KServe?** Not either/or, and worth being clear because it confuses people:

| | KServe (§13) | Ray Serve |
|---|---|---|
| Unit of thought | a model, declared in YAML | a Python application graph |
| Who writes it | platform/ops | ML engineers |
| Scaling | HPA per model | per-deployment, inside Ray |
| Multi-node model parallelism | delegates to the engine (which uses Ray) | native |
| Coexist? | yes — a `RayService` can sit behind a KServe endpoint, and KServe's own multi-node serving uses Ray underneath |

For this POC we stand up a `RayCluster`, prove it schedules, and stop there. Ray Serve as the *primary* serving path is a legitimate later experiment — precisely the kind the rig exists for.

## Step 15.1 — The KubeRay operator

```
head$ cd ~/techwatch-flux
head$ cat > infrastructure/controllers/kuberay.yaml << 'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: kuberay
  namespace: flux-system
spec:
  url: https://ray-project.github.io/kuberay-helm/
  interval: 1h
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kuberay-operator
  namespace: kuberay-system
spec:
  interval: 1h
  targetNamespace: kuberay-system
  install:
    createNamespace: true
  chart:
    spec:
      chart: kuberay-operator
      version: "1.6.0"
      sourceRef:
        kind: HelmRepository
        name: kuberay
        namespace: flux-system
EOF
head$ cat > infrastructure/controllers/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kserve-source.yaml
  - kserve.yaml
  - kuberay.yaml
EOF
head$ git add -A && git commit -m "Install KubeRay operator 1.6.0" && git push
head$ flux reconcile kustomization infrastructure --with-source
head$ kubectl -n kuberay-system get pods
```

The chart installs the CRDs for `RayCluster`, `RayJob`, `RayService` and `RayCronJob` along with the operator. (If your cluster splits CRD and operator permissions, install CRDs separately with `kubectl create -k` and pass `--skip-crds` — see the KubeRay chart README.)

## Step 15.2 — A small `RayCluster`

Sized for our CPU-only workers. Note the deliberately modest numbers: the point is to see scheduling work, not to run anything heavy.

```
head$ mkdir -p apps/ray
head$ cat > apps/ray/raycluster.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ray
---
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: tw-ray
  namespace: ray
spec:
  rayVersion: "2.56.0"
  headGroupSpec:
    rayStartParams:
      dashboard-host: "0.0.0.0"
    template:
      spec:
        containers:
          - name: ray-head
            image: rayproject/ray:2.56.0
            ports:
              - { containerPort: 6379,  name: gcs }
              - { containerPort: 8265,  name: dashboard }   # design slide port
              - { containerPort: 10001, name: client }
            resources:
              requests: { cpu: "1", memory: 3Gi }
              limits:   { cpu: "2", memory: 4Gi }
  workerGroupSpecs:
    - groupName: cpu-workers
      replicas: 1
      minReplicas: 1
      maxReplicas: 3
      template:
        spec:
          containers:
            - name: ray-worker
              image: rayproject/ray:2.56.0
              resources:
                requests: { cpu: "1", memory: 3Gi }
                limits:   { cpu: "2", memory: 4Gi }
EOF
head$ cat > apps/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - inference/qwen05b.yaml
  - ray/raycluster.yaml
EOF
head$ git add -A && git commit -m "A small CPU RayCluster" && git push
head$ flux reconcile kustomization apps --with-source
head$ kubectl -n ray get rayclusters,pods
```

⚠ **`rayVersion` and the image tag must match.** A mismatch produces obscure GCS-connection failures rather than a clear error. Both say `2.56.0` above; keep them in step when you bump.

⚠ **Ray head pods want more memory than you'd guess.** The head runs the GCS, the dashboard and the autoscaler. Under ~3 GiB it gets OOM-killed intermittently, which looks like a network problem. If quota is tight, take memory from the worker group, not the head.

## Step 15.3 — Prove it schedules

```
head$ kubectl -n ray exec -it deploy/tw-ray-head -- python -c "
import ray; ray.init(address='auto')
print('nodes:', len(ray.nodes()))
print('resources:', ray.cluster_resources())

@ray.remote
def where(): 
    import socket; return socket.gethostname()

print('tasks ran on:', set(ray.get([where.remote() for _ in range(20)])))
"
```

✅ **Checkpoint**

```
⟨captured on first run — expect:
   nodes: 2
   resources: {'CPU': 4.0, 'memory': …, 'node:…': 1.0, …}
   tasks ran on: {'tw-ray-head-…', 'tw-ray-cpu-workers-…'}  ← more than one name⟩
```

Two distinct hostnames in that last set is the whole point: work was distributed, not run locally. Note that `ray.cluster_resources()` has **no `GPU` key** — that absence is what §16 fixes on real hardware, and it is worth seeing now so the difference is concrete.

The dashboard, through §11.5's tunnel pattern:

```
head$   kubectl -n ray port-forward svc/tw-ray-head-svc 8265:8265
devbox$ ssh -i ~/.ssh/tw_ed25519 -N -L 8265:localhost:8265 rocky@${TW_HEAD_FIP}
# then open http://localhost:8265
```

Port 8265 is the one the TechWatch design slide reserves in its security-group list — this is what it is for.

## Step 15.4 — What this becomes with accelerators

Nothing to run today; this is the shape §16 fills in. Once nodes have GPUs and a device plugin advertises them, worker groups become hardware-specific:

```yaml
  workerGroupSpecs:
    - groupName: rtx-workers
      replicas: 2
      template:
        spec:
          nodeSelector:
            nvidia.com/gpu.product: NVIDIA-RTX-PRO-6000-Blackwell
          containers:
            - name: ray-worker
              image: rayproject/ray:2.56.0-gpu
              resources:
                limits:
                  nvidia.com/gpu: 4
    - groupName: mi210-workers
      # …amd.com/gpu: 2, on the R760XA nodes
    - groupName: gaudi-workers
      # …habana.ai/gaudi: 4, on the XE7740
```

Then a workload asks for what it needs and Ray places it:

```python
@ray.remote(num_gpus=1, accelerator_type="NVIDIA_RTX_PRO_6000")
def generate(prompt): ...
```

That is the heterogeneous-scheduling capability in one line, and it is why Ray is in the design rather than just KServe.

## Common failures

| Symptom | Cause / fix |
|---|---|
| Head pod `Pending`, `Insufficient memory` | see the ⚠ above — the head needs ~3 GiB. Shrink the worker group instead |
| Workers never join; GCS connection errors in worker logs | `rayVersion` ≠ image tag, or the head's service isn't resolving. `kubectl -n ray get svc` |
| `ray.init(address='auto')` fails inside the head pod | the head isn't fully started — `kubectl -n ray logs deploy/tw-ray-head` |
| Dashboard blank over the tunnel | `dashboard-host: "0.0.0.0"` missing from `rayStartParams` (it defaults to localhost) |
| `RayCluster` created but no pods | the operator isn't running: `kubectl -n kuberay-system get pods`, then `flux get helmreleases -A` |
| Everything `Pending` after adding Ray | you are out of cluster capacity. Ray and vLLM together need more than two small workers — scale down `qwen05b` to `minReplicas: 0` temporarily, or add a worker (§7.3) |

Next: [§16 — Heterogeneous hardware](16-heterogeneous-hardware.md)
