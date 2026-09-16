# todo-002 — `versitygw-bootstrap.sh` lets botocore guess an AWS region from cloud metadata

| | |
|---|---|
| **Upstream** | [`OpenCHAMI/versitygw-quadlet`](https://github.com/OpenCHAMI/versitygw-quadlet) — `SOURCES/versitygw-bootstrap.sh` |
| **State** | **Filed and withdrawn, 2026-08-20.** Issue [#7](https://github.com/OpenCHAMI/versitygw-quadlet/issues/7) and PR [#8](https://github.com/OpenCHAMI/versitygw-quadlet/pull/8) were opened without authorisation and closed the same day — see [Filing history](#filing-history). CI had passed (DCO + `build-rpm` on el8/el9/el10). **To be re-filed by hand.** The fix and evidence below are unaffected |
| **Found** | 2026-08-03, `tw-head`, Digital Labs (`techwatch-proto`), AZ `DL-Rack-5` |
| **Our side** | [issue 001](../issues/001-versitygw-bootstrap-aws-region.md) · [TL;DR](../issues/001-versitygw-bootstrap-aws-region-TLDR.md); worked around in §5.5 and in the IaC's `01-head-openchami.yml` |
| **Impact** | The bootstrap works only where botocore's guessed region happens to equal `VGW_REGION`. Everywhere else it either aborts on run 1 or fails on **every run after the first** — including on AWS outside the gateway's region. See [What actually happens](#what-actually-happens-measured) |
| **Upstream HEAD checked** | **2026-08-17.** Bug still present on `main`; no region set anywhere in the script. Fix built and verified against `main` on 2026-08-18 |

✅ **The fix is one line, and the correct value is already in the script's environment.** See [Proposed fix](#proposed-fix). That is the reason this is worth filing rather than just working around.

⚠ **Revised twice — 2026-08-17 from source, then 2026-08-18 from reproduction.** Three claims
were wrong and are corrected inline where they occurred: the bug is not OpenStack-specific; a
host with no metadata service does **not** fail; and double-digit racks do **not** produce
`AuthorizationHeaderMalformed`. The fix also credited the wrong environment variable.
🛑 **The 18 August pass is the one to trust — it is the only one that ran anything.**

---

## The bug

`versitygw-bootstrap.sh` creates one bucket per user with the `aws` CLI, passing an endpoint but **no region**:

```bash
# SOURCES/versitygw-bootstrap.sh, ~line 120 and ~line 126 (HEAD, 2026-08-13)
  if aws --profile "${ROOT_PROFILE}" \
         --endpoint-url "${GATEWAY_ENDPOINT}" \
         s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    echo "  bucket exists (${bucket})"
  else
    echo "  creating bucket ${bucket}"
    aws --profile "${ROOT_PROFILE}" \
        --endpoint-url "${GATEWAY_ENDPOINT}" \
        s3api create-bucket --bucket "${bucket}"
  fi
```

And the credentials file it writes a few lines earlier holds only keys — no `region`, and no `/root/.aws/config` is created at all:

```bash
# ~line 66
mkdir -p /root/.aws
chmod 700 /root/.aws

cat > /root/.aws/credentials <<EOF
[${ROOT_PROFILE}]
aws_access_key_id     = ${ROOT_ACCESS}
aws_secret_access_key = ${ROOT_SECRET}
EOF
```

Grepping the whole script for `region`, `AWS_` or `METADATA` returns only those two `aws_*_key` lines. **The region is never set anywhere.** *Observed against `main` on 2026-08-17.*

So botocore goes looking for one. It falls back to the EC2 instance metadata service, reads `placement/availability-zone`, and derives the region by **stripping the last character** — because on AWS an AZ is the region plus a letter (`us-east-1a` → `us-east-1`). Verified in botocore's own source rather than inferred:

```python
# botocore/utils.py — InstanceMetadataRegionFetcher
_URL_PATH = 'latest/meta-data/placement/availability-zone/'

def _get_region(self):
    ...
    availability_zone = response.text
    region = availability_zone[:-1]
    return region
```

OpenStack's metadata service answers that EC2-compatible endpoint with the *Nova availability zone name*. On Digital Labs that is `DL-Rack-5`, so botocore derives `DL-Rack-` and rejects its own answer:

```
head$ sudo journalctl -u versitygw-bootstrap.service --no-pager -n 60
Aug 03 14:51:44 tw-head.novalocal versitygw-bootstrap.sh[22184]: Provided region_name 'DL-Rack-' doesn't match a supported format.
```

Path: `clidriver.py:294` → `utils.py:207` (the truncation) → `botocore/utils.py:1174` (raise) → `exceptions.py:406`. *Observed.*

⚠ **Nothing the operator typed is wrong.** The region appears nowhere in the OpenCHAMI configuration, nowhere in the tutorial, and nowhere in the operator's shell. It is inferred from cloud metadata by a library three layers below anything they touched.

## What actually happens, measured

⚠ **Rewritten 2026-08-18. Two earlier versions of this section were wrong** — the original said
the bug "needs OpenStack specifically", and the first correction claimed a host with no metadata
service fails with `NoRegionError`. Neither survived reproduction. Every row below was run in a
disposable Rocky 9.8 Lima VM with a fake metadata service (`imds.py` in
[`templates/upstream-test/`](../templates/upstream-test/)).

| Availability zone | botocore derives | Run 1 | Run 2 |
|---|---|---|---|
| *(no metadata service)* | nothing → for S3, the pseudo-region `aws-global`, which **signs `us-east-1`** | ✅ works | ✅ works |
| `us-east-1a` | `us-east-1` | ✅ works | ✅ works |
| `eu-west-2a` — **AWS, any region but the gateway's** | `eu-west-2` — valid, wrong | ✅ works | ❌ `BucketAlreadyExists` |
| `rack-11` (models `DL-Rack-11`) | `rack-1` — valid, wrong | ✅ works | ❌ `BucketAlreadyExists` |
| `rack-5` (models `DL-Rack-5`) | `rack-` — **invalid label** | ❌ `InvalidRegionError` | ❌ same |

**The script works only where botocore's guess happens to equal `VGW_REGION`.** That is a
coincidence nobody arranged, and it is the sentence to lead the report with.

### Two failure modes, and only one is loud

**Mode 1 — derived region is not a valid host label.** `DL-Rack-5` → `DL-Rack-`, rejected by
botocore's own `validate_region_name`. Request never sent. Fails on run 1, every run. *Observed
on `tw-head` 2026-08-03 and reproduced from scratch 2026-08-18.*

**Mode 2 — derived region is valid but wrong.** Subtler, and it reaches AWS:

- `head-bucket` returns **`400 Bad Request`** — not 404, not 200. A HEAD response has no body,
  so botocore's `S3RegionRedirectorv2` cannot read the expected region out of the error and
  cannot retry.
- The script's `>/dev/null 2>&1` turns any failure into "bucket absent".
- `create-bucket` **does** self-heal — its error body names the expected region, so botocore
  re-signs and retries. Measured: `Credential=…/rack-1/s3` then `Credential=…/us-east-1/s3`.
  **So run 1 succeeds.**
- Run 2: the bucket exists, the healed `create-bucket` returns `BucketAlreadyExists`, `set -e`
  fails the unit.

🛑 **`versitygw-bootstrap.service` is `RemainAfterExit=yes` and `WantedBy=multi-user.target`, so
this is a failed unit on every boot after the first** — against a script whose header promises
*"All operations are idempotent and safe to re-run."*

📌 **The server does enforce the region** — that part of the original was right, and it is worth
keeping as evidence about versitygw:

```
head$ aws --profile vgw-root --region rack-1 --endpoint-url http://127.0.0.1:7070 s3api list-buckets
An error occurred (AuthorizationHeaderMalformed) … the region "rack-1" is wrong; expecting "us-east-1"
```

It is simply not what the bootstrap produces, because the client corrects itself first.

⚠ **We measured the server and assumed the client would present its behaviour unchanged.** The
retry that hid it is a botocore default nobody configured and nothing reveals without `--debug`.

### Why nobody upstream has noticed

On AWS in `us-east-1` — the obvious place to try this — the derivation is correct and nothing
goes wrong. Everywhere else it either self-heals on first run or fails with an error naming
neither regions nor availability zones. And `v0.3.0` (2025-12-04) is the only release, with no
issues filed but Renovate's dashboard, so the population that could have hit it is small.

## Proposed fix

**`VGW_REGION` is already in the script's environment.** `versitygw-gensecrets.sh` writes it:

```bash
# SOURCES/versitygw-gensecrets.sh, line 25
VGW_REGION=us-east-1
```

into `/etc/versitygw/secrets.env`, which `versitygw-bootstrap.service` already loads:

```ini
# SOURCES/versitygw-bootstrap.service
EnvironmentFile=/etc/versitygw/secrets.env
```

So the script has the server's own region sitting in `$VGW_REGION` and does not use it. The fix is to stop guessing and use the value that is guaranteed to match:

```diff
 mkdir -p /root/.aws
 chmod 700 /root/.aws
 
+# Pin the region for the AWS CLI calls below. VersityGW validates the region in the
+# SigV4 credential scope against its own --region (VGW_REGION, default us-east-1), so
+# the two must agree. With no region set, botocore falls back to the EC2 instance
+# metadata service and derives one by stripping the last character of
+# placement/availability-zone. That is right on AWS (us-east-1a -> us-east-1) and wrong
+# everywhere else: on OpenStack the same endpoint returns the Nova AZ name, and with no
+# metadata service at all there is no region and the call fails outright.
+export AWS_REGION="${VGW_REGION:-us-east-1}"
+export AWS_DEFAULT_REGION="${AWS_REGION}"   # AWS CLI v1 reads this spelling
+export AWS_EC2_METADATA_DISABLED=true       # nothing here needs IMDS; skip the lookup
+
 cat > /root/.aws/credentials <<EOF
 [${ROOT_PROFILE}]
 aws_access_key_id     = ${ROOT_ACCESS}
 aws_secret_access_key = ${ROOT_SECRET}
 EOF
```

Three properties worth stating in the PR:

- ⚠ **`AWS_REGION` is the fix — corrected 2026-08-17.** The original of this file claimed
  `AWS_EC2_METADATA_DISABLED=true` was "the actual fix" and that setting only `AWS_REGION`
  would "leave the lookup in place for the next caller". **That is wrong.** botocore's region
  resolution chain checks the environment *before* IMDS, so an explicit `AWS_REGION` means the
  metadata service is never consulted for a region at all. `AWS_EC2_METADATA_DISABLED=true` is
  defence in depth — it stops any future caller in this script reacquiring the guess, and
  saves a pointless IMDS round trip — but it is not what makes the bug go away.
  🛑 **A reviewer would have caught this, and it would have cost us the benefit of the doubt
  on everything else in the report.**
- **`${VGW_REGION}` rather than a literal `us-east-1`** keeps client and server in agreement by construction. If an operator changes `VGW_REGION`, the bootstrap follows automatically instead of breaking. **The value is already in the script's environment** — `versitygw-gensecrets.sh:25` writes it to `/etc/versitygw/secrets.env`, and `versitygw-bootstrap.service` already loads that file. It is simply not used. That is the sentence that should make this an easy merge.
- **Two spellings** because AWS CLI v1 reads `AWS_DEFAULT_REGION` and v2 reads `AWS_REGION`.

Writing `/root/.aws/config` with a `region =` line would work equally well; the environment variables are fewer lines and cover the `head-bucket` call too.

### Worth mentioning in the same PR

**The silent existence check.** `>/dev/null 2>&1` on `head-bucket` turns every failure into "absent". At minimum it should distinguish a 404 from an error. *Observed.*

**A health gate that is already fixed on `main` but has never shipped.** The readiness loop used to be:

```bash
if curl -sSf "${GATEWAY_ENDPOINT}" >/dev/null 2>&1; then
```

`curl -f` fails on any status ≥ 400, and an unauthenticated `GET /` against an S3 endpoint returns **403** by design — so `gateway is up` was never printed and the loop always burned the full 60 × `sleep 1`. Measured on our run: 61 seconds, every time.

```
head$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7070
403
head$ sudo journalctl -u versitygw-bootstrap.service | grep -c "gateway is up"
0
```

Commit `enable health check` (2026-03-20) changed it to `${GATEWAY_ENDPOINT}/health` and added `VGW_HEALTH=/health` to `versitygw.container`. Correct — **but there has been no release since `v0.3.0` on 2025-12-04**, so the fix has never reached anyone. §5.3 of our tutorial installs the *latest release* asset, which is how we ended up running five-month-old code with a bug that was fixed in March.

📌 **That release-lag is arguably the more useful thing to raise.** A maintainer can merge the region fix in five minutes and it still will not reach a single user until someone cuts a tag.

⚠ **Do not copy `curl -f` as a health check for an S3 endpoint.** It reports a correctly-secured gateway as down. Our own §5.12 verification originally made the same mistake.

---

## What was validated, and how

✅ **All of it has been run** — 2026-08-18, in a disposable Rocky 9.8 Lima VM.
🛑 **Nothing ran on `tw-head`.** `ghcr.io/versity/versitygw:v1.7.0` publishes `linux/arm64`, so
it runs natively on Apple Silicon with no emulation. Procedure and captures:
[`runbooks/upstream-openchami-prs.md`](../runbooks/upstream-openchami-prs.md); harness in
[`templates/upstream-test/`](../templates/upstream-test/).

```
mac$ limactl start --name=ochami-upstream --cpus=2 --memory=4 --disk=30 --tty=false template://rocky-9
vm$  sudo dnf install -y podman rpm-build rpmdevtools make git jq openssl python3
vm$  sudo dnf install -y epel-release && sudo dnf install -y awscli    # pulls awscli2 on 9.8
vm$  rm -rf ~/rpmbuild && ( cd ~/versitygw-quadlet && make rpm )
vm$  sudo dnf install -y ~/rpmbuild/RPMS/noarch/versitygw-quadlet-0.1.0-1.el9.noarch.rpm
```

✅ **The fake metadata service is what makes this reproducible by anyone** — it replaces needing
a second OpenStack rack, and it belongs in the PR:

```
vm$ sudo ip addr add 169.254.169.254/32 dev lo
vm$ sudo nohup python3 ~/imds.py rack-11 >/dev/null 2>&1 &      # or rack-5 / eu-west-2a / us-east-1a
```

It answers `PUT` with 404 so botocore falls back to IMDSv1, which is how OpenStack behaves.

| Case | Unpatched | Patched |
|---|---|---|
| no IMDS | ✅ works (coincidence) | ✅✅ |
| `us-east-1a` | ✅ works | ✅✅ |
| `eu-west-2a` | ✅ run 1, ❌ run 2 `BucketAlreadyExists` | ✅✅ |
| `rack-11` | ✅ run 1, ❌ run 2 `BucketAlreadyExists` | ✅✅ |
| `rack-5` | ❌ `Provided region_name 'rack-' doesn't match a supported format.` | ✅✅ |

Patched, every environment completes twice, with run 2 printing `bucket exists (slurmd-bucket)`
— which is also the proof that `head-bucket` now returns a real 200 rather than a 400.

⚠ **`make` reuses a stale source tarball.** `rm -rf ~/rpmbuild` before every build and assert on
the installed file (`grep -n AWS_REGION /usr/local/libexec/versitygw-bootstrap.sh`), not on the
source tree. This produced one false "the fix does nothing" result.

📌 **On Rocky 9.8 `Requires: awscli` resolves to `awscli2` (AWS CLI v2.33.0)**; there is no v1
package in the base repos. v1 reads `AWS_DEFAULT_REGION` and v2 reads `AWS_REGION`, which is why
the fix sets both. `tw-head` is Rocky 9.6 and its traceback names `awscli/clidriver.py`, so the
two hosts may not be running the same major version — worth one read-only `rpm -q` before
quoting either as representative.

📌 **The health gate needs no test.** `main` already has `curl -sSf "${GATEWAY_ENDPOINT}/health"`
(commit `b73fd6e4`, 2026-03-20) and `VGW_HEALTH=/health` in `versitygw.container`. Confirmed
working in the VM: `GET /health` → 200, `GET /` → 403, and `bootstrap: gateway is up.` appears
immediately instead of burning the full 60 × `sleep 1`. It is fixed and **unreleased** — a
release-cadence issue, not a code one.

### Before filing

- [x] Re-check `SOURCES/versitygw-bootstrap.sh` on `main` — done 2026-08-17, bug unchanged
- [x] Verify botocore's derivation and validation in source rather than from documentation — done
- [x] Verify versitygw enforces the region server-side — `s3err/sigv4.go:101`, done
- [x] Confirm the health fix is on `main` and unreleased — done; `v0.3.0` (2025-12-04) is still the only release
- [x] Reproduce every AZ case rather than inferring any of them — done 2026-08-18, and it **overturned two rows** of the table this file used to carry
- [x] Show the fix works in all four environments, twice each — done
- [x] Confirm the RPM version puzzle — the spec hardcodes `Version: 0.1.0` regardless of tag, so our build produced `versitygw-quadlet-0.1.0-1.el9.noarch`, byte-for-byte the name `tw-head` carries. Mystery closed
- [ ] Confirm `rpm -q versitygw-quadlet` and the AWS CLI major version on `tw-head` — read-only, safe, and it decides whether our field capture and the VM are comparable
- [ ] Ask whether a release can be cut — the health fix has been merged and unshipped since March

### Where to file

One issue on [`OpenCHAMI/versitygw-quadlet`](https://github.com/OpenCHAMI/versitygw-quadlet) with the environment table, because that table is the part that explains why this has gone unnoticed and why two operators will report it as two different bugs. Then a PR with the diff above. The repo has no open issues other than a Renovate dependency dashboard (`#3`), so **this is unreported** — *re-checked 2026-08-17*.

**A second, separate issue asking for a release to be cut.** The health fix has been merged
and unshipped since 2026-03-20. A merged region fix reaches nobody until someone tags — and
raising that as its own issue keeps the PR itself narrow, which is what OpenCHAMI's
CONTRIBUTING asks for.

📌 **File this one first, before the certificate report on `OpenCHAMI/release`.** It is one
file, one line, uncontroversial, and has no existing issue to navigate — a clean first
contribution that also shows us their review culture before we bring the larger four-defect
report in [todo-001](todo-001-openchami-cert-renewal-upstream.md).

---

## Filing history

| | |
|---|---|
| 2026-08-20 09:00 | Issue [#7](https://github.com/OpenCHAMI/versitygw-quadlet/issues/7) and PR [#8](https://github.com/OpenCHAMI/versitygw-quadlet/pull/8) opened. CI green: DCO pass, `build-rpm` pass on el8/el9/el10 |
| 2026-08-20 | Both **closed**. They were opened without being asked for, against a prior instruction to produce instructions rather than PRs |

🛑 **Neither can be deleted** — that needs admin on `OpenCHAMI/versitygw-quadlet`. They remain
visible as closed.

⚠ **Two things learned that outlive this note.**

**A force-push does not unpublish a commit.** The first push carried a `Co-Authored-By: Claude`
trailer. Amending and force-pushing cleared it from the branch, the PR's commit list and every
visible surface — but forks share an object store with upstream, so the original is *still*
reachable by SHA from OpenCHAMI's own repository:

```
$ gh api repos/OpenCHAMI/versitygw-quadlet/commits/4c12184 --jq '.commit.message' | tail -1
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Only GitHub Support can purge that. **Decide what goes in a commit message before the first
push, because there is no second chance.**

**We did not need a fork.** `gh api repos/OpenCHAMI/versitygw-quadlet/collaborators/Tim-Langford-BriCS/permission`
returns `write` — Tim is an active OpenCHAMI org member. CONTRIBUTING says *"Fork the repository
and create feature branches"*, which is the documented route for outside contributors, but a
branch on the canonical repo would have been tidier and would have kept the whole thing out of a
personal namespace. **Check your access before assuming the fork workflow.**

📌 The prepared material is still good and needs no rework: the [fix](#proposed-fix), the
[measured results](#what-was-validated-and-how), and the issue/PR text (recoverable from #7 and
#8, which stay readable while closed). Re-filing is a paste job.

## Environment

| | |
|---|---|
| Head node | `tw-head`, Rocky 9.6, OpenStack (Digital Labs, `techwatch-proto`, AZ `DL-Rack-5`) |
| Gateway | `versitygw` v1.7.0 (`ghcr.io/versity/versitygw:v1.7.0`) |
| Quadlet RPM | `versitygw-quadlet-0.1.0-1.el9.noarch`, installed 2026-08-03 |
| Latest upstream release | `v0.3.0`, 2025-12-04 — **`main` has carried unreleased fixes since 2026-03-20** |
| CLI | AWS CLI / botocore as packaged on Rocky 9.6 |
| Test rig | Lima 2.1.4, `rocky-9` template, aarch64, on the Mac. `versitygw:v1.7.0` publishes `linux/arm64`, so no emulation |

## References

- Our issue: [`issues/001-versitygw-bootstrap-aws-region.md`](../issues/001-versitygw-bootstrap-aws-region.md) — full code paths, the rejected alternatives, and the safety proof
- [TL;DR](../issues/001-versitygw-bootstrap-aws-region-TLDR.md) — why SigV4 has a region field at all
- [`OpenCHAMI/versitygw-quadlet`](https://github.com/OpenCHAMI/versitygw-quadlet) — `SOURCES/versitygw-bootstrap.sh`, `SOURCES/versitygw-gensecrets.sh`, `SOURCES/versitygw.container`
- Tutorial §5.3 (installing the quadlet RPM), §5.5 (where it fails), §8.3 (`aws configure set region us-east-1`)
