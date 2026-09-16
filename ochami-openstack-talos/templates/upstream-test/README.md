# Test harness for the upstream OpenCHAMI PRs

Copied into a disposable Rocky 9 Lima VM to reproduce the two upstream bugs and prove their
fixes. Driven by [`runbooks/upstream-openchami-prs.md`](../../runbooks/upstream-openchami-prs.md),
which has the procedure and the captured results.

🛑 **None of this runs against `tw-head`.** It exists so the bugs can be demonstrated on a laptop
with no OpenStack and no production cluster.

| File | For | Used by |
|---|---|---|
| `imds.py` | A fake EC2 instance metadata service on `169.254.169.254`, serving whatever availability zone you name | Bug 1 |
| `reset.sh` | Return the host to a pre-bootstrap state, so each run is a clean reproduction | Bug 1 |
| `run-case.sh` | Run one labelled case — reset, start the fake IMDS, run the bootstrap, print the result with podman's event noise stripped | Bug 1 |
| `harness.sh` | Dummy systemd units mirroring `acme-register` → `acme-deploy` → `haproxy` at two upstream refs, to test whether a restart propagates down the chain | Bug 2 |

## Getting them in

The Mac home is mounted **read-only** at the same path inside the VM, so copy rather than edit
in place:

```
vm$ cp /Users/tl5297/work/brics/the-palaestra/tutorials/ochami-openstack-talos/templates/upstream-test/* ~/
vm$ sudo ip addr add 169.254.169.254/32 dev lo     # once per VM, for imds.py
```

⚠ **`limactl shell` mangles heredocs** containing `$(…)` or backslash-continuations — a script
written that way arrives corrupted with no error. Copy files in, or pipe base64:

```
mac$ base64 -i harness.sh | limactl shell <vm> -- bash -c 'base64 -d > ~/harness.sh'
```

## `imds.py`

```
vm$ sudo nohup python3 ~/imds.py rack-5 >/dev/null 2>&1 &
vm$ curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/; echo
rack-5
vm$ sudo pkill -f imds.py
```

The AZ values that matter, and what botocore derives by stripping the last character:

| Argument | Derived region | Models |
|---|---|---|
| `rack-5` | `rack-` — invalid host label | OpenStack single-digit rack. **The failure we hit** |
| `rack-11` | `rack-1` — valid but wrong | OpenStack double-digit rack |
| `eu-west-2a` | `eu-west-2` — valid but wrong | **AWS outside the gateway's region** |
| `us-east-1a` | `us-east-1` | AWS, the only case that works unpatched |

📌 **It answers `PUT` with 404 on purpose.** That is how OpenStack's metadata service behaves —
no IMDSv2 token endpoint — so botocore falls back to IMDSv1 and the derivation happens. Answer
`PUT` successfully and you are modelling AWS instead.

## `harness.sh`

Prints, for each ref, the modelled dependencies and which units actually run when
`systemctl restart t-register` is issued — the operation `openchami-cert-renewal.service`
performs. This is what disproved the deploy-before-issue theory: propagation reaches haproxy on
**both** refs, via `Requires=`/`After=` rather than the `PartOf=` links added later.

⚠ **No `%` may appear in a unit's `ExecStart`.** systemd reads it as a specifier — `%H` becomes
the hostname — so `date +%H:%M:%S` silently mangles the command and the unit appears not to run
at all. The harness logs through the `/usr/local/bin/t-log` helper for exactly this reason. The
first version of this script looked correct, passed `bash -n`, and produced a false negative on
both refs.

It cleans up after itself. To leave the units in place for inspection, comment out the final
`teardown`.
