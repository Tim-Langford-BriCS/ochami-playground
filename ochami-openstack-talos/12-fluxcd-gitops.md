# §12 — GitOps with FluxCD

*(Time: ~25 minutes. On the head node. This is the pivot from "typing commands" to "declaring intent", and it is what makes the rig re-runnable.)*

## Concepts

**Why GitOps for an experiment rig?** The stated goal of TechWatch is to *plug, play and tweak* — try an inference engine, swap a scheduler, add an accelerator, measure, repeat. Doing that with `kubectl apply` leaves you unable to answer the only question that matters afterwards: *what was actually deployed when we took that measurement?*

GitOps answers it structurally. A controller in the cluster continuously reconciles cluster state against a Git repository, so:

- the repository **is** the record of what ran, with history and authorship;
- a change is a commit, so "revert the experiment" is `git revert`;
- rebuilding the cluster from scratch (which §10.7 makes cheap) restores the entire software stack with one bootstrap command;
- and when the PTR hardware arrives, pointing Flux at the same repository from a bare-metal cluster is the migration.

That last point is the real payoff. §§13–15 could all be done with `helm install`, and every one of those installs would have to be remembered and redone by hand on the PTR. Through Flux they are files.

**Flux vs Argo CD.** Both are mature CNCF projects and either would work.

| | Flux | Argo CD |
|---|---|---|
| Model | a set of controllers; Kustomize and Helm are first-class | a controller plus a strong web UI |
| Footprint | smaller; no UI to run or secure | heavier; the UI needs exposing, which on an isolated wire is friction |
| Fit here | **chosen** — CLI-driven, matches how the rest of this tutorial works, and nothing to publish | better if you want a dashboard for a team |

Neither is a wrong answer. We pick Flux for the smaller surface.

**What Flux is not.** It does not replace §§1–10. OpenStack resources, the OpenCHAMI control plane and the Talos nodes are all *below* Kubernetes, so Flux cannot manage them — that is what OpenTofu and Ansible are for in the companion IaC. Flux owns everything from §11 upward, and the boundary is exactly the Kubernetes API.

## Step 12.1 — A repository

Flux needs a Git repository it can read and write — it commits its own manifests during bootstrap. Create an empty `techwatch-flux` on GitHub or GitLab.

⚠ **Treat this repository as public even if it is private.** Nothing secret goes in it. §12.4 covers how secrets are handled instead.

**Set up Git on the head node, which has never been used for this.** Missing identity fails late, after you have done real work:

```
head$ git config --global user.name  "Your Name"
head$ git config --global user.email "you@example.com"
```

🛑 **Without these, §12.4's `git commit` fails** with `Please tell me who you are` — *after* you have written four files. Nothing is lost, but it interrupts the one step where a mangled paste is most likely, and you will be tempted to fix it in a hurry.

### Choosing how Flux authenticates

Flux needs a credential to clone and push. There are three, and **which one you can use is decided by your organisation's policy, not by preference.** Establish that before you start: both of the obvious routes were closed on our organisation, and finding out mid-bootstrap is expensive.

| Method | Flux command | What it needs |
|---|---|---|
| **SSH deploy key** | `flux bootstrap git` | a key added to the repo with write access. Never calls the provider's API |
| **Fine-grained PAT** | `flux bootstrap github` | Contents *and* Administration read/write; the org may need to approve it |
| **Classic PAT** | `flux bootstrap github` | `repo` scope |

🛑 **Check your organisation's policy first.** Ours (`bristol-supercomputing`) forbids classic PATs with a lifetime over 7 days *and* disables deploy keys entirely, recommending GitHub Apps instead. Both restrictions are reasonable at organisational scale and both are invisible until you hit them:

```
✗ failed to get Git repository: provider error: 403 The 'bristol-supercomputing' organization
  forbids access via a personal access tokens (classic) if the token's lifetime is
  greater than 7 days.
```

and, on the repository's **Settings → Deploy keys** page, `Disabled by bristol-supercomputing`.

**What we did, and why.** We bootstrapped against a repository in a *personal* account using a deploy key — the fastest route that is not a weekly credential treadmill. Nothing secret lives in this repository, so the cost of personal ownership is governance rather than security. That is a POC decision with an expiry date on it: [`todo-003`](notes/todo-003-flux-repo-in-personal-account.md) tracks moving it to an organisation-owned repository behind a GitHub App.

