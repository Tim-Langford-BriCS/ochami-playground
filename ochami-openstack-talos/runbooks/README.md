# Runbooks

**Tutorials teach; runbooks are for doing.** The numbered sections of this tutorial are written to be worked through once, in order, with the reasoning inline. These are the opposite: tasks you will repeat, with the commands first and the explanation underneath, written to be opened at the point of need rather than read.

Everything here is extracted from the tutorial rather than invented alongside it, so a runbook and its section cannot disagree — each one links back to the section that argues the case.

| Runbook | Use it when |
|---|---|
| [Update the VPN tunnel address](update-tunnel-ip.md) | **SSH to the head node has started hanging** — the F5 gave you a new pool address and the security group is still scoped to the old one |
| [Manage application credentials](manage-application-credentials.md) | setting up the member/admin split, rotating a leaked or expiring secret, or decoding an authentication error |
| [Create the project's flavors](create-project-flavors.md) | creating or replacing the three flavors yourself, when you hold `admin` rather than asking someone who does |
| [The OpenCHAMI TLS certificate](openchami-certificate.md) | checking, renewing or debugging the 24-hour certificate on port 8443 — including the routine "is the renewal timer still working?" check, which is worth doing more than once |
| [Surveying a host for inference](inference-host-survey.md) | **before** deploying KServe, vLLM or anything like them on hardware you have not measured — which engine, which `dtype`, which model size, and the container defaults nobody sets and everybody inherits |
| [Cluster health and the model endpoint](cluster-health.md) | **the first thing you run after being away** — a 60-second sweep of all seven layers, and how to get `GW`/`GWPORT`/`HOST` back so you can actually talk to the model |
| [Raising the two upstream OpenCHAMI PRs](upstream-openchami-prs.md) | reproducing both upstream bugs in a disposable Lima VM, proving the fixes, and opening the pull requests — including the five claims of ours that testing disproved |

Not to be confused with [`issues/`](../issues/README.md): a runbook is a task you will **repeat**, an issue is a fault you hit **once** and want to recognise instantly if it recurs.

📌 **The upstream-PR runbook is a task repeated per *contribution*, not per incident.** It sits here rather than in [`notes/`](../notes/README.md) because the notes hold the *evidence and the argument* for each upstream bug, while this holds the *procedure* — build the VM, reproduce, prove, sign, push — which is the same procedure next time we find something in somebody else's repository. ⚠ Its most valuable section is the one listing what testing **disproved**, including two claims invented while planning: read that before quoting any of our own issue files at a maintainer.

📌 **The inference-host survey is the odd one out, and deliberately so.** Every other runbook here is reactive — something is broken, or due, and you open the file. That one is meant to be run *before* anything exists, because each of §§13–14's failures was discoverable in under a minute from commands nobody had thought to run yet. It earns its place by the same rule as the others (repeated, operational, easy to get subtly wrong) — the repetition is per *environment* rather than per incident, and there will be one of those for every hardware type TechWatch evaluates.

## Conventions

Same as the tutorial: `devbox$` is the client VM, `head$` is the OpenCHAMI head node, 🛑 marks something that can affect other people's work, and ⚠ marks a lesson paid for in hours. One extra prompt appears here that the tutorial avoids: **`mac$` is your laptop**, used only where the answer genuinely cannot be obtained from the devbox — the VPN tunnel is the one case.

Values are Digital Labs / `techwatch-proto` throughout. Substitute your own — the shape is what transfers.

## Adding one

A task earns a runbook when it is **repeated**, **operational**, and **easy to get subtly wrong** — the third being the important one. If the tutorial already says it once and you will only ever do it once, leave it in the tutorial.

Keep the task index at the top, put commands before prose, and record errors *as they were actually seen*, with the date and the tool version where it matters. An error table that quotes real output is worth more than one that paraphrases it, because the thing a reader has in front of them is the literal string.
