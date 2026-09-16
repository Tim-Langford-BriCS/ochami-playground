# Issues

**Things that went wrong on a real run, and what settled them.** A runbook is for a task you will repeat; an *issue* is for a fault you hit once and want the next person to recognise in seconds rather than diagnose from scratch.

Each file records the verbatim error, the mechanism underneath it, and every solution considered — including the ones rejected, because "why not just do X" is the first question a reader will have.

📌 **Where the root cause is upstream, the issue stops at the workaround and hands off to [`notes/`](../notes/).** An issue is closed by the tutorial working again; a note is closed by a patch landing in somebody else's repository. Keeping them apart stops a reader who just wants the error gone from wading through a maintainer-facing argument — and stops the upstream evidence from quietly rotting inside a file nobody rereads. 001 → [`todo-002`](../notes/todo-002-versitygw-region-openstack-az-upstream.md), 006 → [`todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md).

Where a fix has to be applied to a partly-built cluster, the file also carries an appendix **proving it is safe before you run it** — read-only checks that nothing cascades, nothing is overwritten and no credentials change, with the captured output. `001` is the worked example of that shape.

| # | Issue | Recognise it by |
|---|---|---|
| [001](001-versitygw-bootstrap-aws-region.md) · [TL;DR](001-versitygw-bootstrap-aws-region-TLDR.md) | `versitygw-bootstrap` fails: botocore derives an AWS region from the OpenStack AZ | `Provided region_name 'DL-Rack-' doesn't match a supported format` at §5.5 |

Where a **TL;DR** is listed, read that first: why the problem exists, the fix, and the commands to run, with nothing else. The full file behind it carries the code paths, the alternatives that were rejected and why, and the proof the fix is safe — worth reading when you want to understand or defend the decision rather than just clear the error.

