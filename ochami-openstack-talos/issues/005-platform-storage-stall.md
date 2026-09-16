# 005 — Root-disk write path wedged on `tw-head`; etcd stalled on `tw-cp1`

**Status: Open — suspected platform fault, not a tutorial fault.** Nothing here is caused by anything the tutorial does, and no fix exists on our side. Written up so the platform team has evidence rather than "my VM is slow".

| | |
|---|---|
| **Observed** | 11 Aug 2026, ~18:30–20:30 BST |
| **Probably started** | ~22:19 BST 10 Aug (last successful write from a working session) |
| **Cloud** | Digital Labs (`api.dl.acrc.bris.ac.uk`), project `techwatch-proto`, AZ `DL-Rack-5` |
| **Instances** | `tw-head` (Rocky 9.6), `tw-cp1` / `tw-w1` / `tw-w2` (Talos v1.13.0) |
| **Recognise it by** | SSH logins take minutes and land on a bare `-bash-5.1$` prompt; `systemctl` returns `Failed to retrieve unit state: Connection timed out`; load average pinned at exactly 61 |

## TL;DR

The **write** path to `tw-head`'s root disk (`/dev/vda4`, XFS) is hung. Reads still serve from page cache, so the box looks healthy until something tries to write — at which point it blocks in uninterruptible sleep and never returns. ~61 processes are now stuck this way, including PID 1.

Separately, `tw-cp1` — a **different instance, with no Cinder volume** — has etcd failing its health check with fsync-latency symptoms (12.7 s for an operation budgeted at 100 ms). That takes the Kubernetes API server down with it.

Two instances, one symptom family, no kernel-level I/O errors on either. The hypothesis is a degraded shared storage backend under Nova **ephemeral** disks.

**The question for the platform team: is Nova ephemeral storage on the same Ceph cluster as Cinder, and is that cluster healthy?**

## Evidence

All commands run as `rocky` on `tw-head` unless marked otherwise. Output is verbatim, trimmed for length.

### 1. The root disk's XFS threads are blocked — this is the core finding

```
head$ ps -eo state,pid,wchan:32,comm --sort=state | awk '$1=="D"' | head -30
D       1 -                                systemd
D     566 -                                xfsaild/vda4
D     768 -                                auditd
D     834 -                                NetworkManager
D   57845 -                                postgres
D   99670 -                                kworker/u17:0+xfs-cil/vda4
D   99702 -                                kworker/u17:1+flush-252:0
D  100001 -                                kworker/0:1+xfs-inodegc/vda4
D  100247 -                                kworker/2:0+xfs-sync/vda4
D  100874 -                                systemd-journal
   … ~15 further systemd-journal, 3 further postgres, plus dnf
```

`xfsaild`, `xfs-cil`, `xfs-inodegc`, `xfs-sync` and `flush-252:0` are all kernel threads for **`vda4`, the root filesystem**. Major 252 is the virtio-blk device backing `/dev/vda`. `D` state is uninterruptible — none of these can be killed, so no userspace recovery is possible.

### 2. Load is parked, not busy

```
head$ cat /proc/loadavg
61.00 61.00 61.00 1/377 101381
```

Three identical figures to two decimal places, with 1 of 377 threads running. This is not work; it is ~61 processes parked in `D` and never leaving.

### 3. It is not disk space, and not a read-only remount

```
head$ /usr/bin/df -h /
/dev/vda4        59G  3.7G   56G   7% /

head$ /usr/bin/findmnt -no OPTIONS /
rw,relatime,seclabel,attr2,inode64,logbufs=8,logbsize=32k,noquota
```

### 4. The Cinder volume is healthy — it is not the culprit

The one Cinder volume in this project (`tw-head-data`, 40 GB, `/dev/vdb`, mounted `/data`) was the first suspect and is exonerated:

```
head$ cat /sys/block/vdb/inflight
       0        0

head$ sudo timeout 10 dd if=/dev/vdb of=/dev/null bs=4k count=1 iflag=direct; echo "exit=$?"
4096 bytes (4.1 kB, 4.0 KiB) copied, 0.000808604 s, 5.1 MB/s
exit=0
```

Nothing queued, sub-millisecond read. Note the `sudo` on that command took **over 60 seconds** to return while `dd` itself reported 0.0008 s — because `sudo` writes an audit record, and that write blocks. That timing split is itself good evidence for a write-path fault.

