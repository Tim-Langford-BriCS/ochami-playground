# Working on this tutorial

A build log for a real cluster, written as a tutorial. Everything in it happened; the value is in what it records, including the parts that went wrong.

## The one rule

**Never invent output.** Every command result in this repository was copied from a terminal. If a command has not been run, its output is `⟨captured on first run⟩` or a short description in the same brackets — never a plausible-looking transcript.

This matters more than it sounds. A reader debugging at 2am pastes our error strings into a search box; a paraphrased or imagined one wastes their evening. It is also the property that makes this repository worth more than the documentation it duplicates.

Corollary: **separate observed from inferred.** Mark inference explicitly — *"⚠ Inferred, not observed."* We ask maintainers to trust our diagnosis of their code (see `notes/`); one overstated inference discredits the rest.

## Where things go

| | For | Closed by |
|---|---|---|
| `NN-*.md` | The build, in order. Reasoning inline, worked through once | — |
| `issues/` | A fault we hit **once** and want recognised in seconds next time | the tutorial working again |
| `runbooks/` | A task we will **repeat**. Commands first, explanation underneath | never — it is reference |
| `notes/` | Somebody else's to fix, or ours to fix later | a patch landing where we do not control |
| `notes/scheduled-checks.md` | A fix made but not yet **proved**, with the date its evidence arrives | enough successful checks |
| `templates/` | Files copied to a machine. `tw-helpers-env.sh` and both entry points are always safe to replace; `tw-vars-env.sh` holds the user's values and **never** is | — |
| `glossary/`, `diagrams/`, `appendix-*` | Reference | — |
| `DECISION-LOG.md` | Choices with consequences, as `DL-NNN` | — |

Each directory has a `README.md` explaining its own conventions. Read it before adding a file there.

## Naming: files a shell sources

`tw-*` is ours on the **devbox** (`~/tw/`), `tw-head-*` ours on the **head** (`~/`). Anything ending `-env.sh` is **sourced**; anything else is **run**. So `ls ~/tw/*-env.sh` is a complete inventory of what a login shell loads.

Each machine has **one entry point** — `tw-env.sh`, `tw-head-env.sh` — and `.bashrc` names only that. Entry points hold no values, list their dependants by name behind `[ -f … ]` guards, and are always safe to re-copy. A section that adds a helper therefore adds a *file*: it never edits `.bashrc` and never edits another helper. (`notes/todo-004` has the reasoning and the migration.)

⚠ **Anything an entry point prints must be inside `case $- in *i*)`.** `.bashrc` runs for non-interactive shells too, and stray stdout there corrupts the stream `scp`, `rsync` and `ssh host '…'` are reading — they fail with `protocol error`, which names neither the file nor `.bashrc`.

## Prompts and markers

`devbox$` is the client VM (a Lima VM on the laptop), `head$` is the OpenCHAMI head node, `mac$` is the laptop itself — used only where the answer genuinely cannot come from the devbox.

| | Means |
|---|---|
| ⚠ | a lesson paid for in hours |
| 🛑 | can affect other people's work, or is destructive/irreversible |
| 📌 | context worth knowing, not a warning |
| ✅ | a checkpoint |

Use them sparingly enough that they still carry weight.

## Writing style

**Prose, not bullet soup.** Explain the mechanism, then give the command. A reader should finish a section understanding *why*, not just having typed things.

**Assertions test effects, not instructions.** A checkpoint that confirms you typed what you were told cannot catch the case where the instruction was wrong — which is exactly what happened in `issues/007`. Reach for the deepest observable consequence: not "the configmap says X" but "the directory exists on the node".

**Say what each assertion proves** when it is easy to misread. `kubectl top` returning *numbers* proves the TLS path works; metrics-server being `Running` proves nothing, because it runs perfectly while failing every scrape.

**Record what does not work, and why.** Rejected alternatives are half the value — "why not just do X" is the first question a reader has. Every issue carries a *What does not work* table.

**Quote versions and dates.** The same command on a newer RPM or a different AZ may behave differently.

## Issues, specifically

Header table (Status / Hit at / Observed / Severity), TL;DR, the symptom with verbatim output, the mechanism, the investigation *including the hypotheses that were wrong and what eliminated them*, solutions, what does not work, checkpoint, common failures.

The wrong hypotheses are not padding. `issues/007` records a control test that gave a false negative because it differed from the original in one field — that is the most transferable thing in the file.