| [002](002-nftables-table-owned-by-podman.md) | `table ip nat` belongs to podman; §5.12's NAT rule must not go in it | `firewall-cmd: command not found`, then `# Warning: table ip nat is managed by iptables-nft, do not touch!` |
| [003](003-bss-ipxe-server-unexpanded-system-url.md) | BSS advertises `${SYSTEM_URL}` as its own hostname, so every retry URL it serves has no host | `https:///apis/bss/boot/v1/bootscript... Error 0x3e11618e` on a node's console at §7.2c or §10 |
| [004](004-cluster-discovery-needs-the-internet.md) | Talos cluster discovery reaches `discovery.talos.dev` over the internet — an undeclared dependency | nothing, here. On an air-gapped cluster: `talosctl get members` empty while `kubectl get nodes` is fine |
| [005](005-platform-storage-stall.md) | Root-disk **write** path wedged on the head; etcd stalled on `tw-cp1`. Suspected platform storage, not ours | SSH takes minutes and lands on `-bash-5.1$`; `systemctl` → `Failed to retrieve unit state: Connection timed out`; load pinned at exactly 61 |
| [006](006-openchami-tls-cert-expiry-no-renewal.md) | The OpenCHAMI TLS certificate lives 24 hours and nothing renews it | `x509: certificate has expired` every 30 s in `coresmd-coredhcp`, and nothing else wrong |
| [007](007-local-path-var-mnt-read-only-kubelet.md) | §11.2 pointed local-path at `/var/mnt`, which the kubelet may not write | A PVC `Pending` *with* a consumer, and `create process timeout after 120 seconds` in the provisioner log every 15 minutes |
| [008](008-kubelet-serving-certs-metrics-server.md) | Talos's kubelet self-signs a serving certificate that names nothing, so metrics-server refuses it | `metrics-server 0/1` and `x509: cannot validate certificate for 172.16.0.1 because it doesn't contain any IP SANs` at §11.3 |
| [009](009-helm-4-crd-ownership-conflict.md) | Helm 4 enforces field ownership, and the chart's Gateway API CRDs are the *experimental* channel where ours were standard | `INSTALLATION FAILED: … conflicts with "kubectl-client-side-apply"` on the Envoy Gateway chart |
| [010](010-cert-renewal-timer-has-no-margin.md) | 006's own renewal timer renews once per certificate lifetime, at a randomised time — so it lands *after* expiry about half the time | Nothing visible. Compare `notAfter` against the timer's `NEXT`: if they are minutes apart, you have it |
| [011](011-vllm-dev-shm-too-small.md) | Kubernetes gives every pod a 64 MiB `/dev/shm`; vLLM's engine needs 160 MiB and refuses to start | `CrashLoopBackOff` at §14.2, exit code 1 after ~40 seconds, and `Insufficient space in /dev/shm` deep in the log |

Cross-referenced from the sections themselves — §5.5's deviation block, §5.12's nftables branch, and §5's *Common failures* table — so a reader hitting an error in the tutorial lands here without knowing this folder exists.

⚠ **002 is the more dangerous shape of bug.** 001 fails loudly and immediately; 002's original instruction *succeeded*, worked through §10, and would have broken at a later container restart or reboot. When you find one of those, say so in the header — "works now, fails later" deserves flagging.

**003 is that shape again, and worse in one respect: it was already visible in a *finished* tutorial.** The same broken URL sits in a captured code block in the libvirt lab from eleven months earlier, in the `:boot_retry` tail of a boot script that worked. Nothing reached that line, so nobody read it. If you are capturing output as evidence, read all of it — including the part that only runs when something else fails.

## Conventions

Same prompts as the tutorial — `devbox$` is the client VM, `head$` is the OpenCHAMI head node. ⚠ marks a lesson paid for in hours.

**Quote real output.** Every error string here was copied from a terminal, not paraphrased, because the literal string is what a reader has in front of them and what they will paste into a search box. Where something is inferred rather than observed, it says so.

**Record the environment.** An issue is only useful with the versions, the cloud and the date attached — the same command on a different availability zone or a newer RPM may behave differently, and issue 001 is precisely such a case.

**005 is the first one that is not ours.** Every other issue here is a fault in something the tutorial does; 005 is the substrate failing underneath a build that was working. It is written for a platform engineer rather than a tutorial reader — hypothesis, evidence with verbatim output, the alternatives the evidence does not exclude, and what we need from them. Keep that separation: when the fault is someone else's, the useful artefact is evidence they can act on, not a workaround.

**006 is 002's shape taken to its limit, and it is the one to learn from.** 002 broke at the next container restart; 006 breaks on a *timer*, twenty-four hours after a §5 that passed every one of its own checks. Nothing you typed was wrong, nothing failed at the time, and the component that eventually complains — `coresmd` — is not the component that broke. It went unnoticed for six days across §§6–10 because the only visible consumer kept serving from a stale cache.

⚠ **When a fault has a clock rather than a trigger, the checkpoint that would catch it does not exist yet.** Ask of any install step: *what here has a lifetime, and what renews it?* That question would have found 006 on the day.

**007 is the first one caused by this tutorial's own fix.** §11.2 already warned that Talos's `/opt` is read-only and told you to move to `/var` — and the path it chose was one the kubelet cannot write. The instruction was applied correctly every time, and every check confirmed it. ⚠ **A checkpoint that verifies your instruction was followed cannot catch an instruction that was wrong.** Where a step tells the reader to write a specific value, the assertion afterwards has to test the *effect* of that value, not its presence. 007's checkpoint reaches all the way down to `talosctl ls` on the node for exactly that reason.

**008 is the first one the tutorial predicted, and it is still worth a file.** §11.3 warned about the kubelet TLS problem before the reader could hit it, and offered two fixes — so why write it up? Because the fix it labelled *correct* was only half a fix. Enabling certificate rotation without deploying an approver leaves the cluster in a state that looks different and fails identically. ⚠ **A warning that names the problem is not the same as a procedure that finishes it.** Where a step offers a "proper" alternative, either give it end to end with its own assertion, or say plainly that it is out of scope — anything in between reads as complete and is not.

008 is also the one carrying **deliberate, dated debt**: the quick fix weakens a trust boundary, it is recorded as temporary in two places, and it will be inherited silently by anything built from this cluster unless somebody greps for it. That is written into the issue as a task, not a caveat.

**009 is 007's shape at one remove, and the most quietly instructive of the set.** §11.4 pins Gateway API, cert-manager and Envoy Gateway, and gives its reasons — then installed the *latest* Helm to deploy them with. ⚠ **The unpinned component was the one installing the pinned ones.** Version discipline that covers only what you deploy has a hole in it the size of the client doing the deploying, and a package manager is not neutral plumbing: it decides how objects are written and who owns them afterwards.

009 is also the one where **the first fix we reached for was the wrong kind of fix.** The obvious escape was to retreat to Helm 3, which does not enforce ownership and would have made the error disappear. It would also have thrown away what the error was saying. Read properly, it named two specific fields — and those two fields were a real, deliberate difference between the standard-channel CRDs we installed and the experimental-channel ones the chart carries. 📌 **A conflict is evidence before it is an obstacle.** Ask what the two sides actually disagree about; the answer decides which fix is correct, and sometimes tells you the tool was right and you were wrong.

Two smaller things it records: a signal walked straight past — `helm list -a` had already failed with `unknown shorthand flag: 'a'`, a flag valid for years, minutes before the real failure — and an explicit assessment of whether the newer major version blocks anything later in the tutorial. **When a long-established flag stops existing, check the version before debugging anything else.**

**010 is the one to read if you only read one.** It is a defect in 006's *fix*, found not by anything breaking but by a scheduled re-check — and it is invisible in every individual file. The certificate lifetime is correct. The timer is correct. The randomised delay is standard practice. ⚠ **The fault exists only in the arithmetic between them**, which no single artefact shows and no checkpoint we would have thought to write would test.

It also settles a question 006 left half-answered. 006's lesson was *"what here has a lifetime, and what renews it?"* — we asked, we answered, we stopped. The complete question is **"what has a lifetime, what renews it, and how much room is there between the two?"** Renewing once per lifetime leaves the margin to chance; renewing at a fraction of it is the rule.

📌 **And it is the argument for `notes/scheduled-checks.md` in one example.** The first unattended renewal succeeded and looked like proof. It was not: the certificate it renewed had been minted by hand, so the timer had not yet set its own next deadline. **A mechanism that determines its own next deadline cannot be validated by a single run.**

**011 is the one to read for how *not* to debug.** The cause is dull — Kubernetes gives every pod a 64 MiB `/dev/shm` and vLLM needs 160 MiB, a default nobody chooses and no manifest shows. What earns it a place is the route: **two confident hypotheses, eleven restarts, and a traceback that named both the required and available sizes sitting in a log the whole time.**

⚠ **The first wrong answer was refuted by evidence already on screen.** We found the nodes had no AVX-512, built a theory that the vLLM image could not run without it — and had already run that image successfully on the head node, which is the same processor. **Check a new hypothesis against what you have already seen before going to measure something new.**

📌 **The second wrong answer came from over-reading an exit code.** Exit 1 correctly eliminated SIGILL and OOM; it does not identify a cause, and we treated it as though it did. **Exit codes narrow the field. Logs name the culprit.** The rule the issue ends on: diagnose from the innermost error outwards, and in a multi-process container remember that PID 1 usually only *reports* the failure — the process that had it is a child, further up the log and past most people's `--tail`.

**004 is a third shape again: nothing went wrong.** It is a dependency the tutorial had, used, and never declared — found because a command *worked* when it was expected to fail. Parked here rather than analysed, because it costs us nothing on this substrate and the question it really raises ("do PTR nodes have outbound internet?") is not ours to answer. If you are looking for a pattern across all four: three of them were things that worked.

## Status values

- **Open** — no fix, or only a workaround that has to be reapplied
- **Open — noted, not analysed** — parked on purpose. Enough is written down to recognise it and to avoid the obvious wrong fix; the investigation has not been done
- **Worked around** — a local fix is in the tutorial and the IaC; the underlying cause is still upstream
- **Fixed upstream** — resolved in a release; the workaround can eventually be dropped