📌 **Rebinding Flux to a different repository is one `--url`.** The layout in §12.4 is designed for several clusters in one repo, so migrating later is a re-bootstrap, not a redesign. That is why taking the quick route here is defensible rather than sloppy.

#### Method A — SSH deploy key *(what we used)*

```
head$ ssh-keygen -t ed25519 -f ~/.ssh/flux_techwatch -N "" -C "flux@tw-head"
head$ cat ~/.ssh/flux_techwatch.pub
```

Add that public key at **the repository → Settings → Deploy keys → Add deploy key**, and **tick "Allow write access"**.

🛑 **Read-only fails halfway, which is the worst shape.** Bootstrap clones, generates manifests, installs the controllers into the cluster, and *then* fails on the push — leaving Flux running with nothing in Git describing it, the exact split GitOps exists to prevent.

A deploy key is scoped to **one repository**. It cannot be replayed against anything else you can reach, and it does not expire. Its cost: the private key sits unencrypted on the head node, so whoever holds that host can push to this repo.

#### Method B — a token

```
head$ read -rs GITHUB_TOKEN && export GITHUB_TOKEN
⟨paste; nothing echoes⟩
```

⚠ **Use `read -rs`, not `export GITHUB_TOKEN=ghp_…`.** The second form puts the token in your shell history and on screen. We did exactly that, and had to revoke a token because of it.

For a fine-grained token: resource owner is the **organisation**, repository access limited to this one, and permissions **Contents: read/write** *and* **Administration: read/write** — the second is non-obvious, and it is what lets bootstrap create the deploy key it uses afterwards.

📌 **Even with a token, the cluster ends up using a deploy key.** `flux bootstrap github` uses the token from the head to talk to the API, then creates a key so `source-controller` can clone. So token expiry breaks your pushes and any re-bootstrap — not reconciliation. Unless you pass `--token-auth`, which stores the token in-cluster and *does* tie reconciliation to its lifetime.

### Can the cluster reach your Git host?

Whichever method you choose, `source-controller` runs **on a worker node**, not the head, and clones over **SSH port 22**. Those nodes reach the internet only through the head's NAT, and §§7–10 only ever proved HTTPS/443 works. Test it before bootstrapping:

```
head$ kubectl run sshtest --rm -it --restart=Never --image=alpine -- \
        sh -c 'apk add -q openssh-client; ssh -o StrictHostKeyChecking=no -T git@github.com; echo rc=$?'
Warning: Permanently added 'github.com' (ED25519) to the list of known hosts.
git@github.com: Permission denied (publickey).
rc=255
```

⚠ **That output is a PASS.** `Permission denied (publickey)` is a protocol-level answer — the TCP connection succeeded, the key exchange completed (note the host key being recorded), and GitHub then rejected authentication because the pod offered no key. Blocked egress gives a **timeout**, never a rejection. The distinction is the whole point of the test.

The PodSecurity warning it prints is advisory (`warn: restricted` against `enforce: baseline`) and blocks nothing — see [issue 007](issues/007-local-path-var-mnt-read-only-kubelet.md).

## Step 12.2 — Install the CLI and check the cluster

📌 **Why the head node and not the devbox.** §11.5 gave the devbox a working `kubectl`, so either would function. The head is the better choice here because Flux needs three things at once — the Kubernetes API, outbound HTTPS to GitHub, and a Git working copy — and the head has all three natively, whereas on the devbox the first arrives through an SSH tunnel that can drop mid-bootstrap. Bootstrapping is the one operation you least want interrupted: it commits to your repository *and* installs controllers, so a failure halfway leaves the two out of step.

🛑 **Pin the Flux version.** Everything this tutorial installs is pinned and says why — see [issue 009](issues/009-helm-4-crd-ownership-conflict.md), where the one unpinned tool turned out to be the one *installing* the pinned ones, across a major version boundary, silently. Flux is in exactly that position here: it is the thing that will apply §§13–15. Pick a version, write it down, and use the same one on the PTR.

Find the current release, then choose deliberately:

