# 006 — the OpenCHAMI TLS certificate lives 24 hours, and nothing renews it

| | |
|---|---|
| **Status** | Worked around — a renewal timer is installed on `tw-head`. **Not yet in the tutorial or the IaC.** Root cause is upstream and unreported → [`notes/todo-001-openchami-cert-renewal-upstream.md`](../notes/todo-001-openchami-cert-renewal-upstream.md) |
| **Hit at** | Nowhere in particular — it fires 24 hours after §5.9, wherever you happen to be |
| **Observed** | 2026-08-13 11:36 UTC, `tw-head`, Digital Labs (`techwatch-proto`), AZ `DL-Rack-5`. Certificate had been dead since 2026-08-07 21:29 UTC — **six days** |
| **Fix verified** | 2026-08-13 13:56 UTC — fresh certificate served, coresmd cache refreshed from SMD. **Verified unattended 2026-08-14 03:02 UTC** — see below |
| **Versions** | OpenCHAMI release RPM, `coresmd` v0.4.3, `acme.sh` 3.1.1, `step-ca` (`local-ca` v0.2.6), Rocky 9.6 |
| **Affects** | Every OpenCHAMI install from the release RPM, on any cloud or metal. Nothing to do with OpenStack |
| **Corrected** | 2026-08-18 — two claims in this file about *upstream's* units were disproved by testing. Upstream's ordering does **not** serve a stale certificate, and enabling its timer does **not** fix the expiry (it cannot fire). Marked inline where they occurred |

## ✅ The timer fired on its own, and the certificate moved

Installed 2026-08-13, first unattended run 2026-08-14 03:02 UTC:

```
head$ systemctl status openchami-cert-renew.service --no-pager | head -20
○ openchami-cert-renew.service - Renew the OpenCHAMI TLS certificate and reload haproxy
     Active: inactive (dead) since Fri 2026-08-14 03:03:01 UTC; 5h 45min ago
TriggeredBy: ● openchami-cert-renew.timer
    Process: 135001 ExecStart=/usr/bin/systemctl restart acme-register (code=exited, status=0/SUCCESS)
    Process: 137444 ExecStart=/usr/bin/systemctl restart acme-deploy   (code=exited, status=0/SUCCESS)
    Process: 137686 ExecStart=/usr/bin/systemctl restart haproxy       (code=exited, status=0/SUCCESS)

head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
notBefore=Aug 14 03:01:52 2026 GMT
notAfter=Aug 15 03:02:52 2026 GMT
```

🛑 **`notAfter` is the assertion. `LAST` on the timer is not.** `systemctl list-timers` showing a populated `LAST` proves only that systemd *started* the unit — and the entire upstream defect this issue documents is a renewal path that runs and achieves nothing. The previous certificate expired `Aug 14 13:58:08`; this one runs to `Aug 15 03:02:52`. That movement is what closes it.

📌 **All three steps exited `0` in sequence** — `acme-register` issues, `acme-deploy` writes the combined PEM, `haproxy` reloads and serves it. ⚠ **This paragraph used to claim upstream's ordering serves a stale certificate. It does not** — systemd propagates the restart along `Requires=` and re-runs deploy and haproxy after the new certificate exists. Corrected in [Why our unit differs](#why-our-unit-differs-from-upstreams); what we do send upstream is in [`todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md).

⚠ **Three renewals is the number to trust, not one.** A single success proves the units work when the certificate is already near expiry and `step-ca` is healthy. Recurrence, `notAfter` advancing each day, and no drift in the timer's schedule are what prove the mechanism. Check again on 15 and 16 August before treating this as settled for the PTR.

🛑 **And that re-check found a defect in this very fix — see [issue 010](010-cert-renewal-timer-has-no-margin.md).** The timer above renews once per 24-hour lifetime at a randomised time, which means it lands *after* expiry on roughly half of days. The units are right; the schedule is not. Read 010 before copying this timer anywhere.

⚠ **This is the "works now, fails later" shape, at its purest.** §5 completes, its checkpoints pass, and everything is genuinely correct. Twenty-four hours later the cluster is quietly broken, and the thing that breaks is not the thing you were working on. We ran §§6–10 across six days without noticing.

## The symptom

Every 30 seconds, in `coresmd-coredhcp`:

```
head$ sudo podman logs --tail 4 coresmd-coredhcp
time="2026-08-13T11:36:15Z" level=info msg="initiating cache refresh" prefix="plugins/coresmd"
time="2026-08-13T11:36:15Z" level=error msg="failed to refresh cache: failed to fetch
  EthernetInterfaces from SMD: failed to execute HTTP request:
  Get "https://demo.openchami.cluster:8443/hsm/v2/Inventory/EthernetInterfaces":
  tls: failed to verify certificate: x509: certificate has expired or is not yet valid:
  current time 2026-08-13T11:36:15Z is after 2026-08-07T21:29:06Z" prefix="plugins/coresmd"
```

**And nothing else.** DHCP still works, nodes keep their addresses, Kubernetes is untouched. That is the whole problem — see [Why nothing appeared to be wrong](#why-nothing-appeared-to-be-wrong).

## Concepts you need for this one

**The certificate pipeline** (§5, and the [glossary](../glossary/openchami.md#the-certificate-pipeline)). OpenCHAMI's APIs sit behind haproxy on port 8443 with TLS. The certificate is issued by a private CA running *inside the head node* — `step-ca` — over **ACME**, the same protocol Let's Encrypt uses. Three containers cooperate:

| Unit | What it does |
|---|---|
| `acme-register` | `acme.sh --issue` — asks step-ca for a certificate, writes it into the `acme-certs` volume |
| `acme-deploy` | `acme.sh --deploy` — copies whatever is *already* in `acme-certs` into the `haproxy-certs` volume |
| `openchami-cert-trust` | installs step-ca's **root** CA into the head's system trust store |

⚠ **`--issue` and `--deploy` are separate operations, and the order matters.** Deploying does not issue. This is the crux of both the local fix and the upstream bug.

**Root CA vs leaf certificate.** step-ca's root is long-lived and does not change here. What expired is the **leaf** — the per-hostname certificate for `demo.openchami.cluster`. Clients (coresmd) validate the leaf against the root. So a new leaf needs no action from clients; a new *root* would. That distinction is why the fix below does not disturb coresmd's trust configuration.

**`Type=oneshot` with `RemainAfterExit=yes`.** Seven of OpenCHAMI's nineteen units are one-shots (§5.6). They run once, exit 0, and report `active (exited)` forever after. `active` here means "it succeeded once", **not** "it is doing anything". Both ACME units are of this kind.

## Why it occurs

The certificate has a **24-hour** lifetime, and nothing ever runs `acme-register` a second time.

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 -servername demo.openchami.cluster 2>/dev/null \
        | openssl x509 -noout -subject -issuer -dates
subject=CN=demo.openchami.cluster
issuer=O=OpenCHAMI, CN=OpenCHAMI Intermediate CA
notBefore=Aug  6 21:28:06 2026 GMT
notAfter=Aug  7 21:29:06 2026 GMT
```

Twenty-four hours and one minute, because step-ca backdates `notBefore` by 60 s for clock skew. 24 h is step-ca's default `maxTLSCertDuration`, taken as shipped.

That is not a fault on its own — short-lived certificates with automated renewal is the *correct* design, and the whole reason step-ca exists. The fault is that the automation never runs:

```
head$ systemctl list-timers --all --no-pager | grep -iE 'acme|cert|step'
head$
```

Nothing. No timer, no cron, no `Restart=`. And the units that would do the work last ran when §5.9 did:

```
head$ systemctl status acme-register --no-pager | head -3
● acme-register.service - The acme-register container
     Loaded: loaded (/etc/containers/systemd/acme-register.container; generated)
     Active: active (exited) since Thu 2026-08-06 21:29:08 UTC; 6 days ago
```

`active (exited) since 6 days ago` against a certificate that lived 24 hours. The certificate was doomed from the moment it was issued.

📌 **Upstream ships a renewal timer. The RPM never enables it.** `OpenCHAMI/release` has contained both `systemd/system/openchami-cert-renewal.service` and `.timer` since May 2025, and `openchami.spec` packages them — into `/etc/systemd/system/` in v0.1.6, `/usr/lib/systemd/system/` from v0.2.0. But the `%post` scriptlet only calls `systemctl daemon-reload` and `bootstrap_openchami.sh` — there is no `systemctl enable`, no `%systemd_post` macro, and no preset file. `bootstrap_openchami.sh` does not mention systemd at all. So the units land on disk, correctly written, and sit there disabled forever. Full analysis in [`notes/todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md).

Worth confirming on your own head node, because it tells you whether the file is even present:

```
head$ ls -la /etc/systemd/system/openchami-cert-renewal.* /usr/lib/systemd/system/openchami-cert-renewal.* 2>/dev/null
head$ systemctl is-enabled openchami-cert-renewal.timer
head$ rpm -q openchami
```

## Why nothing appeared to be wrong

This is the part worth internalising, because it is why six days passed.

**Kubernetes does not use this certificate.** Talos has its own PKI end to end — etcd, the API server, kubelet. Nothing in §§10–11 touches port 8443. A completely healthy `kubectl` proves nothing about OpenCHAMI's TLS.

**coresmd kept serving DHCP from a stale cache.** It refreshes SMD's inventory every 30 s, and *the refresh is the only thing that failed*. The last good copy stayed in memory and kept answering:

```
time="2026-08-13T11:44:50Z" level=info msg="assigning 172.16.0.1 to 52:54:00:be:ef:01 (Node)
  with a lease duration of 1h0m0s" prefix="plugins/coresmd"
```

Correct address, correct MAC, six days after the certificate died.

🛑 **So the danger is a restart, not the expiry.** coresmd's cache is the only thing holding the provisioning network together while the certificate is dead. Restart `coresmd-coredhcp` with an expired certificate and it comes up with an **empty** cache, cannot populate it, and falls through to the `bootloop` plugin — nodes get `172.16.0.200`-`250` addresses instead of their real ones as each 1-hour lease expires, and the cluster comes apart. That is the §5.10 warning arriving by a different road.

⚠ **Fix the certificate *before* restarting coresmd. Never the other way round.**

## How to diagnose it

Four commands, in this order. Each one narrows it.

```
head$ sudo podman logs --tail 20 coresmd-coredhcp
```
→ `certificate has expired or is not yet valid: current time … is after <date>`. Read the date: that is when your certificate died.

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 -servername demo.openchami.cluster 2>/dev/null \
        | openssl x509 -noout -subject -issuer -dates
```
→ confirms it from the server side, and tells you the lifetime. If `notAfter - notBefore` is ~24 h, you have this issue.

```
head$ systemctl list-timers --all --no-pager | grep -iE 'acme|cert|step'
```
→ **empty output is the diagnosis.** No renewal mechanism exists.

```
head$ systemctl status acme-register --no-pager | head -3
```
→ `active (exited) since <install date>`. Confirms it has not run since §5.9.

## Solutions

### What does not work

**Restarting `acme-deploy` alone.** This was our first instinct and it is wrong. Read its `ExecStart`:

```
ExecStart=/usr/bin/podman run --name acme-deploy … docker.io/neilpang/acme.sh:3.1.1 \
    --deploy --ca-bundle /root_ca/root_ca.crt --server https://step-ca:9000/acme/acme/directory \
    -d demo.openchami.cluster --home /acme.sh --standalone --deploy-hook haproxy --force
```

`--deploy`, not `--issue`. It copies whatever is in the `acme-certs` volume into `haproxy-certs`. That is the *expired* certificate. You would redeploy a dead certificate and get `Success` in the log for doing it.

⚠ **`acme-deploy` logs `Reload successful` and it means nothing.** That line comes from acme.sh's generic haproxy deploy-hook, which assumes haproxy is a local process it can signal. Here haproxy is a separate container on a separate network — acme.sh cannot reach it. haproxy reads its certificate at startup and must be restarted explicitly.

**Enabling upstream's `openchami-cert-renewal.timer`, if the RPM put it on your disk.** 🛑 **This changes nothing at all** — a stronger statement than the one that used to be here, which said it would fix the expiry but run the restarts in the wrong order. Both halves were wrong. The timer's only schedule directive is `OnUnitActiveSec=1d`, which is relative to the last activation of the service it triggers; on a host where that service has never run there is no anchor, so systemd computes no next elapse and **the timer never fires**. Verified on a clean install:

```
vm$ sudo systemctl enable --now openchami-cert-renewal.timer
vm$ systemctl list-timers --all --no-pager openchami-cert-renewal.timer
NEXT LEFT LAST PASSED UNIT                         ACTIVATES
-    -    -    -      openchami-cert-renewal.timer openchami-cert-renewal.service
```

`enabled`, `active`, and `NextElapseUSecMonotonic=infinity`. `Persistent=true` does not rescue it — that applies only to `OnCalendar=`. Full analysis in [`notes/todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md).

### The immediate fix

Re-issue, redeploy, then restart the consumer:

```
head$ sudo systemctl restart acme-register     # --issue: mint a new leaf from step-ca
head$ sudo systemctl restart acme-deploy       # --deploy: copy it into haproxy-certs
head$ sudo systemctl restart haproxy           # load it
```

Verify **before** touching anything else:

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 -servername demo.openchami.cluster 2>/dev/null \
        | openssl x509 -noout -dates
notBefore=Aug 13 13:55:44 2026 GMT
notAfter=Aug 14 13:56:44 2026 GMT
```

`notAfter` in the future. Only now is it safe to restart coresmd:

```
head$ sudo systemctl restart coresmd-coredhcp coresmd-coredns
head$ sudo podman logs --tail 10 coresmd-coredhcp
time="2026-08-13T13:58:23Z" level=info msg="Cache updated with 10 EthernetInterfaces and 10 Components" prefix="plugins/coresmd"
time="2026-08-13T13:58:23Z" level=info msg="starting TFTP server on port 69 with directory /tftpboot" prefix="plugins/coresmd"
time="2026-08-13T13:58:23Z" level=info msg="coresmd plugin initialized with base URL https://demo.openchami.cluster:8443 and validity duration 30s" prefix="plugins/coresmd"
```

✅ **`Cache updated with 10 EthernetInterfaces and 10 Components` is the assertion.** Not "no errors" — an actual successful TLS fetch that returned data. Ten of each, matching §6's inventory.

### The durable fix

The immediate fix buys 24 hours. Install a timer:

```
head$ sudo tee /etc/systemd/system/openchami-cert-renew.service > /dev/null << 'EOF'
[Unit]
Description=Renew the OpenCHAMI TLS certificate and reload haproxy
After=openchami.target

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart acme-register
ExecStart=/usr/bin/systemctl restart acme-deploy
ExecStart=/usr/bin/systemctl restart haproxy
EOF
head$ sudo tee /etc/systemd/system/openchami-cert-renew.timer > /dev/null << 'EOF'
[Unit]
Description=Daily OpenCHAMI TLS certificate renewal

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
head$ sudo systemctl daemon-reload
head$ sudo systemctl enable --now openchami-cert-renew.timer
head$ systemctl list-timers openchami-cert-renew.timer --no-pager
NEXT                        LEFT     LAST PASSED UNIT                       ACTIVATES
Fri 2026-08-14 03:13:14 UTC 13h left -    -      openchami-cert-renew.timer openchami-cert-renew.service
```

⚠ **`enable --now` on a *timer* starts the timer, not the service.** `LAST` is `-`; nothing has been renewed. And `Persistent=true` only replays a *missed* window, which needs a previous run to compare against — on a first install there is none, so it will not fire early. **Run the service once by hand**, which also proves the unit works:

```
head$ sudo systemctl start openchami-cert-renew.service
head$ systemctl status openchami-cert-renew.service --no-pager | head -9
    Process: 122849 ExecStart=/usr/bin/systemctl restart acme-register (code=exited, status=0/SUCCESS)
    Process: 125298 ExecStart=/usr/bin/systemctl restart acme-deploy (code=exited, status=0/SUCCESS)
    Process: 125544 ExecStart=/usr/bin/systemctl restart haproxy (code=exited, status=0/SUCCESS)
```

All three `0/SUCCESS`, ~23 seconds. Then check the certificate dates as above.

**Why 03:00 daily against a 24-hour certificate.** Renewal at 03:00 with up to 15 minutes of jitter, against a certificate minted at whatever time you last ran it, gives at least ten hours of margin in the observed case. It is not elegant — the honest design is renewal at half the lifetime — but a fixed daily slot is legible, and the alternative (raising step-ca's `maxTLSCertDuration`) means editing `ca.json` inside the CA's volume and restarting the CA on a working cluster.

🛑 **The name is what keeps these safe, not the directory.** Ours are `openchami-cert-**renew**`; upstream's are `openchami-cert-**renewal**`. That one syllable is the whole separation — and in release RPM **v0.1.6, which is what this head node has, upstream installs its units into `/etc/systemd/system/` too**, the same directory we just wrote into. (v0.2.0 moved them to `/usr/lib/systemd/system/`, which is where RPM-owned units belong.) So do not "tidy up" by renaming ours to match, and do not assume `/etc` means "mine".

If upstream ever fixes this and you enable theirs, **disable ours** — otherwise the certificate is re-issued twice a day for no reason, and you have two units fighting over `haproxy`.

⚠ **No coresmd restart in the timer, deliberately.** coresmd validates against the **root** CA, which renewal never changes. A fresh leaf needs nothing from it, and this cluster has renewed three times a day since 15 August with no coresmd restart and no errors. Upstream issue [#57](https://github.com/OpenCHAMI/release/issues/57) argues otherwise; its reporter is renewing **by hand** at roughly 24-hour intervals against a 24-hour certificate, because nothing automated is running on their host — which is the expiry arithmetic, not a client-side staleness problem. See [`notes/todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md).

