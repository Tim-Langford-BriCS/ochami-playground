# 001 — `versitygw-bootstrap` fails: botocore derives an AWS region from the OpenStack AZ

📗 **In a hurry, or just want it working?** Read [the TL;DR](001-versitygw-bootstrap-aws-region-TLDR.md) instead — why a region exists at all, the fix, and the commands. This file is the long form: exact code paths, the alternatives weighed and rejected, and a read-only proof that the fix cascades nowhere.

| | |
|---|---|
| **Status** | Worked around locally — fix is in [§5.5](../05-install-openchami.md#step-55--start-the-s3-gateway-and-registry) and in the IaC's `01-head-openchami.yml`. Upstream report **filed and withdrawn** on 2026-08-20 ([#7](https://github.com/OpenCHAMI/versitygw-quadlet/issues/7), [#8](https://github.com/OpenCHAMI/versitygw-quadlet/pull/8)) and still to be re-filed → [`notes/todo-002`](../notes/todo-002-versitygw-region-openstack-az-upstream.md) |
| **Hit at** | §5.5 — Start the S3 gateway and registry |
| **Observed** | 2026-08-03 14:51 UTC, `tw-head`, Digital Labs (`techwatch-proto`), AZ `DL-Rack-5` |
| **Fix verified** | 2026-08-03 16:03 UTC on the same head node — `bootstrap: COMPLETE`, both buckets created, no other unit disturbed |
| **Versions** | `versitygw` v1.7.0 (`ghcr.io/versity/versitygw:latest`, built 2026-07-15), `versitygw-quadlet` RPM, Rocky 9.6 |
| **Affects** | **Anywhere the availability zone does not truncate to the gateway's own region** — every Digital Labs rack, and AWS outside `us-east-1`. Not OpenStack-only, and the symptom differs by AZ name: see [Who else sees this](#who-else-sees-this) |
| **Corrected** | 2026-08-18 — the double-digit-rack prediction in this file was wrong. Reproduced properly in a Lima VM; see [What the original draft claimed](#what-the-original-draft-claimed-and-why-it-was-wrong) |

## The error

The last command of §5.5 fails:

```
head$ sudo systemctl enable --now versitygw-bootstrap.service
Created symlink /etc/systemd/system/multi-user.target.wants/versitygw-bootstrap.service → /etc/systemd/system/versitygw-bootstrap.service.
Job for versitygw-bootstrap.service failed because the control process exited with error code.
```

`systemctl status` gives the exit code but not the cause:

```
× versitygw-bootstrap.service - Bootstrap VersityGW IAM users and buckets
     Active: failed (Result: exit-code) since Mon 2026-08-03 14:51:44 UTC
    Process: 21978 ExecStart=/usr/local/libexec/versitygw-bootstrap.sh (code=exited, status=255/EXCEPTION)
```

The whole diagnosis is one line, buried among a dozen verbose `podman` container-lifecycle records in the journal:

```
Aug 03 14:51:44 tw-head.novalocal versitygw-bootstrap.sh[22184]: Provided region_name 'DL-Rack-' doesn't match a supported format.
```

That message comes from **botocore**, the Python library under the `aws` CLI — not from versitygw, not from OpenCHAMI, and not from anything in this tutorial.

⚠ **`journalctl -xeu` is the wrong command here.** It shows only systemd's own epilogue (`the unit has entered the 'failed' state`) and scrolls the one useful line off the top. Use `sudo journalctl -u versitygw-bootstrap.service --no-pager -n 60` and read for a line attributed to `versitygw-bootstrap.sh`.

## Why it occurs

`/usr/local/libexec/versitygw-bootstrap.sh` creates one bucket per user with the `aws` CLI, passing an endpoint but **no region**:

```bash
aws --profile "${ROOT_PROFILE}" \
    --endpoint-url "${GATEWAY_ENDPOINT}" \
    s3api create-bucket --bucket "${bucket}"
```

The credentials file the script writes a few lines earlier holds only keys — no `region`, and no `/root/.aws/config` is created at all:

```bash
cat > /root/.aws/credentials <<EOF
[${ROOT_PROFILE}]
aws_access_key_id     = ${ROOT_ACCESS}
aws_secret_access_key = ${ROOT_SECRET}
EOF
```

So botocore works down its region-resolution chain — `--region` flag, `AWS_REGION`, `AWS_DEFAULT_REGION`, the profile's `region` key — finds nothing, and reaches its last resort: **the EC2 instance metadata service**. On a real EC2 instance that is a reasonable guess. OpenStack implements the same EC2-compatible metadata API, so the query succeeds — and answers with the OpenStack availability zone:

```
head$ curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone
DL-Rack-5
```

An AWS availability zone is its region plus a trailing letter — `us-east-1a` is in region `us-east-1` — so botocore derives the region by **stripping the last character**. Applied to a Digital Labs zone name:

```
DL-Rack-5   →   DL-Rack-
```

botocore then validates it, and rejects it. The check is a DNS-label pattern — roughly `(?!-)[a-zA-Z0-9-]{1,63}(?<!-)` — because the region is normally substituted into an endpoint hostname such as `s3.us-east-1.amazonaws.com`, and **a DNS label may not end in a hyphen**. Hence `doesn't match a supported format`.

The script runs under `set -euo pipefail`, so the failed `aws` call aborts everything immediately. It had already processed the first user as far as creating the IAM account:

```
bootstrap: processing 'slurmd'
  generating new credentials
  creating IAM user
  creating bucket slurmd-bucket          ← dies here
```

The second user, `fabricmanager`, is never touched.

### The code, with line numbers

Useful to have precisely, because the mechanism spans two vendored libraries and reads as magic otherwise. Package `awscli2-2.33.0-1.el9_8.noarch` on Rocky 9.6; the CLI bundles its own `botocore` under `awscli/` rather than using the system one, so nothing here is on `python3`'s import path — `import botocore` at a shell prompt fails.

**1. The resolution chain** — `/usr/lib/python3.9/site-packages/awscli/clidriver.py:286-296`. Providers are tried in order, and the metadata service is the last resort:

```python
            EnvironmentProvider(
                name='AWS_DEFAULT_REGION',
                env=os.environ,
            ),
            ScopedConfigProvider(
                config_var_name='region',
                session=self.session,
            ),
            IMDSRegionProvider(self.session),
        ]
```

This is why setting either environment variable fixes it: both sit *above* `IMDSRegionProvider` in the chain, so it is never reached.

**2. The derivation** — `/usr/lib/python3.9/site-packages/awscli/utils.py:164-207`. The URL path and the one-character truncation:

```python
class InstanceMetadataRegionFetcher(IMDSFetcher):
    _URL_PATH = 'latest/meta-data/placement/availability-zone/'
    ...
    def _get_region(self):
        token = self._fetch_metadata_token()
        response = self._get_request(
            url_path=self._URL_PATH,
            retry_func=self._default_retry,
            token=token,
        )
        availability_zone = response.text
        region = availability_zone[:-1]
        return region
```

`availability_zone[:-1]` at **line 207** is the whole bug in one expression. It encodes "an AZ is a region plus one trailing letter", true of every AWS zone and of no OpenStack zone.

**3. The validation and the raise** — `/usr/lib/python3.9/site-packages/awscli/botocore/utils.py:1167-1174`:

```python
def validate_region_name(region_name):
    """Provided region_name must be a valid host label."""
    if region_name is None:
        return
    valid_host_label = re.compile(r'^(?![0-9]+$)(?!-)[a-zA-Z0-9-]{,63}(?<!-)$')
    valid = valid_host_label.match(region_name)
    if not valid:
        raise InvalidRegionError(region_name=region_name)
```

The docstring names the reason: a region must be a valid **host label**, because it is substituted into endpoint hostnames such as `s3.us-east-1.amazonaws.com`. `(?<!-)$` is the negative lookbehind that rejects a trailing hyphen — the clause `DL-Rack-` fails. (`(?!-)` rejects a leading one and `(?![0-9]+$)` rejects an all-numeric label.)

**4. The message** — `/usr/lib/python3.9/site-packages/awscli/botocore/exceptions.py:406`:

```python
    fmt = "Provided region_name '{region_name}' doesn't match a supported format."
```

So the path is: `clidriver.py:294` → `utils.py:207` (`DL-Rack-5` → `DL-Rack-`) → `botocore/utils.py:1174` (raise) → `exceptions.py:406` (the string you saw).

### A second, harmless upstream bug in the same script

Worth recording because it wastes a minute of every run and makes the log misleading. The script's readiness gate is:

```bash
echo "bootstrap: waiting for VersityGW at ${GATEWAY_ENDPOINT}..."
for i in {1..60}; do
  if curl -sSf "${GATEWAY_ENDPOINT}" >/dev/null 2>&1; then
    echo "bootstrap: gateway is up."
    break
  fi
  sleep 1
done
```

`curl -f` fails on any HTTP status ≥ 400, and an unauthenticated `GET /` against an S3 endpoint returns **403** by design:

```
head$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7070
403
```

So the condition can never be true, `gateway is up` is never printed, and the loop always burns the full 60 × `sleep 1` before falling through and continuing anyway. Measured: the journal shows `waiting for VersityGW` at 14:50:42 and the first real work at 14:51:43 — 61 seconds.

```
head$ sudo journalctl -u versitygw-bootstrap.service | grep -c "gateway is up"
0
```

It is harmless because the loop has no `else` and the gateway genuinely is up, so the script proceeds correctly. But it means **the readiness check provides no protection at all** — if versitygw were slow to start, the script would fall through at 60 seconds regardless and fail for a different reason. A correct gate would accept any HTTP response, e.g. `curl -s -o /dev/null -w '%{http_code}' … | grep -qE '^[2-4]'`.

⚠ **Do not copy `curl -f` as a health check for an S3 endpoint.** It reports a correctly-secured gateway as down. The tutorial's §5.12 verification originally made the same mistake.

**Two things that make this harder to spot than it should be:**

1. **The existence check fails silently first.** Immediately before the create, the script asks whether the bucket already exists using the same `aws` binary — but wraps it so that *any* failure reads as "absent":

   ```bash
   if aws ... s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
   ```

   That call dies of the identical region error. Its output is discarded, so the log shows the script confidently deciding to create a bucket rather than reporting that it could not look one up.

2. **Nothing you typed is wrong.** The region never appears in the tutorial, in `tw-vars-env.sh`, or in any OpenCHAMI config. It is inferred from cloud metadata by a library three layers down.

## Who else sees this

⚠ **This section was rewritten on 2026-08-18. The version it replaces was wrong**, and wrong in
the direction that matters: it predicted a failure that does not happen and missed one that
does. The corrected picture comes from reproducing every case in a disposable Rocky 9 Lima VM
with a fake metadata service — see
[`runbooks/upstream-openchami-prs.md`](../runbooks/upstream-openchami-prs.md). What the original
got right is that **the AZ name decides your symptom**; what it got wrong is which symptom.

**Not OpenStack only.** The script sets no region anywhere, so botocore must find one, and the
outcome depends entirely on what it lands on:

| Availability zone | botocore derives | Run 1 | Run 2 |
|---|---|---|---|
| *(no metadata service at all)* | nothing → for S3, falls back to the pseudo-region `aws-global`, which **signs `us-east-1`** | ✅ works | ✅ works |
| `us-east-1a` (AWS, gateway's own region) | `us-east-1` | ✅ works | ✅ works |
| `eu-west-2a` (**AWS, any other region**) | `eu-west-2` — valid label, wrong region | ✅ works | ❌ `BucketAlreadyExists` |
| `DL-Rack-11`, `DL-Rack-12` | `DL-Rack-1` — valid label, wrong region | ✅ works | ❌ `BucketAlreadyExists` |
| `DL-Rack-5`, `DL-Rack-6` | `DL-Rack-` — **invalid** label | ❌ `InvalidRegionError` | ❌ same |

All five rows reproduced 2026-08-18, with `rack-5` / `rack-11` / `eu-west-2a` / `us-east-1a`
standing in for the AZ names.

### Two failure modes, and only one of them is loud

**Mode 1 — the derived region is not a valid host label.** `DL-Rack-5` → `DL-Rack-`, rejected by
botocore's own `validate_region_name` on the trailing hyphen. The request is never sent. This is
[the error at the top of this file](#the-error), it happens on run 1, and it happens every run.

**Mode 2 — the derived region is valid but wrong.** This is the one the original draft got
backwards. It predicted `AuthorizationHeaderMalformed`; what actually happens is:

- `head-bucket` returns **`400 Bad Request`** — not 404, not 200. A HEAD response carries no
  body, so botocore's `S3RegionRedirectorv2` cannot read the expected region out of the error
  and cannot retry.
- The bootstrap script's `>/dev/null 2>&1` on that call turns *any* failure into "bucket absent".
- `create-bucket` **does** self-heal, because its error body names the expected region, so
  botocore re-signs and retries. Measured directly — `Credential=…/rack-1/s3` followed by
  `Credential=…/us-east-1/s3`. **So run 1 succeeds and everything looks fine.**
- On run 2 the bucket now exists, the healed `create-bucket` returns `BucketAlreadyExists`, and
  `set -e` fails the unit.

🛑 **`versitygw-bootstrap.service` is `RemainAfterExit=yes` and `WantedBy=multi-user.target`, so
once enabled this is a failed unit on every boot after the first** — against a script whose own
header promises *"All operations are idempotent and safe to re-run."*

⚠ **This is the [002 shape](002-nftables-table-owned-by-podman.md) again: it works when you run
it and breaks later.** A colleague on rack 11 completes §5.5 cleanly, and finds
`versitygw-bootstrap` failed after the next reboot with an error naming neither regions nor
availability zones. Same root cause as ours, same one-line fix, no shared search term.

### What the original draft claimed, and why it was wrong

📌 Kept because the reasoning is the transferable part.

The prediction was that `DL-Rack-1` would be sent and rejected server-side with
`AuthorizationHeaderMalformed`. Half of that is true: versitygw **does** enforce the region, and
forcing one by hand still produces exactly that error —

```
head$ aws --profile vgw-root --region rack-1 --endpoint-url http://127.0.0.1:7070 s3api list-buckets
An error occurred (AuthorizationHeaderMalformed) when calling the ListBuckets operation:
The authorization header is malformed; the region "rack-1" is wrong; expecting "us-east-1"
```

— which is what the earlier signing test measured, and it remains good evidence about
*versitygw*. It is simply not what the bootstrap produces, because **the client corrects itself
before the operator ever sees it**. We had measured the server's behaviour and assumed the
client would present it unchanged.

⚠ **A component's documented behaviour is not the same as the behaviour you will observe through
two layers of client library.** The retry that hid it is a botocore feature nobody configured,
switched on by default, invisible without `--debug`.

📌 **And the second wrong claim was ours from the other direction:** a working note briefly said
a host with no metadata service would fail with `NoRegionError`. It does not — S3 falls back to
`aws-global` and signs `us-east-1`, which is exactly what the gateway expects, so it works.
**The libvirt lab is unaffected**, and no longer needs the "untested elsewhere" caveat this
section used to carry.

## Solutions

### Adopted — a systemd drop-in

```
head$ sudo mkdir -p /etc/systemd/system/versitygw-bootstrap.service.d
head$ sudo tee /etc/systemd/system/versitygw-bootstrap.service.d/10-aws-region.conf <<'EOF'
[Service]
Environment=AWS_EC2_METADATA_DISABLED=true
Environment=AWS_REGION=us-east-1
Environment=AWS_DEFAULT_REGION=us-east-1
EOF
head$ sudo systemctl daemon-reload
head$ sudo systemctl restart versitygw-bootstrap.service
```

`AWS_EC2_METADATA_DISABLED=true` is the part that fixes the cause: botocore stops consulting the metadata service, so no AZ name can ever be mangled into a region again — on any rack.

The two region variables then supply the value the **gateway itself** is configured with. `us-east-1` is not a placeholder: versitygw runs with `VGW_REGION=us-east-1`, the region forms part of the SigV4 credential scope, and a mismatch is rejected as `AuthorizationHeaderMalformed`. It is also what [§8.3](../08-talos-assets-and-config.md) sets for your interactive shell and what the IaC's `04-talos-assets.yml` already used, so all four places agree. Both spellings are set because AWS CLI v1 reads `AWS_DEFAULT_REGION` and v2 reads `AWS_REGION`.

A drop-in rather than an edit to `/etc/systemd/system/versitygw-bootstrap.service` because that unit is owned by the `versitygw-quadlet` RPM and a `dnf` upgrade would overwrite an edit while leaving a drop-in alone.

**Re-running is safe.** The script's own header claims idempotency and the code supports it: per-user credentials persist in `/etc/versitygw/users.d/<user>.env` and are reused (`using existing credentials`), the IAM user is checked with `list-users` before creation, and the bucket is checked with `head-bucket`. A half-completed run leaves nothing that a second run trips over.

### Alternative — a region in `/root/.aws/config`

```
head$ sudo mkdir -p /root/.aws
head$ printf '[profile vgw-root]\nregion = us-east-1\n' | sudo tee /root/.aws/config
```

Works, and survives the script because the script writes `credentials`, not `config`. Two reasons it wasn't adopted: it still lets botocore query the metadata service in other contexts, and it is invisible — a file in `/root` explains nothing to whoever finds this failing in six months, whereas a named drop-in with a comment does.

### Rejected — a region that survives the truncation, e.g. `DL-Rack-5a`

Tempting, and better motivated than a dummy: `AWS_REGION=DL-Rack-5a` is a valid host label, it names the rack the head is actually on, and it looks like an AWS AZ so the truncation would be *correct* rather than merely tolerated. It also reads as honest where `us-east-1` reads as a lie.

It does not work, because the region is **not cosmetic** — it is part of the SigV4 credential scope (`…/20260803/us-east-1/s3/aws4_request`), so it feeds the signing-key derivation and the server checks it. Tested on `tw-head`, read-only, both regions against the same endpoint and profile:

```
head$ sudo AWS_EC2_METADATA_DISABLED=true aws --region us-east-1 \
        --endpoint-url http://127.0.0.1:7070 --profile vgw-root s3 ls
rc=0

head$ sudo AWS_EC2_METADATA_DISABLED=true aws --region DL-Rack-5a \
        --endpoint-url http://127.0.0.1:7070 --profile vgw-root s3 ls
An error occurred (AuthorizationHeaderMalformed) when calling the ListBuckets
operation: The authorization header is malformed; the region "DL-Rack-5a" is
wrong; expecting "us-east-1"
rc=254
```

The gateway's own region is fixed, and it is what the client must match:

```
head$ sudo podman inspect versitygw --format '{{json .Config.Env}}'
"VGW_REGION=us-east-1"

head$ sudo podman exec versitygw versitygw --help | grep -- --region
   --region value, -r value     s3 region string (default: "us-east-1") [$VGW_REGION]
```

So the correct value is *whatever the server is configured with*, and `us-east-1` is that value — not an arbitrary placeholder. Adopting `DL-Rack-5a` would mean also setting `VGW_REGION` to match in the RPM-owned `versitygw.container` quadlet, restarting the gateway, and updating §8.3's s3cmd `bucket_location` and the IaC's `AWS_DEFAULT_REGION` — four coupled changes to make one string prettier, in a field nothing ever reads. It would also swap a loud failure for a subtler one: `AuthorizationHeaderMalformed` on every S3 call looks like a credentials problem, not a configuration problem.

⚠ **The general lesson**: on an S3-compatible gateway the region is a shared constant between client and server, not a description of where anything is.

### Rejected — patch the bootstrap script

Adding `--region us-east-1` to the two `aws` calls in `/usr/local/libexec/versitygw-bootstrap.sh` is the most direct fix and the most fragile: the file belongs to the RPM and the next upgrade silently reverts it, at which point the failure returns and the notes saying it was fixed are worse than no notes.

### Rejected — block the metadata service

Firewalling `169.254.169.254` would stop the bad lookup and break `cloud-init`, which needs that address for the SSH keys, hostname and the static provisioning-NIC configuration described in [§4](../04-head-node-instance.md). Never do this on a cloud instance.

### The real fix, upstream

`versitygw-bootstrap.sh` should pass `--region` explicitly, or set `region` in the profile it writes. It knows it is talking to a local S3-compatible gateway on `127.0.0.1:7070` where the region is meaningless, so relying on cloud metadata to supply one is a latent bug on **any** non-AWS cloud, not just this one. Worth reporting to [`OpenCHAMI/versitygw-quadlet`](https://github.com/OpenCHAMI/versitygw-quadlet) with the AZ table above, since it shows the failure is data-dependent and explains why it has gone unnoticed.

**Not yet reported** — the report is drafted, with the diff and a validation plan, in [`notes/todo-002-versitygw-region-openstack-az-upstream.md`](../notes/todo-002-versitygw-region-openstack-az-upstream.md).

📌 **Better than `--region`: the script already has the answer.** `versitygw-gensecrets.sh` writes `VGW_REGION=us-east-1` into `/etc/versitygw/secrets.env`, and `versitygw-bootstrap.service` already loads that file with `EnvironmentFile=`. So `$VGW_REGION` is sitting unused in the script's environment — exporting `AWS_REGION="${VGW_REGION}"` alongside `AWS_EC2_METADATA_DISABLED=true` keeps client and server in agreement *by construction*, rather than by two hard-coded strings that can drift. Verified against upstream `main` on 2026-08-13.

## Where the fix lives

| Place | What it does |
|---|---|
| [§5.5](../05-install-openchami.md#step-55--start-the-s3-gateway-and-registry) | 🔀 deviation block, placed *before* the `systemctl` commands so readers never see the failure |
| §5's Common failures table | one row keyed on the literal error string |
| `ochami-openstack-talos-iac/ansible/playbooks/01-head-openchami.yml` | the drop-in as two tasks before *§ 5.5 — Bootstrap Versity users*, with `daemon_reload` gated on whether it changed. The IaC had the identical defect and would have failed at the same step |

---

# Appendix — proving the fix is safe before running it

The fix restarts a service on a head node that already has a half-built control plane on it, so it is worth establishing *before* running it that nothing can cascade, nothing gets overwritten, and no credentials change. Every command below is read-only. All outputs were captured from `tw-head` on 2026-08-03, after the failure and before the fix.

Seven things could plausibly go wrong. Each is ruled out by evidence.

## 1. Nothing is overwritten — both paths are new

```
head$ ls -la /etc/systemd/system/versitygw-bootstrap.service.d
ls: cannot access '/etc/systemd/system/versitygw-bootstrap.service.d': No such file or directory
```

The directory does not exist, so `mkdir -p` creates it and `tee` writes to a path nothing occupies. No existing configuration is replaced.

## 2. The RPM's unit file is untouched

```
head$ rpm -qf /etc/systemd/system/versitygw-bootstrap.service
versitygw-quadlet-0.1.0-1.el9.noarch
```

The unit belongs to that package; the drop-in path does not. So `rpm -V` stays clean, and a later `dnf upgrade` neither reverts our change nor conflicts with it. This is the concrete reason a drop-in beats editing the unit — see [Rejected — patch the bootstrap script](#rejected--patch-the-bootstrap-script) for the same argument applied to the script.

## 3. Restarting cannot cascade to another service

```
head$ systemctl list-dependencies --reverse versitygw-bootstrap.service
versitygw-bootstrap.service
● └─multi-user.target
○   └─graphical.target

head$ systemctl show versitygw-bootstrap.service \
        -p Requires -p Wants -p PartOf -p BoundBy -p ConsistsOf \
        -p RequiredBy -p WantedBy -p PropagatesReloadTo -p Conflicts
Requires=versitygw-gensecrets.service versitygw.service sysinit.target system.slice
Wants=
PartOf=
RequiredBy=
WantedBy=multi-user.target
BoundBy=
ConsistsOf=
Conflicts=shutdown.target
PropagatesReloadTo=
```

`PartOf=`, `BoundBy=`, `ConsistsOf=`, `RequiredBy=` and `PropagatesReloadTo=` are **all empty** — those are the only mechanisms by which restarting a unit propagates to others. The one non-empty relation points the other way: bootstrap depends on gensecrets and the gateway, not the reverse. Both are already running:

```
head$ systemctl is-active versitygw.service versitygw-gensecrets.service registry.service
active
active
active
```

A satisfied `Requires=` is a no-op, so the gateway and registry are neither stopped, started nor restarted.

## 4. The root S3 credentials §8 depends on will not change

This is the one with real consequences: if the root keys were regenerated, §8's uploads would fail against buckets created under the old ones.

```
head$ sudo stat -c '%n  mtime=%y' /etc/versitygw/secrets.env
/etc/versitygw/secrets.env  mtime=2026-08-03 14:50:21.722456616 +0000

head$ systemctl show versitygw-gensecrets.service -p ActiveState -p Result -p ExecMainStatus
ActiveState=active
Result=success
ExecMainStatus=0
```

`secrets.env` is written by `versitygw-gensecrets.service`, a **separate** one-shot that has already completed successfully. Bootstrap only reads it, via `EnvironmentFile=`. Restarting bootstrap does not re-run gensecrets, so those keys are frozen.

## 5. The existing user's credentials are reused, not regenerated

```
head$ sudo ls -la /etc/versitygw/users.d/
-rw-------. 1 root root 144 Aug  3 14:51 slurmd.env
```

The script's first branch is `if [[ ! -f "${user_file}" ]]`. That file exists, so the test is false and it takes the else:

```bash
  else
    . "${user_file}"
    access="${VGW_ACCESS_KEY}"
    echo "  using existing credentials"
```

The IAM user created during the failed run keeps the same access key — which matters, because step 2 identifies that user *by* the key. `fabricmanager.env` is absent, so it gets fresh credentials, correctly, having never existed.

## 6. There is no data to destroy

```
head$ sudo podman exec versitygw ls -la /data
total 0
drwxr-xr-x 2 root root 6 Dec  4  2025 .
```

The gateway's backend is empty — no buckets yet. `create-bucket` therefore cannot overwrite a bucket or its objects, and the worst outcome of a botched run is *no* bucket rather than a damaged one.

## 7. The environment change is scoped to one unit

```
head$ sudo grep -rl "AWS_" /etc/systemd/system/
(nothing)
```

`Environment=` in a drop-in applies only to that unit's own processes, so `AWS_EC2_METADATA_DISABLED=true` cannot reach `cloud-init`, `NetworkManager` or anything else — and nothing else on the host sets `AWS_*` for it to collide with or shadow. The metadata service at `169.254.169.254` stays fully reachable for everything that legitimately needs it, which is the distinction that makes this acceptable where [firewalling that address](#rejected--block-the-metadata-service) is not: we are telling one program to stop asking a question, not removing the answer.

## What this appendix does *not* prove

⚠ **Step 4 of the script is unguarded.** Unlike the IAM-user and bucket checks, it runs unconditionally on every invocation:

```bash
  # 4. Assign bucket owner
  vgw_admin change-bucket-owner --bucket "${bucket}" --owner "${access}"
```

For the run described here it was harmless, as predicted — `assigning bucket owner` completed for both users on the 16:03 run, the buckets having just been created. Whether `change-bucket-owner` is idempotent on a *later* re-run, when the owner is already correct, is still **not tested**. If a future re-run fails, this is the line to look at. The script's header claims full idempotency; steps 1–3 verifiably deliver it, step 4 is so far only known to work first-time.

⚠ **`daemon-reload` not restarting running services** is systemd's documented contract, not something the outputs above demonstrate. The empty `PropagatesReloadTo=` is consistent with it, but this is cited behaviour rather than measured behaviour.

## Rollback

```
head$ sudo rm -rf /etc/systemd/system/versitygw-bootstrap.service.d
head$ sudo systemctl daemon-reload
```

That restores the unit to exactly its packaged definition. Nothing in the fix touches data, networking, security groups, or any shared cloud resource — it is one file under `/etc` and one service restart.
