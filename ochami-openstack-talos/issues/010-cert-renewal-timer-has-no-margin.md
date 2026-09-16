# 010 — the certificate renewal timer renews *after* expiry, about half the time

| | |
|---|---|
| **Status** | **Fix applied 2026-08-15 12:37 UTC; margin went from −7m19s to +20h37m. Open until it has held for three days** — see [Verification plan](#verification) |
| **Hit at** | Nowhere in the tutorial. Found by a [scheduled re-check](../notes/scheduled-checks.md) of [issue 006](006-openchami-tls-cert-expiry-no-renewal.md)'s fix, the day after installing it |
| **Observed** | Predicted 2026-08-14 23:11 UTC. **Occurred 2026-08-15 03:02:52–03:10:25 UTC: 7 min 33 s of expired certificate**, against a prediction of 7 min 19 s |
| **Severity** | Low impact, high embarrassment. A few minutes of expired certificate per day, on roughly half of days — and **zero margin for a failed renewal** |
| **Cause** | **Ours.** The timer installed by issue 006 renews once per certificate lifetime, at a randomised time |

## TL;DR

The certificate lives 24 hours. The timer renews it once every 24 hours, at `03:00` plus a random delay of up to 15 minutes. Because each renewal sets the *next* expiry, tomorrow's deadline is pinned to today's random offset — so whether you renew before or after expiry depends on which way the dice fall two days running.

```
Certificate expires   Aug 15 03:02:52 UTC     ← set by yesterday's run at 03:02:38
Next renewal fires    Aug 15 03:10:11 UTC     ← today's roll of RandomizedDelaySec
                      ─────────────────────
Gap                   7 min 19 s of expired certificate
```

**Fix:** renew every 8 hours rather than every 24. Three attempts per lifetime, ~16 hours of standing margin, and a failed run becomes a warning instead of an outage.

## The evidence

```
head$ date -u
Fri Aug 14 11:11:15 PM UTC 2026

head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
notBefore=Aug 14 03:01:52 2026 GMT
notAfter=Aug 15 03:02:52 2026 GMT

head$ systemctl list-timers openchami-cert-renew.timer --no-pager
NEXT                        LEFT          LAST                        PASSED  UNIT
Sat 2026-08-15 03:10:11 UTC 3h 58min left Fri 2026-08-14 03:02:38 UTC 20h ago openchami-cert-renew.timer

head$ systemctl cat openchami-cert-renew.timer
[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15m
Persistent=true
```

Everything there is healthy. The units work, the timer is enabled, the last run succeeded, `Persistent=true` is set. The defect is entirely in the *arithmetic between* those numbers.

## Why it happens

Three facts that are individually reasonable and jointly wrong:

**1. The certificate lives 24 hours.** step-ca's default, taken as shipped ([issue 006](006-openchami-tls-cert-expiry-no-renewal.md)).

**2. The timer runs once every 24 hours.** One renewal per lifetime — the same period, which means the margin is whatever the phase difference happens to be, and nothing keeps that positive.

**3. `RandomizedDelaySec=15m` re-rolls that phase difference daily.** Each run's actual time is `03:00` + a random offset in `[0, 15m]`. Since the new certificate expires ~24 h after the run that issued it, **tomorrow's expiry inherits today's offset**:

| Day | Offset drawn | Renewal at | Sets expiry to | Versus next day's renewal |
|---|---|---|---|---|
| 14 Aug | 2m38s | 03:02:38 | 15 Aug 03:02:52 | — |
| 15 Aug | 10m11s | 03:10:11 | 16 Aug 03:1x | **7m19s too late** |

🛑 **The offset is redrawn independently each day, so this is a coin flip.** Draw a larger offset than the previous day and you renew after expiry, by the difference. Draw smaller and you are fine. Roughly half of days lose, with an expected gap of about five minutes when they do.

### Both faces of the coin, observed

The next two mornings settled it. Nothing was changed between them:

| | 15 Aug (predicted, then observed) | 16 Aug (as scheduled) |
|---|---|---|
| Offset drawn | `10m11s` | `2m59s` |
| Renewal fires | `03:10:11` | `03:02:59` |
| Certificate expires | `03:02:52` | `03:10:25` |
| **Margin** | **−7m19s** → **7m33s of outage** | **+7m26s** |

```
head$ date -u                                                    # 15 Aug 11:13 UTC
Sat Aug 15 11:13:43 AM UTC 2026

head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -dates
notBefore=Aug 15 03:09:25 2026 GMT      ← reissued 03:10:25, minus step-ca's 60 s backdate
notAfter=Aug 16 03:10:25 2026 GMT

head$ systemctl list-timers openchami-cert-renew.timer --no-pager
NEXT                        LEFT     LAST                        PASSED UNIT
Sun 2026-08-16 03:02:59 UTC 15h left Sat 2026-08-15 03:10:11 UTC 8h ago openchami-cert-renew.timer
```

⚠ **The outage was 14 seconds longer than predicted, and the difference is instructive.** The forecast used the timer's fire time (`03:10:11`); the certificate did not actually exist until `acme-register` → `acme-deploy` → `haproxy` had all run (`03:10:25`, from `notBefore` plus the backdate). **When you predict a gap from a schedule, add the time the work itself takes** — the schedule says when the attempt starts, not when the outage ends.

📌 **`notBefore` is the better forensic timestamp than the timer's `LAST`.** `LAST` records when systemd started the unit; `notBefore + 60 s` records when a valid certificate actually existed. The second is the one that closes the outage.

📌 **16 August is a *success* that proves the defect.** Same units, same timer, same everything — a positive margin because the dice fell the other way. Had the first re-check landed on that day, everything would have looked correct.

📌 **Which is why the first check looked perfect.** On 14 August the certificate had been minted *by hand* the previous afternoon, so the deadline was hours away and the offset was irrelevant. The first automated run was never going to expose this. It took the second look, with the timer setting its own next deadline, for the arithmetic to become visible.

⚠ **`RandomizedDelaySec` is not a mistake in general.** It exists so that a fleet of hosts does not stampede a service at the same instant. There is one host here, so it buys nothing — and against a certificate whose lifetime equals the renewal period, it converts a fixed thin margin into a random one that is negative half the time.

## What this actually costs

**Not much, today.** During the gap, `coresmd` logs a TLS error every 30 seconds and keeps serving DHCP from its cache. Nothing else consumes this certificate.

🛑 **But the margin is the real loss, not the gap.** With one renewal per lifetime there is *no room for a failed attempt*. If a run fails — step-ca briefly unavailable, a podman hiccup, the head node rebooting at the wrong moment — the next attempt is 24 hours later, and the certificate has already been dead for most of that time. That is precisely the outage issue 006 was written about, reintroduced by its own fix with a smaller blast radius.

⚠ **And a restart during the gap is the dangerous case.** Issue 006's warning applies unchanged: restart `coresmd-coredhcp` while the certificate is expired and it comes up with an empty cache, cannot repopulate, and falls through to the `bootloop` plugin — nodes lose their real addresses as leases expire. A seven-minute window is small, but "small" is not "impossible", and an unattended reboot does not consult the timer.

## The fix

Renew three times per lifetime instead of once:

```
head$ sudo tee /etc/systemd/system/openchami-cert-renew.timer > /dev/null << 'EOF'
[Unit]
Description=OpenCHAMI TLS certificate renewal (every 8 hours)

[Timer]
OnCalendar=*-*-* 00,08,16:00:00
RandomizedDelaySec=2m
Persistent=true

[Install]
WantedBy=timers.target
EOF
head$ sudo systemctl daemon-reload
head$ sudo systemctl restart openchami-cert-renew.timer
head$ systemctl list-timers openchami-cert-renew.timer --no-pager
```

Why these values:

- **`00,08,16`** — three runs per 24-hour lifetime. Expiry is always ~24 h after the most recent success, and the next attempt is at most 8 h away, so the standing margin is ~16 h. Two consecutive failures are survivable.
- **`RandomizedDelaySec=2m`** — kept small and mostly out of politeness to step-ca. At 16 h of margin the offset no longer matters, which is the point: the schedule should not be sensitive to it.
- **`Persistent=true`** — unchanged. Catches a run missed while the host was down.

📌 **The general rule this is an instance of: renew at a fraction of the lifetime, never once per lifetime.** A third is the common choice — it is what ACME clients do by default and why Let's Encrypt's 90-day certificates are renewed at 60 days. Equal periods leave the margin to chance.

## What does not work

| Idea | Why not |
|---|---|
| Just delete `RandomizedDelaySec` | Leaves a fixed daily run at `03:00:00` against an expiry of ~`03:00:2x` — a margin of *seconds*, positive only because the renewal takes ~23 s to complete and step-ca backdates by 60 s. Any slowdown, clock drift or slow start flips it negative. It removes the randomness without creating room |
| Move the timer earlier, e.g. `02:00` | Same shape. The expiry follows the renewal, so after one cycle you are back to renewing at the moment of expiry, just an hour earlier in the day |
| Lengthen the certificate to 7 days | Would work, and discards the property that makes step-ca worth running. Short-lived certificates with frequent renewal is the correct design; the bug is in the renewal, not the lifetime |
| Renew hourly | Also works. Twenty-four re-issues a day for a certificate nothing rotates against is noise in the logs and in step-ca's database, for no additional safety over 8-hourly |

## Verification

**Applied 2026-08-15 12:37 UTC.** Immediately after `systemctl restart`:

```
head$ systemctl list-timers openchami-cert-renew.timer --no-pager
NEXT                        LEFT          LAST                        PASSED  UNIT
Sat 2026-08-15 16:00:13 UTC 3h 22min left Sat 2026-08-15 12:37:44 UTC 22s ago openchami-cert-renew.timer

head$ echo | openssl s_client -connect demo.openchami.cluster:8443 \
        -servername demo.openchami.cluster 2>/dev/null | openssl x509 -noout -enddate
notAfter=Aug 16 12:37:59 2026 GMT
```

**Margin: 20 h 37 m**, against −7 m 19 s the day before.

📌 **`Persistent=true` renewed the certificate the moment the timer restarted**, without being asked. The new schedule's `08:00` occurrence was already in the past, so systemd treated it as a missed run and caught up — which is exactly the behaviour that flag exists for, seen working. It also means the fix proved itself immediately rather than at the next scheduled hour.

Still to confirm, in [`notes/scheduled-checks.md`](../notes/scheduled-checks.md):

1. `notAfter` advances **three times a day**, once per scheduled run.
2. The margin stays >12 h on every check — it should settle at ~16 h once renewals are landing on the `00/08/16` boundaries rather than on a catch-up.
3. Nothing accumulates across the extra runs: stale files in `acme-certs`, acme.sh state, or a `haproxy` restart that eventually fails. Three renewals a day is three times the previous exercise of that path.

Point 2 is the assertion. Points 1 and 3 only show it running.

Record results in [`notes/scheduled-checks.md`](../notes/scheduled-checks.md).

## Upstream — answered, 2026-08-17

The question this section originally left open was: *does upstream's packaged timer have the
same daily shape?* Checked against [`OpenCHAMI/release`](https://github.com/OpenCHAMI/release)
at `main`. **Yes — and it is worse.**

```ini
# systemd/system/openchami-cert-renewal.timer, unchanged since 2025-05-02
[Timer]
OnUnitActiveSec=1d
Persistent=true
```

Three things follow, and they are now defects **B** and **C** in
[`todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md):

**1. Same period as the lifetime, same defect as ours.** `1d` against a 24-hour certificate is
one renewal per lifetime. Ours at least oscillated around the deadline because of
`RandomizedDelaySec`; upstream's has no jitter, so instead of a coin flip it **drifts**. Each
cycle starts later than the last by however long the service took to run plus the timer's
`AccuracySec` (1 min by default), so it walks steadily *past* the expiry and stays there.

**2. It cannot fire at all on a fresh host.** `OnUnitActiveSec=` is relative to the last
activation of the triggered unit. systemd's `timer_enter_waiting()`:

```c
case TIMER_UNIT_ACTIVE:
        base = MAX(trigger->inactive_exit_timestamp.monotonic, t->last_trigger.monotonic);
        if (base <= 0)
                continue;
```

Where `openchami-cert-renewal.service` has never run, both are zero and the value is skipped
entirely — `systemctl list-timers` shows `NEXT: -`. And `Persistent=true` does not rescue it:
it applies only to `OnCalendar=`, and the stamp file it restores sets `last_trigger.realtime`,
not `.monotonic`.

🛑 **So the "just enable upstream's timer" advice in [issue 006](006-openchami-tls-cert-expiry-no-renewal.md#what-does-not-work) is not merely
suboptimal — it does nothing.** That entry should be read as: enabling it changes no
observable behaviour at all.

**3. Our `OnCalendar` fix is the right shape for upstream too**, for a reason we arrived at by
accident. We moved to `OnCalendar` for the margin; it also happens to be the only form that
schedules without a prior activation, and the only one that makes `Persistent=true` mean
anything.

📌 **This is the more interesting defect to report, exactly as this section predicted** — and
better than predicted, because we can now say "we made the same mistake, here is the
arithmetic, here are both faces of the coin observed on consecutive days". A maintainer can
dismiss "it never worked for us" as local misconfiguration. A defect we demonstrably walked
into ourselves, with the numbers, is a different conversation.

⚠ **What this section originally got wrong:** it assumed the ordering bug (`todo-001`'s
defect D) was the headline and the margin a second defect. It is the other way round. The
ordering fault may be masked on upstream's current release by unit dependencies added for
unrelated reasons; the timer defects are certain on every release.

## The lesson

⚠ **A schedule and a lifetime are two numbers, and their *relationship* is the thing that has to be right.** Both were individually defensible: a 24-hour certificate is good practice, a daily renewal at 3am is obvious, and jitter on a timer is a standard courtesy. Nothing here is a typo or an oversight. The defect only exists in the arithmetic between them, which is not visible in any one file.

📌 **This is the second-order version of issue 006's question.** That issue's lesson was *"ask of any install step: what here has a lifetime, and what renews it?"* — which we then answered, and stopped. The complete question is: **what has a lifetime, what renews it, and how much room is there between the two?**

⚠ **It also vindicates checking a fix more than once.** One successful unattended run looked like proof and was not: the certificate it renewed had been minted by hand, so the timer was not yet setting its own deadline. The mechanism could not fail until it had run twice. That is why `notes/scheduled-checks.md` exists, and this is the first thing it caught.

## Related

- [issue 006](006-openchami-tls-cert-expiry-no-renewal.md) — the original expiry, and the timer this defect is in
- [`runbooks/openchami-certificate.md`](../runbooks/openchami-certificate.md) — how to check, renew and investigate
- [`notes/scheduled-checks.md`](../notes/scheduled-checks.md) — the re-check that found it
- [`notes/todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md) — the upstream report
