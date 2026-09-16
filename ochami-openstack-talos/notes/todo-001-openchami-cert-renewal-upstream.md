# todo-001 — OpenCHAMI certificate renewal: shipped, never enabled, unschedulable, and with no margin

| | |
|---|---|
| **Upstream** | [`OpenCHAMI/release`](https://github.com/OpenCHAMI/release) |
| **State** | **Fix written and verified, not reported.** Three defects survived testing; a fourth was withdrawn |
| **Found** | 2026-08-13, `tw-head`, Digital Labs (`techwatch-proto`) — while recovering from [issue 005](../issues/005-platform-storage-stall.md) |
| **Our side** | [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) (the expiry) and [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md) (the margin defect in our own fix); workaround installed on `tw-head`, not yet in the tutorial or the IaC |
| **Impact** | Every OpenCHAMI install from the release RPM loses TLS 24 hours after installation, on any cloud and on metal |
| **Upstream HEAD checked** | **2026-08-17.** `main` at `c315e687`, latest release `v0.2.0` (2026-08-07). `tw-head` is on the RPM installed 2026-08-06, almost certainly `v0.1.6` |

⚠ **This file was substantially revised on 2026-08-17 after a source-level re-check.** Two
claims in the original did not survive it. They are recorded in
[What the re-check changed](#what-the-re-check-changed) rather than quietly deleted, because
the reasoning that produced them is the same reasoning we are asking a maintainer to trust.

**Three defects, stacked.** A is the outage. B and C are why the shipped mechanism could not
have saved anyone even if A were fixed. A fourth — D, the `ExecStart` ordering — was withdrawn
after testing; it is kept below because how it failed is worth more than the claim was.

| | Defect | Confidence |
|---|---|---|
| [**A**](#defect-a--the-renewal-timer-is-packaged-but-never-enabled) | `%post` never enables the timer | **Certain** — source-verified, and observed on `tw-head` |
| [**B**](#defect-b--the-timer-cannot-fire-even-if-you-enable-it) | `OnUnitActiveSec=1d` alone gives the timer no anchor, so it schedules nothing | **Certain** from systemd source; one command confirms it |
| [**C**](#defect-c--renewal-period-equals-certificate-lifetime) | Renewal period equals certificate lifetime — zero margin | **Certain** arithmetic; we reproduced the shape ourselves in issue 010 |
| ~~**D**~~ | ~~The service deploys *before* it issues~~ | 🛑 **WITHDRAWN 2026-08-18 — disproved on both refs.** [Why](#defect-d--withdrawn) |

---

## What the re-check changed

📌 Kept deliberately, per this repository's rule that rejected reasoning is half the value.

### 1. We misquoted issue #57

The original said the gap between expiry and error was **42 seconds**. It is **12 seconds**.
The issue body reads:

```
May 22 08:29:03 admin coresmd-coredns[869438]: time="2026-05-22T07:29:03Z" level=error
  msg="failed to refresh cache: … x509: certificate has expired or is not yet valid:
  current time 2026-05-22T07:28:33Z is after 2026-05-22T07:28:21Z"
```

We had read `07:29:03` — the journal line's own timestamp — as the error's "current time",
which is `07:28:33`, thirty seconds earlier.

🛑 **The number was load-bearing.** It was the whole basis for arguing that #57's certificate
had expired "moments ago". It still had, but by 12 seconds rather than 42 — and more
importantly, we had misread the source we were about to contradict in public. **Re-read the
report you are disagreeing with, in the original, immediately before you post.**

### 2. Defect D does not explain #57 — defect A does

The original argued that deploy-before-issue was the true cause of #57, and that its reporter
had misdiagnosed their own system. That claim is withdrawn.

Read what the reporter actually says: *"I am currently having to manually restart OpenCHAMI
daily."* So on their host **nothing automated is renewing anything** — they are re-minting the
certificate by hand at roughly 24-hour intervals against a 24-hour lifetime. A 12-second
overrun is the arithmetic of hand-renewal at one-per-lifetime. It needs no ordering bug to
explain it.

Defect A alone accounts for #57 in full, and A is source-certain. The stronger report is also
the simpler one.

⚠ **We built a confident causal story on top of a misread timestamp, and it survived a
write-up.** The tell was available throughout: our own hypothesis required the renewal timer
to be *running* on their host, and we had already established that the RPM never enables it.
**Check a new hypothesis against what you have already established before publishing it** —
the same lesson as [issue 011](../issues/011-vllm-dev-shm-too-small.md), reached from the
opposite direction.

### 3. Defect D is disproved — the ordering is not a bug

An earlier revision of this file said the blast radius of defect D "depends on the release",
reasoning that PR #50 added `PartOf=` links to `main` which might mask it, while v0.1.6 had
none. **That framing was itself wrong**, and testing settled it in minutes.

Dummy `systemd` units mirroring both refs' `Requires`/`After`/`PartOf`/`Upholds` graphs, with
`systemctl restart t-register` — the operation the renewal service performs:

```
v0.1.6 — t-register 15:54:50.238 → t-deploy .242 → t-proxy .245
main   — t-register 15:54:55.889 → t-deploy .893 → t-proxy .895
```

**The chain restarts, in the correct order, on both refs.** And it is *not* PR #50's `PartOf=`
links that do it — v0.1.6 has none of them. It is `Requires=` / `After=`, present since the
units were written: `acme-deploy` has `Requires=acme-register.service`, `haproxy` has
`Requires=acme-deploy.service`, and systemd propagates a restart along that chain.

So upstream's `deploy → register → haproxy` wastes one deploy and one haproxy restart on the
old certificate, and then re-runs both *after* the new one exists. **No stale certificate is
ever served.** Defect D is withdrawn.

⚠ **We had the evidence and read past it.** `Requires=acme-register.service` is on the second
line of `acme-deploy.container`, a file quoted in this very document. We were looking for the
propagation mechanism among the *new* `PartOf=` lines because that is where the diff was, and
missed the older one doing the work. **A diff tells you what changed, not what matters.**

📌 **The mechanism underneath was never wrong.** `--deploy` genuinely cannot issue — verified in
acme.sh 3.1.1 source, and still worth stating. What was wrong is the step from "this command
cannot issue" to "therefore haproxy serves a stale certificate", which skipped over everything
systemd does in between. **A verified mechanism tells you what one component does; only running
it tells you what the system does.**

---

## Defect A — the renewal timer is packaged but never enabled

### What we observed

On a head node built by following the OpenCHAMI tutorial, the TLS certificate for
`demo.openchami.cluster` expired 24 hours after installation and stayed expired for six days.
Nothing renewed it.

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 -servername demo.openchami.cluster 2>/dev/null \
        | openssl x509 -noout -dates
notBefore=Aug  6 21:28:06 2026 GMT
notAfter=Aug  7 21:29:06 2026 GMT          ← observed on 13 August
```

```
head$ systemctl list-timers --all --no-pager | grep -iE 'acme|cert|step'
head$                                       ← no output: no timer loaded at all
```

```
head$ systemctl status acme-register --no-pager | head -3
● acme-register.service - The acme-register container
     Active: active (exited) since Thu 2026-08-06 21:29:08 UTC; 6 days ago
```

The downstream symptom is `coresmd` failing its 30-second SMD cache refresh with
`x509: certificate has expired`, which — because coresmd keeps serving DHCP from its stale
cache — is invisible until something restarts it.

*All of the above is observed, on one host.*

### What the source says

The units exist and are correct. `systemd/system/openchami-cert-renewal.timer`, unchanged
since it was added:

```ini
[Unit]
Description=Renew OpenCHAMI certificates daily

[Timer]
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
```

`openchami.spec` packages both units — `/etc/systemd/system/` in v0.1.6,
`/usr/lib/systemd/system/` from v0.2.0 (changed by
[#61](https://github.com/OpenCHAMI/release/pull/61)). But `%post` never enables them, in
either version. At `main` today:

```spec
%post
# reload systemd so new units are seen
systemctl daemon-reload
# bootstrap
systemctl stop firewalld
/usr/libexec/openchami/bootstrap_openchami.sh

%postun
# reload systemd on uninstall
systemctl daemon-reload
```

A grep of the **entire repository** at `main` settles that nothing else does it either:

```
$ grep -rn "systemctl enable\|preset\|cert-renewal\|timers.target" . --exclude-dir=.git
openchami.spec:68:/usr/lib/systemd/system/openchami-cert-renewal.service
openchami.spec:69:/usr/lib/systemd/system/openchami-cert-renewal.timer
systemd/system/openchami-cert-renewal.timer:9:WantedBy=timers.target
```

Two `%files` lines and the timer's own `[Install]`. **No preset file, no `systemctl enable`,
no `%systemd_post` macro, and `scripts/bootstrap_openchami.sh` contains no reference to
systemd at all.** So `[Install] WantedBy=timers.target` is never acted on. The timer is
installed, correct, and inert.

⚠ **Latent since May 2025.** The units were added in
[`#5`](https://github.com/OpenCHAMI/release/pull/5) — *"Update container images and add
certificate renewal services for the tutorial"* — on 2025-05-02. `%post` was never updated.

📌 **A maintainer does not know the timer is there.** On #57, `synackd` replied:

> Restarting `openchami-cert-renewal.service` has typically worked for me. Perhaps we could
> add a systemd timer for it.

The timer has been in the repository for fifteen months. That comment is the opening for the
report: we are not proposing a feature, we are pointing out that a shipped one was never
switched on.

*Source contents and the grep are observed, at `main`, 2026-08-17.*

### Proposed fix

The packaging-correct form, which respects distro presets:

```spec
%post
%systemd_post openchami-cert-renewal.timer
systemctl daemon-reload
systemctl stop firewalld
/usr/libexec/openchami/bootstrap_openchami.sh

%preun
%systemd_preun openchami-cert-renewal.timer

%postun
%systemd_postun_with_restart openchami-cert-renewal.timer
systemctl daemon-reload
```

`%systemd_post` only enables what a preset permits, so the package should also ship
`85-openchami.preset` containing `enable openchami-cert-renewal.timer`, installed into
`/usr/lib/systemd/system-preset/`. Requires `BuildRequires: systemd-rpm-macros` and
`%{?systemd_requires}`.

Blunter, and closer to what `%post` already does — it stops firewalld, so it is not shy of
imperative action:

```spec
systemctl enable --now openchami-cert-renewal.timer
```

📌 **Offer both and let the maintainers choose.** Which one is right is their packaging
policy, not ours, and arguing for one is a good way to stall a PR that both forms would fix.

📌 **Enabling the timer does not repair a host that is already broken** — the first fire is
hours away. `%post` should also run the service once, or the release notes must tell existing
operators to run `systemctl start openchami-cert-renewal.service` by hand. We hit exactly
this: `enable --now` on the *timer* started the timer, not the service, and left the dead
certificate in place.

---

## Defect B — the timer cannot fire even if you enable it

This one was missed entirely the first time round, and it makes defect A worse than we wrote
it: **`systemctl enable --now openchami-cert-renewal.timer` is not a workaround.**

The timer's only schedule directive is `OnUnitActiveSec=1d`, which is *relative to when the
triggered unit was last activated*. systemd's `timer_enter_waiting()`:

```c
case TIMER_UNIT_ACTIVE:
        leave_around = true;
        base = MAX(trigger->inactive_exit_timestamp.monotonic, t->last_trigger.monotonic);
        if (base <= 0)
                continue;
        break;
```

`continue` — the value is skipped entirely. On a host where
`openchami-cert-renewal.service` has never run, both timestamps are zero, so **the timer
computes no next elapse at all**. `systemctl list-timers` shows `NEXT: -`.

And `Persistent=true` does not rescue it, for two independent reasons:

1. It only applies to `OnCalendar=`; on a purely monotonic timer it is documented as having
   no effect.
2. The persistent stamp file restores `last_trigger.**realtime**` only. `.monotonic` stays
   zero, so it cannot serve as the anchor the code above is looking for.

Nothing in the OpenCHAMI install path ever runs `openchami-cert-renewal.service` — `%post`
does not, `bootstrap_openchami.sh` does not, and `openchami.target` does not list it. So the
anchor never comes into existence.

⚠ **The service *does* carry `[Install] WantedBy=multi-user.target`.** So a site that enabled
the *service* as well as the timer would get one run per boot, which would anchor it. Nothing
suggests that is intended, and nothing enables it either — but it is why "just enable the
timer" advice sometimes appears to work on a host that has been rebooted.

*The systemd behaviour is read from source. That the anchor never occurs on an OpenCHAMI
install is inferred from the grep above — confirm with the one-command test.*

### Proposed fix

Fold into defect C's diff below: `OnCalendar=` is absolute, needs no prior activation, and
gives `Persistent=true` something real to compare against.

---

## Defect C — renewal period equals certificate lifetime

The certificate lives **24 hours**: step-ca's default `maxTLSCertDuration`, taken as shipped,
less a 60-second backdate for clock skew. The timer renews every **24 hours**. One renewal per
lifetime leaves the margin to whatever the phase difference happens to be, and nothing keeps
it positive.

🛑 **We proved this the expensive way, on our own fix.** [Issue 010](../issues/010-cert-renewal-timer-has-no-margin.md)
is the same defect in the timer we wrote to work around defect A — and it was found not by
anything breaking, but by a scheduled re-check. Observed there:

| | 15 Aug | 16 Aug |
|---|---|---|
| Renewal fires | `03:10:11` | `03:02:59` |
| Certificate expires | `03:02:52` | `03:10:25` |
| **Margin** | **−7m19s** → **7m33s of expired certificate** | **+7m26s** |

Same units, same timer, nothing changed between them. Ours had `RandomizedDelaySec=15m`, which
made it a coin flip; upstream's has none, which makes it a slow drift instead — every cycle
starts later than the last by the time the service takes to run plus the timer's
`AccuracySec`, so it walks steadily *past* the expiry rather than oscillating around it.

📌 **This is the more interesting defect to report, and issue 010 says why.** A maintainer can
dismiss "it never worked for us" as local misconfiguration. "The period equals the lifetime,
here is the arithmetic, and here is us reproducing it on our own timer" is harder to argue
with — and it comes with an admission that we made the same mistake, which is the right tone.

### Proposed fix — one diff for B and C

```diff
 [Unit]
-Description=Renew OpenCHAMI certificates daily
+Description=Renew OpenCHAMI certificates

 [Timer]
-OnUnitActiveSec=1d
+# Certificates from the bundled step-ca live 24h (its default maxTLSCertDuration).
+# Renew three times per lifetime: ~16h of standing margin, so a failed run is a warning
+# rather than an outage. OnCalendar rather than OnUnitActiveSec because the latter has no
+# anchor until the service has run at least once, so a freshly enabled timer never fires.
+OnCalendar=*-*-* 00,08,16:00:00
+RandomizedDelaySec=2m
 Persistent=true

 [Install]
 WantedBy=timers.target
```

**The rule this is an instance of: renew at a fraction of the lifetime, never once per
lifetime.** A third is the conventional choice — it is what ACME clients do by default and
why Let's Encrypt's 90-day certificates are renewed at 60 days.

---

## Defect D — withdrawn

🛑 **Not a defect. Do not file it.** Disproved 2026-08-18; the summary is in
[section 3](#3-defect-d-is-disproved--the-ordering-is-not-a-bug). This section is kept because
a wrong claim that survived two write-ups is worth more as a record than as a deletion.

### The claim

`systemd/system/openchami-cert-renewal.service`, unchanged between v0.1.6 and `main`:

```ini
[Service]
Type=oneshot
ExecStart=systemctl restart acme-deploy
ExecStart=systemctl restart acme-register
ExecStart=systemctl restart haproxy
```

We read this as *deploy the old certificate → mint a new one and leave it undeployed → restart
haproxy onto the old one*, and concluded that haproxy always serves the previous cycle's
certificate — one expiring at almost exactly the moment of the next run.

### The half that is true

`--deploy` genuinely cannot issue. Verified in the pinned version's source, not inferred from
documentation:

```
$ grep -n "_deploy \|_deploy(\|deploy()" acme.sh      # tag 3.1.1
5513:  if [ "$Le_DeployHook" ]; then
5514:    _deploy "$Le_Domain" "$Le_DeployHook"
5802:_deploy() {
5840:deploy() {
```

Line 5513 sits inside `renew()`, immediately after its call to `issue()`. There is **no call to
`_deploy` from `issue()`**. `acme-register` runs `--issue --force`, entering `issue()` directly,
so the `Le_DeployHook=haproxy` saved by a previous `--deploy` is never invoked.

*Observed. Still true, and still the reason the ordering reads wrong.*

### The half that is false

systemd restarts the rest of the chain regardless. `acme-deploy` has
`Requires=acme-register.service`; `haproxy` has `Requires=acme-deploy.service`; a restart
propagates along that chain. Measured at both refs with dummy units:

```
v0.1.6 — restart t-register:  t-register 15:54:50.238 → t-deploy .242 → t-proxy .245
main   — restart t-register:  t-register 15:54:55.889 → t-deploy .893 → t-proxy .895
```

So upstream's second `ExecStart` re-runs deploy and haproxy *after* the new certificate exists,
in the right order. The first `ExecStart` is redundant work on a stale certificate — untidy,
not broken.

### Our counter-evidence, and what it actually showed

```
head$ sudo systemctl start openchami-cert-renew.service     # at 13:56:30 UTC
    Process: ExecStart=/usr/bin/systemctl restart acme-register  (status=0/SUCCESS)
    Process: ExecStart=/usr/bin/systemctl restart acme-deploy    (status=0/SUCCESS)
    Process: ExecStart=/usr/bin/systemctl restart haproxy        (status=0/SUCCESS)

head$ echo | openssl s_client -connect demo.openchami.cluster:8443 … | openssl x509 -noout -dates
notBefore=Aug 13 13:55:44 2026 GMT       ← minted during this run
```

*Observed* — and it shows **our** order works. It never showed upstream's fails, because we
never ran upstream's unit. That gap sat in the file, correctly labelled, for five days while the
conclusion built on it was stated as fact elsewhere.

⚠ **A caveat you have written down is not a caveat you have acted on.** This file said plainly
*"We have not run upstream's unit"* and listed the test that would settle it. [Issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md)
meanwhile asserted the conclusion without the caveat, and so did an early draft of the upstream
report. **Label an inference once and it stays labelled; repeat it elsewhere and the label falls
off.**

### If anyone still wants the reorder

It is defensible as tidying — `register → deploy → haproxy` says what it means and does not
depend on a dependency edge two files away — but it fixes nothing, and a PR that claims
otherwise will be refuted by the first maintainer who runs it. **Leave it out of the report**,
or mention the redundant first restart as a footnote and nothing more.

---

## A fifth thing, in a different file

`scripts/openchami-certificate-update` — the supported way to change the certificate's FQDN —
prints this after writing its override:

```
Either restart all of the OpenCHAMI services:

  sudo systemctl restart openchami.target

or run the following to just regenerate/redeploy the certificates:

  sudo systemctl restart acme-deploy
```

The second path cannot work. `--deploy` does not issue, and `Requires=acme-register.service`
does not re-run an already-active `RemainAfterExit=yes` oneshot — so this redeploys the
certificate bearing the **old** FQDN, and reports success for doing it. The first path is
fine: restarting the target propagates to both ACME units via `PartOf=`.

*Observed in the script at `main`. The failure is inferred from the same acme.sh and systemd
semantics as defect D, and would be settled by the same test.*

📌 **Worth a separate, small PR rather than folding into the main one.** Same misunderstanding,
different code path — and OpenCHAMI's CONTRIBUTING explicitly asks for smaller PRs.

---

## The adjacent upstream issue

[`OpenCHAMI/release#57`](https://github.com/OpenCHAMI/release/issues/57) — *"[Feature]: Restart
containers after certificates rotate"*, opened 2026-06-01 by `spresse1`, still open. The
reporter sees `coresmd-coredns` failing to validate an expired certificate and concludes that
coresmd needs restarting after every rotation; their workaround is a cron job, and they say
they are *"having to manually restart OpenCHAMI daily."*

**Defect A explains it in full.** No timer is running on their host, so nothing is rotating
automatically; the daily hand-restart re-mints a 24-hour certificate at roughly 24-hour
intervals, and it expires shortly before each one. The 12-second overrun in their log is that
arithmetic.

Two things follow:

1. Enabling a timer at a fraction of the lifetime fixes #57 outright, and nobody needs to
   restart coresmd on a schedule.
2. Their instinct was sound given what they could see. ⚠ **Do not tell them their diagnosis is
   wrong.** They asked for the thing that would have helped; our contribution is the layer
   underneath.

📌 **It also settles a question for us.** Issue 006 deliberately leaves coresmd out of our
renewal timer, reasoning that coresmd validates against the **root** CA and a new leaf needs
nothing from it. `tw-head` has renewed three times a day since 2026-08-15 with no coresmd
restart and no errors — which is the evidence that closes #57, and we already have it. It can
be read out of the journal without touching anything.

---

## What was validated, and how

✅ **All of this has been run** — 2026-08-17/18, in a disposable Rocky 9.8 Lima VM on the Mac.
🛑 **Nothing ran on `tw-head`.** The only thing taken from the live cluster is journal history
we already had. Procedure and full captures:
[`runbooks/upstream-openchami-prs.md`](../runbooks/upstream-openchami-prs.md); harness in
[`templates/upstream-test/`](../templates/upstream-test/).

```
mac$ limactl start --name=ochami-upstream --cpus=2 --memory=4 --disk=30 --tty=false template://rocky-9
vm$  sudo dnf install -y podman rpm-build rpmdevtools systemd-rpm-macros make git jq openssl
```

**Defects A and B need no containers** — `is-enabled` and `list-timers` answer without anything
running. On pristine `main`:

| | Result |
|---|---|
| fresh install → `systemctl is-enabled openchami-cert-renewal.timer` | `disabled` — **defect A** ✅ |
| then `systemctl enable --now`, then `list-timers` | `NEXT` is `-`, `NextElapseUSecMonotonic=infinity` — **defect B** ✅ |
| fresh install of the fix, nothing typed after | `enabled`, `active`, `NEXT=Mon 2026-08-17 16:00:11 BST` ✅ |
| **upgrade** pristine → fixed | `enabled`, `active`, `NEXT` populated, config preserved ✅ |
| `rpm -e` | no unit files, no dangling symlink ✅ |

**Defect D was disproved** by the dependency harness — see
[section 3](#3-defect-d-is-disproved--the-ordering-is-not-a-bug). No ACME pipeline test was
needed, and none was run.

⚠ **Three traps, each of which produced a false result before it was caught.**

1. **`make` reuses a stale source tarball.** Twice, "the fix does nothing" was actually the
   unpatched RPM being reinstalled. `rm -rf ~/rpmbuild` before every build, and **assert on the
   built artifact**, not on the source tree:
   `rpm -qlp …rpm | grep -c preset`, `rpm -qp --scripts …rpm | grep -c 'enable --now'`.
2. **`dnf remove` leaves `timers.target.wants` symlinks and `/var/lib/systemd/timers` stamps
   behind.** An "enabled" reading after installing the fix was, once, a leftover from a manual
   `enable` two tests earlier. Wipe both between runs, and print the residual counts as part of
   the test.
3. **No `%` may appear in a unit's `ExecStart`.** systemd reads it as a specifier — `%H` is the
   hostname — so `date +%H:%M:%S` silently mangles the command and the unit appears not to run
   at all. The first harness passed `bash -n`, looked correct, and returned a false negative on
   both refs.

📌 **The common thread: every one of these produced a *plausible* wrong answer rather than an
error.** A stale RPM, a leftover symlink and a mangled `ExecStart` all fail by quietly agreeing
with whatever you expected. **Assert on the artifact you are about to measure, not on the thing
you think produced it.**

### One thing the fix needed that source-reading missed

`%systemd_post` alone is **not** sufficient, and only testing showed it:

- it does not *start* the timer, so a host installed and not rebooted has an enabled timer with
  nothing scheduled;
- it only applies the preset on **initial installation**, so **every existing cluster upgrading
  from a broken release stays broken** — which is the population the whole report is about.

Hence the explicit `systemctl enable --now` in `%post` alongside the preset. 📌 State the
trade-off in the PR: it re-enables a timer an operator may have deliberately disabled. Offer to
drop it for strict preset semantics, but say plainly what that costs.

### Before filing

- [x] Re-check `%post` at HEAD — done 2026-08-17, unchanged
- [x] Verify no preset or other enable path exists — full-repo grep, done
- [x] Verify acme.sh `--issue` does not run the deploy hook — source-checked at tag 3.1.1
- [x] Re-read #57 in the original and fix our quote — done
- [x] Reproduce defects A and B on a clean install — done 2026-08-17, captured above
- [x] Test defect D before filing it — done, and it **disproved** the claim. Withdrawn
- [x] Verify the fix on fresh install, upgrade and uninstall — done 2026-08-18
- [ ] Confirm `rpm -q openchami` on `tw-head` — read-only, safe. We still only *assume* v0.1.6
- [ ] Pull the coresmd journal evidence across a renewal boundary — read-only, and it is the evidence that closes #57
- [ ] Check whether the `deployment-recipes` Ansible path enables a timer by another route — it is a separate install path and may not have this bug
- [ ] Search Slack `#openchami` — #57 references thread `p1780222681743229`, which may already contain the answer
- [ ] Re-read #57 in the original once more immediately before posting

### Where to file

Comment on **#57** first with the root cause, addressing `synackd`'s reply — *"Perhaps we could
add a systemd timer for it"* — since it confirms the shipped timer's existence is not widely
known. Then one PR carrying the spec change and the timer change; both are independently
defensible, so split them into two commits and a reviewer can take either.

🛑 **The ordering is not a third commit.** It was withdrawn — see
[Defect D](#defect-d--withdrawn).

📌 **File this *after* [todo-002](todo-002-versitygw-region-openstack-az-upstream.md)'s PR has
been through review.** That one is a single line in a single file with no existing issue to
navigate; it tells us how this project reviews before we bring the larger report. Procedure in
[`runbooks/upstream-openchami-prs.md`](../runbooks/upstream-openchami-prs.md).

The `openchami-certificate-update` fix goes in its own small PR afterwards — ⚠ **and is
untested**, so test it or drop it. It rests on the same reasoning that produced defect D.

---

## Environment

| | |
|---|---|
| Head node | `tw-head`, Rocky 9.6, OpenStack (Digital Labs, `techwatch-proto`, AZ `DL-Rack-5`) |
| OpenCHAMI | release RPM installed 2026-08-06 21:29 UTC — version unconfirmed, likely `v0.1.6` |
| ACME client | `docker.io/neilpang/acme.sh:3.1.1` |
| CA | `ghcr.io/openchami/local-ca:v0.2.6` (step-ca), 24 h default `maxTLSCertDuration`, 60 s backdate |
| Affected client | `ghcr.io/openchami/coresmd:v0.4.3` |
| FQDN | `demo.openchami.cluster` |
| Test rig | Lima 2.1.4, `rocky-9` template, aarch64. All four pipeline images publish `linux/arm64` |

## References

- Our issues: [006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) (the expiry), [010](../issues/010-cert-renewal-timer-has-no-margin.md) (the margin, in our own fix)
- [`OpenCHAMI/release`](https://github.com/OpenCHAMI/release) — `systemd/system/openchami-cert-renewal.{service,timer}`, `openchami.spec` `%post`, `scripts/bootstrap_openchami.sh`, `scripts/openchami-certificate-update`
- [`#5`](https://github.com/OpenCHAMI/release/pull/5) — added the renewal units, 2025-05-02
- [`#50`](https://github.com/OpenCHAMI/release/pull/50) — the fabrica refactor that added the `PartOf=` chain, 2026-08-05
- [`#61`](https://github.com/OpenCHAMI/release/pull/61) — moved unit install path, 2026-08-07
- [`#57`](https://github.com/OpenCHAMI/release/issues/57) — the adjacent open issue
- systemd `src/core/timer.c`, `timer_enter_waiting()` — the `base <= 0 → continue` behaviour
- acme.sh 3.1.1 line 5513 — `_deploy` called only from `renew()`
- Tutorial §5.9 (FQDN and certificates), §5.10 (⚠ restart coresmd after certificate changes)
