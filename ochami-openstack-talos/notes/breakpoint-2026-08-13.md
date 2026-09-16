# Breakpoint — 2026-08-13, 14:00 UTC

> ✅ **Superseded later the same day.** The `smoke` PVC problem below is solved and written up as [issue 007](../issues/007-local-path-var-mnt-read-only-kubelet.md) — the cause was §11.2's own `/var/mnt` path, not the NAT. The leading hypothesis recorded here was wrong. Everything above the fold about head-node and cluster health still stands.

**Stopped in §11.2, part way through proving storage works.** The cluster and the head node are both healthy; the one open fault is a PVC that will not bind.

Resume by running [`where-am-i.sh`](where-am-i.sh) on the head node — it re-derives everything below from live state, so trust it over this file if they disagree.

```
devbox$ scp -i ~/.ssh/tw_ed25519 notes/where-am-i.sh rocky@${TW_HEAD_FIP}:~/
head$ bash ~/where-am-i.sh
```

## What is healthy, and how we know

| | Evidence, 2026-08-13 |
|---|---|
| Head node storage | 4 KiB direct write in **1.7 ms**; `ps -eo state \| grep -c '^D'` → **0**; load `0.01` |
| Head node uptime | `up 10 days, 18:59` — **never rebooted.** It recovered on its own when the platform storage came back |
| OpenCHAMI | 13 containers `Up`, `openchami.target` `active` |
| DHCP | `Cache updated with 10 EthernetInterfaces and 10 Components` — a real TLS fetch from SMD |
| Kubernetes | `nid0001` (control-plane), `nid0002`, `nid0003` all `Ready`, v1.36.0 |
| etcd | single member, own leader, `RAFT INDEX 922435` = `RAFT APPLIED INDEX`, `ERRORS` empty |
| API server | `readyz check passed` in **50 ms** |

📌 **On etcd's `apply request took too long` warnings:** they are now 147–173 ms against a 100 ms threshold. That is ordinary jitter. During [issue 005](../issues/005-platform-storage-stall.md) the same message read **12.7 seconds**. Two orders of magnitude apart — do not confuse them.

## What we fixed this session

**[Issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) — the TLS certificate had been expired since 7 August.** 24-hour lifetime, no renewal mechanism. Re-issued, and a renewal timer installed:

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager
NEXT                        LEFT     LAST PASSED UNIT                       ACTIVATES
Fri 2026-08-14 03:13:14 UTC 13h left -    -      openchami-cert-renew.timer openchami-cert-renew.service
```

⚠ **Check this actually fired.** As of this breakpoint it had only been run by hand; `LAST` was still `-`. First thing on resuming:

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager     # LAST should now be populated
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 -servername demo.openchami.cluster 2>/dev/null \
        | openssl x509 -noout -dates                                  # notAfter in the future
```

If `LAST` is still empty and the certificate has expired again, the timer is not working and issue 006's durable fix needs revisiting before anything else.

## The open problem — `smoke` will not bind

§11.2's consumer pod was applied on 10 August at ~21:48, minutes before the crash. It has been `Pending` ever since, **and it is still failing now on a healthy cluster** — so this is a real fault, not outage debris.

```
head$ kubectl get pvc smoke
NAME    STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
smoke   Pending                                      local-path     2d16h

head$ kubectl describe pod smoke | tail -8
Warning  FailedScheduling  4m41s  default-scheduler  running PreBind plugin "VolumeBinding": binding volumes: context deadline exceeded
```

### What is already ruled out

- **Not the Talos `/opt` gotcha.** The configmap is correctly repointed:
  `{"nodePathMap":[{"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/var/mnt/local-path-provisioner"]}]}`
- **Not a dead provisioner.** `local-path-provisioner-85dfdd8c9c-jfw2s  1/1  Running  0  2d16h`
- **Not the scheduler.** The failure is at **PreBind**, which means a node was already chosen. The scheduler stamps `volume.kubernetes.io/selected-node` on the PVC and waits for a PV that never appears, then times out — every ~10 minutes, indefinitely.