```
head$ curl -fsSL https://api.github.com/repos/fluxcd/flux2/releases/latest | grep -m1 '"tag_name"'
⟨the current release tag, e.g. "tag_name": "v2.9.4"⟩
head$ FLUX_VERSION=2.9.4          # ← what you chose, without the leading v
```

📌 **2.9.4 is what this build used**, against Kubernetes v1.36.0. Record the pair, not either half — that combination is what has been shown to work here.

Download, verify, install — the same shape as §11.4's helm:

```
head$ ARCH=$(uname -m); [ "$ARCH" = x86_64 ] && ARCH=amd64 || ARCH=arm64
head$ curl -fsSLO https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz
head$ curl -fsSLO https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_checksums.txt
head$ sha256sum --check --ignore-missing flux_${FLUX_VERSION}_checksums.txt
flux_${FLUX_VERSION}_linux_amd64.tar.gz: OK
head$ tar -xzf flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz flux
head$ sudo install -m 0755 flux /usr/local/bin/flux
head$ rm -f flux flux_${FLUX_VERSION}_*
head$ flux --version
flux version 2.9.4
```

`--ignore-missing` is needed because the checksums file covers every platform's artefact and you downloaded one. Without it `sha256sum` reports every other line as missing and exits non-zero, which reads like a verification failure and is not.

If you would rather keep it to one line, upstream's installer honours the same pin — this is still pinned, it just trusts a script fetched from the internet and run as root:

```
head$ curl -s https://fluxcd.io/install.sh | sudo FLUX_VERSION=${FLUX_VERSION} bash
```

Then check the cluster before changing anything:

```
head$ flux check --pre
```

`flux check --pre` verifies the Kubernetes version and your permissions before touching the cluster. The line to read is the version comparison, which after bootstrap appears in `flux check` too:

```
► checking prerequisites
✔ Kubernetes 1.36.0 >=1.33.0-0
```

⚠ **A Kubernetes-version complaint here is about the CLI, not the cluster.** Talos ships a very current Kubernetes and Flux states a supported *floor* — `>=1.33.0-0` for 2.9.4. If `--pre` objects, the fix is a newer `flux`, not an older cluster. That is precisely why the pair is worth writing down: neither half is the thing that works.

## Step 12.3 — Bootstrap

**With a deploy key** — the provider-agnostic form. `flux bootstrap git` never calls GitHub's API, so no token policy applies:

```
head$ flux bootstrap git \
    --url=ssh://git@github.com/<owner>/techwatch-flux.git \
    --branch=main \
    --path=clusters/techwatch-poc \
    --private-key-file=$HOME/.ssh/flux_techwatch \
    --components-extra=image-reflector-controller,image-automation-controller
```

**With a token**, if your organisation permits one:

```
head$ flux bootstrap github \
    --owner=<your-org-or-user> \
    --repository=techwatch-flux \
    --branch=main \
    --path=clusters/techwatch-poc \
    --components-extra=image-reflector-controller,image-automation-controller
```

⚠ **`--personal` only for user-owned repositories.** Against an organisation it sends Flux looking in the wrong place and fails on a `404` that reads like the repository not existing.

A successful run, abridged:

```
► cloning branch "main" from Git repository "ssh://git@github.com/…/techwatch-flux.git"
✔ cloned repository
✔ committed component manifests to "main" ("b7416236…")
► installing components in "flux-system" namespace
✔ installed components
► generating source secret
✔ public key: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINQrzEdVAEiF6xY3hXcx+iFyPQXFdQvuBWn7zgEVZtSS
Please give the key access to your repository: y
✔ committed sync manifests to "main" ("bbc0dbcc…")
✔ GitRepository reconciled successfully
✔ Kustomization reconciled successfully
► confirming components are healthy
✔ helm-controller: deployment ready
✔ image-automation-controller: deployment ready
✔ image-reflector-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all components are healthy
```

📌 **`Please give the key access to your repository:` is a confirmation, not a new task.** When you supplied `--private-key-file`, that public key is the one you already added as a deploy key — Flux is asking you to confirm it has access before it proceeds. Answer `y`. (Without `--private-key-file` it generates a fresh pair, and then you really do have to go and add it.)

What this does: installs the Flux controllers into `flux-system`, commits their manifests to `clusters/techwatch-poc/flux-system/` in your repository, and configures Flux to reconcile that path. From now on, **anything committed under that path is applied to the cluster within a minute**.