### Why our unit differs from upstream's

⚠ **Rewritten 2026-08-18. The claim this section used to make was wrong**, and it was the
central claim we were preparing to send upstream. Kept in corrected form because the way it
failed is more useful than the conclusion was.

Upstream's `openchami-cert-renewal.service` restarts things in this order:

```
ExecStart=systemctl restart acme-deploy
ExecStart=systemctl restart acme-register
ExecStart=systemctl restart haproxy
```

We read that as *deploy the old certificate → mint a new one and leave it undeployed → restart
haproxy onto the old one*, and concluded haproxy would always serve the previous cycle's
certificate. The mechanism underneath is real and still verified: **`--deploy` cannot issue.**
In `acme.sh` 3.1.1, `_deploy` is called only from `renew()` at line 5513, never from `issue()`,
and `acme-register` runs `--issue --force` — so the saved `Le_DeployHook` is not invoked.

**But the conclusion does not follow, because systemd restarts the rest of the chain anyway.**
`acme-deploy` has `Requires=acme-register.service`, `haproxy` has `Requires=acme-deploy.service`,
and a restart propagates along that chain. Modelled with dummy units at both upstream refs and
measured:

```
v0.1.6 — restart t-register:  t-register 15:54:50.238 → t-deploy .242 → t-proxy .245
main   — restart t-register:  t-register 15:54:55.889 → t-deploy .893 → t-proxy .895
```

