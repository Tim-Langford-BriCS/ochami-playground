# 007 — the PVC that never binds: a directory the kubelet is not allowed to create

| | |
|---|---|
| **Status** | **Fixed.** §11.2 now carries the `extraMounts` step and the corrected path. No workaround outstanding |
| **Hit at** | §11.2, the storage smoke test |
| **Observed** | 10–13 Aug 2026, `tw-head` + `nid0001`–`nid0003`, Digital Labs (`techwatch-proto`) |
| **Versions** | Talos v1.13.0 (kernel 6.18.24-talos), Kubernetes v1.36.0, containerd 2.2.3, local-path-provisioner from `deploy/local-path-storage.yaml` on `master` |
| **Recognise it by** | A PVC that stays `Pending` **even though a pod is mounting it**, and `failed to provision volume … create process timeout after 120 seconds` in the provisioner log every 15 minutes |
| **Time to find** | Roughly two hours of live debugging, across five wrong hypotheses |

## TL;DR

§11.2 tells you to repoint local-path-provisioner away from Talos's read-only `/opt` and onto `/var`, which is writable. We picked **`/var/mnt/local-path-provisioner`**. That directory is writable *on the node* — and unwritable *by the kubelet*, which is the process that actually has to create it.

The fix is two parts, and the order matters:

1. Declare the directory as a kubelet `extraMounts` bind in the Talos machine config, on every node.
2. Point the provisioner's configmap at **`/var/local-path-provisioner`**.

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
head$ kubectl -n local-path-storage patch configmap local-path-config --type merge -p '
{"data":{"config.json":"{\"nodePathMap\":[{\"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\"paths\":[\"/var/local-path-provisioner\"]}]}"}}'
head$ kubectl -n local-path-storage rollout restart deploy/local-path-provisioner
```

Applied without a reboot; the kubelet restarts and the nodes flap `NotReady` for a few seconds.

## Concepts you need for this one

**`WaitForFirstConsumer`.** local-path's `StorageClass` does not provision anything when a PVC is created. It waits until a pod mounts the claim, so it can put the directory on the node the pod was scheduled to. A `Pending` PVC with no consumer is therefore *correct and permanent* — which is why §11.2 insists on a consumer pod as the actual test.

**The helper pod.** local-path-provisioner does not create directories itself. It has no access to the node's filesystem. Instead it launches a short-lived pod on the target node — image `busybox`, priority `system-node-critical` — whose job is to `mkdir` the volume directory and exit. It mounts two volumes: a `script` configmap holding `setup`/`teardown`, and a `data` `hostPath` pointing at the parent directory:

```yaml
volumes:
- hostPath:
    path: /var/mnt/local-path-provisioner/
    type: DirectoryOrCreate          # ← this is the whole issue
  name: data
```

**`hostPath` types.** A `hostPath` volume's `type` field decides what the kubelet checks *before* mounting. With `type` unset the kubelet performs no checks at all. With **`DirectoryOrCreate`** the kubelet creates the directory if it is absent — and the kubelet does that `mkdir` itself, as the kubelet, not as the pod. Remember this: it is what made one of our tests lie to us.

**Talos runs the kubelet in a container.** Talos is an immutable, API-driven OS with no shell. The kubelet is a container with a curated set of host paths bind-mounted into it — `/var/lib/kubelet`, `/var/log/pods`, `/var/run`, and so on — not the whole of `/var`. `machine.kubelet.extraMounts` is the supported way to add another one. This is the mechanism the whole issue turns on, and it has no equivalent on a conventional distribution, where the kubelet is a plain systemd unit that sees the real root filesystem.

## The symptom

A PVC that will not bind, with a pod waiting on it:

```
head$ kubectl get pvc smoke
NAME    STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
smoke   Pending                                      local-path     2d16h

