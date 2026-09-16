# §1 — Safety, access and reconnaissance

*(Time: ~45 minutes, most of it waiting for accounts. Everything in this section is read-only. **Do not skip it** — it is the section that resolves every `<PLACEHOLDER>` in the rest of the tutorial, and the section that keeps you from disturbing somebody else's work.)*

## Concepts

**You are a tenant on a shared production cloud.** This is the single most important difference between this tutorial and the libvirt lab. Digital Labs OpenStack has three hypervisors serving real users, including BC5. A mistake here is not "rebuild the lab", it is "somebody's job died". So the whole of §1 exists to establish three things before we create anything:

1. **A scoped identity** — credentials that can only affect our own project.
2. **A contained blast radius** — our instances land only on the hypervisor set aside for us.
3. **Known facts** — the real image names, flavors, networks and quotas, so that no command in §§3–16 is a guess.

**Who runs this cloud, and who else is on it.** The OpenStack deployment itself — the control plane, the hypervisors, the networking and the storage behind it — is **operated by [StackHPC](https://www.stackhpc.com/)**, an external company specialising in OpenStack for research computing, working with UoB/BriCS staff (§1.5's hypervisor isolation is an example: "jcwomack, with StackHPC"). We are tenants of it and nothing more. That relationship is not a temporary feature of this rehearsal, and it is worth understanding for three reasons:

- **The cloud is not ours and never becomes ours.** Anything at deployment level — a flavor, a host aggregate, an image, whether nested virtualisation is on — is a request to somebody else, not a task. The whole of §1 is built around that asymmetry, and so is the [OpenStack glossary](glossary/openstack.md), where every entry says *who runs it*.
- **TechWatch is not getting its own cloud; it is adding hardware to this one.** The PTR machines are new capacity in the same StackHPC-operated estate, not a separate cluster stood up for us. So the tenancy discipline in this section is permanent rather than scaffolding for the prototype — the habits you build here are the habits you will still need on real metal.
- **This estate carries other systems, and their requirements outrank ours.** The same OpenStack cloud and hypervisors support **BC5** (BlueCrystal Phase 5, the university's HPC cluster), **Ceph disk arrays**, and other services. That is not incidental background: it is the direct cause of the biggest constraint in this tutorial. Nested virtualisation is disabled cloud-wide because the patched kernel breaks the offloaded networking BC5 depends on ([§0](00-introduction.md), [DL-001](DECISION-LOG.md#dl-001--substrate-shape-flat-not-nested)) — a production HPC service's needs, correctly, beating a prototype's convenience.

The practical reading: when something you want is unavailable, the first question is not "how do I work around this" but **"is this mine to change?"** Usually it is not, and then the answer is to ask, to wait, or to design around it — which is what §0's two decisions are.

**Keystone, projects and roles.** OpenStack authorisation is *identity × project × role*. A user (`tlangford`) holds a role (`member`) **in a project** (`techwatch-proto`). Every API call is made in the scope of one project, and a `member` in one project can do nothing at all in another. This is what makes the cloud safe to experiment in — provided you never authenticate as anything more powerful.

⚠ **There are two very different kinds of OpenStack account at Digital Labs, and this tutorial uses the weaker one.** Administering the OpenStack *deployment* itself needs a UoB admin (`-a`) account and F5 admin VPN, because it means touching the control plane. Being a *tenant* — which is all we do — needs only your ordinary project account. If you find yourself needing admin rights to follow a step in this tutorial, the step is wrong. Stop and re-read it.

**Application credentials** are Keystone's answer to "don't put your password in a config file" — but the reason they matter here is narrower and more important than that. You create one, get an ID and a secret, and it authenticates as you *with a subset of your roles that is fixed at creation time*. So it is the only mechanism in this section that survives a change to your **account**: a later grant of `admin` cannot widen a credential that was created `--role member`. Since we hand credentials to Ansible, to OpenTofu, and (in [appendix A](appendix-a-redfish-sushy.md)) to a service running on the head node, "what can this credential do, six months from now, if somebody adjusts my roles" is a question worth being able to answer. §1.2 is where this happens, and it is not optional.

**Host aggregates and hypervisor isolation.** Nova decides which hypervisor an instance lands on. A *host aggregate* plus scheduler filters can pin a project to specific hypervisors — the technique StackHPC describe in [Hypervisor isolation](https://www.stackhpc.com/hypervisor-isolation.html). For TechWatch prototyping this has been set up so that `techwatch-proto` instances land only on the hypervisor set aside for us, and — just as important — other projects' instances don't land there.

🛑 **Hypervisor isolation is a precondition you verify, never something you configure.** It requires admin rights, it affects scheduling for the whole cloud, and it is somebody else's job (at Digital Labs: jcwomack, with StackHPC). §1.5 shows you how to *confirm* it is working. If it isn't, stop and ask — do not proceed and do not attempt to fix it.

## The rules

Print these. They are short on purpose.

**Always:**

- Authenticate with a **project-scoped** application credential for `techwatch-proto`, and nothing else.
- Name every resource with the `tw-` prefix, so `openstack … list` makes it obvious what is ours.
- Run `list` / `show` before `create`, and read the `plan` before the `apply`.
- Check quota before creating, and ask an admin if you need more.
- Verify placement (§1.5) after your **first** instance, and again any time you add a new kind of instance.
- Tear down what you're not using (§18). Idle instances hold quota and power.

**Never:**

- Authenticate as an admin, or with `--os-project-name` / `--os-cloud` pointing at anything but our project, **for any step of this tutorial**. Two steps legitimately need admin (creating flavors, §1.5; reading a server's host, §1.6) — those are done deliberately, from a separate credential, and nowhere else. See "If you are granted the `admin` role" below.
- Run any of these from the tutorial's credential, ever:

  ```
  openstack hypervisor …          # cloud-wide compute state
  openstack aggregate …           # scheduling for every project
  openstack compute service …     # can disable a hypervisor
  openstack host …
  openstack flavor create/delete … # global namespace; admin-only (§1.5)
  openstack quota set …           # admin's decision, not ours
  openstack network rbac …        # controls sharing across projects
  openstack project/user/role …   # identity management
  ```

  The first four have no place in this work at all. `flavor create` is the one exception you may end up performing as a considered admin action — never from the shell you are running the tutorial in.

- Touch the shared `slurm-*` networks. Several of them are shared across all projects (tightening that with [Neutron RBAC](https://docs.openstack.org/neutron/latest/admin/config-rbac.html) is an open item for the cloud admins). We create our own networks in §3 and attach to nothing we don't own.
- Delete anything you did not create. If `openstack server list` shows something without a `tw-` prefix, it is not yours — even if you have permission to delete it.
- Create instances without checking placement, in case the aggregate pinning has regressed.

🛑 **`openstack server rebuild` destroys an instance's disk, and we use it deliberately.** §10.7 re-provisions a compute node by rebuilding it back onto the iPXE image — on a node that is the correct tool, and the whole re-provisioning story. On the **head node** the same command would erase OpenCHAMI, the S3 bucket and your Talos machine configs, with no undo. So the rule is not "never rebuild", it is **always read the instance name before you press return**, and never rebuild anything that is not a `-cp` or `-w` node.

## Step 1.1 — Confirm what you have been given

Before anything technical, confirm in writing (Slack, ticket, email) that:

| | Ours is |
|---|---|
| Project name and ID | `techwatch-proto` / `c12540ed6a8b4d9991db1e1adaa4068b` |
| Your username and roles in it | `tlangford`, roles `member` + `reader` — **plus `admin` from 31 Jul 2026**, granted for flavor management. See "If you are granted the `admin` role" |
| Is `[oslo_policy] enforce_scope = true`? | **⟨ask — unanswered⟩.** If not, `admin` on *any* project is evaluated as cloud-wide admin by most services. This decides how much care the admin credential needs |
| The hypervisor the project is pinned to | `compute2` |
| How the pinning works | Placement trait `CUSTOM_TECHWATCH_PROTO` on the flavor (§1.5) |
| Whether pinning is **active** | confirmed working — must stay *yes* before §4 |
| Who to ask for quota changes and flavors | at Digital Labs: jcwomack |
| The Keystone endpoint | `https://api.dl.acrc.bris.ac.uk:5000/v3` |
| Horizon | `https://api.dl.acrc.bris.ac.uk/` |

**Finding these yourself, in Horizon:** the project selector in the top-left header shows your current project name; your username is top-right. Then **Project → API Access** lists every service endpoint — the **Identity** row is the Keystone URL (append `/v3`), and the project *ID* is embedded in several of the others, e.g. `Compute_Legacy` ends `…:8774/v2/c12540ed6a8b4d9991db1e1adaa4068b`.

Once the CLI works, the same facts come from:

```
devbox$ openstack token issue -c project_id -f value    # the ID
devbox$ openstack project list                          # name ↔ ID, for projects you can see
devbox$ openstack catalog list                          # the endpoint table, as above
```

> You do **not** need the project name to configure the CLI. With an application credential the scope is carried by the credential itself, which is why `clouds.yaml` in §1.4 has no project name in it at all. If you are chasing a `Cloud … was not found` error, the project name is not the answer — see §1.4.

If pinning is not yet active, you can still do §§1–2 (all read-only) but **stop before §3**.

## Step 1.2 — Create an application credential

**Do this whether or not you have admin, and do it before §3.** It is not a tidiness measure or an optimisation for later — it is the only mechanism here that keeps working when something about your account changes without your involvement. Somebody grants you `admin` so you can manage flavors; your role assignments are adjusted during a reorganisation; you are added to a second project. With password authentication, every one of those silently changes what the commands you have already written are capable of. An application credential does not move.

### What it is, and what it is not

- **Not a new user.** You would then have two identities to keep track of, and somebody else would have to create and maintain the second one.
- **Not a new role.** A role is a cloud-wide named thing that only an admin defines (`openstack role create`). `member` and `admin` already exist, and the problem is not which roles exist — it is which ones your *credential* is able to exercise.
- **It is a down-scoped, derived credential of your existing user.** Keystone gives you an `id` and a `secret`; they authenticate as you, in one project, with a *subset* of your roles that you fix at creation time.

Three properties make it the right answer:

| Property | Consequence |
|---|---|
| **The role set is frozen when you create it** | `--role member` means the credential can never use admin policy, *even after your account is granted `admin`*. This is enforcement, not a convention you have to remember |
| **It is bound to one project** — whichever you were scoped to at creation | It cannot be pointed at another project, however the account's memberships change. This is why §1.1 comes first |
| **`unrestricted` is `false` by default** | It cannot create further application credentials or trusts, so it cannot be used to escalate back out |

### Creating it

Log in to Horizon (or use the CLI with your password once — this is the last useful thing password auth does here). Confirm your scope first, because the credential inherits it:

```
devbox$ openstack token issue -c project_id -f value        # must be our project
devbox$ openstack application credential create \
    --description "TechWatch OpenCHAMI prototyping — member only, expires 2026-12-31" \
    --expiration 2026-12-31T00:00:00 \
    --role member \
    tw-ochami-proto
```

Copy the `id` and `secret` immediately — **the secret is shown exactly once.** There is no recovery; if you lose it, delete the credential and make another.

`--expiration` means a forgotten credential eventually stops working, which is the difference between a mistake and an incident. §1.4's Path B shows where the `id` and `secret` go in `clouds.yaml`.

### How it behaves when you use it

**There is no login step and no token to manage.** The CLI exchanges the `id` and `secret` for a Keystone token on every invocation, exactly as password authentication does — the only thing that differs is what sits in `clouds.yaml`. Nothing to refresh, nothing to re-source per shell, and no password prompt.

If you ever suspect a leak, revoking is instant and costs your account nothing — no password change, and no effect on any resource the credential created:

```
devbox$ openstack --os-cloud techwatch-admin application credential delete tw-ochami-proto
devbox$ openstack --os-cloud techwatch-admin application credential create \
    --role member --expiration 2026-12-31T00:00:00 \
    --description "TechWatch OpenCHAMI prototyping — member only" tw-ochami-proto
```

⚠ **Note `--os-cloud techwatch-admin`: you cannot rotate the credential using the credential.** Attempting it from the `techwatch` entry gives:

```
ForbiddenException: 403: … Using method 'application_credential' is not allowed
for managing additional application credentials.
```

That is the `unrestricted: false` property in the table above doing its job — a leaked credential cannot be used to mint replacements or escalate. **It does not need the `admin` role**, only *password* authentication as the same user, so any non-credential entry works. Confirmed on Digital Labs, 2 Aug 2026.

### Prove it is actually down-scoped

Worth doing once, because "it is scoped to `member`" is otherwise just an assertion. Any admin-gated read will do; a good one is Glance, because clouds accumulate identically-named private images belonging to other projects and **a member cannot see them**:

```
devbox$ OS_CLOUD=techwatch       openstack image list --name 'Rocky-9.6' -f value -c ID
devbox$ OS_CLOUD=techwatch-admin openstack image list --name 'Rocky-9.6' -f value -c ID
```

Observed on Digital Labs, 31 Jul 2026: **one** image under the member credential, **three** under the admin login — two of them private and owned by another project entirely. Same command, same cloud, same account, different credential.

That difference is not cosmetic. It is also the failure mode: with an admin-capable shell, `openstack image show Rocky-9.6` starts returning `More than one Image exists with the name 'Rocky-9.6'`, and `server create --image Rocky-9.6` in §4.4 fails the same way — a step that worked last week breaking because of a change to your *account*. §1.5 covers pinning the image by UUID for that reason.

### If you are granted the `admin` role

You may be given `admin` on the project so you can manage flavors yourself (§1.5 explains why flavors need it). That is reasonable, and the right way to hold it is the one this section already prescribes: **the admin role lives in your interactive login; everything in this tutorial runs through a down-scoped `member` application credential.** Two separate identities, used deliberately.

Concretely:

- Keep `OS_CLOUD=techwatch` pointing at the **`member`** application credential, and run every command in §§2–19 and all of the IaC through it. `--role member` in §1.2 is what makes this real: the credential cannot exercise admin policy even though the account behind it could.
- Use a *separate* `clouds.yaml` entry (say `techwatch-admin`) with your password or an admin-scoped credential, and reach for it only for a specific, considered action — creating a flavor, reading `OS-EXT-SRV-ATTR:host`. Then go back.
- Do not point the IaC at the admin entry, even briefly. `tofu apply` with admin policy available is precisely the situation where a typo stops being local.

**The two entries, in full.** Note that the member entry needs no `username`, no `project_id` and no password — the credential carries all three, which is the whole point of §1.2:

```yaml
clouds:
  techwatch:                                    # ← §§2–19, and ALL of the IaC
    auth_type: v3applicationcredential
    auth:
      auth_url: https://api.dl.acrc.bris.ac.uk:5000
      application_credential_id: <ID_FROM_§1.2>
      application_credential_secret: <SECRET_FROM_§1.2>
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3

  techwatch-admin:                              # ← one deliberate action at a time
    auth_type: v3password
    auth:
      auth_url: https://api.dl.acrc.bris.ac.uk:5000
      username: "<YOUR_USERNAME>"
      project_id: <PROJECT_ID>
      project_name: "techwatch-proto"
      user_domain_name: "Default"
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3
```

Both are in [`templates/techwatch-proto-clouds.yaml`](templates/techwatch-proto-clouds.yaml), commented out and ready to uncomment. `chmod 600 ~/.config/openstack/clouds.yaml` afterwards.

⚠ **If your existing entry is `auth_type: v3password`, the grant has already widened everything you type** — including every command the IaC runs, since it reads the same file. There is no warning and nothing looks different. Check with:

```
devbox$ grep -A6 'techwatch:' ~/.config/openstack/clouds.yaml
```

**Elevate per command, never per shell:**

```
devbox$ openstack --os-cloud techwatch-admin flavor create techwatch-proto-head …
```

`--os-cloud` on the single command is strictly better than `export OS_CLOUD=techwatch-admin`, because there is no way to forget to change it back — and "I thought I was in the other shell" is the entire failure mode this split exists to prevent. [`templates/tw-status.sh`](templates/tw-status.sh) reports which identity a shell is holding, so you can check rather than assume.

**The admin entry will prompt for your password every time. That is the feature, not the friction to remove.** It puts a deliberate act on every privileged command, which is what makes the boundary real. Note the asymmetry when you use both: the member credential runs silently, the admin one asks. That is the design working, and it is worth *noticing* rather than smoothing away.

For a genuine burst — creating three flavors, say — use a **subshell**, so the password exists only for those commands:

```
devbox$ (
    read -srp "Admin password: " OS_PASSWORD && echo && export OS_PASSWORD
    openstack --os-cloud techwatch-admin flavor create …
    openstack --os-cloud techwatch-admin flavor create …
  )
```

The outer parentheses are the point. `OS_PASSWORD` lives in the subshell and is gone when it exits, so it cannot be picked up later by an `OS_CLOUD=techwatch` command — which would otherwise be exactly the `OS_*`-on-top-of-`clouds.yaml` mixing failure documented at the end of §1.4.

**Or use the helpers**, which [`templates/tw-helpers-env.sh`](templates/tw-helpers-env.sh) provides for the same job with the state made visible:

```
devbox$ tw_admin                       # prompts, switches cloud, marks the prompt red
 ADMIN  (openstack) devbox$ openstack flavor create …
 ADMIN  (openstack) devbox$ tw_member  # clears OS_PASSWORD, restores cloud and prompt
```

Three things they add over `export OS_CLOUD=techwatch-admin`:

- **The prompt is marked.** Elevated state you cannot see is elevated state you forget.
- **It expires.** After `TW_ADMIN_TTL` seconds (default 900) it drops you back on its own, so walking away from the keyboard is not a way to stay privileged. The check runs on each prompt, so it fires when you next return to the shell rather than mid-command.
- **`OS_CLOUD` and `OS_PASSWORD` move together**, so dropping out cannot leave a password behind for a later member command to pick up.

`tw_admin` also validates the password immediately with a `token issue`, so a typo fails there rather than three commands later as a confusing 401. `tw_unload` drops you out of admin before removing anything, so it cannot leave you with a red prompt and no way to restore it.

⚠ **The helper still holds your password in the shell's environment for up to the TTL** — a real trade against per-command prompting, and the reason for both the timer and the marker. For a single command, `openstack --os-cloud techwatch-admin …` remains the cheapest option; for absolute certainty that nothing persists, use the subshell above.

⚠ **Two ways not to solve the prompting.** Do not put your password in `clouds.yaml` or `secure.yaml` — it is your personal account password sitting on a VM's disk, and unlike an application credential's secret it cannot be revoked without changing it everywhere. And do not create an *admin-scoped* application credential: that puts an admin-capable secret on disk permanently and removes the friction, which defeats the whole arrangement. If flavor management becomes frequent enough to be annoying, the better answer is to ask an admin to create the flavors, as §1.5 originally assumed.

⚠ **"Admin on a project" may not mean "admin on only that project."** This is a long-standing OpenStack wart. Unless the deployment sets `[oslo_policy] enforce_scope = true` and `enforce_new_defaults = true`, the `admin` role granted on *any* project is evaluated as cloud-wide admin by most services — so you would be able to delete other people's instances, disable hypervisors, and change other projects' quotas. Newer releases default these to true, but it varies by service and by deployment.

**Ask your cloud admin which of those two settings are enabled before accepting the role**, and record the answer in your run log. It is a one-line question that tells you exactly how much care the admin credential needs. Either way, the member/admin split above is what keeps the blast radius small — but if scope is not enforced, treat that admin shell the way you would `root` on a shared machine.

## Step 1.3 — The client VM

Everything in this tutorial is typed inside a small Linux VM with the OpenStack clients installed, not on your laptop. Two reasons: the client stack is a pile of Python that you don't want in your system interpreter, and a VM gives you one tidy place for credentials that you can delete afterwards.

The team already has a Lima template for exactly this — [`team_tools/lima_templates/openstack-devbox.yml`](https://github.com/isambard-sc/team_tools/blob/main/lima_templates/openstack-devbox.yml) — which builds an Ubuntu 24.04 VM with `python-openstackclient`, `python-ironicclient`, `python-cinderclient` and friends in a virtualenv at `~/os-venv`:

```
mac$ limactl create --name openstack-devbox \
      ~/work/brics/team_tools/lima_templates/openstack-devbox.yml
mac$ limactl start openstack-devbox
mac$ limactl shell openstack-devbox
devbox$ source ~/os-venv/bin/activate
```

🔀 **Deviation — three more tools arrive later.** The shared template targets general OpenStack work. This tutorial also needs `talosctl` (§8), `kubectl` (§10) and `flux` (§12), but those get installed **on the head node**, not here: the head is inside the provisioning network and is the only machine that can reach the Talos and Kubernetes APIs directly. So the devbox stays a pure OpenStack client, and the shared template needs no changes.

> **On a Linux workstation**, skip Lima: `python3 -m venv ~/os-venv && ~/os-venv/bin/pip install python-openstackclient` gets you the same thing. Everything below is identical.

## Step 1.4 — `clouds.yaml`

### What a "cloud" is here, and what it isn't

This trips up nearly everyone once, so it is worth being precise. The `openstack` CLI (python-openstackclient, on top of openstacksdk) resolves a **cloud** before it does anything else. A cloud is a *named bundle of connection settings in a local YAML file*. It is:

- **not** your project name (`techwatch-proto`),
- **not** your username (`tlangford`),
- **not** anything that exists on the server side at all.

It is a nickname you choose, local to your machine. `OS_CLOUD=techwatch` means "look up the key `techwatch` under `clouds:` in my config". If there is no such key, you get:

```
Cloud techwatch was not found.
```

⚠ **That error is raised locally, before any network request is made** — before authentication, before argument validation, before the server is contacted. Which is why it looks identical whether you ran `flavor list`, `flavor create` or `server create`: none of them got as far as the API. Fix this first and any *real* error underneath it will then surface.

The search order, first match wins:

| Order | Location |
|---|---|
| 1 | `$OS_CLIENT_CONFIG_FILE` |
| 2 | `./clouds.yaml` — **relative to your current directory** |
| 3 | `~/.config/openstack/clouds.yaml` |
| 4 | `/etc/openstack/clouds.yaml` |

Entry 2 is the surprising one: a stray `clouds.yaml` in whatever directory you happen to be standing in silently wins over your real one.

> ⚠ **The `(openstack)` in your shell prompt is not a credential.** It is the Python virtualenv's name — `openstack-devbox.yml` creates the venv with `--prompt openstack`. An activated venv means the *client* is installed, and says nothing about whether you can authenticate.

## Two paths — pick one, don't mix them

Horizon offers two downloads that do the same job, and this tutorial documents both. **Pick one.** They cannot be used together (see the ⚠ at the end of this section for why), and both templates are ready to copy:

| | **Path A — openrc** | **Path B — clouds.yaml** |
|---|---|---|
| Template | [`techwatch-proto-openrc.sh`](templates/techwatch-proto-openrc.sh) | [`techwatch-proto-clouds.yaml`](templates/techwatch-proto-clouds.yaml) |
| Horizon download | *Project → API Access → Download OpenStack RC File* | *Project → API Access → Download clouds.yaml* |
| How you use it | `source` it once per shell | put it at `~/.config/openstack/clouds.yaml`, set `OS_CLOUD` |
| Password | prompts once, lives in the shell's environment | four options — see B.2 below |
| Identity | you, with **every role your account has — now and in future** | same, or an application credential **pinned** to `member` (§1.2) |
| Nothing on disk | ✅ password never written down | only if you use the prompt or `OS_PASSWORD` |
| Works for the IaC | ✗ OpenTofu and Ansible read `clouds.yaml` | ✅ |
| Good for | getting unblocked; §§1–2 read-only recon | everything from §3 onward |

**Recommendation: start with A, move to B before §3 — and to B with an application credential (§1.2), not with a password.** §3 is the first section that creates anything, and B is the only path the companion IaC can use.

⚠ **Both paths above authenticate as *you*, with every role your account holds.** That is fine for §§1–2's read-only recon and it is why Path A is a reasonable way to get unblocked. It stops being fine the moment the account gains a role you did not plan for — and "somebody grants you `admin` so you can manage flavors" is a normal thing to happen mid-project, not an edge case. The application credential in §1.2 is the only option here that cannot be widened after the fact, so treat A as scaffolding and B-with-a-credential as the destination.

---

## Path A — the openrc script

```
devbox$ source ~/techwatch-proto-openrc.sh
Please enter your OpenStack Password for project techwatch-proto as user tlangford:
devbox$ openstack token issue -c project_id -f value
```

That is the whole path. The script sets `OS_*` environment variables and reads your password into `OS_PASSWORD` **once**, so every later command in that shell reuses it. Open a new terminal and you source it again.

Two rules:

- **Don't put it in `~/.bashrc`.** Every new shell would block on a password prompt, including non-interactive ones, which breaks `ansible` and `tofu` in confusing ways.
- **Don't set `OS_CLOUD` in the same shell.** That is the mixing failure below.

---

## Path B — `clouds.yaml`

The `openstack` CLI reads connection details from `~/.config/openstack/clouds.yaml`. One entry per cloud; `OS_CLOUD` (or `--os-cloud`) picks which. Start from the template, which is Horizon's download with the entry renamed to `techwatch`:

```
devbox$ mkdir -p ~/.config/openstack
devbox$ cp techwatch-proto-clouds.yaml ~/.config/openstack/clouds.yaml
devbox$ chmod 600 ~/.config/openstack/clouds.yaml
devbox$ echo 'export OS_CLOUD=techwatch' >> ~/.bashrc && export OS_CLOUD=techwatch
```

### B.1 — How authentication actually works here

Worth understanding, because it explains the ergonomics. There is no persistent login. **Every `openstack` command authenticates from scratch:** it POSTs your credentials to Keystone's `/v3/auth/tokens`, gets back a token and the service catalogue, uses them for that one command, and throws them away. Nothing is cached on disk.

You can see the exchange yourself:

```
devbox$ openstack token issue
```

That is the API call every other command makes silently. The `id` field is a bearer token, valid for about an hour, and the reason `expires` is shown is that it matters.

So the question "where does the password come from?" has to be answered *per invocation* — which is why Path A's single prompt feels so much better than it should. It exports `OS_PASSWORD` into the shell, and every subsequent command picks it up from the environment.

### B.2 — Four ways to supply the password

| Option | How | Prompts | On disk |
|---|---|---|---|
| **1. Omit it** | leave `password` out of `clouds.yaml`, as the template does | **every command** | nothing |
| **2. `secure.yaml`** | a second file, merged on top, holding only the secret | never | your password, 0600 |
| **3. `OS_PASSWORD`** | export it once per shell | once per shell | nothing |
| **4. Application credential** | no password at all | never | a revocable secret, 0600 |

**Option 1** is safe and correct but prompts on every single command, because of B.1. Tolerable for a dozen commands; not for §5.

**Option 2 — `secure.yaml`** is openstacksdk's own mechanism for exactly this problem: a separate file with the same structure, merged over `clouds.yaml`, so the secret lives in one place you can delete.

```
devbox$ cat > ~/.config/openstack/secure.yaml << 'EOF'
clouds:
  techwatch:
    auth:
      password: "your-password-here"
EOF
devbox$ chmod 600 ~/.config/openstack/secure.yaml
```

**Option 3 — `OS_PASSWORD`** gives you Path A's ergonomics with Path B's file, and writes nothing down. **This is the fix if you are being prompted over and over:**

```
devbox$ read -srp "OpenStack password: " OS_PASSWORD && export OS_PASSWORD && echo
devbox$ openstack token issue -c project_id -f value      # no prompt
```

This is the **one** `OS_*` variable it is reasonable to set alongside `clouds.yaml`, because it supplies a value the file deliberately omits rather than overriding one the file sets.

Add it to your session the same way you would `OS_CLOUD`, but **never** to `.bashrc` — a password prompt in a shell startup file blocks non-interactive shells, which is how `ansible` and `tofu` runs hang with no output.

⚠ **Repeated prompting is not just tedious, it is a source of false errors.** A mistyped password returns `The request you have made requires authentication. (HTTP 401)`, which reads like a broken credential rather than a typo. If you see an intermittent 401 while being prompted per command, suspect your fingers before you suspect the cloud.

**Option 4 — an application credential** is where to end up, and it removes the question entirely: there is no password to supply, per invocation or otherwise. [§1.2](#step-12--create-an-application-credential) creates one and explains the mechanism; the template has a ready-to-uncomment entry. The property that matters is that it is **pinned** to the `member` role at creation, so a later `admin` grant on your account cannot widen it — which is not hypothetical tidiness. It is what stops §4.4's `server create` from breaking because your account changed.

> **If you want a long-lived token instead of a password**, that also works: `export OS_TOKEN=$(openstack token issue -c id -f value)` then `export OS_AUTH_TYPE=v3token`. It is genuinely useful for a scripted burst, but the token expires in about an hour and the failure at expiry is a confusing 401 rather than a prompt. An application credential is the better answer to the same want.

### B.3 — Verify

```
devbox$ openstack configuration show
```

This prints the **effective, merged** configuration — the single most useful debugging command in this section. Check `auth_type`, `auth_url`, `region_name`, and that nothing appears which you did not intend.

🛑 **Filter it before you show it to anyone.** `openstack configuration show` masks `auth.password` but does **not** mask `auth.application_credential_secret` — it prints that in full, in clear. So read the plain output yourself, and pipe it whenever it leaves your terminal:

```
devbox$ openstack configuration show | grep -vi 'secret\|password'      # before pasting
``` Confirmed with `osc-lib` 4.7.0 on 31 Jul 2026. That is a genuinely dangerous default, because this is the command everybody reaches for when debugging authentication, and its output is the thing you are most likely to paste into a ticket, a Slack thread, or a chat with an AI assistant.

If you have already pasted an unfiltered `configuration show` anywhere, **treat the credential as compromised and rotate it** — which costs one command each way and is exactly what application credentials are for:

```
devbox$ openstack --os-cloud techwatch-admin application credential delete tw-ochami-proto
devbox$ openstack --os-cloud techwatch-admin application credential create \
    --description "TechWatch OpenCHAMI prototyping — member only, expires 2026-12-31" \
    --expiration 2026-12-31T00:00:00 --role member tw-ochami-proto
```

Then update the `id` and `secret` in `clouds.yaml`. Nothing else is affected: your password is unchanged, and no resource the old credential created is touched.

```
devbox$ openstack token issue -c project_id -f value
```

### Where each value comes from

Only four values are variable. The other three lines (`auth_type`, `interface`, `identity_api_version`) are fixed by the authentication method and are copied verbatim — there is nothing to look up.

| Value | Where to get it | At Digital Labs |
|---|---|---|
| `auth_url` | Horizon → **Project → API Access**, the **Identity** row, with `/v3` appended. Or `OS_AUTH_URL` in the downloaded RC file. | `https://api.dl.acrc.bris.ac.uk:5000/v3` |
| `application_credential_id` | Shown when you create the credential (§1.2, or Horizon → **Identity → Application Credentials → Create**). Recoverable later with `openstack application credential list`. | — |
| `application_credential_secret` | Shown **exactly once**, at creation. **Not recoverable** — if you lose it, delete the credential and create another. | — |
| `region_name` | `OS_REGION_NAME` in the downloaded RC file, or `openstack region list` once you can authenticate. | `RegionOne` |

⚠ **Don't guess the region, and don't leave the placeholder in.** If you don't know it yet, **delete the `region_name` line entirely** — on a single-region cloud the SDK picks the only region there is. Leaving a literal `<REGION>` in the file is worse than omitting it, because the SDK treats that string as the name of your cloud's one region and then rejects the real one:

```
Region RegionOne is not a valid region name for cloud techwatch.
Valid choices are <REGION>. Please note that region names are case sensitive.
```

Read that message carefully when you see it: "valid choices are `<REGION>`" is the SDK quoting your own unfilled placeholder back at you.

### Where the application credential's own values come from

If you go on to the credential (option 4 above, and §1.2), Horizon gives you the whole file: **Identity → Application Credentials → Create Application Credential**, and the result page offers **Download clouds.yaml** with the ID and secret already in it. Take it there and then — the secret is displayed once.

⚠ **Two things to fix in whichever file Horizon gives you.** First, **the entry it writes is named `openstack`, not `techwatch`** — which produces exactly the `Cloud techwatch was not found` error if you point `OS_CLOUD` at the tutorial's name. **Rename the key to `techwatch`** rather than changing `OS_CLOUD`: four things name that cloud (`templates/tw-vars-env.sh`, `templates/sushy-emulator.conf`, `tofu/terraform.tfvars`, and your shell), so a one-word edit here keeps all of them true. Second, it sometimes omits `interface: public`; add it.

⚠ **Note which download you took.** *Project → API Access → Download clouds.yaml* gives **password auth** — an entry with `username`, `project_id` and `project_name` and no password, with a comment telling you to add one. Only the button on the *Application Credentials* page gives you a credential-based entry. Two consequences of the password one:

- **Don't add your password to the file.** `python-openstackclient` prompts for it when it is missing, which is strictly better than a plaintext copy of your personal password on a VM's disk.
- **This identity carries every role your account has.** That is the real argument for §1.2's application credential: if your account is later granted `admin` (see above), password auth silently makes *every* command you type admin-capable, including the ones in the IaC. An application credential created with `--role member` cannot do that, no matter what your account gains later.

So: password auth is a reasonable way to get unblocked and do the read-only recon in §1.5. **Switch to an application credential before §3**, which is the first section that creates anything.

🛑 **`Application credentials cannot request a scope. (HTTP 401)`** — the commonest failure when converting a password entry into a credential entry, and confirmed on Digital Labs, 31 Jul 2026. An application credential **carries its own project scope**, so Keystone rejects any request that also supplies one. It is not a broken credential; it is one scope too many.

The entry must contain *nothing* about who or where you are. Delete `username`, `project_id`, `project_name`, `user_domain_name`, `project_domain_name` and `password` — they are the leftovers of the password stanza you edited:

```yaml
  techwatch:
    auth_type: v3applicationcredential
    auth:
      auth_url: https://api.dl.acrc.bris.ac.uk:5000
      application_credential_id: <ID>
      application_credential_secret: <SECRET>
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3
```

If the file is already that clean and the error persists, the scope is arriving from the **environment**, which is the mixing failure at the end of this section:

```
devbox$ env | grep '^OS_'                                   # expect only OS_CLOUD
devbox$ openstack --os-cloud techwatch configuration show    # the effective merged config
```

`OS_PROJECT_NAME`, `OS_PROJECT_ID`, `OS_USERNAME` or `OS_AUTH_TYPE` left over from a sourced `openrc` will each produce this error, because openstacksdk merges `OS_*` **on top of** `clouds.yaml` rather than choosing between them. `configuration show` does not authenticate, so it works even while auth is failing — it is the right tool here. Clear the offenders (`unset OS_PROJECT_NAME OS_PROJECT_ID OS_USERNAME OS_PASSWORD OS_AUTH_TYPE`) or, more reliably, start a fresh shell.

### Ending up with more than one entry

Multiple entries in one `clouds.yaml` is normal and useful — that is what named clouds are *for*. What must not happen is an entry that is half-filled, because `OS_CLOUD` pointing at it produces errors that read like cloud faults (see the region example above). Either complete a stanza or delete it. A sensible end state is two:

```yaml
clouds:
  techwatch:          # member application credential — everything in this tutorial
  techwatch-admin:    # your account, for the rare deliberate admin action (§1.2)
```

Getting the file from your Mac to the devbox needs a copy, because `openstack-devbox.yml` sets `mounts: []` — there is deliberately no shared filesystem:

```
mac$ limactl copy ~/Downloads/clouds.yaml openstack-devbox:/tmp/clouds.yaml
devbox$ mkdir -p ~/.config/openstack
devbox$ mv /tmp/clouds.yaml ~/.config/openstack/clouds.yaml
devbox$ chmod 600 ~/.config/openstack/clouds.yaml
```

Then confirm the SDK can see the entry, and that its name matches `OS_CLOUD`:

```
devbox$ python3 -c 'import openstack.config as c; \
          print("\n".join(sorted(c.OpenStackConfig().get_cloud_names())))'
devbox$ echo "$OS_CLOUD"
```

Those two must print the same name. This is the single check that would have saved you the error.

Note what is *absent*: no username, no password, no project name. The application credential carries its own scope, so this file cannot be accidentally pointed at another project. That is the property we want.

There is a ready-made copy at [`templates/clouds.yaml.example`](templates/clouds.yaml.example).

### 🛑 Pick one mechanism: `clouds.yaml` **or** an `openrc` file, never both

Horizon also offers a **`*-openrc.sh`** download — the traditional way to configure the CLI. It is a shell script that exports `OS_AUTH_URL`, `OS_USERNAME`, `OS_PROJECT_NAME`, `OS_REGION_NAME` … and prompts for your password.

**Sourcing that file while also using `clouds.yaml` breaks things in confusing ways**, because openstacksdk does not treat them as alternatives — it **merges them**, with `OS_*` environment variables layered *on top of* the entry selected by `OS_CLOUD`. So you end up with a hybrid configuration that matches neither file:

| What you set | What the SDK does with it |
|---|---|
| `clouds.yaml` says `auth_type: v3applicationcredential` | uses the application credential… |
| `OS_USERNAME` / `OS_PASSWORD` from openrc | …but also sees password parameters, which that auth type does not accept |
| `OS_PROJECT_NAME` / `OS_PROJECT_ID` from openrc | adds a project scope the credential already carries — a source of "scope conflict" errors |
| `OS_REGION_NAME` from openrc | **overrides** `region_name` in `clouds.yaml`, and is then validated against it |

That last row is the one that produces the region error quoted above: openrc exports `RegionOne`, `clouds.yaml` still says `<REGION>`, and the SDK rejects the mismatch. The failure looks like a broken cloud but is entirely local.

**Recommendation for this tutorial: use `clouds.yaml`, and do not source openrc in your shell.** The application credential is the safer identity (§1.2), and `clouds.yaml` is what the IaC in the companion repo reads too, so one mechanism serves both. Keep the openrc file if you like — it is a convenient place to read `OS_AUTH_URL` and `OS_REGION_NAME` out of — but source it only deliberately, in a throwaway subshell, never from `.bashrc`.

If you have already mixed them, this returns you to a clean shell:

```
devbox$ for v in $(env | sed -n 's/^\(OS_[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
devbox$ export OS_CLOUD=techwatch
devbox$ env | grep '^OS_'          # must print exactly one line: OS_CLOUD=techwatch
```

Then make sure nothing puts them back:

```
devbox$ grep -n 'openrc\|OS_' ~/.bashrc ~/.bash_profile ~/.profile 2>/dev/null
```

Anything that sources an openrc should be deleted from those files. A single `export OS_CLOUD=techwatch` line is the only `OS_*` that belongs in your shell startup.

⚠ **`chmod 600`, and never commit it.** The tutorial's `.gitignore` already excludes `clouds.yaml`, but the habit matters more than the file.

⚠ **`Cloud techwatch was not found` — the first error most people hit.** `techwatch` is not a magic name; it is just the key we chose under `clouds:` above. The error means the name in `OS_CLOUD` and the name in the file disagree, or the file isn't in a place the SDK looks. Ask the SDK what it can actually see:

```
devbox$ python3 -c 'import openstack.config as c; \
          print("\n".join(sorted(c.OpenStackConfig().get_cloud_names())))'
```

If that prints nothing, you have no `clouds.yaml` yet — go back up this section. If it prints a *different* name (you may already have one from earlier OpenStack work on this devbox), either `export OS_CLOUD=<that name>` and change the same line in `tw-vars-env.sh` below, or rename the entry in `clouds.yaml` to `techwatch`. Either is fine; the tutorial only cares that the two agree.

> The search order is worth knowing, because one entry is surprising: `$OS_CLIENT_CONFIG_FILE`, then **`./clouds.yaml` relative to your current directory**, then `~/.config/openstack/clouds.yaml`, then `/etc/openstack/clouds.yaml`. A stray `clouds.yaml` in the directory you happen to be standing in wins over your real one.

Prove it works:

```
devbox$ openstack token issue -c project_id -c expires -f value
```

✅ **Checkpoint** — the project ID must be **ours**:

```
c12540ed6a8b4d9991db1e1adaa4068b
2026-07-26T14:32:11+0000
```

If the project ID is anything else, stop: your credential is scoped somewhere unexpected and nothing below should be run.

## Step 1.5 — Reconnaissance (read-only)

Now we replace every `<PLACEHOLDER>` in this tutorial with a real value. All of these are `list`/`show`/`quota show` — they change nothing.

First, somewhere to work and something to write the answers into:

```
devbox$ mkdir -p ~/tw && cd ~/tw
devbox$ cp <this-tutorial>/templates/tw-env.sh         ~/tw/tw-env.sh
devbox$ cp <this-tutorial>/templates/tw-vars-env.sh    ~/tw/tw-vars-env.sh
devbox$ cp <this-tutorial>/templates/tw-helpers-env.sh ~/tw/tw-helpers-env.sh
devbox$ source ~/tw/tw-env.sh
```

Then make it come back at every login, so a reboot or a new terminal does not silently leave you with an empty environment:

```
devbox$ echo '[ -f ~/tw/tw-env.sh ] && . ~/tw/tw-env.sh' >> ~/.bashrc
```

📌 **`.bashrc` names `tw-env.sh` and nothing else, ever.** That is the one shell-startup edit this tutorial asks for on the devbox. `tw-env.sh` holds no values — it is an **entry point** whose only job is to source whichever `*-env.sh` files sit beside it — so adding a file later is a `cp`, never another `.bashrc` line. The `[ -f … ] &&` guard is not decoration: `.bashrc` runs on **every** shell, including the non-interactive one behind `scp`, `rsync` and `ssh devbox '…'`, and an unguarded `source` of a missing file writes an error into the byte stream those tools are reading. They then fail with `protocol error` or `unexpected tag`, which names neither the file nor `.bashrc`.

🛑 **This is the opposite of the `.bashrc` advice in §1.4.** Do not put `openrc` there — it prompts for a password, and a password prompt in a startup file hangs every non-interactive shell. `tw-env.sh` prompts for nothing and reaches no network, which is exactly what makes it safe to load unconditionally.

**The naming rule, once, for the whole tutorial.** `tw-*` is a file of ours on the **devbox**, `tw-head-*` a file of ours on the **head node** (§5.1); anything ending `-env.sh` is **sourced**, and anything else — `tw-status.sh` — is **run**. So `ls ~/tw/*-env.sh` is a complete list of what a login shell loads, and nothing outside that list can change your environment behind your back.

⚠ **`tw-vars-env.sh` is filled in over the course of this section, not before it.** It has three regions, marked in the file, populated at different times:

| Region | When | Why that order |
|---|---|---|
| **1 — `OS_CLOUD`** | §1.4, before any recon | you cannot run an OpenStack command without it |
| **2 — recon results** | as you work through §1.5 below | these values are the *output* of the recon commands |
| **3 — tutorial constants** | already correct; leave alone | the prefix, CIDRs, node map, `172.16.0.254`, architecture. Several are hardcoded into the OpenCHAMI configs and BSS payloads |

Then §4.5 appends `TW_HEAD_FIP` and §4.6 appends `TW_PROV_IF`, at the very end of the file.

📗 **This file stays on the devbox.** The head node never sources it — it has no OpenStack credentials and no business with them. Instead §5 *generates* a ten-variable `~/tw-head-vars-env.sh` on the head from these values and `scp`s it across, which is why the recon answers here have to be right before §5: the head inherits them without re-checking.

🛑 **`tw-vars-env.sh` is yours; the other two are the tutorial's.** That is why they are three files. Once you have started filling in `tw-vars-env.sh`, **never re-copy it from the template** — you would lose every §1.5 answer and the two values §4 appends. `tw-helpers-env.sh` and `tw-env.sh` contain no values at all, so both are **always** safe to re-copy wholesale, at any point, which is how you pick up an improved helper without a merge. It is also why the file you must never re-copy is not the one with the obvious name: `tw-env.sh` is the name a hurried reader types.

So immediately after `source ~/tw/tw-env.sh`, most of the `TW_*` variables still hold `<PLACEHOLDER>` — that is correct, not a mistake. The recon commands below therefore take **literal values you type**, not the variables they are about to fill. `echo $TW_HEAD_IMAGE` printing `<ROCKY9_IMAGE>` means you have reached this step, not that something is broken.

**What already exists in the project** (should be empty or nearly so):

```
devbox$ openstack server list
devbox$ openstack network list
devbox$ openstack port list
devbox$ openstack volume list
devbox$ openstack security group list
devbox$ openstack keypair list
devbox$ openstack floating ip list
```

⚠ **`network list` is the exception — it will not be empty, and should not be.** It returns every network *visible* to you, which includes other projects' `Shared: True` networks and the external provider network. On a shared cloud that can be a dozen entries with no bearing on you. Visibility is not ownership, so compare the `Project` column against your own project ID:

```
devbox$ openstack token issue -c project_id -f value        # your project ID
devbox$ openstack network list --long -c Name -c Project -c Shared -c 'Router Type'
```

Only rows whose `Project` matches your ID are yours. Expect `external` (or whatever §1.5 finds) to belong to a different project with `Shared: True` and `Router Type: External` — that is the network you attach to in §3.1 and must never modify.

🛑 **If any of these show resources you did not create *in your own project*, stop and find out whose they are before continuing.** Someone else may be prototyping in the same project — and unlike another project's shared network, their resources are ones you can genuinely damage.

⚠ **A `Shared: True` network from another project is attachable, even though it is not deletable.** You cannot remove it, but you *can* create a port on it, and a stray `--network` flag naming someone else's Slurm network puts an instance of yours on their wire. Every command in this tutorial names `tw-prov` or `tw-ext` explicitly; keep it that way when improvising.

**Quota — the constraint that shapes §4 and §7:**

```
devbox$ openstack quota show -f table
```

Compare against what we need. The TechWatch design slide asks for rather more than a POC needs; this is the trimmed-down version:

| Resource | This tutorial needs | Design slide asks for |
|---|---|---|
| instances | 4 (head + cp1 + 2 workers) | up to 8 |
| vCPU | 22 (head 4, cp1 4, workers 2×8… trim to 2×4 if tight) | ~40 |
| RAM | 40 GB (head 8, cp1 8, workers 2×12) | 100 GB+ |
| disk (local/root) | ~150 GB | 200 GB+ |
| networks / subnets / ports | 2 / 2 / ~8 | — |
| security groups | 2 | — |
| floating IPs | 1 | 1 |

If quota is short, **ask** — don't work around it. §4 and §7 both note where to shrink first (workers before head; the head's 40 GB root disk is not negotiable, it holds the S3 store and container images).

**Images — which Rocky 9 x86_64 do we get, and does it boot UEFI or BIOS?**

```
devbox$ openstack image list --status active | grep -i -E 'rocky|ubuntu'
```

Take the name of the Rocky 9 x86_64 image from that listing — at Digital Labs it is something like `Rocky-9.6` — and use it **literally** in the next command. Then write it into `tw-vars-env.sh` as `TW_HEAD_IMAGE`:

```
devbox$ openstack image show Rocky-9.6 \
          -c name -c id -c disk_format -c min_disk -c min_ram -c properties
devbox$ sed -i "s|<ROCKY9_IMAGE_NAME_OR_UUID>|Rocky-9.6|" ~/tw/tw-vars-env.sh    # then re-source
```

⚠ **If that `image show` says `More than one Image exists with the name …`, pin the UUID instead of the name.** Glance does not enforce unique image names, and clouds accumulate them — a maintained image plus somebody's upload, or two revisions of one release. Confirmed on Digital Labs, 31 Jul 2026: `Rocky-9.6` is ambiguous. An ambiguous name fails identically in §4.4's `server create`, so settle it here:

```
devbox$ openstack image list --name 'Rocky-9.6' -f value -c ID -c Name -c Status
devbox$ for i in $(openstack image list --name 'Rocky-9.6' -f value -c ID); do
    echo "=== $i ==="
    openstack image show $i -c name -c visibility -c owner -c created_at \
      -c min_disk -c properties -f yaml
  done
devbox$ sed -i "s|<ROCKY9_IMAGE_NAME_OR_UUID>|<THE_UUID_YOU_CHOSE>|" ~/tw/tw-vars-env.sh
```

Choosing between them: prefer the newer, and read `owner` — an image owned by **our own project** is somebody's upload rather than the cloud's maintained one, and is the likelier of the two to disappear or to carry unexpected properties. A UUID has a second advantage worth having regardless: it cannot start silently resolving to a different image later, which a name can the next time an admin uploads a new build.

In the `properties` column look for `hw_firmware_type`. This single value decides §7's iPXE artifact:

| `hw_firmware_type` | Firmware | §7 needs |
|---|---|---|
| absent, or `bios` | SeaBIOS (legacy) | `ipxe.iso` — legacy BIOS iPXE |
| `uefi` | OVMF/edk2 | `ipxe.efi` wrapped in an ESP image |

Write back whichever it is. Note the `#` delimiter: this placeholder is `<bios|uefi>` and contains a `|`, so the usual `s|…|…|` form would be parsed as a broken expression:

```
devbox$ sed -i 's#<bios|uefi>#bios#' ~/tw/tw-vars-env.sh            # or uefi
```

Appendix D settles this empirically if the image properties are silent; §7 is where a wrong value shows up, as an instance that never reaches iPXE.

Also note `hw_machine_type` and whether the image sets `hw_scsi_model`/`hw_disk_bus` — it tells you which device name the node's root disk will get, which §8.6 deliberately avoids depending on.

**Flavors:**

```
devbox$ openstack flavor list
devbox$ openstack flavor show <FLAVOR> -c name -c vcpus -c ram -c disk -c properties
```

Pick three and record them: a head flavor (≥2 vCPU, ≥8 GB RAM, **≥40 GB disk**), a Kubernetes control-plane flavor (≥2 vCPU, ≥4 GB, ≥20 GB disk), and a worker flavor (as much CPU and RAM as quota allows — vLLM on CPU is entirely memory-bandwidth-bound, so this is the flavor that decides whether §14 is tolerable or glacial).

Then write all three names back, exactly as `openstack flavor list` spells them:

```
devbox$ sed -i "s|<FLAVOR_HEAD>|techwatch-proto-head|"     ~/tw/tw-vars-env.sh
devbox$ sed -i "s|<FLAVOR_CP>|techwatch-proto-cp|"         ~/tw/tw-vars-env.sh
devbox$ sed -i "s|<FLAVOR_WORKER>|techwatch-proto-worker|" ~/tw/tw-vars-env.sh
```

🔀 **Deviation — flavors are cloud-wide and we cannot create one.** In the libvirt lab we chose exact CPU/RAM/disk per VM. Here we choose from a menu. If no flavor has a big enough root disk for the head, §4 shows how to attach a Cinder volume for `/data` instead.

⚠ **`openstack flavor create` is admin-only, even for a private flavor.** Nova's default policy for `os_compute_api:os-flavor-manage:create` is `rule:admin_api`. `--private --project <ours>` does not change that: `--project` grants a project *access* to a private flavor, it does not let a member create one. With `member` + `reader` you get a 403 — confirmed on Digital Labs, 29 Jul 2026:

```
devbox$ openstack flavor create techwatch-proto-head --vcpus 4 --ram 16384 --disk 60 \
    --private --project techwatch-proto --property … 
ForbiddenException: 403: Client Error for url: https://api.dl.acrc.bris.ac.uk:8774/v2.1/flavors,
Policy doesn't allow os_compute_api:os-flavor-manage:create to be performed.
``` Flavors also live in Nova's global namespace, so a mistaken one is visible cloud-wide even when private — which is why it is on the never-run list above. **If you need a bespoke flavor, an admin creates it and grants your project access; you then see it in `openstack flavor list` like any other.**

📓 **If you have since been granted `admin` and are creating them yourself**, the procedure is [`runbooks/create-project-flavors.md`](runbooks/create-project-flavors.md) — the six commands, the `--private` / `--project` pairing that is easy to half-do, and how to verify from the member credential afterwards. The reasoning stays here; the runbook does not repeat it.

### Pinning by placement trait, on HPC-tuned hypervisors

Host aggregates and availability zones are the two obvious pinning mechanisms, but Digital Labs uses a third: a **custom placement trait** on the resource provider (the hypervisor), required by a flavor property.

```
trait:CUSTOM_TECHWATCH_PROTO=required
```

Placement then only considers hosts whose resource provider is decorated with `CUSTOM_TECHWATCH_PROTO`. Custom trait names must start with `CUSTOM_` and are upper-case with underscores. Compared with an aggregate this is finer-grained — it travels with the *flavor* rather than with the project — and that has one consequence you must not lose track of: **the flavor is load-bearing for isolation.** Booting with any other flavor silently opts out of the pinning and your instance can land anywhere in the cloud.

⚠ **On these hypervisors, a plain flavor does not schedule.** The DL compute nodes are configured for HPC — CPU pinning and preallocated 1 GB hugepages — and a flavor that does not ask for that topology finds no valid host. So the working flavor is not "the trait plus nothing else"; it needs the full set. This is the one confirmed by our admin as scheduling successfully onto the right host:

```
--vcpus 8 --ram 65536 --disk 30
--property hw:cpu_policy=dedicated             # pin vCPUs to physical cores
--property hw:cpu_sockets=2                    # guest sees 2 sockets
--property hw:mem_page_size=1GB                # match the host's hugepages
--property hw:numa_nodes=8                     # guest NUMA topology
--property hw:pci_numa_affinity_policy=preferred
--property hw_rng:allowed=True                 # entropy source for the guest
--property trait:CUSTOM_TECHWATCH_PROTO=required
```

Only `--vcpus`, `--ram` and `--disk` should vary between our flavors; every `--property` line should be copied verbatim, because each one is either the isolation contract or a host-topology requirement.

`hw_rng:allowed=True` is worth a note of its own: it gives the guest a `virtio-rng` device. Without a hardware entropy source, early boot can block on `/dev/random` — and this cluster generates a *lot* of keys at first boot (step-ca's CA in §5, Talos's PKI in §8, etcd's certificates in §10). Leave it on.

**What this means for the tutorial:**

- Record the traited flavor names in `tw-vars-env.sh` and use **only** those.
- `openstack flavor show <FLAVOR> -c properties` confirms the trait is still present. Run it if instances start landing unexpectedly.
- `No valid host was found` now has an extra cause: the host has run out of *dedicated* cores or 1 GB pages. Because CPUs are pinned, capacity is exclusive — a hypervisor with 128 cores fits sixteen 8-vCPU instances and no more, however idle they are. Budget instance count against cores, not load.
- Never "fix" a scheduling failure by dropping the properties or switching AZ. That is the one change that quietly breaks the isolation this whole section exists to protect.

### Ask for a *set* of flavors, not one

A single 8 vCPU / 64 GB flavor is the wrong shape for this cluster: the head node does no compute but needs disk, while the workers want RAM. Since flavors are admin-created, ask for all of them in one go, with the property block above copied unchanged:

| Flavor | vCPU | RAM | Disk | Used by |
|---|---|---|---|---|
| `techwatch-proto-head` | 4 | 16 GB | **60 GB** | the OpenCHAMI head (§4) |
| `techwatch-proto-cp` | 4 | 16 GB | 30 GB | Talos control plane (§7) |
| `techwatch-proto-worker` | 8 | 64 GB | 30 GB | Talos workers (§7, §14) |

⚠ **The head node's disk is the one dimension not to compromise on.** It holds the S3 object store (Talos kernel and initramfs), an OCI registry, and around 18 container images — `--disk 30` will be tight and may fail during §5. Ask for 60 GB on the head flavor. If you have to live with 30 GB, §4.7 shows how to attach a Cinder volume for `/data` instead, which works but adds a moving part.

`hw:numa_nodes` is the only property here you should not copy blindly, and the intuitive adjustment is the wrong one. Because `hw:mem_page_size=1GB` means each guest NUMA node's memory must come from a single host cell's preallocated hugepages, *reducing* the node count *increases* what each one demands — so the reference flavor's `8` across 8 vCPUs is not the oversight it looks like. Match the reference where the shape matches, and otherwise keep the per-node ask the same size. [`runbooks/create-project-flavors.md`](runbooks/create-project-flavors.md) has the arithmetic; the host's own topology decides what is valid, so it is a question for whoever tuned the compute nodes rather than a guess.

**External network, for a floating IP to reach the head:**

```
devbox$ openstack network list --external
devbox$ sed -i "s|<EXT_NET>|external|" ~/tw/tw-vars-env.sh          # the NAME from that listing
```

⚠ **This is the placeholder most often left behind**, because §3 is the first step that uses it and the failure arrives one section later: `No Network found for <EXT_NET>` from `openstack router set`. Write it back now. `external` above is a placeholder for whatever your cloud calls it — take the exact `Name` from the listing.

**The network your devbox appears from**, which every SSH and ICMP rule in §3.5 is scoped to.

⚠ **Ask the right question first, because the obvious command answers a different one.** What you need is the source address **the head node will see**, and that depends on whether the floating-IP network is publicly routable. Check before you measure anything:

```
devbox$ openstack subnet list --network ${TW_EXT_NET} -c Name -c Subnet -f value
```

| If that subnet is | Then the address you want is | Find it with |
|---|---|---|
| **publicly routable** | your internet egress address | `curl -s ifconfig.me` on the devbox |
| **private** — `10.x`, `172.16–31.x`, `192.168.x` | the address your **VPN or campus path** presents, which is *not* your internet egress | see below |

At Digital Labs it is **private**: the router's `external_fixed_ips` sits on `10.3.0.0/x`, so floating IPs are `10.3.0.x` and you reach them over the F5 VPN. With a split-tunnel VPN — the normal configuration — `curl -s ifconfig.me` goes out your local line and reports your *home or office* address, while traffic to `10.3.0.x` goes down the tunnel and arrives from a University address. Scoping the rule to what `ifconfig.me` said would then block the only path you use, and the symptom is an SSH timeout in §4.6 against a head node that booted perfectly.

**To find the tunnel-side address, run this on the laptop, not on the devbox.** The devbox is a VM behind its host's NAT, so it cannot see the tunnel at all — `ip route get` there reports an address private to the VM, which is true and useless:

```
devbox$ ip route get 10.3.0.185
10.3.0.185 via 192.168.5.2 dev eth0 src 192.168.5.15    ← Lima's internal NAT. Never leaves the VM.
```

The machine running the VPN client holds the answer. On macOS, ask which interface carries the route, then read its address:

```
mac$ route -n get 10.3.0.185 | grep interface
  interface: utun10
mac$ ifconfig utun10 | grep 'inet '
	inet 10.11.0.49 --> 1.1.1.1 netmask 0xffffffff
```

(On Linux, `ip route get 10.3.0.185` run *on the laptop* gives the same thing in one command. Expect several `utun` interfaces on a Mac — most belong to other services; the one the route names is the F5's.)

✅ **Checkpoint** — measured 2 Aug 2026, from home over the F5 VPN:

| | Value | Verdict |
|---|---|---|
| `curl -s ifconfig.me` | `86.x.y.z` | **wrong** — the ISP line, which never carries `10.3.0.x` |
| `ip route get` on the devbox | `192.168.5.15` | **wrong** — Lima's NAT, invisible outside the VM |
| `utun10` on the laptop | **`10.11.0.49`** | correct |
| the head's own `sshd` log, after login | `Accepted publickey for rocky from 10.11.0.49` | **confirms it** |

Three plausible-looking answers, one right one, and only the last is authoritative. So confirm empirically at your first successful login and correct the rule if it disagrees:

```
head$ sudo journalctl -u sshd | grep -i accepted | tail -3
```

### Write it back: the F5 pool range, and how to tighten it

**Use the VPN pool's range.** At Digital Labs the F5 concentrator — run by **UoB IT Services**, not by the cloud team and not by us — hands each client an address that we understand to come from `10.11.0.0/16`:

```
devbox$ sed -i "s|<YOUR_ADMIN_CIDR>|10.11.0.0/16|" ~/tw/tw-vars-env.sh
```

**Where that number comes from, and how much to trust it.** It is what the cloud team told us the F5 allocates from (3 Aug 2026), and it is consistent with every address we have measured — `10.11.0.49`, `10.11.0.52` and `10.11.0.54` are all inside it. But the pool is **somebody else's service**: we do not administer the F5, we have not seen its configuration, and a pool can be renumbered or split across profiles without anyone telling us. So treat `10.11.0.0/16` as a well-supported belief rather than a verified boundary — which is exactly why the measurement above is worth keeping in your hands, and why the next paragraph matters.

**The measured `/32` is how you tighten it.** The address you just read off `utun10` is the *actual* dynamic value the F5's client software assigned to this laptop for this session. If you want the tightest possible rule — or if you are ever asked to justify the scope — use that instead:

```
devbox$ sed -i "s|<YOUR_ADMIN_CIDR>|10.11.0.49/32|" ~/tw/tw-vars-env.sh    # your measured address
```

Both are defensible. Choose deliberately rather than by default:

| | `10.11.0.0/16` — the pool | `10.11.0.49/32` — your address |
|---|---|---|
| **Scope** | anyone authenticated onto the UoB VPN | exactly you, nothing else |
| **Redo it** | never | **every VPN reconnect** |
| **Audit trail** | none | the rule list records each session |
| **Depends on** | a fact IT Services owns and could change | only your own measurement |
| **Best for** | weeks of intermittent work — the default here | a short attentive session; a cloud with *public* floating IPs |

⚠ **An F5 pool address is per-session.** We saw `.49`, then `.52` an hour later, then `.54` the next day, with nothing changed but VPN sessions. A `/32` is therefore correct today and stale tomorrow, and the symptom when it goes stale is an SSH **hang** against a perfectly healthy cluster. That is the whole reason the range is the default.

**And the range is not the compromise its width suggests.** `10.11.0.0/16` is RFC1918 and unroutable from the internet, so the set of hosts that can reach the head's port 22 is the *same* under `/16` as under `/32`: those already authenticated onto the VPN or inside the University network. The mask does not move that boundary — the VPN's authentication does. What the range gives up is only the distinction between you-on-the-VPN and anyone-else-on-the-VPN, and they would still need your private key.

**Run the measurement either way.** On a `/32` it is the value you write down. On the range it is how you confirm you are on the tunnel at all — and if a measured address ever lands *outside* `10.11.0.0/16`, that is your signal the pool assumption has changed. Do not widen the range to accommodate it; find out what happened. [runbooks/update-tunnel-ip.md](runbooks/update-tunnel-ip.md) has both procedures and the re-issue routine; §17 has the general form of the problem.

🛑 **Never widen this to `0.0.0.0/0`.** It is the single rule standing between a public SSH port and the internet, and the IaC refuses that value deliberately. Note what the choice above really is: a scope you can *live with* versus one you will be tempted to escape. Repeated friction is how a cluster ends up open — not a considered decision that it should be.

**And the availability zone / hypervisor question:**

```
devbox$ openstack availability zone list
devbox$ sed -i "s|<AZ>|DL-Rack-5|"        ~/tw/tw-vars-env.sh       # observed 2 Aug 2026
devbox$ sed -i "s|<HYPERVISOR>|compute2|" ~/tw/tw-vars-env.sh       # from §1.6's admin-side check
```

Record `<AZ>` for the record, not for use. **Digital Labs' zones are named after racks** — ours reports `DL-Rack-5` — and a rack holds several hypervisors, so the zone is demonstrably *not* the boundary that isolates this project. `compute2` is one host inside `DL-Rack-5`; asking for the zone would let the scheduler pick any host in it. That is the concrete reason the pinning here has to be the placement trait on the flavor, and the concrete reason **not to pass `--availability-zone` anywhere** in this tutorial.

> If you are following this on a cloud whose default zone is the stock `nova`, the same reasoning holds: a single cloud-wide zone constrains nothing at all.

`TW_HYPERVISOR` is only ever compared against, never passed to a command, so if §1.6's check has not run yet put the hypervisor you were *told* to expect and confirm it there.

**Finish filling in `~/tw/tw-vars-env.sh` now, and re-source it.** Every later section starts with `source ~/tw/tw-env.sh`, and from §2 onward a `<…>` appearing in a command means you skipped one of the answers above:

```
devbox$ source ~/tw/tw-env.sh
devbox$ tw_check                    # anything listed is still unanswered
```

⚠ **Use `tw_check`, not `grep '<' ~/tw/tw-vars-env.sh`.** `tw-vars-env.sh` ships with explanatory comments containing `<` of their own, so a grep over the file never reaches zero and cannot tell you when you are done. `tw_check` reads the `TW_*` *values* after sourcing, which is the thing that actually matters, and also confirms the credential still authenticates.

🛑 **`tw_check` must report `✓ No placeholders left in TW_* variables` before you start §3.** This is the gate, not a suggestion. Every placeholder left here surfaces as a confusing error one or two sections later, and the error rarely names `tw-vars-env.sh` — these are the nine values and where each one detonates:

| Variable | Set from | Fails at |
|---|---|---|
| `TW_EXT_NET` | `network list --external` | §3.1 — `No Network found for <EXT_NET>` |
| `TW_ADMIN_CIDR` | §1.5 — the F5 pool `10.11.0.0/16` at DL, or a measured `/32`. **Not** plain `ifconfig.me` if the floating-IP net is private | §3.5 — `bash: YOUR_ADMIN_CIDR: No such file or directory` |
| `TW_HEAD_IMAGE` | `image list --status active` | §4.3 — no image of that name |
| `TW_FIRMWARE` | `hw_firmware_type`, or appendix D | §7 — builds the wrong iPXE artifact; boots to nothing |
| `TW_FLAVOR_HEAD` / `_CP` / `_WORKER` | `flavor list` | §4.3, §7.3 — no valid flavor |
| `TW_AZ` | `availability zone list` | never — recorded only; never passed (ours: `DL-Rack-5`) |
| `TW_HYPERVISOR` | §1.6's admin-side check | never — compared against, not passed |

The last two are the only ones you can safely leave; every other row is a section that will stop.

⚠ **A literal `<…>` in a command is worse than a plain error, because bash sees `<` as an input redirection.** So the message you get is not `invalid value` but something like `bash: YOUR_ADMIN_CIDR: No such file or directory`, which points at a file that was never involved. If a command fails mentioning a bare placeholder name, the cause is always an unfilled variable, not a missing file.

## Step 1.6 — Confirm placement (after your first instance)

You can't do this until §4 creates something, so bookmark it. The moment the head instance exists:

```
devbox$ openstack server show tw-head -c 'OS-EXT-SRV-ATTR:host' -c 'OS-EXT-AZ:availability_zone'
```

⚠ **At Digital Labs this field is empty for project members.** `OS-EXT-SRV-ATTR:host` is gated behind an admin-only policy rule, and we confirmed by testing that a `member` in `techwatch-proto` cannot see it. That is a policy decision, not a fault, and not something to work around.

So the placement check is **an admin runs one command on your behalf**:

```
admin$ openstack server list --project techwatch-proto --long \
         -c Name -c Networks -c Flavor -c Host
```

✅ **Checkpoint** — confirmed on the head node, 2 Aug 2026:

```
admin$ openstack server list --project techwatch-proto --long -c Name -c Host
+---------+----------+
| Name    | Host     |
+---------+----------+
| tw-head | compute2 |
+---------+----------+
```

`Host` is `compute2` — the trait pinning works, end to end, on an instance this tutorial created. (The same was true earlier of a colleague's `techwatch-proto-test-vm`, which is where the expected value came from.)

Note what this does *not* say: nothing here mentions an availability zone. `compute2` sits in `DL-Rack-5` alongside other hypervisors, so landing in the right zone would have proved nothing — it is landing on the right *host* that matters, and only the flavor's trait produces that.

🛑 **If `Host` is not the hypervisor set aside for you, stop immediately**, delete the instance (`openstack server delete tw-head`), and tell your cloud admin that the isolation is not taking effect. Do not continue: every further instance would land somewhere it shouldn't.

**What a member *can* verify unaided** — worth doing, because it catches the realistic failure mode. The trait lives on the flavor, so confirming the flavor still requires it proves the *mechanism* is intact even when you cannot see the *evidence*:

```
devbox$ openstack server show tw-head -c flavor -f value
devbox$ openstack flavor show "$TW_FLAVOR_HEAD" -c properties -f value 2>/dev/null \
          | tr ',' '\n' | grep trait:
```

Expect `trait:CUSTOM_TECHWATCH_PROTO='required'`. An instance booted from a traited flavor cannot have landed on an untraited host — Placement would have refused to schedule it. Ask for the admin-side check once at the start and again if you ever change flavors.

## Step 1.7 — The helpers in `tw-helpers-env.sh`, and a run log

`tw-helpers-env.sh` — loaded for you by `tw-env.sh`, so you never source it by name — defines a handful of `tw_*` shell functions. They are conveniences only, nothing in them creates or deletes a cloud resource, but two of them save real time:

```
devbox$ source ~/tw/tw-env.sh
TechWatch env loaded (OS_CLOUD=techwatch). Run 'tw_help'.
devbox$ tw_help
```

| Function | What it does |
|---|---|
| `tw_help` | the list, plus where every config file lives and the SDK's search order |
| `tw_env` | every `TW_*` variable currently set, with `OS_PASSWORD` shown as set/unset rather than printed |
| `tw_check` | **the one to run before §3** — asserts no `<PLACEHOLDER>` is left *and* that the API answers |
| `tw_config` | which config files exist, which cloud is selected, what the SDK can see, and every `OS_*` in your environment |
| `tw_whoami` | project, user and token expiry |
| `tw_login` | one password prompt for the whole shell (§1.4 option 3) |
| `tw_clean_os` | unset every `OS_*` except `OS_CLOUD` — the openrc/`clouds.yaml` mixing fix |
| `tw_flavors` | do our three flavors still carry the isolation trait? (§1.5) |
| `tw_vpn` | SSH to the head hangs — is the VPN down, or has your address changed and left the security group behind? (§17, [appendix E](appendix-e-network-map.md)) |
| `tw_nodes` | the node map as a table |
| `tw_unload` | remove every `TW_*` variable and every `tw_*` function |

`tw_check` is the useful one, because it collapses "am I ready?" into one line:

```
devbox$ tw_check
✓ No placeholders left in TW_* variables
✓ Authenticated; project_id c12540ed6a8b4d9991db1e1adaa4068b
```

It returns non-zero on failure, so `tw_check && make apply` is a reasonable habit when you get to the IaC.

`tw_unload` exists because `source` has no undo. It unsets the `TW_*` variables, `OS_CLOUD`, and — deliberately, unconditionally — `OS_PASSWORD`, then removes the functions including itself. Leaving a password in the environment of a shell you believed you had cleaned is worse than typing it again.

> **Everything is namespaced.** Variables are `TW_*`, functions are `tw_*`. That is what lets `tw_unload` find them all reliably, and it means nothing here can collide with `openstack`, `talosctl` or your own shell setup.

### A run log

`~/tw` and `tw-vars-env.sh` already exist from §1.5. Keep a plain text run log next to them. Every checkpoint in this tutorial is marked `⟨captured on first run⟩` until someone pastes real output into it; your log is where that output comes from. This is not bureaucracy — this tutorial is the deliverable, and its value is that its commands are known to work.

## ✅ Checkpoint for the whole section

```
devbox$ openstack token issue -c project_id -f value    # ours, and only ours
devbox$ echo $OS_CLOUD                                  # matches a name in clouds.yaml
devbox$ tw_check                                        # ✓ no placeholders, ✓ authenticated
```

Three green lights: scoped identity, right cloud selected, and no unknowns carried forward.

🛑 **Now do [appendix D — the ten-minute smoke test](appendix-d-smoke-test.md) before you read §3.** It costs one throwaway instance and settles four things this tutorial cannot know about your cloud: that you can actually *use* the flavor an admin created for you, whether the firmware is BIOS or UEFI (§7), whether Neutron permits MAC-pinned ports and disabling port security (§§3, 6, 9), and whether Nova policy permits `server rescue` — no longer §7's mechanism, but still what [appendix A](appendix-a-redfish-sushy.md)'s Redfish emulation needs. Each has a fallback — but choosing one now is much cheaper than discovering the need at §10 with a half-built cluster in the way.

## Common failures

| Symptom | Cause / fix |
|---|---|
| **Authentication fails with a password you know is correct** | 🛑 **Check the VPN before touching the credential.** If the API is reached over a tunnel (F5 at Digital Labs) and that tunnel drops, the CLI does not report a network problem — it reports an *authentication* failure. Confirmed 31 Jul 2026 after three attempts at retyping a correct password. `tw_reach` distinguishes the two in one second, and `tw_check`/`tw_admin` now run it before blaming anything: `unreachable` means reconnect the VPN and change nothing else |
| Everything worked an hour ago and now nothing authenticates | same cause, and the giveaway is *everything* failing at once rather than one command. A credential does not spontaneously stop working; a tunnel does. `tw_reach` |
| `Cloud techwatch was not found` | `OS_CLOUD` names an entry that isn't in any `clouds.yaml` the SDK can find. **Not** a project-name problem — the name is a local nickname (§1.4). List what exists with the `openstack.config` one-liner, then make `OS_CLOUD`, `tw-vars-env.sh` and the file agree. If Horizon generated the file, its entry is called `openstack` |
| The same error from every command, including ones with obvious typos | expected: cloud resolution happens before argument validation and before any request, so it masks everything underneath. Fix it and the real error appears |
| `Region RegionOne is not a valid region name for cloud techwatch. Valid choices are <REGION>` | `clouds.yaml` still has the literal `<REGION>` placeholder while `OS_REGION_NAME` (from a sourced openrc) says the real one. Set `region_name: RegionOne` — or delete the line — and stop sourcing openrc; see §1.4 |
| Auth errors mentioning a username, password or project scope you didn't put in `clouds.yaml` | you have an openrc sourced as well. `OS_*` env vars are merged *on top of* the selected cloud. Purge them with the loop in §1.4 |
| A command contains a literal `<…>`, e.g. `openstack image show <ROCKY9_IMAGE>` | you sourced `tw-vars-env.sh` before §1.5 filled in that value. Expected during §1.5 — type the real value; from §2 onward it means an answer is missing (`tw_check`) |
| `bash: SOMETHING: No such file or directory` from an `openstack` command | you pasted a placeholder literally and bash read the `<` as an input redirection, so the command never ran. The name in the message is the placeholder, not a file. Fill it in `tw-vars-env.sh`, re-source, and use `${TW_…}` |
| `No Network found for <EXT_NET>`, or any OpenStack `not found` naming a `<…>` value | the opposite case: the variable *was* set, to the template's placeholder string, so bash passed it through happily and OpenStack looked up a network called `<EXT_NET>`. §1.5's write-back for that value was skipped |
| `No image with a name or ID of 'Rocky-9.6' exists` | the image name is not what you assumed. `openstack image list --status active` — names are exact, and images can be per-region |
| `The request you have made requires authentication` | `OS_CLOUD` unset, or `clouds.yaml` not at `~/.config/openstack/clouds.yaml` |
| `Could not find requested endpoint` / connection timeout | you're off the network that can reach `<AUTH_URL>` — connect the VPN |
| `You are not authorized to perform the requested action` | you tried something admin-scoped. Check it against the "never" list above — the tutorial should not need it |
| `openstack token issue` shows a different project | the application credential was created while scoped elsewhere; delete it and redo §1.2 after §1.1 |
| quota shows 0 for instances or cores | the project hasn't had its defaults adjusted yet — this is expected early on; ask an admin |

Next: [appendix D — the ten-minute smoke test](appendix-d-smoke-test.md), then [§2 — An OpenStack primer for libvirt people](02-openstack-primer.md)