So upstream's second command re-runs deploy and haproxy *after* the new certificate exists, in
the right order. Their sequence wastes one deploy and one haproxy restart on the old
certificate; it does **not** leave a stale one in front of clients.

📌 **Ours is still the order to prefer** — it says what it means, and it does not depend on a
dependency edge two files away — but it is a tidier unit, not a fix for an outage. Do not cite
this as a bug.

⚠ **The lesson, and it is this repository's own rule turned on us.** We verified a mechanism in
source, inferred an outcome from it, wrote the outcome down as fact, and never ran the thing.
The `Requires=` lines were in the quadlets we had already read. **A mechanism you have proved
tells you what one component does; only running it tells you what the system does.**

📌 **It also matters for what we file.** [`notes/todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md)
carries three defects that survived testing — the timer is never enabled, it cannot fire even
when enabled, and its period equals the certificate lifetime. The ordering is not a fourth.

## What this cost us

Six days of a dead certificate, and — indirectly — most of a debugging session. When [005](005-platform-storage-stall.md)'s storage stall was cleared and we came back to a healthy head node, this was still throwing an error every 30 seconds, and it read like fresh damage from the outage. It was not. **The two faults are unrelated and overlapped by accident**: the certificate expired on 7 August, the storage stalled on 11 August.

⚠ **After any incident, date every error you find before attributing it to the incident.** The certificate's `notAfter` said 7 August; the storage stall started on the 11th. One line of output separated "caused by the outage" from "was already broken".

## Checkpoint

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 -servername demo.openchami.cluster 2>/dev/null \
        | openssl x509 -noout -dates
⟨notAfter in the future⟩

head$ systemctl list-timers openchami-cert-renew.timer --no-pager
⟨NEXT within 24h, and after a run, LAST populated⟩

head$ sudo podman logs --tail 5 coresmd-coredhcp | grep -c 'level=error'
0
```

## Common failures

| Symptom | Cause / fix |
|---|---|
| `x509: certificate has expired` in `coresmd-coredhcp` | this issue. Fix the certificate, *then* restart coresmd |
| Certificate still expired after restarting `acme-deploy` | `--deploy` does not issue. Restart `acme-register` first |
| Certificate re-issued but haproxy still serves the old one | haproxy reads its certificate at startup — `sudo systemctl restart haproxy` |
| Nodes on `172.16.0.200`-`250` after a coresmd restart | coresmd restarted with a dead certificate, cache empty, `bootloop` plugin serving. Fix the certificate and restart coresmd again |
| Timer installed, certificate still expired | `enable --now` starts the *timer*. Run `systemctl start openchami-cert-renew.service` once by hand |
| `ochami` or `s3cmd` TLS errors, days after a working §5 | same root cause; check `notAfter` before anything else |