head$ kubectl describe pod smoke | tail -3
Warning  FailedScheduling  4m41s  default-scheduler  running PreBind plugin "VolumeBinding": binding volumes: context deadline exceeded
```

⚠ **That scheduler message is a red herring, and it sent us the wrong way first.** `PreBind` runs *after* a node has been chosen. The scheduler has already done its job: it picked a node, stamped `volume.kubernetes.io/selected-node` on the PVC, and is now waiting for a PersistentVolume that never arrives. Nothing about the scheduler is wrong. The message describes a timeout, not a cause.

The cause is one layer down, in the provisioner:

```
head$ kubectl -n local-path-storage logs deploy/local-path-provisioner --tail=80
Creating volume pvc-900df…_default_smoke at nid0003:/var/mnt/local-path-provisioner/…
create the helper pod helper-pod-create-pvc-900df… into local-path-storage
… 120 seconds later …
failed to provision volume with StorageClass "local-path": create process timeout after 120 seconds
Giving up syncing claim because failures >= threshold  failures=15 threshold=15
```

Every 15 minutes, indefinitely. The provisioner is doing everything right; the helper pod never starts.

## The investigation, and why each step

The value here is not the answer — it is the order. Each hypothesis was chosen because it was the cheapest thing that could still explain *all* the evidence, and each result cut the search space.

### The constraints we were working under

Three facts shaped everything:

- **The helper pod is short-lived.** It exists for 120 seconds, then the provisioner deletes it. Every `describe` we tried came back empty because we happened to look between attempts.
- **Retries are 15 minutes apart** — `:01`, `:16`, `:31`, `:46`. A polling loop started at the wrong moment sees nothing for five minutes and looks like it has hung. Ours did.
- **The failure is silent.** Nothing crashes. No pod is `Error` or `CrashLoopBackOff`. The nodes are `Ready`, the provisioner is `1/1 Running`, and the only visible artefact is a pod stuck in `ContainerCreating` — a state with no logs, because no container has started.

### Hypothesis 1 — the `/opt` gotcha did not take

**Why plausible.** It is the failure §11.2 exists to prevent, and it produces read-only errors.

```
head$ kubectl -n local-path-storage get cm local-path-config -o jsonpath='{.data.config\.json}'
{"nodePathMap":[{"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/var/mnt/local-path-provisioner"]}]}
```

**Ruled out.** The patch had applied. ⚠ In hindsight this was the near miss of the whole investigation: we checked that the patch *applied* and stopped, without asking whether the value it applied was *correct*. A checkpoint that verifies your own instruction was followed cannot catch an instruction that was wrong.

### Hypothesis 2 — the provisioner is dead

**Why plausible.** Cheapest possible check.

`local-path-provisioner-85dfdd8c9c-jfw2s  1/1  Running  0  2d16h`. **Ruled out.**

### Hypothesis 3 — the nodes cannot pull images

**Why plausible.** This was the leading theory for two days, and it was a *good* theory. The helper pod's image is `busybox` from Docker Hub. The nodes sit on `172.16.0.x` and reach the internet only through the head's NAT ([issue 002](002-nftables-table-owned-by-podman.md) — a rule that had already broken once). A pod that cannot pull sits in `ContainerCreating` exactly as observed.

**How we tested it.** Not by inspecting the NAT, but by creating a pod we *own* — one that does the same pull and then stays put, instead of being deleted after 120 seconds:

```
head$ kubectl run nettest --image=docker.io/library/busybox --restart=Never --command -- sleep 3600
head$ kubectl describe pod nettest | sed -n '/Events:/,$p'
Normal  Pulled  39s  kubelet  Successfully pulled image "docker.io/library/busybox" in 1.924s. Image size: 2236931 bytes.
```

**Ruled out**, and cheerfully — it also cleared a worry about §§13–15, which pull multi-gigabyte vLLM images down the same path.

📌 **The technique is the transferable part.** When the thing you want to inspect keeps vanishing, stop trying to catch it. Build a copy that differs in exactly one respect — it doesn't get deleted — and inspect that instead.

### Hypothesis 4 — `nid0003` is damaged

**Why plausible.** Every failing attempt named `nid0003`, and `nettest` had landed on `nid0002`. Different node, different result — a real asymmetry. `nid0003` had also been caught by [issue 005](005-platform-storage-stall.md), so residual damage was credible; `Ready` only reflects the kubelet's heartbeat and would not necessarily show a containerd that cannot create sandboxes.

```
head$ kubectl run nettest3 --image=docker.io/library/busybox --restart=Never \
        --overrides='{"spec":{"nodeName":"nid0003"}}' --command -- sleep 3600