Status values: **Open**, **Open — noted, not analysed**, **Worked around**, **Fixed**, **Fixed upstream**.

## Git

Commit subject: `ochami-openstack-talos: <lowercase description>`. Body in prose — what was wrong, why it happened, what was rejected. Long is fine; these are the record.

```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Branch `ochami-openstack`, remote `git@github.com:isambard-sc/the-palaestra.git`.

🛑 **Commit only when asked.** Not after finishing a piece of work, not "to be safe". Wait to be told.

## Before committing

```
bash -n templates/*.sh notes/*.sh          # shell files parse
grep -rn '⟨' <changed .md files>           # placeholders left behind — intentional or forgotten?
```

And check relative links resolve — a broken cross-reference between `issues/`, `runbooks/` and the numbered sections is the easiest thing to get wrong, since they sit at different depths.

## The environment

- **`tw-head`** — Rocky 9, OpenCHAMI from the release RPM as rootful podman quadlets. `sudo podman ps` for containers, not `docker`.
- **Three Talos nodes** — `nid0001` (control plane), `nid0002`, `nid0003` on `172.16.0.0/24`, reachable **only** from the head. No SSH: `talosctl` for everything.
- **The devbox** — a Lima VM, so `aarch64` on Apple Silicon. It cannot see the Mac's filesystem; `limactl copy` moves files in. Derive architecture from `uname -m` rather than assuming.
- **Certificates** — the OpenCHAMI TLS certificate lives **24 hours**. If something has been sitting idle, check it before debugging anything else: `runbooks/openchami-certificate.md`.

## Things learned the hard way

**Pin the tools, not just the payloads.** The unpinned component is often the one *installing* the pinned ones. (`issues/009`)

**A conflict is evidence before it is an obstacle.** Ask what the two sides actually disagree about — the answer decides which fix is correct, and sometimes says the tool was right. (`issues/009`)

**"On Talos, is this path writable?" is not a question about the path.** It is about which process is writing and what it can see. (`issues/007`)

**When a long-established flag stops existing, check the version before debugging anything else.** (`issues/009`)

**Date every error before blaming it on the incident you just had.** (`issues/006`)

**Ask of any install step: what here has a lifetime, what renews it, and how much room is there between the two?** (`issues/006`, `issues/010`)

**In a Flux repo, a new manifest is two edits — the file, and the `kustomization.yaml` that references it.** Both halves went missing once each on the §13 run: a file listed but absent (Kustomize fails loudly) and a file present but unlisted (Flux reports success and applies nothing). `git commit`'s `N files changed` / `create mode` lines are the cheapest check, and they print one line above the push.

**A reproduction that differs from the original in any respect can only disprove things about the reproduction.** (`issues/007`)

## Three standing constraints

🛑 **Do not publish artifacts of this material.** It carries internal hostnames, `172.16.0.x` addressing, real domains and rack identifiers. An artifact was published once without being asked for and was not welcome. Markdown in the repository is the form that circulates.

🛑 **Read before overwriting anything on a live machine.** Diff first, back up, and verify afterwards that files holding the user's own values are byte-identical. `templates/tw-vars-env.sh` is the file that must never be replaced wholesale.

🛑 **Never open a pull request, issue, or comment on somebody else's repository.** Not after being asked to "do" a filing task, not because a plan said to, not because CI is green. **Tim raises upstream contributions by hand and pastes the text himself**, so the deliverable is always *the text and the commands*, never the act.

Prepare everything — branch, commit, verified diff, issue body, PR body, the exact `gh` invocations — and hand it over. Local git work on a local clone is fine; anything that reaches a remote is not. A general instruction like "let's do Bug 1: file the issue and PR" is a request to get it **ready**, not permission to post; if it truly means "post it now", it will say so unmistakably, and asking costs one line.

⚠ **This is written down because it happened.** On 2026-08-20 an issue and a PR were opened on `OpenCHAMI/versitygw-quadlet` without being asked for, after an earlier instruction to produce instructions rather than PRs. Both were withdrawn, but neither can be deleted, and the commit carried a `Co-Authored-By` line that had never been cleared for a project whose AI policy is unknown. **Forks share an object store with upstream, so a force-push does not unpublish a commit** — the withdrawn one is still reachable by SHA from OpenCHAMI's own repository. Publishing is the one class of action with no undo; treat it accordingly. See [`runbooks/upstream-openchami-prs.md`](runbooks/upstream-openchami-prs.md).