- `--path` names this cluster, so the same repository can later hold `clusters/techwatch-ptr/` alongside it — sharing the `infrastructure/` and `apps/` definitions while differing where they must. That is the migration path, designed in from the start.
- `--components-extra` adds the image-automation controllers, which can bump a container tag automatically when a new one is published. Useful for tracking fast-moving inference images; harmless if unused.
- `flux bootstrap gitlab` exists too; `git` is the one that works anywhere.

✅ **Checkpoint**

```
head$ flux check
► checking prerequisites
✔ Kubernetes 1.36.0 >=1.33.0-0
► checking version in cluster
✔ distribution: flux-v2.9.4
✔ bootstrapped: true
► checking controllers
✔ helm-controller: deployment ready
⟨…six controllers, each with the image tag it is running…⟩
► checking crds
⟨…fourteen Flux CRDs…⟩
✔ all checks passed

head$ kubectl -n flux-system get pods
NAME                                          READY   STATUS    RESTARTS   AGE
helm-controller-66b87ccf5b-r6jts              1/1     Running   0          63m
image-automation-controller-6df84bd69-mxgsn   1/1     Running   0          63m
image-reflector-controller-678fc4d54c-txjdl   1/1     Running   0          63m
kustomize-controller-6d959d5f65-t92gf         1/1     Running   0          63m
notification-controller-5c895fb568-zpk78      1/1     Running   0          63m
source-controller-645ff9f8b9-25pnb            1/1     Running   0          63m

head$ flux get kustomizations
NAME          REVISION             SUSPENDED   READY   MESSAGE
flux-system   main@sha1:add5c7be   False       True    Applied revision: main@sha1:add5c7be
```

📌 **`bootstrapped: true` is worth noticing.** It distinguishes a Flux installed by `flux bootstrap` — which owns a path in Git and will reconcile itself — from one applied by hand, which will not. If this ever reads `false` on a cluster you thought was bootstrapped, the Git half is missing and nothing will self-heal.

📌 **`flux check` prints the image tag of each controller.** Those are the versions that matter when reading upstream issues, and they are not the same as `flux --version` — the CLI and the controllers are released together but numbered separately, so `flux-v2.9.4` ships `kustomize-controller:v1.9.4` and `helm-controller:v1.6.3`.

⚠ **`✔ all components are healthy` describes the *controllers*, not your cluster's desired state.** It means six deployments are running. Whether they are successfully applying anything is `flux get kustomizations`, which is why the checkpoint asks for both.

## Step 12.4 — The repository layout

Clone it and lay out the structure §§13–15 will fill:

```
head$ GIT_SSH_COMMAND="ssh -i $HOME/.ssh/flux_techwatch -o IdentitiesOnly=yes" \
        git clone ssh://git@github.com/<owner>/techwatch-flux.git ~/techwatch-flux
head$ git -C ~/techwatch-flux config core.sshCommand "ssh -i $HOME/.ssh/flux_techwatch -o IdentitiesOnly=yes"
head$ cd ~/techwatch-flux
head$ mkdir -p clusters/techwatch-poc infrastructure/{controllers,configs} apps/inference
```

⚠ **A plain `git clone` fails here with `Permission denied (publickey)`, even though bootstrap just worked.** Bootstrap was told which key to use; `git` was not. SSH only offers keys with **default names** — `id_ed25519`, `id_rsa` and so on — and `flux_techwatch` is not one, so it offers whatever else it finds (on this head, the OpenStack key), GitHub rejects it, and you get an error that reads like a missing repository.

The second line writes that setting into `~/techwatch-flux/.git/config`, so every later `push` uses the deploy key with no environment variable to remember. `IdentitiesOnly=yes` stops ssh working through every key it can find first, which wastes attempts against GitHub's limit.

📌 **Per-repository rather than `~/.ssh/config`.** A `Host github.com` block would work and would also silently change how every other repository on this host authenticates. Scope it to the thing that needs it.

🛑 **The four `cat > … << 'EOF'` blocks below are the riskiest paste in this tutorial.** Long multi-line pastes get truncated by some terminals — we lost one earlier in this build and got `yaml: line 13: found unexpected end of stream`, which named a line number in a file that had simply arrived incomplete. Here the damage is worse than a failed command, because a half-written manifest is a *valid file* that gets committed and applied.

