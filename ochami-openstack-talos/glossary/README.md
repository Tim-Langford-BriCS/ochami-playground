# Glossary

**Every component in the system, in one place.** This tutorial builds a stack out of two large, unfamiliar ecosystems: OpenStack below and OpenCHAMI above. Each introduces a dozen named things, and the tutorial explains each one *where it first matters* — which is right for a first read and useless when you want to look something up three sections later.

These files are the lookup. They are built up as we go, so an entry appearing here means we have actually met it.

| File | Covers |
|---|---|
| [OpenStack](openstack.md) | the cloud below: services, identity, networking, compute, storage — things **someone else runs** and we consume |
| [OpenCHAMI](openchami.md) | the control plane we build on the head node: quadlets, SMD, BSS, CoreDHCP, the certificate chain, the object store |

## The schema, and why the two files differ

Every entry answers the same questions — *what is it, what is it for, where does it come from, where is it configured, how do I check it, where did we meet it*. But the two stacks answer "where does it come from" differently, and pretending otherwise would be misleading:

- **OpenStack components we do not install.** They are run by the cloud operator, and most of what we can do is *ask*. So those entries carry **Who runs it** and **How we reach it** (the CLI call), not an install step. Where something is genuinely ours — a network, a port, a security group — it says so.
- **OpenCHAMI components we install ourselves**, on the head node, mostly from one release RPM. Those entries carry **Installed by** and **Configured in** with real paths.

That asymmetry is the single most useful thing on this page. Nearly every confusing failure in this tutorial comes from forgetting which side of it you are on: a security group is something you own and can fix in ten seconds, a flavor is something you must ask for, and CoreDHCP is something you configured yourself and can therefore have configured wrongly.

## Conventions

Same as the tutorial: `devbox$` is the client VM, `head$` is the OpenCHAMI head node. Values are Digital Labs / `techwatch-proto` throughout — substitute your own.

Where a claim is inferred rather than observed, it says so. **"Installed" means the unit or resource exists** — not that it is configured or running, which for much of OpenCHAMI happens several steps later.

## Adding entries

Add a component the first time it is *encountered*, not the first time it is mentioned in passing. Keep entries to a few lines: this is a lookup, and an entry long enough to need skimming has failed. Link out to the section that explains it properly rather than re-explaining here — the tutorial is the argument, this is the index.

If a term needs more than a paragraph of *reasoning* (a decision, a trade-off, a failure mode), it belongs in the section, the [decision log](../DECISION-LOG.md) or an [issue](../issues/README.md), with a one-line pointer from here.
