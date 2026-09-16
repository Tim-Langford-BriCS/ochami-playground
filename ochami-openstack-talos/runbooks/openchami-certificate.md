# The OpenCHAMI TLS certificate — check, renew, investigate

**The certificate on port 8443 lives 24 hours.** That is by design, not a fault — but it means this is the one part of the head node that has to keep working on its own, forever, and the one most likely to be quietly broken when you come back to it.

This runbook is for four tasks. Commands first; the mechanism is explained underneath.

| I want to… | Go to |
|---|---|
| Check whether the certificate is currently healthy | [The 30-second check](#the-30-second-check) |
| Fix it — it has expired | [Renew it by hand](#renew-it-by-hand) |
| Confirm the automatic renewal is actually working | [Is the timer doing its job?](#is-the-timer-doing-its-job) |
| Know why I should care, and what breaks if this fails | [What this protects](#what-this-protects-and-what-breaks-without-it) |
| Understand what any of this is | [How the pipeline works](#how-the-pipeline-works) |
| Read a certificate properly | [Reading certificates](#reading-certificates) |

The fault that made this necessary is [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md); the upstream half is [`todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md). Dated results of the recurring check live in [`notes/scheduled-checks.md`](../notes/scheduled-checks.md) — **record them there, not here**, so this file stays a procedure rather than a logbook.

---

## What this protects, and what breaks without it

Worth reading once before the commands, because the blast radius is not obvious from the error message.

**What the certificate is for.** Every OpenCHAMI API — SMD (inventory), BSS (boot scripts), and the rest — sits behind haproxy on port `8443`, and that port is TLS. The certificate is the *only* thing standing between those APIs and every client that talks to them. It is not decorative and there is no fallback to plaintext.

**Who depends on it:**

| Consumer | What it does with the API | What an expired certificate costs it |
|---|---|---|
| `coresmd-coredhcp` | refreshes its inventory cache from SMD every 30 s | **nothing immediately** — it keeps serving DHCP from the last good cache |
| `coresmd-coredns` | the same inventory, for names | as above |
| a node **network-booting** | fetches its boot script from BSS | **fails outright** — the node cannot boot while the certificate is dead |
| `ochami` CLI, `curl`, you | everything | `x509: certificate has expired`, on every call |

🛑 **The dangerous case is a restart during the gap, and it is the reason to fix this before anything else.** coresmd's in-memory cache is what holds the provisioning network together. Restart it while the certificate is expired and it comes up empty, cannot repopulate over TLS, and falls through to the `bootloop` plugin — nodes begin taking `172.16.0.200`–`250` addresses as their leases expire, and the cluster's addressing comes apart. Recovering from that is far more work than the certificate ever was.

⚠ **What does *not* break, which is why this hides so well.** The Kubernetes cluster does not consume this certificate. Talos does not. Already-booted nodes keep running, `kubectl` keeps working, workloads keep serving. You can have a completely dead OpenCHAMI control plane and a Kubernetes cluster that looks perfect — which is exactly how [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) went unnoticed for six days.

📌 **The renewal runs at ~03:00 UTC, which is the worst time for a fault to be interesting.** Nobody is watching, the errors scroll past in a container log, and by the time anyone looks the certificate is valid again. A gap that only exists between 03:02 and 03:10 is invisible to every check made during working hours — and is still a window in which an unattended reboot, a scheduled node action, or a node rebuilding itself will fail. **The absence of a complaint is not evidence the schedule is sound; check the margin instead.**

---

## The 30-second check

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
notBefore=Aug 14 03:01:52 2026 GMT
notAfter=Aug 15 03:02:52 2026 GMT
```

**`notAfter` in the future = healthy.** That is the whole test.

If you want it to answer yes/no rather than make you read dates:

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null \
      | openssl x509 -noout -checkend 3600 && echo "good for at least another hour" \
                                           || echo "EXPIRES WITHIN THE HOUR"
```

`-checkend N` exits non-zero if the certificate expires within `N` seconds. It is the right tool for a monitoring check, and it removes the date arithmetic that people get wrong at 2am.

⚠ **Check the certificate the *server is serving*, not the one on disk.** haproxy reads its certificate at startup and holds it in memory. A perfectly fresh file in the volume proves nothing if haproxy has not been restarted since — and that exact gap is the failure mode described in [Why `acme-deploy` lies to you](#why-acme-deploy-lies-to-you). `s_client` asks the running server, which is the only answer that matters.

### The other way you will notice

You usually will not run the check. You will see this instead, every 30 seconds, in the DHCP server:

```
head$ sudo podman logs --tail 4 coresmd-coredhcp
level=error msg="failed to refresh cache: failed to fetch EthernetInterfaces from SMD:
  … tls: failed to verify certificate: x509: certificate has expired or is not yet valid:
  current time 2026-08-13T11:36:15Z is after 2026-08-07T21:29:06Z"
```

Read the second date: **that is when your certificate died.** The gap between the two tells you how long you have been broken.

🛑 **Do not restart `coresmd-coredhcp` to "clear" this.** It is serving DHCP from a cache that was populated while the certificate was still valid, and that cache is the only thing holding the provisioning network together. Restart it with a dead certificate and it comes up empty, cannot repopulate, and falls through to the `bootloop` plugin — nodes start getting `172.16.0.200`–`250` addresses as their leases expire, and the cluster comes apart. **Fix the certificate first. Always.**

---

## Renew it by hand

Three units, in this order. The order is the entire point:

```
head$ sudo systemctl restart acme-register     # --issue:  mint a new leaf from step-ca
head$ sudo systemctl restart acme-deploy       # --deploy: copy it into haproxy-certs
head$ sudo systemctl restart haproxy           # load it
```

Verify before doing anything else:

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
notBefore=Aug 13 13:55:44 2026 GMT
notAfter=Aug 14 13:56:44 2026 GMT
```

Only once `notAfter` is in the future is it safe to restart the consumers:

```
head$ sudo systemctl restart coresmd-coredhcp coresmd-coredns
head$ sudo podman logs --tail 10 coresmd-coredhcp
… msg="Cache updated with 10 EthernetInterfaces and 10 Components" prefix="plugins/coresmd"
```

`Cache updated with 10 … and 10 …` is the assertion. It means a real TLS fetch from SMD succeeded — the numbers are your inventory.

⚠ **Restarting `acme-deploy` on its own does nothing useful, and looks like it worked.** Its command is `--deploy`, not `--issue`. It copies whatever is *already* in the `acme-certs` volume — which, when you are debugging an expiry, is the expired certificate. You will redeploy a dead certificate and be told `Success`.

---

## Is the timer doing its job?

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager
head$ systemctl status openchami-cert-renew.service --no-pager | head -20
```

Healthy looks like this:

```
○ openchami-cert-renew.service - Renew the OpenCHAMI TLS certificate and reload haproxy
     Active: inactive (dead) since Fri 2026-08-14 03:03:01 UTC; 5h 45min ago
TriggeredBy: ● openchami-cert-renew.timer
    Process: 135001 ExecStart=/usr/bin/systemctl restart acme-register (code=exited, status=0/SUCCESS)
    Process: 137444 ExecStart=/usr/bin/systemctl restart acme-deploy   (code=exited, status=0/SUCCESS)
    Process: 137686 ExecStart=/usr/bin/systemctl restart haproxy       (code=exited, status=0/SUCCESS)
```

Three things to read, in this order:

1. **`inactive (dead)` is correct.** This is a `oneshot`. It runs, it exits, it is dead until the timer wakes it again. `active` would be the surprising state.
2. **All three `status=0/SUCCESS`**, in that sequence — issue, deploy, reload.
3. **`TriggeredBy`** confirms the timer owns it, rather than it having been run by hand.

🛑 **Check the *margin*, not just that it ran.** This is the check that everything else misses: two numbers and one subtraction. Compare the timer's `NEXT` against the certificate's `notAfter`:

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -enddate
```

**`notAfter` minus `NEXT` is the margin.** It must be positive, and it must be *comfortably* positive — more than half the certificate's lifetime. With the 8-hourly timer it reads ~16 h. If it is minutes, or negative, you have [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md).

⚠ **A negative margin looks completely healthy on every other check**, which is why this one exists. Real output from `tw-head`, taken on two consecutive mornings under the old daily timer:

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager        # 14 Aug 23:11 UTC
NEXT                        LEFT          LAST                        PASSED
Sat 2026-08-15 03:10:11 UTC 3h 58min left Fri 2026-08-14 03:02:38 UTC 20h ago
head$ … | openssl x509 -noout -enddate
notAfter=Aug 15 03:02:52 2026 GMT                                        ← margin: MINUS 7m19s
```

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager        # 15 Aug 11:13 UTC
NEXT                        LEFT     LAST                        PASSED
Sun 2026-08-16 03:02:59 UTC 15h left Sat 2026-08-15 03:10:11 UTC 8h ago
head$ … | openssl x509 -noout -dates
notBefore=Aug 15 03:09:25 2026 GMT
notAfter=Aug 16 03:10:25 2026 GMT                                        ← margin: PLUS 7m26s
```

Same timer, same units, same everything — **a negative margin one day and a positive one the next**, decided by `RandomizedDelaySec`. The first cost 7 minutes 33 seconds of expired certificate (expiry `03:02:52`, reissue `03:10:25`); the second cost nothing. Neither day produced a failed unit, a non-zero exit, or an alert.

📌 **`notBefore` tells you when the renewal actually completed**, minus step-ca's 60-second backdate. It is the most precise timestamp you have for the end of an outage — more precise than the timer's `LAST`, which only records when systemd *started* the unit.

🛑 **`LAST` on the timer is not the assertion. `notAfter` is.** A populated `LAST` proves only that systemd *started* the unit. The upstream defect this whole area exists to work around is a renewal path that runs to completion and achieves nothing — so "it fired" and "it worked" are genuinely different claims. Always finish with:

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
```

and check that `notAfter` **moved** since you last looked.

⚠ **Two similarly-named units exist. Know which one you have.**

| Unit | Whose | State |
|---|---|---|
| `openchami-cert-renew.*` | **ours**, installed by [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) | enabled and working |
| `openchami-cert-renewal.*` | **upstream's**, shipped in the RPM | present on disk and never enabled — and enabling it achieves nothing, because `OnUnitActiveSec=1d` alone gives it no anchor and it never fires. [`todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md) |

`renew` versus `renewal`. Autocomplete will not save you. If you enable the wrong one you get a timer that fires faithfully and leaves haproxy serving the old certificate.

### If the timer does not exist at all

```
head$ systemctl list-timers --all --no-pager | grep -iE 'acme|cert|step'
head$
```

**Empty output is the diagnosis.** No renewal mechanism is installed and the certificate is on a 24-hour fuse. Go to [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md), which carries the unit files.

---

## How the pipeline works

Worth ten minutes once, because every failure below is one of these pieces not doing its job.

OpenCHAMI's APIs sit behind **haproxy** on port `8443`, with TLS. The certificate is issued by a private CA running *inside the head node* — **step-ca** — over **ACME**, the same protocol Let's Encrypt uses. Nothing external is involved; there is no public DNS, no Let's Encrypt, no internet dependency.

```
   step-ca  ──issues──▶  acme-certs volume  ──copies──▶  haproxy-certs volume  ──reads──▶  haproxy :8443
      ▲                        ▲                              ▲                                 │
      │                        │                              │                                 │
  the CA              acme-register (--issue)          acme-deploy (--deploy)             coresmd, you, kubectl-adjacent
                                                                                          clients validating against
                                                                                          step-ca's ROOT cert
```

| Unit | What it actually runs | What it changes |
|---|---|---|
| `acme-register` | `acme.sh --issue` | asks step-ca for a **new** certificate, writes it into `acme-certs` |
| `acme-deploy` | `acme.sh --deploy` | copies whatever is **already** in `acme-certs` into `haproxy-certs` |
| `haproxy` | — | reads `haproxy-certs` **at startup only** |
| `openchami-cert-trust` | — | installs step-ca's **root** CA into the head's system trust store |

🛑 **Three separate steps, three separate ways to be wrong.** `--issue` gets a new certificate but does not put it where haproxy looks. `--deploy` puts a certificate where haproxy looks but does not care whether it is new. haproxy serves whatever it read when it started. Skip any one and the pipeline silently produces the wrong result — which is why the fix is always all three, in order.

### Root CA vs leaf certificate

- The **root** is step-ca's own certificate. Long-lived, and it does not change here. It is what clients trust.
- The **leaf** is the per-hostname certificate for `demo.openchami.cluster`. 24-hour lifetime. This is what expires.

Clients validate the leaf against the root. So a new leaf needs **no action from any client** — coresmd's trust configuration is untouched by renewal. A new *root* would be a different and much larger job.

📌 **This is why "just restart coresmd" never helps.** coresmd is not the broken party. It is correctly refusing to trust an expired certificate.

### Why 24 hours

```
notBefore=Aug 14 03:01:52 2026 GMT
notAfter=Aug 15 03:02:52 2026 GMT
```

Twenty-four hours and one minute — step-ca backdates `notBefore` by 60 seconds to absorb clock skew between issuer and verifier. 24 h is step-ca's default `maxTLSCertDuration`, taken as shipped.

Short-lived certificates with automated renewal is the *correct* modern design: a leaked key is worthless within a day, and the renewal path gets exercised constantly instead of annually. The design is not the problem. The problem was that nothing renewed it.

### `Type=oneshot` and what `active` means

Seven of OpenCHAMI's units are one-shots. They run once, exit `0`, and report `active (exited)` forever after.

⚠ **`active (exited)` means "it succeeded once", not "it is doing anything".** Both ACME units are of this kind. `systemctl status acme-register` showing `active (exited) since 6 days ago` next to a certificate with a 24-hour life is the shape of this entire issue in two lines.

### Why `acme-deploy` lies to you

```
… msg="Reload successful"
```

That line comes from acme.sh's generic haproxy deploy-hook, which assumes haproxy is a local process it can signal. Here haproxy is a **separate container on a separate network**, and acme.sh cannot reach it. The hook reports success for a reload that never happened.

**So `haproxy` must be restarted explicitly, every time.** That is the third command in [Renew it by hand](#renew-it-by-hand), and it is the one people drop.

---

## Reading certificates

The commands worth knowing, roughly in order of how often you need them.

**From the wire — what the server is actually serving.** This is almost always what you want:

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates
subject=CN=demo.openchami.cluster
issuer=O=OpenCHAMI, CN=OpenCHAMI Intermediate CA
notBefore=Aug 14 03:01:52 2026 GMT
notAfter=Aug 15 03:02:52 2026 GMT
```

- `echo |` closes stdin so `s_client` exits instead of sitting there waiting for you to type HTTP.
- `-servername` sets **SNI**. Without it a server hosting several names may hand you a different certificate than the one under test — and here the hostname is exactly what is being certified.
- `2>/dev/null` drops the handshake chatter; drop the redirect when you actually want to see the chain.

**The full chain and how verification went:**

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster -showcerts 2>&1 | grep -E 'Verify|depth|s:|i:'
```

`Verify return code: 0 (ok)` is what you want. `19 (self signed certificate in certificate chain)` or `21 (unable to verify the first certificate)` means the **root** is not trusted by *this* machine — a different problem from expiry, fixed by `openchami-cert-trust`, not by renewal.

**Expiry as an exit code, for scripts:**

```
head$ … | openssl x509 -noout -checkend 3600     # non-zero if it expires within an hour
```

**A certificate file on disk:**

```
head$ sudo openssl x509 -in /path/to/cert.pem -noout -text | head -30
```

`-text` gives you everything: serial, validity, SANs, key usage. Pipe to `grep -A1 'Subject Alternative Name'` when you care about which hostnames it covers.

**What is in the volumes:**

```
head$ sudo podman volume ls | grep -E 'acme|haproxy'
head$ sudo podman volume inspect acme-certs --format '{{.Mountpoint}}'
head$ sudo ls -la "$(sudo podman volume inspect acme-certs --format '{{.Mountpoint}}')"
```

Useful for answering "did `--issue` actually write anything?" — compare file mtimes against when you ran it.

⚠ **A fresh file on disk does not mean a fresh certificate is being served.** Always finish at the wire. The disk tells you what `acme-register` and `acme-deploy` did; only `s_client` tells you what haproxy is doing about it.

**Whose clock is wrong?** `x509: certificate has expired or is not yet valid` also fires when a certificate is *not yet* valid — a clock skewed backwards on the client looks identical to expiry on the server. If the dates look fine but clients still complain:

```
head$ timedatectl                               # and the same on the complaining node
```

---

## Error table

| What you see | What it means | What to do |
|---|---|---|
| `x509: certificate has expired or is not yet valid: current time X is after Y` | The leaf expired at `Y` | [Renew it by hand](#renew-it-by-hand) |
| Same message, but the dates look fine | Clock skew between issuer and verifier | `timedatectl` on both ends |
| `x509: certificate signed by unknown authority` | The **root** is not in this machine's trust store | `openchami-cert-trust`, not renewal |
| `Verify return code: 21 (unable to verify the first certificate)` | Chain incomplete or root untrusted here | as above |
| `acme-deploy` logs `Reload successful` and nothing improves | The hook cannot reach haproxy's container | `sudo systemctl restart haproxy` |
| `acme-register` is `active (exited) since <install date>` | It has not run since installation | The renewal timer is missing or disabled |
| `systemctl list-timers … \| grep cert` is empty | No renewal mechanism at all | [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) |
| Timer `LAST` is populated but `notAfter` did not move | The renewal ran and achieved nothing | Check the `ExecStart` order — you may have upstream's `renewal` unit, not ours |
| Timer `NEXT` is *after* the certificate's `notAfter` | The schedule renews once per lifetime, so the margin is chance | [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md) — move to 8-hourly |
| Brief TLS errors in `coresmd` at the same time each day, then fine | The daily renewal is landing minutes after expiry | as above |
| DHCP hands out `172.16.0.200`–`250` | coresmd restarted with a dead certificate and lost its cache | Fix the certificate, then restart coresmd |

---

## The rules that matter

🛑 **Fix the certificate before restarting coresmd.** Never the other way round. coresmd's in-memory cache is load-bearing while the certificate is dead.

🛑 **All three units, in order: register → deploy → haproxy.** Any subset produces a plausible-looking result that is wrong.

⚠ **Assert on `notAfter` moving, not on anything succeeding.** Units exiting `0`, timers showing `LAST`, and acme.sh saying `Success` are all compatible with a certificate that never changed.

⚠ **One successful renewal is not proof.** It shows the units work when the certificate is near expiry and step-ca is healthy. What proves the mechanism is **recurrence**: `notAfter` advancing on consecutive days with no drift in the schedule. Three consecutive days is the number to trust.

⚠ **Renew at a fraction of the lifetime, never once per lifetime.** Equal periods leave the margin to chance — and to whatever jitter the timer adds. A third is the conventional choice, and it is why a 24-hour certificate is renewed every 8 hours here. [Issue 010](../issues/010-cert-renewal-timer-has-no-margin.md) is what happens when you get this wrong; nothing in any individual file looks incorrect.

## Where this came from

| Source | What it holds |
|---|---|
| [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) | The original fault, why six days passed without anyone noticing, and the unit files for the renewal timer |
| [`notes/todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md) | The upstream defect — the timer is packaged but never enabled, and its `ExecStart` order is wrong |
| [§5](../05-install-openchami.md) | Where the pipeline is installed |
| [glossary](../glossary/openchami.md#the-certificate-pipeline) | The pieces, defined |
