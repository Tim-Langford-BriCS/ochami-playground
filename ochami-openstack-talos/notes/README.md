# Notes

**Work we have decided to do, but not yet.** An [issue](../issues/) records a fault we hit and settled. A *note* records something we found that is somebody else's to fix, or ours to fix later — captured while the evidence is fresh, so that picking it up in three weeks does not mean re-deriving it.

The distinction that matters: an issue is closed by the tutorial working again. A note is closed by a patch landing somewhere we do not control — or, for the one that is ours, by work we have deliberately deferred rather than forgotten.

| # | TODO | Upstream | State |
|---|---|---|---|
| [todo-001](todo-001-openchami-cert-renewal-upstream.md) | Certificate renewal timer is packaged but never enabled — and cannot fire even when it is, and renews once per certificate lifetime | [`OpenCHAMI/release`](https://github.com/OpenCHAMI/release) | Fix written and verified, not reported |
| [todo-002](todo-002-versitygw-region-openstack-az-upstream.md) | `versitygw-bootstrap.sh` lets botocore derive an AWS region from cloud metadata | [`OpenCHAMI/versitygw-quadlet`](https://github.com/OpenCHAMI/versitygw-quadlet) | **Filed and withdrawn 2026-08-20** — [#7](https://github.com/OpenCHAMI/versitygw-quadlet/issues/7) / [#8](https://github.com/OpenCHAMI/versitygw-quadlet/pull/8). To be re-filed by hand |
| [todo-003](todo-003-flux-repo-in-personal-account.md) | The GitOps repository lives in a personal account, because org policy closed both deploy keys and long-lived classic PATs | — **ours** | Decision taken deliberately; must not reach the PTR |
| [todo-004](todo-004-env-file-naming.md) | Env files were named three different ways, and hooked to each other in a chain no one file could describe | — **ours** | **Done, 15 Aug.** One rule (`tw-*` / `tw-head-*` / `-env.sh`) and one entry point per machine. The file is now the migration record |

## Conventions

Each TODO carries enough to act on **without going back to the cluster**: the observed evidence with verbatim output, the upstream file and line, the proposed change, and — the part that is easy to skip — how the fix would be *validated*. A patch nobody can test is a patch nobody will merge.

🛑 **Filing is Tim's, not Claude's.** These notes exist to be handed over — the deliverable is the diagnosis, the patch and the exact commands, never the act of opening anything on somebody else's repository. Bug 1 was filed without permission on 2026-08-20 and withdrawn; neither the issue nor the PR could be deleted, and a `Co-Authored-By` trailer in the first push turned out to be unremovable because forks share an object store with upstream. The full account is in [`todo-002`](todo-002-versitygw-region-openstack-az-upstream.md#filing-history) and the constraint is in [`CLAUDE.md`](../CLAUDE.md).

⚠ **Separate what we observed from what we infer.** Every claim in these files is marked one way or the other. We are asking a maintainer to trust our diagnosis of their code; overstating a single inference is the fastest way to have the whole report discounted.

**Check whether it is already reported before writing the patch.** Both TODOs here record that search and its result, including near-misses — [`OpenCHAMI/release#57`](https://github.com/OpenCHAMI/release/issues/57) is adjacent to todo-001 and may well be the *same* bug seen from the other end.

## State values

- **Done** — for the notes that are ours: the work landed, and the file becomes the record of what changed and how to migrate. todo-004 is the worked example
- **Evidence gathered, not reported** — we have the diagnosis; nothing has been filed
- **Reported** — an upstream issue exists; link it
- **Patch proposed** — a PR is open
- **Filed and withdrawn** — an issue or PR was opened and then closed by us. Worth its own state because GitHub will not delete either one: the record stays public, so the note has to say what happened and why. todo-002 is the worked example
- **Landed** — merged upstream; our local workaround can be retired, and the corresponding issue file updated

## Other things in here

[**`scheduled-checks.md`**](scheduled-checks.md) — fixes we have made but not yet *proved*, each with the date its evidence arrives. A note here says "we believe this works and have not seen it work enough times", which is a different and more honest state than either open or closed. Currently: the certificate renewal timer, to be re-checked on 15 and 16 August.

Session breakpoints — where we stopped and what state the cluster was in — live alongside the TODOs as `breakpoint-YYYY-MM-DD.md`. They are disposable; the most recent one is the only one that matters.