head$ kubectl get pod nettest3 -o wide
nettest3   1/1   Running   0   48s   10.244.2.3   nid0003
```

**Ruled out.** And later the fault reappeared on `nid0002`, confirming the node was never the variable — it was simply wherever the scheduler had put the consumer.

### Hypothesis 5 — the `hostPath` mount (right idea, wrong test)

By now the eliminations had done their work. The image, the network, the node and the priority class were all clear, so the difference had to be in the helper pod's own spec — and the conspicuous thing there is a `hostPath`.

**The test looked decisive:**

```
head$ kubectl -n local-path-storage run hptest --image=docker.io/library/busybox --restart=Never --overrides='{
  "spec":{"nodeName":"nid0003",
    "containers":[{"name":"hptest","image":"docker.io/library/busybox","command":["sleep","3600"],
      "volumeMounts":[{"name":"d","mountPath":"/data"}]}],
    "volumes":[{"name":"d","hostPath":{"path":"/var/mnt/local-path-provisioner"}}]}}'
head$ kubectl -n local-path-storage get pod hptest -o wide
hptest   1/1   Running   0   44s   10.244.2.4   nid0003
```

**Running.** So we ruled out the `hostPath` — **and that was a mistake.** The test pod's volume had no `type` field. The helper pod's has `type: DirectoryOrCreate`. With `type` unset the kubelet performs no checks and no `mkdir`; with `DirectoryOrCreate` it must create the directory before mounting. The two are not the same operation, and only the second one fails.

🛑 **A reproduction that differs from the original in any respect can only disprove things about the reproduction.** We had built a control that omitted the one field that mattered, and it returned a confident, wrong answer. Copy the spec; do not paraphrase it.

Two useful things did come out of this step. `local-path-storage` carries `pod-security.kubernetes.io/enforce: privileged`, which is why the helper pod is admitted at all — the same pod in `default` is rejected outright:

```
Error from server (Forbidden): pods "hptest" is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "d")
```

⚠ Note the difference from the `would violate PodSecurity "restricted:latest"` lines §11.2 tells you to expect. Those are *warnings* at the cluster warn level and block nothing. This is `Forbidden` from the enforce level. Same subsystem, entirely different consequence — read which word it used.

### Catching the helper pod

The remaining question was simply *what the kubelet says* while the helper hangs. Rather than wait 15 minutes for the failing claim's next retry, we created a **new** PVC — which provisions immediately, with no backoff — and started a poll loop straight after:

```
head$ for i in $(seq 1 90); do h=$(kubectl -n local-path-storage get pod -o name 2>/dev/null | grep helper | head -1); \
        if [ -n "$h" ]; then sleep 8; kubectl -n local-path-storage describe $h | sed -n '/Events:/,$p'; break; fi; sleep 2; done
```

And there it was:

```
Events:
  Type     Reason       Age               From     Message
  ----     ------       ----              ----     -------
  Warning  FailedMount  8s (x6 over 23s)  kubelet  MountVolume.SetUp failed for volume "data" :
                                                   mkdir /var/mnt/local-path-provisioner/: read-only file system
