# Scheduled checks

**Things that must be re-checked on a date, not when we happen to think of them.** A note here is not a task waiting for someone to be free — it is a claim we have made that is not yet supported by enough evidence, with the date the evidence arrives.

The distinction from [`issues/`](../issues/README.md): an issue records a fault we fixed. This records a fix we have not yet *proved*.

| Check | When | Why it is not settled |
|---|---|---|
| [Certificate renewal recurs](#certificate-renewal-recurs) | **15 Aug 2026**, then **16 Aug** | ⚠ **Found a defect on the first re-check** — [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md). Now tracking the replacement schedule |

✅ **This file has already paid for itself, twice over.** The 14 August check found that the renewal timer renews *after* expiry on roughly half of days — a defect invisible to the first successful run, because that run renewed a certificate we had minted by hand. The mechanism could not fail until it had run twice. The 15 August check then **watched the predicted outage happen**: 7 minutes 33 seconds of expired certificate, against a forecast of 7 min 19 s. See [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md).

⚠ **And the day after was fine.** 16 August's margin is *positive* by 7m26s, on exactly the same schedule. Had the re-check landed one day later it would have found nothing wrong. **When a fault is intermittent by construction, a single check can only ever be a sample** — which is an argument for recording every result here rather than stopping at the first clean one.

---

## Certificate renewal recurs

**Claim being tested:** the `openchami-cert-renew.timer` installed by [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) keeps the certificate alive indefinitely, without anyone touching it.

**Evidence so far:** one successful unattended run, 2026-08-14 03:02 UTC. `notAfter` moved from `Aug 14 13:58:08` to `Aug 15 03:02:52`, all three `ExecStart` steps exited `0`.

**Why that is not enough.** A single success shows the units work *when the certificate is near expiry and step-ca is healthy*. It does not show:

- that the timer's schedule holds rather than drifting
- that renewal works from a certificate this mechanism itself issued, rather than one we minted by hand the day before
- that nothing accumulates across runs — stale files in `acme-certs`, a `haproxy` restart that eventually fails, acme.sh state growing

Each is the kind of thing that shows up on run two or three and never on run one.

**The check**, ~30 seconds — full detail in the [certificate runbook](../runbooks/openchami-certificate.md#is-the-timer-doing-its-job):

```
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
head$ systemctl status openchami-cert-renew.service --no-pager | head -12
```

**Passes if** `notAfter` has advanced by roughly 24 hours since the previous check *and* all three `ExecStart` lines show `status=0/SUCCESS`.

⚠ **`notAfter` is the assertion. Not `LAST`, not `SUCCESS`.** The upstream defect behind this whole area is a renewal path that runs to completion and changes nothing, so "the unit ran" is precisely the evidence that does not distinguish working from broken.

**Record of checks:**

| Date | `notAfter` observed | Result |
|---|---|---|
| 2026-08-14 | `Aug 15 03:02:52 2026 GMT` | ✅ first unattended run — but see below, this proved less than it appeared to |
| 2026-08-14 23:11 | `Aug 15 03:02:52 2026 GMT` (unchanged) | ⚠ **defect found** — next run scheduled `03:10:11`, i.e. **7m19s after expiry**. [Issue 010](../issues/010-cert-renewal-timer-has-no-margin.md) |
| 2026-08-15 11:13 | `Aug 16 03:10:25 2026 GMT` | 🛑 **defect occurred as predicted** — certificate dead `03:02:52`–`03:10:25`, **7m33s**. Margin for 16 Aug happens to be **+7m26s**: the same schedule, the other way up |
| 2026-08-15 12:37 | `Aug 16 12:37:59 2026 GMT` | ✅ **8-hourly timer applied.** `NEXT` `16:00:13` → margin **20 h 37 m**. `Persistent=true` renewed on the spot, catching up a missed `08:00` |
| 2026-08-16 | | *(expect margin ~16 h, and `notAfter` to have advanced three times)* |
| 2026-08-17 | | |
| 2026-08-18 | | |

⚠ **Why the first check was misleading, which is the transferable part.** The certificate it renewed had been minted **by hand** the previous afternoon, so its deadline was hours away and the timer's own scheduling was irrelevant. Only once the timer had set the *next* deadline itself did the arithmetic become visible. **A mechanism that determines its own next deadline cannot be validated by one run.**

### Now tracking instead: does the 8-hourly schedule hold margin?

After [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md)'s timer is applied, the assertion changes. It is no longer "did it renew" but **"how much room is there?"**:

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager     # when is the NEXT run?
head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
```

**Passes if `notAfter` minus `NEXT` is comfortably more than 12 hours**, on every check. The old schedule's margin was ±5 minutes and negative half the time; the new one should be ~16 h and never close.

📌 **`notAfter` advancing is necessary and no longer sufficient.** It advanced perfectly well under the broken schedule — just, on some days, a few minutes too late.

**When it has held for three days**, update [issue 006](../issues/006-openchami-tls-cert-expiry-no-renewal.md) and [issue 010](../issues/010-cert-renewal-timer-has-no-margin.md), and add the margin defect to [`todo-001`](todo-001-openchami-cert-renewal-upstream.md) if upstream's packaged timer shares the shape.

**If a check fails**, do not simply re-run it by hand and move on. A renewal that works when driven and fails on a timer is a *different* bug, and re-running by hand destroys the evidence for it. Capture `journalctl -u openchami-cert-renew.service --since '-24h'` first.

---

## Adding one

A check belongs here when the honest state is **"we believe this works but have not seen it work enough times"**. Give it a date, the claim, what would falsify it, and a table to record results in — the table is what stops the check being done once and forgotten.

Delete the entry once it has passed enough times to be boring. This file should stay short; anything permanent is a monitoring job, not a note.
