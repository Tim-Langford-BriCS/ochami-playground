# Raising the two upstream OpenCHAMI PRs

**Everything here has been run and its output captured.** This is the procedure for reproducing
both bugs on a laptop, proving both fixes, and preparing the two pull requests — in order, with
the exact commands.

🛑 **The commands that touch GitHub are for Tim to run, not for Claude.** He raises upstream
contributions by hand and pastes the text himself. Bug 1 was filed without permission on
2026-08-20 and withdrawn; see [§4](#4--raising-pr-1-versitygw-quadlet---attempted-and-withdrawn)
for what that cost and why a force-push did not undo it.

| | |
|---|---|
| **Bug 1** | `versitygw-bootstrap.sh` sets no AWS region → [`OpenCHAMI/versitygw-quadlet`](https://github.com/OpenCHAMI/versitygw-quadlet). File **first** |
| **Bug 2** | The certificate renewal timer is packaged, never enabled, and cannot schedule itself → [`OpenCHAMI/release`](https://github.com/OpenCHAMI/release) |
| **Where the work already is** | `~/work/brics/openchami-versitygw-quadlet` and `~/work/brics/openchami-release`, both with the fix applied and uncommitted |
| **Test rig** | Lima VM `ochami-upstream`, Rocky 9.8, aarch64. Already built |
| **Verified** | 2026-08-17/18, in that VM. Both fixes proven; see [Captured results](#captured-results) |

🛑 **`tw-head` is not involved at any point.** No command below touches production. The live
cluster keeps its own workaround from [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md);
it is unaffected by anything upstream does.

✅ **§0 is done.** Testing invalidated five claims in our own issue files — including one in
`issues/006` and the whole double-digit-rack table in `issues/001` — and all five are now
corrected. Those files are what a maintainer reads if they follow our links, so this had to
land first. Read [§0](#0--corrections-to-our-own-files---done-2026-08-18) before quoting any of
our own material at anyone.

---

## §0 — Corrections to our own files — ✅ done 2026-08-18

Testing overturned five claims. All are now fixed, and each file carries a dated note saying
what it used to say and why that was wrong — because in this repository the rejected reasoning
is half the value.

| File | What was wrong | Now |
|---|---|---|
| `issues/001` + TL;DR | Double-digit racks fail server-side with `AuthorizationHeaderMalformed`; "two unrecognisably different errors" | ✅ Replaced with the measured matrix. They self-heal on run 1 and fail on run 2 with `BucketAlreadyExists`. TL;DR warns rack 11/12 readers they will see *nothing* at first |
| `issues/006` | Upstream's ordering serves a stale certificate; enabling upstream's timer "would fix the expiry" | ✅ Both corrected. Restart propagates via `Requires=`; and the timer cannot fire at all, which is a stronger statement than the one it replaced |
| `notes/todo-001` | Defect D listed as a real, untested defect | ✅ **Withdrawn**, with the disproof and the reason we missed it |
| `notes/todo-002` | `NoRegionError` with no IMDS; the double-digit prediction | ✅ Replaced with the measured matrix |
| `issues/010`, `issues/003` | — | ✅ Annotated earlier |
| `notes/README.md`, `runbooks/openchami-certificate.md`, `notes/breakpoint-2026-08-13.md` | Carried "restarts are in the wrong order" in summary tables | ✅ Swept and corrected |

📌 **Two of the five were mine, invented while planning and never tested** — that a host with no
metadata service fails with `NoRegionError` (it works), and that PR #50's `PartOf=` links were
what made the ordering safe on `main` (it was `Requires=`, present all along). Both were written
in the confident register of the surrounding evidence, which is exactly what makes that register
dangerous.

⚠ **The pattern worth carrying forward:** every wrong claim here came from verifying a
*mechanism* in source and then inferring an *outcome* without running it. The mechanisms were
all correct. `--deploy` really cannot issue; botocore really does truncate the AZ; versitygw
really does reject a wrong region. **A verified mechanism tells you what one component does.
Only running it tells you what the system does.**

---

## §1 — The test VM

Already built. To recreate from scratch:

```
mac$ limactl start --name=ochami-upstream --cpus=2 --memory=4 --disk=30 --tty=false template://rocky-9
mac$ limactl shell ochami-upstream
vm$  sudo dnf install -y podman rpm-build rpmdevtools systemd-rpm-macros make git jq openssl python3
vm$  sudo dnf install -y epel-release && sudo dnf install -y awscli   # pulls awscli2
```

⚠ **The Mac home is mounted read-only at the same path inside the VM.** So `cp -r
/Users/…/openchami-release ~/release` works, and edits are made on the Mac and re-copied in.
Do not try to edit in place from the VM.

⚠ **`make` reuses a stale source tarball.** `rm -rf ~/rpmbuild` before every build, and assert
on the built RPM rather than trusting the build. This bit twice: two "the fix does nothing"
results were actually the unpatched RPM being reinstalled.

```
vm$ rm -rf ~/rpmbuild && ( cd ~/release && make >/dev/null 2>&1 )
vm$ rpm -qlp ~/rpmbuild/RPMS/noarch/openchami-0.2.0-1.noarch.rpm | grep -c preset      # expect 1
vm$ rpm -qp --scripts ~/rpmbuild/RPMS/noarch/openchami-0.2.0-1.noarch.rpm | grep -c 'enable --now'   # expect 1
```

Teardown when finished: `limactl delete -f ochami-upstream`.

---

## §2 — Bug 1: reproduce, fix, prove

### The mechanism

The script calls `aws s3api head-bucket` and `create-bucket` with `--endpoint-url` but **no
region**, and writes `/root/.aws/credentials` with keys only — no `region`, no
`/root/.aws/config`. SigV4 needs a region, so botocore asks the EC2 metadata service and
derives one by **stripping the last character** of the availability zone
(`botocore/utils.py`, `InstanceMetadataRegionFetcher._get_region`: `region = availability_zone[:-1]`).
Correct on AWS (`us-east-1a` → `us-east-1`); wrong everywhere else.

`VGW_REGION=us-east-1` is **already in the script's environment** —
`versitygw-gensecrets.sh:25` writes it to `/etc/versitygw/secrets.env`, and
`versitygw-bootstrap.service` already has `EnvironmentFile=/etc/versitygw/secrets.env`. It is
simply not used. That is the sentence that should make this an easy merge.

### The measured matrix

| Fake IMDS AZ | botocore derives | Run 1 | Run 2 |
|---|---|---|---|
| *(no IMDS)* | → pseudo-region `aws-global`, signs `us-east-1` | ✅ success | ✅ success |
| `us-east-1a` | `us-east-1` | ✅ success | ✅ success |
| `eu-west-2a` | `eu-west-2` | ✅ success | ❌ `BucketAlreadyExists` |
| `rack-11` | `rack-1` | ✅ success | ❌ `BucketAlreadyExists` |
| `rack-5` | `rack-` (invalid label) | ❌ `InvalidRegionError` | ❌ same |

**Two failure modes, one root cause.**

1. **AZ truncates to an invalid host label** — `rack-5` → `rack-`, rejected by botocore's own
   `validate_region_name` regex `^(?![0-9]+$)(?!-)[a-zA-Z0-9-]{,63}(?<!-)$` on the trailing
   hyphen. Aborts on run 1, every time. **This is what we hit on `tw-head`.**
2. **AZ truncates to a valid but wrong label** — `rack-11` → `rack-1`, *or any AWS region other
   than the gateway's*. Subtler and broader:
   - `head-bucket` returns **`400 Bad Request`** — a HEAD response has no body, so the
     redirector cannot learn the correct region and cannot retry.
   - The script's `>/dev/null 2>&1` reads any failure as "bucket absent".
   - `create-bucket` **does** self-heal, because its error body names the expected region.
     Measured directly: `Credential=…/rack-1/s3` then `Credential=…/us-east-1/s3`. So run 1
     succeeds.
   - Run 2: bucket exists → the healed `create-bucket` returns `BucketAlreadyExists` →
     `set -e` fails the unit. The service is `RemainAfterExit=yes` and
     `WantedBy=multi-user.target`, so **once enabled this is a failed unit on every boot after
     the first** — against a script whose header promises *"All operations are idempotent and
     safe to re-run."*

### The fix

`SOURCES/versitygw-bootstrap.sh`, applied in `~/work/brics/openchami-versitygw-quadlet`:

```diff
 mkdir -p /root/.aws
 chmod 700 /root/.aws
 
+# Pin the region for the AWS CLI calls below. VersityGW validates the region in the
+# SigV4 credential scope against its own --region (VGW_REGION, default us-east-1), so
+# the two have to agree. With no region configured anywhere, botocore instead queries
+# the EC2 instance metadata service and derives one by stripping the last character of
+# placement/availability-zone. That is correct on AWS (us-east-1a -> us-east-1) and
+# wrong elsewhere: OpenStack answers the same endpoint with the Nova availability-zone
+# name, so "rack-5" becomes the invalid region "rack-" and the CLI aborts, while
+# "rack-11" becomes the valid-but-wrong "rack-1" and quietly costs a retry on every
+# call. VGW_REGION reaches us from secrets.env via the unit's EnvironmentFile.
+export AWS_REGION="${VGW_REGION:-us-east-1}"
+export AWS_DEFAULT_REGION="${AWS_REGION}"   # AWS CLI v1 reads this spelling
+export AWS_EC2_METADATA_DISABLED=true       # nothing here needs IMDS; skip the lookup
+
 cat > /root/.aws/credentials <<EOF
```

📌 **`AWS_REGION` is the fix.** botocore checks the environment before IMDS, so an explicit
region means the metadata service is never consulted. `AWS_EC2_METADATA_DISABLED=true` is
defence in depth and saves a pointless round trip. ⚠ Do **not** claim the metadata variable is
the fix — an earlier draft of `todo-002` did, and a reviewer would catch it.

### The harness

Three helper files, kept in [`templates/upstream-test/`](../templates/upstream-test/). The fake
IMDS is the piece that matters — **it replaces needing a second OpenStack rack**, and it goes in
the PR so a maintainer can re-run it:

```
vm$ sudo ip addr add 169.254.169.254/32 dev lo
vm$ sudo nohup python3 ~/imds.py rack-11 >/dev/null 2>&1 &     # or rack-5, us-east-1a, eu-west-2a
vm$ curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/; echo
rack-11
```

`imds.py` answers `PUT` with 404 so botocore falls back to IMDSv1, which is how OpenStack
behaves. Then:

```
vm$ bash ~/run-case.sh "rack-5" rack-5        # unpatched: expect InvalidRegionError
vm$ bash ~/reset.sh                            # back to a pre-bootstrap state
```

To test run-2 behaviour, start the service, stop it, and start it again — the second start is
where the idempotence break shows.

### Prove the fix

Rebuild, reinstall, and run **each environment twice**:

```
vm$ cp /Users/tl5297/work/brics/openchami-versitygw-quadlet/SOURCES/versitygw-bootstrap.sh ~/versitygw-quadlet/SOURCES/
vm$ rm -rf ~/rpmbuild && ( cd ~/versitygw-quadlet && make rpm )
vm$ sudo rpm -Uvh --force ~/rpmbuild/RPMS/noarch/versitygw-quadlet-0.1.0-1.el9.noarch.rpm
vm$ grep -n AWS_REGION /usr/local/libexec/versitygw-bootstrap.sh     # assert the fix shipped
```

✅ **Captured result — all four environments, twice each, all `success`:**

```
======== PATCHED: rack-5   (was: InvalidRegionError, run 1) ========
run 1: success
run 2: success
  bucket exists (slurmd-bucket)
  bucket exists (fabricmanager-bucket)
bootstrap: COMPLETE
```

…and identically for `rack-11`, `eu-west-2a` and no-IMDS. Then prove the buckets are real:

```
vm$ sudo AWS_EC2_METADATA_DISABLED=true AWS_REGION=us-east-1 \
      aws --profile vgw-root --endpoint-url http://127.0.0.1:7070 s3 ls
```

### Optional second commit

The `head-bucket` check swallows every error as "absent", which is why the first visible symptom
is one step later than the first failure. **The region fix alone resolves the idempotence break**
(run 2 passes above), so this is defence in depth — offer it as a separate commit a reviewer can
drop:

```diff
-  if aws --profile "${ROOT_PROFILE}" \
-         --endpoint-url "${GATEWAY_ENDPOINT}" \
-         s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
+  head_err="$(aws --profile "${ROOT_PROFILE}" \
+                  --endpoint-url "${GATEWAY_ENDPOINT}" \
+                  s3api head-bucket --bucket "${bucket}" 2>&1)" && head_rc=0 || head_rc=$?
+  if [[ ${head_rc} -eq 0 ]]; then
     echo "  bucket exists (${bucket})"
+  elif ! grep -qE '404|Not Found' <<<"${head_err}"; then
+    echo "  ERROR: could not query bucket ${bucket}: ${head_err}" >&2
+    exit 1
   else
```

⚠ **Untested.** Either run it (delete a bucket and re-run; then point `GATEWAY_ENDPOINT` at a
dead port) or leave it out. Do not ship an untested diff in a first contribution.

---

## §3 — Bug 2: reproduce, fix, prove

### The three defects

| | Defect | Evidence |
|---|---|---|
| **A** | `%post` never enables the timer. No `systemctl enable`, no `%systemd_post`, no preset; `bootstrap_openchami.sh` never mentions systemd | `is-enabled` → `disabled` on a fresh install |
| **B** | Even enabled, the timer schedules **nothing**. `OnUnitActiveSec=1d` is relative to the triggered unit's last activation; with no anchor systemd computes no elapse. `Persistent=true` applies only to `OnCalendar` | `enabled`, `active`, `NEXT: -`, `NextElapseUSecMonotonic=infinity` |
| **C** | Renewal period (1 d) equals certificate lifetime (24 h), so renewal lands at or after expiry | Arithmetic — and we reproduced the same shape in our own timer, [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md) |

🛑 **Defect D — "the service deploys before it issues" — is withdrawn. Do not file it.**
See [Defect D is dead](#defect-d-is-dead).

### Prove defects A and B

**No containers needed** — `is-enabled` and `list-timers` answer without anything running.
`%post` runs `bootstrap_openchami.sh`, which will be noisy on a bare VM; a failing `%post` is an
rpm *warning*, not an install failure, so the tests work regardless.

⚠ **Wipe completely between runs, or you will measure your own leftovers.** A stray
`timers.target.wants` symlink from an earlier `enable` survives `dnf remove`:

```
vm$ sudo systemctl stop openchami-cert-renewal.timer
vm$ sudo dnf remove -y openchami
vm$ sudo rm -f /etc/systemd/system/timers.target.wants/openchami-cert-renewal.timer \
               /var/lib/systemd/timers/stamp-openchami-cert-renewal.timer
vm$ sudo systemctl daemon-reload && sudo systemctl reset-failed
```

Then, on pristine `main`:

```
vm$ sudo dnf install -y /tmp/openchami-PRISTINE.rpm
vm$ systemctl is-enabled openchami-cert-renewal.timer          # disabled          <- defect A
vm$ sudo systemctl enable --now openchami-cert-renewal.timer   # what an operator would do
vm$ systemctl list-timers --all --no-pager openchami-cert-renewal.timer
```

✅ **Captured — the single most quotable output in the report:**

```
NEXT LEFT LAST PASSED UNIT                         ACTIVATES
-    -    -    -      openchami-cert-renewal.timer openchami-cert-renewal.service

  is-enabled=enabled   is-active=active
  NextElapseUSecMonotonic = infinity
```

**Enabled, active, and it will never fire.** So "just enable the shipped timer" is not a
workaround — it changes no observable behaviour.

### The fix

Three parts, applied in `~/work/brics/openchami-release`:

**`systemd/system/openchami-cert-renewal.timer`** — fixes B and C in one change, and makes
`Persistent=true` meaningful for the first time:

```diff
-Description=Renew OpenCHAMI certificates daily
+Description=Renew OpenCHAMI certificates
 [Timer]
-OnUnitActiveSec=1d
+OnCalendar=*-*-* 00,08,16:00:00
+RandomizedDelaySec=2m
 Persistent=true
```

(The committed version carries a comment block explaining both reasons — margin, and the
missing anchor. Keep it; it is the part that makes the change reviewable.)

**`systemd/presets/85-openchami.preset`** — new file:

```
enable openchami-cert-renewal.timer
```

**`openchami.spec`** — `BuildRequires: systemd-rpm-macros`, `%{?systemd_requires}`, the preset
installed to `/usr/lib/systemd/system-preset/` and listed in `%files`, plus:

```spec
%post
%systemd_post openchami-cert-renewal.timer
… existing body, including bootstrap_openchami.sh …
systemctl enable --now openchami-cert-renewal.timer || :

%preun
%systemd_preun openchami-cert-renewal.timer

%postun
%systemd_postun_with_restart openchami-cert-renewal.timer
systemctl daemon-reload
```

⚠ **`%systemd_post` alone is not enough, and this was found by testing.** It only applies the
preset on *initial* installation and never starts anything. So:

- a host that is not rebooted has an enabled timer with nothing scheduled;
- **an existing cluster upgrading from a broken release stays broken** — which is the case that
  matters most, since every deployed OpenCHAMI head node is in it.

Hence the unconditional `enable --now`. 📌 **State the trade-off in the PR:** it re-enables a
timer an operator may have deliberately disabled. Offer to drop it and rely on the preset alone
if the maintainers prefer strict preset semantics — but say plainly what that costs.

### Prove the fix

✅ **Captured — before, after, and the upgrade path:**

| Scenario | `is-enabled` | `is-active` | `NEXT` |
|---|---|---|---|
| fresh install, pristine `main` | `disabled` | `inactive` | — |
| …then operator types `enable --now` | `enabled` | `active` | **`-`** |
| fresh install, **fixed** (nothing typed) | `enabled` | `active` | **`Mon 2026-08-17 16:00:11 BST`** |
| **upgrade** pristine → fixed | `enabled` | `active` | **`Mon 2026-08-17 16:00:07 BST`** |
| uninstall | *unit files 0, dangling symlinks 0* | | |

Config preserved across upgrade (`%config(noreplace)`): yes.

### Defect D is dead

The claim was: the service runs `acme-deploy` before `acme-register`, and `--deploy` cannot
issue, so haproxy ends up serving the *previous* certificate.

**The mechanism is true** — verified in acme.sh 3.1.1, where `_deploy` is called only from
`renew()` (line 5513), never from `issue()`. **The conclusion is false.** A harness of dummy
oneshot units mirroring both refs' dependency graphs shows `systemctl restart acme-register`
restarting the whole chain, in the right order, on **both** v0.1.6 and `main`:

```
v0.1.6 — t-register 15:54:50.238 → t-deploy .242 → t-proxy .245
main   — t-register 15:54:55.889 → t-deploy .893 → t-proxy .895
```

And it is **not** PR #50's `PartOf=` links — v0.1.6 has none of them. It is `Requires=` /
`After=`, present all along: `acme-deploy` has `Requires=acme-register.service`, `haproxy` has
`Requires=acme-deploy.service`, and systemd propagates a restart along that chain.

So the shipped order wastes one deploy and one haproxy restart on the old certificate, but does
not serve a stale one. **At most a footnote in the PR. Not a commit, not a claim.**

⚠ **The lesson is the repository's own:** we verified a mechanism and inferred an outcome without
testing the outcome. A dependency we had read past did the work anyway. `bash -n` on the harness
is not the check — running it is.

---

## §4 — Raising PR 1 (versitygw-quadlet) — 🛑 attempted and withdrawn

**Issue [#7](https://github.com/OpenCHAMI/versitygw-quadlet/issues/7) and PR
[#8](https://github.com/OpenCHAMI/versitygw-quadlet/pull/8) were opened on 2026-08-20 and closed
the same day.** CI had passed — DCO, and `build-rpm` on el8/el9/el10. They were opened without
being asked for, against an earlier instruction to produce instructions rather than PRs.

🛑 **Nothing in this file may be executed against a remote.** Prepare, hand over, stop.
See the third standing constraint in [`CLAUDE.md`](../CLAUDE.md).

⚠ **Three things that cost more than the mistake itself.**

**A force-push does not unpublish a commit.** The first push carried a `Co-Authored-By: Claude`
trailer that had never been cleared for a project whose AI policy we had not checked. Amending
and force-pushing cleared every visible surface — branch, PR commit list, diff, timeline — but
forks share an object store with their upstream, so the original is still reachable by SHA from
OpenCHAMI's own repository:

```
$ gh api repos/OpenCHAMI/versitygw-quadlet/commits/4c12184 --jq '.commit.message' | tail -1
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Only GitHub Support can purge it. **Decide what a commit message contains before the first push.**

**A closed PR and a closed issue cannot be deleted.** That needs admin on the upstream repo. They
stay visible as closed for good, so "we can always withdraw it" is not a real safety net.

**We did not need a fork.**
`gh api repos/OpenCHAMI/versitygw-quadlet/collaborators/Tim-Langford-BriCS/permission` returns
`write` — Tim is an active OpenCHAMI org member, and the diff is served from upstream's own
`refs/pull/8/head` rather than from the fork at all. CONTRIBUTING says *"Fork the repository and
create feature branches"*, which is the documented route for outside contributors, but a branch
on the canonical repo would have been tidier. **Check access before assuming the fork workflow.**

📌 **The prepared material is unaffected and re-filing is a paste job** — the fix, the measured
results, and the issue/PR text, which stays readable on #7 and #8 while closed.

The procedure, for next time — **to hand to Tim, not to run:**



**Do this one first.** One file, one line, no existing issue to navigate, and it shows us their
review culture before the larger report.

```
mac$ cd ~/work/brics/openchami-versitygw-quadlet
mac$ gh repo fork --remote --remote-name fork      # creates Tim-Langford-BriCS/versitygw-quadlet
mac$ git checkout -b fix/bootstrap-aws-region
mac$ git add SOURCES/versitygw-bootstrap.sh
mac$ git commit -s -m "fix: pin the AWS region for bootstrap's S3 calls"
mac$ git push fork fix/bootstrap-aws-region
```

🛑 **`-s` is mandatory** — DCO sign-off with a real name and email is enforced by CI, as is a
cryptographic signature. `git config user.name/user.email` are already correct in this repo.
Forgot it? `git commit --amend -s && git push --force`.

**Open the issue first**, then the PR referencing it. The issue should carry the measured matrix
— that table is what explains why this has gone unnoticed and why two operators see two
different failures.

Suggested issue title: *"versitygw-bootstrap.sh sets no AWS region, so botocore derives one from
instance metadata"*.

The PR body needs: the mechanism, the matrix, the `VGW_REGION`-is-already-here point, the
reproduction commands including `imds.py`, and the before/after output. The PR template asks for
tests proving the fix — **say explicitly that the captured reproductions are that**, since the
repo has no test suite.

📌 **Also open a separate issue asking for a release to be cut.** `v0.3.0` (2025-12-04) is the
only release; the `/health` fix (`b73fd6e4`, 2026-03-20) and container pinning have been merged
and unshipped for months. A merged region fix reaches nobody until someone tags. Arguably the
more useful thing to raise.

⚠ **Do not add SPDX/REUSE headers unasked.** CONTRIBUTING asks for them, but neither target repo
has any today. Ask in the PR.

---

## §5 — Raising PR 2 (release)

**Only after PR 1 has been through review.**

### First: comment on [#57](https://github.com/OpenCHAMI/release/issues/57)

An existing open issue by `spresse1` — *"Restart containers after certificates rotate"* — whose
workaround is a cron job and who says they are *"having to manually restart OpenCHAMI daily."*
A maintainer (`synackd`) replied: *"Perhaps we could add a systemd timer for it."*

**The timer has been in the repo since PR #5, 2025-05-02.** That comment is the opening.

The comment should say: the timer already exists; `%post` has never enabled it; and even when
enabled it cannot fire, with the `NEXT: -` output as proof. Then: renewing at a fraction of the
lifetime fixes #57 outright and nobody needs to restart coresmd on a schedule.

⚠ **Do not tell the reporter their diagnosis is wrong.** They asked for containers to be
restarted after rotation, which is entirely reasonable given what they could see. Our
contribution is the layer underneath. Their observed 12-second expiry overrun (**not** 42
seconds — an early draft of `todo-001` misread the journal timestamp for the error's own
`current time`) is exactly what hand-renewal at one-per-lifetime produces.

📌 **Our coresmd evidence is already captured and needs nothing new.** `tw-head` has renewed
three times a day since 2026-08-15 with no coresmd restart and no errors — read it from the
journal, which is read-only and safe.

### Then the PR

```
mac$ cd ~/work/brics/openchami-release
mac$ gh repo fork --remote --remote-name fork
mac$ git checkout -b fix/cert-renewal-timer
mac$ git add systemd/system/openchami-cert-renewal.timer systemd/presets/ openchami.spec
mac$ git commit -s -m "fix: enable and correctly schedule the certificate renewal timer"
mac$ git push fork fix/cert-renewal-timer
```

Two commits is cleaner than one if you want to split it — the timer schedule and the packaging
are independently defensible, and CONTRIBUTING explicitly says smaller PRs review faster.

**The PR body must include**, beyond the mechanism and the captured before/after table:

🛑 **A migration note.** Sites that worked around this — us, and #57's reporter — will end up
with **two renewal mechanisms**: certificates re-issued 3–4 times a day and two units contending
for haproxy. Not dangerous, but noisy and confusing. *If you added your own timer or cron job,
remove it.* This belongs in the release notes, not only the PR.

🛑 **The cascade, because it is the real hazard and it is not obvious.** During an expiry window
`coresmd` keeps serving DHCP from a stale cache, so the cluster looks healthy. Restart
`coresmd-coredhcp` then and it comes up with an empty cache, cannot repopulate from SMD, and
falls through to the `bootloop` plugin — nodes get `172.16.0.200-250` addresses as leases
expire. **Fix the certificate before restarting coresmd, never the reverse.**

**The cost of three renewals a day:** three step-ca round trips and three haproxy restarts,
briefly dropping in-flight `:8443` connections; step-ca's database grows by one certificate per
issue. Worth a sentence — and it is still an open assertion in our own
[`notes/scheduled-checks.md`](../notes/scheduled-checks.md).

### Optional follow-up, separate PR

`scripts/openchami-certificate-update` tells the operator, after an FQDN change, to run
`systemctl restart acme-deploy` — which redeploys the certificate bearing the **old** FQDN and
reports success. Should be register → deploy → haproxy, or simply `systemctl start
openchami-cert-renewal.service`. ⚠ **Untested** — same reasoning as defect D, so test it before
filing, or leave it.

---

## Captured results

All from the Lima VM, 2026-08-17. Full transcripts are in the session log; the load-bearing
lines are quoted in §2 and §3 and in
[`notes/todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md) /
[`notes/todo-002`](../notes/todo-002-versitygw-region-openstack-az-upstream.md).

| Claim | Status |
|---|---|
| Bug 1 fails on OpenStack single-digit AZ | ✅ reproduced from scratch |
| Bug 1 breaks idempotence on valid-but-wrong regions, incl. AWS | ✅ measured, new finding |
| Bug 1 fails with no IMDS | ❌ **disproved** — works fine |
| Bug 1 double-digit → `AuthorizationHeaderMalformed` | ❌ **disproved** — self-heals, run 1 succeeds |
| Bug 1 fix works in all four environments, twice each | ✅ |
| Bug 2 defect A — timer never enabled | ✅ |
| Bug 2 defect B — timer cannot schedule | ✅ `NextElapseUSecMonotonic=infinity` |
| Bug 2 fix: fresh install, upgrade, clean uninstall | ✅ all three |
| Bug 2 defect D — deploy-before-issue serves stale cert | ❌ **disproved** on both refs |

## Checklist

- [ ] §0 corrections landed in `issues/001`, its TL;DR, `issues/006`, `notes/todo-001`, `notes/todo-002`
- [ ] Every remaining public claim marked *observed* or *inferred*
- [x] ~~Bug 1: issue opened with the matrix; PR opened, DCO-signed, CI green~~ — done 2026-08-20 then **withdrawn**, see [§4](#4--raising-pr-1-versitygw-quadlet---attempted-and-withdrawn)
- [ ] Bug 1: **re-file by hand** — text recoverable from [#7](https://github.com/OpenCHAMI/versitygw-quadlet/issues/7) / [#8](https://github.com/OpenCHAMI/versitygw-quadlet/pull/8)
- [ ] Bug 1: separate release-cut issue opened
- [ ] Comment posted on #57
- [ ] Bug 2: PR opened, DCO-signed, CI green, with the migration note and the cascade warning
- [ ] `issues/001`, `006`, `010` updated with the real filing state and links — 001 currently reads *filed and withdrawn*
- [ ] `notes/README.md` state values updated
- [ ] 🛑 Confirm `tw-head` was never touched
- [ ] `limactl delete -f ochami-upstream`