### Leading hypothesis — the nodes cannot pull images

local-path provisions by launching a short-lived **helper pod** on the target node to `mkdir -p` the directory. That helper pod's image is `busybox`, from Docker Hub. The nodes sit on `172.16.0.x` and reach the internet only through the head's NAT (§5.12, and [issue 002](../issues/002-nftables-table-owned-by-podman.md)). If that path is broken the helper pod sits in `ImagePullBackOff`, no directory is created, no PV appears, and PreBind times out exactly as observed.

*Untested.* The `smoke` pod itself also uses `busybox`, so it would fail the same way even after binding.

### Next commands

```
head$ kubectl -n local-path-storage logs deploy/local-path-provisioner --tail=60
head$ kubectl get pvc smoke -o jsonpath='{.metadata.annotations}'; echo
head$ kubectl get events -A --sort-by=.lastTimestamp | tail -20
head$ sudo nft list ruleset | grep -i -B2 -A4 masquerade
head$ sysctl net.ipv4.ip_forward
```

🛑 **If it is the NAT, fix it before §§13–15.** Those sections pull multi-gigabyte vLLM images down the same path. Better to find it now on a 4 MB busybox.

## Where §11 stands

| Step | State |
|---|---|
| 11.1 — check what you have | ✅ done |
| 11.2 — storage | ⚠ **blocked.** local-path installed, configmap patched. Default-class annotation **unverified**. `smoke` PVC + pod not binding |
| 11.3 — metrics-server | not started (unverified) |
| 11.4 — Gateway API, cert-manager, Envoy Gateway | not started (unverified) |
| 11.5 — tunnel from the laptop | not started |

Once `smoke` binds, the assertion is `Bound` plus:

```
head$ kubectl exec smoke -- cat /d/f
ok
```

then clean up (**pod first** — a PVC with a live consumer hangs in `Terminating`):

```
head$ kubectl delete pod smoke && kubectl delete pvc smoke
```

## Outstanding, not urgent

- **Stale `systemd` failed unit on the head.** `systemctl is-system-running` → `degraded`, from `session-94.scope` — an SSH session killed during the storage stall. Cosmetic. Clear with `sudo systemctl reset-failed`. *Not yet done.*
- **Uncommitted in the working tree**: `issues/005-platform-storage-stall.md`, the `issues/README.md` edits, `issues/006-…`, and everything in `notes/`. An earlier commit attempt was declined.
- **Placeholders to backfill**: §11 lines 111, 158, 231, 234, 237, 240, 243. §10 lines 78, 172, 189.
- **§10 discrepancy**: *Common failures* says the bootscript "sleeps 10"; the real one sleeps 30. One-word fix, not yet made.
- **A published artifact of issue 005 exists** at `https://claude.ai/code/artifact/ef3ffe80-a4ad-470b-92ed-ffbc22133cd6`. It was published without being asked for. It is private to the account and has not been shared, but it carries internal hostnames, `172.16.0.x` addressing, `api.dl.acrc.bris.ac.uk`, `techwatch-proto` and `DL-Rack-5`. **Decide whether to delete it** — manage at `claude.ai/code/artifacts`. The markdown in `issues/005` is the version to circulate.

## Two upstream reports to write

Both have their evidence captured and neither has been filed:

- [`todo-001`](todo-001-openchami-cert-renewal-upstream.md) — OpenCHAMI's renewal timer is packaged but never enabled (the "wrong order" claim recorded here on 13 Aug was disproved on 18 Aug)
- [`todo-002`](todo-002-versitygw-region-openstack-az-upstream.md) — `versitygw-bootstrap.sh` lets botocore derive an AWS region from the OpenStack AZ

## The lesson from this session

⚠ **Date every error before blaming it on the incident you just had.** Coming back to a recovered head node, the certificate error was throwing every 30 seconds and read like fresh damage from the storage stall. It was not — the certificate died on 7 August, the storage stalled on the 11th. One `notAfter` field separated "caused by the outage" from "was already broken, and would have stayed broken".