```

## Why it happens

`/var` on a Talos node is genuinely writable. From the node:

```
head$ talosctl -n 172.16.0.2 read /proc/mounts | grep -E ' /var '
/dev/vda4 /var xfs rw,seclabel,nosuid,nodev,relatime,inode64,logbufs=8,logbsize=32k,prjquota 0 0
head$ talosctl -n 172.16.0.2 ls /var
NODE         NAME
172.16.0.2   lib
172.16.0.2   log
172.16.0.2   mnt
172.16.0.2   run
172.16.0.2   system
```

`rw`. `/var/mnt` exists. Everything looks fine — **and that is the trap.** `talosctl` reports from the host's mount namespace. The `mkdir` is performed by the kubelet, which lives in a different one.

⚠ *Observed:* the `mkdir` fails with `read-only file system` while the host shows `/var` mounted `rw`. *Inferred:* Talos exposes `/var/mnt` into the kubelet's namespace read-only, because it is reserved as the mount point for declared **user volumes** rather than being general scratch space. The inference is consistent with the fix working, but we did not read the kubelet's own `/proc/self/mounts` to confirm it directly.

Either way the operational rule is the same, and it is the lesson worth carrying:

🛑 **On Talos, "is this path writable?" is not a question about the path. It is a question about *which process* is writing, and what that process can see.** A shell check answers it for the wrong process.

`/var/local-path-provisioner` with a matching `extraMounts` entry sidesteps this entirely: the bind is declared, so it exists in the kubelet's namespace by construction, and Talos creates the source directory as part of applying the config.

## Solutions

### What does not work

| Attempt | Why not |
|---|---|
| Waiting | The retry loop runs for ever. `failures=15 threshold=15` is per cycle, not a give-up |
| Deleting and recreating the PVC | It reprovisions, and fails identically. The stale `selected-node` annotation is a symptom, not the cause |
| `kubectl` anything | The failing operation is a `mkdir` inside the kubelet on a node. No cluster-level object controls it |
| Pointing the configmap at `/var/mnt/…` and adding `extraMounts` for it | Would probably work, but it puts a bind mount over Talos's user-volume mount point. Use a path Talos does not reserve |
| Declaring a Talos **user volume** at `/var/mnt/local-path-provisioner` | The "correct" use of `/var/mnt`, but it wants a disk or partition to back it. Overkill for a directory on the existing root filesystem |

### The fix

As in the TL;DR above: `extraMounts` on every node, then the configmap, then a rollout restart. `talosctl … patch machineconfig` applies it without a reboot — the kubelet restarts, running pods survive, and the node flaps `NotReady` briefly.

📌 **Apply it to the control plane too**, not just workers. `nid0001` is schedulable in this build, so it can host a volume like any other node.

## Checkpoint

```
head$ kubectl get pvc smoke
NAME    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
smoke   Bound    pvc-e372aa11-dc71-440c-bc7f-2470026b82dd   1Gi        RWO            local-path     83s

head$ kubectl exec smoke -- cat /d/f
ok

head$ talosctl -n 172.16.0.2 ls /var/local-path-provisioner
NODE         NAME
172.16.0.2   .
172.16.0.2   pvc-e372aa11-dc71-440c-bc7f-2470026b82dd_default_smoke
```

All three matter, and they prove different things. `Bound` says Kubernetes made a PV. `ok` says a container wrote through the mount and read it back. The `talosctl ls` says a real directory exists on a real node — the only one of the three that would have caught this issue, because the first two never happened at all.

The other nodes show only `.`, which is correct: local-path is *local*.

## Common failures

| Symptom | Cause / fix |
|---|---|
| PVC `Pending`, **no** consumer pod | Normal and permanent. `WaitForFirstConsumer` — §11.2 |
| PVC `Pending` **with** a consumer, `create process timeout after 120 seconds` | This issue. Check `extraMounts` and the configmap path |
| `PreBind plugin "VolumeBinding" … context deadline exceeded` | The same fault from the scheduler's side. Read the provisioner log instead |
| Helper pod in `ContainerCreating`, no events by the time you look | It lives 120 s. Trigger a fresh PVC and poll, or use `kubectl get events -n local-path-storage` |
| `Forbidden … violates PodSecurity "baseline:latest"` on a `hostPath` pod | Enforcement, not a warning. `local-path-storage` is labelled `enforce: privileged`; other namespaces are not |
| Volume works on one node, pod fails after rescheduling | Working as designed. local-path volumes exist on exactly one node |

## What this cost us, and what to take from it

Three days of a stuck PVC, most of it unattended, then about two hours of debugging across five hypotheses — four correctly eliminated, one eliminated *incorrectly* by a flawed control that we then had to revisit.

Three things generalise:

1. **When the evidence keeps disappearing, build something that stays.** The `nettest` pods answered in seconds what three days of `describe` had not.
2. **A control must differ in exactly one variable.** `hptest` omitted `type: DirectoryOrCreate` and confidently exonerated the actual culprit.
3. **Verifying that your instruction was followed is not verifying that it was right.** The configmap check passed at every stage of this investigation. It was the value inside it that was wrong.