Two habits make it safe:

- **Paste one block at a time**, not all four together.
- **Look at what landed before committing**, which is one command and takes five seconds:

```
head$ git status --short && git diff --stat
head$ tail -3 clusters/techwatch-poc/infrastructure.yaml     # ends where you expect?
```

⚠ **A mangled *screen* is not a mangled *file*, and you will see the first before you see the second.** Pasting a heredoc over SSH often redraws badly — rows overwrite each other without being cleared, so you get composites like this, three lines superimposed on one:

```
EOF         kserveGateway: kserve/kserve-ingress-gatewayources, no Knative.
```

That is the terminal, not the shell. Every character arrived; only the drawing was wrong, and `Ctrl-L` fixes it. **The failure that matters looks less alarming than this one** — a truncated paste usually scrolls past without complaint and leaves a short file that is still valid YAML. So do not judge either case by the echo. Ask the file:

```
head$ wc -l <file>                       # the length you expect?
head$ tail -1 <file>                     # ends on the line you expect?
head$ kubectl apply --dry-run=client -f <file>
```

The last one is the strongest: it parses the file and validates every document against the real schema, without sending anything to the cluster. One `created (dry run)` line per document.

⚠ **`git diff` is the check, not `flux get kustomizations`.** Flux will happily reconcile a truncated manifest if it still parses — you would get a Kustomization missing its `dependsOn`, which fails much later as a mysterious ordering problem in §13. Verify the text before it becomes cluster state.

The shape we use, and the reason for it:

```
techwatch-flux/
├── clusters/
│   └── techwatch-poc/          ← what THIS cluster runs
│       ├── flux-system/        ← created by bootstrap; don't hand-edit
│       ├── infrastructure.yaml ← Kustomization → ../../infrastructure
│       └── apps.yaml           ← Kustomization → ../../apps  (depends on infra)
├── infrastructure/
│   ├── controllers/            ← KServe, KubeRay: things that add CRDs (§13, §15)
│   └── configs/                ← Gateways, ServingRuntimes: things that USE those CRDs
└── apps/
    └── inference/              ← the actual models being served (§14)
```

Two Kustomizations rather than one, because ordering matters: an `InferenceService` cannot be applied before KServe's CRDs exist. Flux expresses that with `dependsOn`:

```
head$ cat > clusters/techwatch-poc/infrastructure.yaml << 'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  path: ./infrastructure
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true          # block until everything here is Ready…
  timeout: 10m
EOF

head$ cat > clusters/techwatch-poc/apps.yaml << 'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure   # …so that CRDs exist before apps use them
EOF

head$ cat > infrastructure/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - controllers
  - configs
EOF
head$ printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' \
        | tee infrastructure/controllers/kustomization.yaml \
              infrastructure/configs/kustomization.yaml \
              apps/kustomization.yaml > /dev/null

head$ wc -l clusters/techwatch-poc/*.yaml infrastructure/kustomization.yaml
 14 clusters/techwatch-poc/apps.yaml
 14 clusters/techwatch-poc/infrastructure.yaml
  5 infrastructure/kustomization.yaml
head$ git add -A && git diff --cached --stat       # look before you commit
head$ git commit -m "Scaffold infrastructure and apps kustomizations" && git push
head$ flux reconcile kustomization flux-system --with-source
head$ flux get kustomizations
```

📌 **`git diff` shows nothing for new files — stage them first.** `git diff` reports modifications to *tracked* files, and these are untracked: `git status --short` lists them as `??` and `git diff --stat` prints nothing at all, which looks like the files are empty. `git add -A` then `git diff --cached --stat` is the check that actually works. The `wc -l` above is the blunter version and catches truncation just as well.

`prune: true` matters more than it looks: delete a file, and Flux deletes the resource. Without it, experiments accumulate silently — which is the failure mode GitOps is supposed to prevent.

**On secrets.** Nothing in §§13–15 needs one, because we deliberately use a model that isn't gated (§14). If you later need a Hugging Face token or registry credentials, do **not** commit them. Two options:

- **SOPS + age** — encrypt the secret in Git; Flux's kustomize-controller decrypts it with a key held in-cluster. The GitOps-native answer, and what to use on the PTR.
- **Create the Secret out of band** with `kubectl create secret` and reference it by name from the committed manifests. Less pure, perfectly adequate for a POC — and it keeps the "nothing secret in Git" rule absolute.

