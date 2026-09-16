# todo-003 — the GitOps repository lives in a personal account

| | |
|---|---|
| **State** | Deliberate POC decision, taken 2026-08-14. **Ours to fix, not upstream** |
| **Where** | `github.com/Tim-Langford-BriCS/techwatch-flux`, bootstrapped in §12.3 |
| **Should be** | An organisation-owned repository under `bristol-supercomputing`, authenticated by a GitHub App |
| **Blocked on** | An organisation owner installing a GitHub App, which is a conversation rather than a command |
| **Cost of leaving it** | Governance, not security. Nothing secret is in the repository by design |

## What happened

§12 needs a Git repository that Flux can read *and write* — bootstrap commits the controller manifests into it. `bristol-supercomputing/techwatch-flux` was created for exactly this, and both machine-credential routes turned out to be closed by organisation policy.

**Classic personal access tokens are capped at 7 days:**

```
✗ failed to get Git repository "https://github.com/bristol-supercomputing/techwatch-flux":
  provider error: 403 The 'bristol-supercomputing' organization forbids access via a
  personal access tokens (classic) if the token's lifetime is greater than 7 days.
```

**Deploy keys are disabled outright** — the repository's *Settings → Deploy keys* page reads `Disabled by bristol-supercomputing`, with the organisation's own banner recommending GitHub Apps instead.

Both restrictions are sound at organisational scale. A deploy key is an unencrypted private key on whatever host holds it; a long-lived classic PAT is a credential with `repo` scope across everything its owner can reach. Neither is what you want scattered across an estate.

## Why we did not simply comply

A GitHub App is the sanctioned route and is genuinely better — per-repository permissions, no long-lived secret on the host, revocable centrally, and it survives the departure of whoever set it up. It also requires an organisation owner to create and install it. That is a conversation with a person, and §12 was blocking §§13–15.

So the cluster was bootstrapped against a personal-account repository using a deploy key.

⚠ **The thing that makes this defensible is the §12.1 rule: nothing secret is in this repository.** Manifests, Kustomizations, image tags. If the repository leaked tomorrow the loss would be embarrassment, not compromise. Were there SOPS-encrypted secrets in it, or credentials of any kind, a personal account would be the wrong answer regardless of convenience.

## What is actually wrong with it

Not confidentiality. The problems are all about **continuity**:

- **Bus factor.** The repository, and the deploy key that writes to it, belong to one person's account. If that account is closed or that person leaves, the cluster's source of truth goes with them.
- **Access.** Nobody else on the team can be granted access through the usual organisational mechanisms.
- **Audit.** Organisation-level policies, required reviews and audit logging do not apply to it.
- **Precedent.** It is the sort of shortcut that gets copied into the PTR build because it was in the tutorial.

🛑 **This must not reach the PTR.** A production-track rig whose desired state lives in an individual's GitHub account is not defensible, however convenient it was on the day.

## The fix

1. Ask an organisation owner to create and install a **GitHub App** on `bristol-supercomputing`, granted `Contents: read & write` on `techwatch-flux` only.
2. Recreate (or unarchive) `bristol-supercomputing/techwatch-flux`.
3. Re-bootstrap against it. Flux ≥ 2.5 supports GitHub App authentication for `GitRepository` directly, so this is a `flux bootstrap` with different credentials — not a redesign.
4. Verify, then delete the personal repository and revoke the deploy key.

📌 **The migration is cheap by construction.** Flux's binding to a repository is a single `--url`, and §12.4's layout already anticipates several clusters in one repository (`clusters/techwatch-poc/`, later `clusters/techwatch-ptr/`). Moving is a re-bootstrap and a push, on the order of ten minutes.

**How it would be validated:** all three Kustomizations (`flux-system`, `infrastructure`, `apps`) reconciling the same revision from the new URL, and `kubectl -n flux-system get secret flux-system` no longer holding an SSH key.

## Also to clear up when this is done

- **The deploy key's private half sits unencrypted at `~/.ssh/flux_techwatch` on `tw-head`.** Whoever holds that host can push to the repository. Acceptable for a POC on a host we control; not a pattern to carry forward.
- **A classic PAT was created and then exposed** during this work — it was printed in full in a terminal and written to `~/.bash_history`. **Confirmed deleted by the operator, 15 Aug 2026**, and nothing depends on it: §12's Flux install authenticates with the deploy key above, not the PAT. Recorded with a date because "we revoked it" is worth being able to point at later, and an undated claim is the kind that gets re-litigated a year on.

  ⚠ **Deleting the token does not remove it from `~/.bash_history`.** The string is dead, so this is tidiness rather than exposure — but a history file that still contains something shaped like a credential will be read as a live one by the next person to grep it. `history -d`, or clear the file, on both boxes.

## Related

- [§12.1](../12-fluxcd-gitops.md) — the three authentication methods and how to choose between them
- [`todo-001`](todo-001-openchami-cert-renewal-upstream.md), [`todo-002`](todo-002-versitygw-region-openstack-az-upstream.md) — the upstream TODOs. This one differs in being entirely ours