### 5. systemd itself is unreachable

```
head$ systemctl is-active coredhcp bss smd
Failed to retrieve unit state: Connection timed out
```

Expected, given PID 1 is in `D`.

### 6. Networking is fine — this is not a network fault

```
head$ ip -br a
eth0             UP             192.168.200.91/24
eth1             UP             172.16.0.254/24
```

`talosctl` reaches `tw-cp1` over that interface and gets a full response, so the provisioning network works end to end.

### 7. `tw-cp1`: etcd is stalled, and the API server with it

```
head$ talosctl -n 172.16.0.1 service
NODE         SERVICE      STATE     HEALTH   LAST CHANGE    LAST EVENT
172.16.0.1   etcd         Running   Fail     4h28m3s ago    Health check failed: context deadline exceeded
172.16.0.1   kubelet      Running   OK       24h0m21s ago   Health check successful
   … apid, containerd, cri, machined, trustd, udevd all Running/OK
```

```
head$ talosctl -n 172.16.0.1 logs etcd | tail
{"level":"warn","caller":"txn/util.go:93","msg":"apply request took too long",
 "took":"12.733422891s","expected-duration":"100ms",
 "prefix":"read-only range ","request":"key:\"health\" ",
 "error":"etcdserver: request timed out"}
{"level":"warn","caller":"etcdserver/v3_server.go:1030",
 "msg":"timed out waiting for read index response (local node might have slow network)","timeout":"7s"}
{"level":"warn","caller":"etcdserver/server.go:939",
 "msg":"Failed to check current member's leadership","error":"context deadline exceeded"}
```

**This is a single-member etcd** (one control-plane node), so raft agreement should be instantaneous and leadership is never in question. Timeouts of this shape on a single member point at the etcd process being unable to make progress — characteristically WAL `fsync` latency. etcd is the most fsync-sensitive process in the stack and is normally the first thing to fail when disk latency degrades.

Consequence, from the kubelet log — every request to the local API server endpoint fails:

```
head$ talosctl -n 172.16.0.1 logs kubelet | tail
"Error updating node status, will retry","err":"error getting node \"nid0001\":
 Get \"https://127.0.0.1:7445/api/v1/nodes/nid0001?timeout=10s\":
 net/http: request canceled (Client.Timeout exceeded while awaiting headers)"
```

```
head$ talosctl -n 172.16.0.1 get staticpodstatus
kube-system/kube-apiserver-nid0001            1   True
kube-system/kube-controller-manager-nid0001   2   True
kube-system/kube-scheduler-nid0001            5   False
```

The API server process is up but cannot serve, because etcd underneath it will not answer. That is why `kubectl` times out.

### 8. No kernel I/O errors on `tw-cp1`

```
head$ talosctl -n 172.16.0.1 dmesg | grep -iE 'error|blocked|timeout|i/o' | tail
```

Returns **only** DHCP renewal failures and kubelet static-pod-controller timeouts — no I/O errors, no blocked tasks. Consistent with storage that is *slow* rather than *failing*: a degraded backend produces latency, not kernel error messages.

### 9. All instances are ACTIVE at the hypervisor level

```
devbox$ openstack server list
tw-w2    ACTIVE   tw-prov=172.16.0.3
tw-w1    ACTIVE   tw-prov=172.16.0.2
tw-cp1   ACTIVE   tw-prov=172.16.0.1
tw-head  ACTIVE   tw-ext=10.3.0.185, 192.168.200.91; tw-prov=172.16.0.254
```

Nothing crashed, migrated or rebooted from Nova's point of view.

## The causal chain

```
degraded storage backend under Nova ephemeral disks
  │
  ├── tw-head: XFS log write path hangs on /dev/vda4
  │     └── everything that writes blocks in D state — journald, auditd,
  │         postgres, NetworkManager, systemd(1) — load 61
  │           └── OpenCHAMI services (CoreDHCP → SMD → postgres) stop serving
  │                 └── tw-cp1 "DHCP request/renew failed" every 40 s  ⚠ see below
  │
  └── tw-cp1: etcd WAL fsync stalls (12.7 s vs 100 ms budget)
        └── kube-apiserver cannot serve
              └── kubectl times out; kube-scheduler static pod READY=False
```

⚠ **Time-sensitive consequence.** `tw-cp1` has been failing DHCP renewals every 40 seconds since at least 20:13:

```
[talos] DHCP request/renew failed {"operator": "dhcp4",
 "error": "unable to receive an offer: got an error while the discovery
 request: no matching response packet received", "link": "enp3s0"}
```

The node still holds `172.16.0.1` — a lease does not drop the instant renewal fails — but **when it expires the node loses its address**, and with it `talosctl`, the API server endpoint and worker connectivity. This is a direct knock-on from the head being wedged (§3 of the tutorial disables Neutron DHCP; CoreDHCP on the head is the only DHCP server on that wire). It is the strongest argument for recovering the head promptly.

## Alternatives not ruled out

Recorded because the evidence does not exclude them:

- **CPU steal / hypervisor contention** rather than storage could explain etcd's stalls on `tw-cp1`, though it does not explain XFS log threads blocked on `tw-head`. `/proc/pressure/*` is unavailable on this kernel (PSI not compiled in), so that avenue is closed from inside the guest.
- **A `tw-head`-local XFS or virtio-blk bug** independent of any backend issue. Weaker, because it requires two unrelated faults on two instances in the same window.
- **The two faults being genuinely unrelated.** Possible. The single shared factor is the storage substrate, which is why that is the question being asked.

## What we need from the platform team

1. Is **Nova ephemeral** storage (instance root disks) backed by the same Ceph cluster as Cinder, or by hypervisor-local disk?
2. Was there a storage incident overlapping **~22:00 BST 10 Aug through 20:30 BST 11 Aug**? A colleague mentioned a BC5 storage issue; we cannot see whether the window matches.
3. `ceph -s` / `ceph health detail`, and any slow-ops or blocked-request counters on the OSDs serving `DL-Rack-5`.

## How to confirm storage is healthy again

The failing path is **writes**, so a read test proves nothing. Test writes, with a timeout so it cannot hang the shell:

```
head$ timeout 30 dd if=/dev/zero of=/var/tmp/wtest bs=1M count=64 oflag=direct conv=fsync && rm -f /var/tmp/wtest
```

- **Now**: hangs, or exits 124.
- **Recovered**: completes in a second or two with a sensible throughput figure.

Corroborate with all three of:

```
head$ cat /proc/loadavg                                  # want < 1, not 61
head$ ps -eo state,comm | awk '$1=="D"'                  # want no output
head$ timeout 10 sync; echo "exit=$?"                    # want exit=0, fast
```

And on the node, that etcd has stopped complaining:

```
head$ talosctl -n 172.16.0.1 logs etcd | grep -c 'took too long'   # want this to stop growing
head$ talosctl -n 172.16.0.1 service etcd                          # want HEALTH=OK
```

⚠ The `D`-state processes on `tw-head` **will not clear on their own even after storage recovers** — uninterruptible sleep survives the underlying fault being fixed in some cases, and PID 1 is among them. Expect to reboot regardless.

## Recovery, once storage is confirmed healthy

Order matters: the head first, because `tw-cp1`'s DHCP depends on it.

```
devbox$ openstack server reboot --hard tw-head
```

**Hard, not soft** — a graceful reboot asks PID 1 to shut down, and PID 1 is blocked. `/data`'s fstab entry is `nofail`, so a missing Cinder volume will not hold up the boot.

Then, in order:

```
head$   systemctl is-active coredhcp bss smd postgresql        # all active
head$   talosctl -n 172.16.0.1 dmesg | grep -i dhcp | tail     # renewals succeeding again
head$   talosctl -n 172.16.0.1 service etcd                    # HEALTH=OK
head$   kubectl get nodes                                       # three nodes Ready
```

If etcd is still unhealthy once its disk is demonstrably fine, reboot the node **gracefully** — this preserves everything, per §10.7:

```
head$ talosctl -n 172.16.0.1 reboot
```

🛑 **Never `talosctl reset` or `openstack server rebuild` `tw-cp1`.** It is a single-member etcd with no replicas; either command destroys the cluster and means rebuilding from §10.1. `reboot` is safe and is the only node-level action warranted here.

## Impact on the tutorial

None to the written material — everything is committed and pushed (`f2d1641` on `origin/ochami-openstack`). §8's boot assets and §9's BSS payloads are on the head's root disk, readable, last modified 7 Aug, so there is nothing recent to lose.

Work stopped part-way through **§11.2** (storage classes). It resumes at the consumer-pod step, `11-cluster-foundations.md:94`, once `kubectl` answers again.