## ✅ Checkpoint

```
head$ flux get kustomizations
NAME            REVISION             SUSPENDED  READY  MESSAGE
apps                                 False      False  dependency 'flux-system/infrastructure' is not ready
flux-system     main@sha1:add5c7be   False      True   Applied revision: main@sha1:add5c7be
infrastructure  main@sha1:add5c7be   False      True   Applied revision: main@sha1:add5c7be

head$ flux get kustomizations
NAME            REVISION             SUSPENDED  READY  MESSAGE
apps            main@sha1:add5c7be   False      True   Applied revision: main@sha1:add5c7be
flux-system     main@sha1:add5c7be   False      True   Applied revision: main@sha1:add5c7be
infrastructure  main@sha1:add5c7be   False      True   Applied revision: main@sha1:add5c7be
```

📌 **Both runs are shown deliberately — that first one is not a failure.** `dependency 'flux-system/infrastructure' is not ready` is `dependsOn` doing its job: `apps` refuses to apply until `infrastructure` reports healthy, and with `wait: true` that means everything under `./infrastructure` is Ready — currently an empty set, so it resolves in seconds. Run it twice and watch it clear. In §13 the same message appears for minutes while KServe's CRDs establish, and it means exactly the same thing.

⚠ **All three sharing one revision is the assertion.** `main@sha1:add5c7be` across every row means all three Kustomizations are reconciling the same commit. Different revisions would mean one is stuck on an older one, which `READY True` alone would not tell you.

Three reconciling Kustomizations with the dependency ordering in place. From here on, **the way to change the cluster is a commit** — and if you find yourself reaching for `kubectl apply` in §§13–15, that is a sign to put the file in Git instead.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `flux bootstrap` fails on authentication | `GITHUB_TOKEN` lacks repo scope, or `--personal` is wrong for an org-owned repo |
| `403 … organization forbids access via a personal access tokens (classic) if the token's lifetime is greater than 7 days` | Org policy. Shorten the token's life, use a fine-grained one, or switch to `flux bootstrap git` with a deploy key — §12.1 |
| Deploy keys page says `Disabled by <org>` | Org policy again. A GitHub App is the sanctioned route; a personal-account repo is the POC shortcut — [`todo-003`](notes/todo-003-flux-repo-in-personal-account.md) |
| `git clone` → `Permission denied (publickey)` after bootstrap worked | `git` was never told which key to use. `GIT_SSH_COMMAND`, then `core.sshCommand` — §12.4 |
| Bootstrap installed the controllers but failed to push | The deploy key is read-only. Tick **Allow write access** and re-run |
| `apps` shows `dependency … is not ready` | Not a failure — `dependsOn` waiting. Re-run the command |
| `flux check --pre` complains about the Kubernetes version | Talos ships a current Kubernetes, so this normally passes; if not, check `kubectl version` |
| Kustomization `Ready=False`, `kustomization path not found` | the `path:` doesn't exist in the repo, or you didn't push |
| `apps` never becomes Ready | `dependsOn` is working: fix `infrastructure` first, then `apps` follows |
| Flux applies nothing after a push | `flux reconcile kustomization flux-system --with-source` to force it; the default interval is 10 m |
| Resources you deleted from Git are still in the cluster | `prune: true` missing from that Kustomization |
| `git commit` → `Please tell me who you are` | No Git identity on the head node — §12.1 |
| `git push` prompts for a username, or `Authentication failed` | The clone URL carries no token; `GITHUB_TOKEN` is only used by `flux bootstrap` — §12.1 |
| `sha256sum --check` reports dozens of missing files | Expected — the checksums file covers every platform. Add `--ignore-missing` |
| `error converting YAML to JSON`, or a manifest that ends mid-line | A truncated paste. Re-paste that block alone, then `git diff` before committing |
| A Kustomization is Ready but ordering is wrong in §13 | `dependsOn` was lost to a truncated paste — the file parsed, so nothing complained |
| `flux check --pre` warns about the Kubernetes version | Your `flux` is older than this Talos. Install a newer one; do not downgrade the cluster |

Next: [§13 — KServe](13-kserve.md)
