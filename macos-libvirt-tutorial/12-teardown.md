# §12 — Teardown

*(Upstream: guide §5. Time: ~2 minutes.)*

Tear down in layers, innermost first — or skip straight to step 12.3,
which vaporises everything at once.

## Step 12.1 — Compute nodes and head (on the host)

```
host$ virsh destroy compute1
host$ virsh undefine --nvram compute1
host$ virsh destroy head
host$ virsh undefine --nvram head
```

`destroy` = power off; `undefine` = forget the VM. `--nvram` also removes
the per-VM UEFI variable store that aarch64 VMs carry — without it,
undefine refuses. The compute node leaves nothing else behind (diskless!);
the head leaves its disk files, so optionally:

```
host$ rm -f ~/cluster/head.qcow2 ~/cluster/seed.iso ~/cluster/rocky9-base.qcow2
```

## Step 12.2 — Networks (on the host)

```
host$ virsh net-destroy openchami-net-internal
host$ virsh net-undefine openchami-net-internal
host$ virsh net-destroy openchami-net-external
host$ virsh net-undefine openchami-net-external
```

## Step 12.3 — The whole lab (on the Mac)

```
mac$ limactl stop ochami-host       # keep it, powered off
      # ...or...
mac$ limactl delete --force ochami-host   # gone entirely
```

Deleting the Lima VM removes *everything* built in §§2–10 in one stroke —
the only artefacts remaining on your Mac are `~/ochami-tutorial/` (one
YAML file) and Lima's cached Rocky image (`limactl prune` clears caches).

## ✅ Checkpoint

```
mac$ limactl list | grep ochami-host || echo "gone"
gone
```

## Where next

- Boot `compute2`–`compute5`: they're already in SMD — §10.1 with the next
  MAC (`52:54:00:be:ef:02`) is literally all it takes.
- Switch off the debug image: repeat §8 with the `compute/base` S3 prefix
  and power-cycle (upstream tutorial Part 2.8) — then nodes are reachable
  *only* via the cloud-init root key, like production.
- The same lab as one-command IaC: `~/work/brics/ochami-iac` (OpenTofu +
  Ansible), and the tutorial-topology bash lab in `~/work/brics/ochami-lab`
  — [Appendix B](appendix-b-mapping.md) maps every section here to both.
- Upstream extensions: NFS root, dynamic discovery with magellan, Slurm —
  [tutorial Part 3](https://openchami.org/docs/tutorial/).

Next: [§13 — Summary: what we built and decided](13-summary.md)
