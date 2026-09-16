# Runbook — OpenStack application credentials

*Operational reference, not a tutorial. Commands first. The reasoning behind all of this is [§1.2](../01-safety-and-access.md) and [§1.4](../01-safety-and-access.md); this file is what you open when you already know why and just need to do it.*

| I want to… | Go to |
|---|---|
| Set up the two-identity split for the first time | [1. Create](#1-create-the-member-credential) |
| Check which identity a shell is holding | [2. Test](#2-test-each-credential) |
| Replace a leaked or expiring credential | [3. Rotate](#3-rotate-delete-and-recreate) |
| See what exists and clean up stale ones | [4. Audit](#4-audit) |
| Understand an error I just got | [5. Errors](#5-errors-seen-in-practice) |

Values below are Digital Labs / `techwatch-proto`. Substitute your own.

---

## The shape we are aiming for

Two `clouds.yaml` entries, used for different things, never interchangeable:

| Entry | Auth | Used for | Prompts? |
|---|---|---|---|
| `techwatch` | application credential, `--role member` | everything: all tutorial sections, **all IaC** | no |
| `techwatch-admin` | password, your full account | one deliberate privileged action at a time | yes, every command |

Three properties make the member entry genuinely safer rather than merely tidier:

- **Roles are frozen at creation.** `--role member` cannot use admin policy even after your account is granted `admin`.
- **It is bound to one project** — whichever you were scoped to when you created it.
- **`unrestricted` is `false` by default**, so it cannot mint further credentials or trusts. This is why [rotation](#3-rotate-delete-and-recreate) needs the password entry.

---

## 1. Create the member credential

**Prerequisite:** password authentication already works, and you are scoped to the right project. The credential inherits that scope permanently.

```
devbox$ openstack token issue -c project_id -f value      # must be YOUR project
```

Create it:

```
devbox$ openstack application credential create \
    --description "TechWatch OpenCHAMI prototyping — member only, expires 2026-12-31" \
    --expiration 2026-12-31T00:00:00 \
    --role member \
    tw-ochami-proto
```

**Copy the `id` and `secret` now — the secret is displayed exactly once.** There is no recovery; if you lose it, [rotate](#3-rotate-delete-and-recreate).

> `--unrestricted` exists and would let the credential manage other credentials. **Do not use it.** It removes the property that makes a leak survivable.

### Wire up `clouds.yaml`

`~/.config/openstack/clouds.yaml`, then `chmod 600`:

```yaml
clouds:
  techwatch:                                    # ← everything, including the IaC
    auth_type: v3applicationcredential
    auth:
      auth_url: https://api.dl.acrc.bris.ac.uk:5000
      application_credential_id: <ID>
      application_credential_secret: <SECRET>
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3

  techwatch-admin:                              # ← one privileged action at a time
    auth_type: v3password
    auth:
      auth_url: https://api.dl.acrc.bris.ac.uk:5000
      username: "<YOUR_USERNAME>"
      user_domain_name: "Default"
      project_id: <PROJECT_ID>
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3
```

🛑 **The member entry must contain nothing about who or where you are.** No `username`, no `project_id`, no `project_name`, no `user_domain_name`, no `password`. The credential carries its own scope, and supplying a second one is rejected — see [5. Errors](#5-errors-seen-in-practice).

The commonest way to get this wrong is editing a password stanza in place and leaving its keys behind.

> **Getting the entry from Horizon instead:** *Identity → Application Credentials → Create Application Credential* offers **Download clouds.yaml** with the id and secret already filled in. Two fixes needed: the entry is named `openstack` (rename it to `techwatch`), and it sometimes omits `interface: public`. Note that *Project → API Access → Download clouds.yaml* is a **different, password-based** file — not this.

---

## 2. Test each credential

Always check reachability first. **A dropped VPN presents as an authentication failure**, not a network error, and will send you chasing a credential that is perfectly fine:

```
devbox$ tw_reach                     # must print: ok
```

### The member credential

```
devbox$ OS_CLOUD=techwatch openstack image list --name 'Rocky-9.6' -f value -c ID
```

Any ordinary read will do. Two things to look for:

- **It does not prompt.** No password, ever.
- **It sees less than the admin entry does.** On a cloud where several projects have images of the same name, the member credential returns only the public one and the admin entry returns all of them. That difference *is* the down-scoping, demonstrated rather than asserted.

### The admin entry

```
devbox$ OS_CLOUD=techwatch-admin openstack image list --name 'Rocky-9.6' -f value -c ID
Password:
```

**It should prompt every time.** That friction is the feature — it puts a deliberate act on every privileged command. If it stops prompting, something is storing your password.

### Which identity is this shell holding?

```
devbox$ echo $OS_CLOUD
devbox$ openstack configuration show | grep -i auth_type
devbox$ bash ~/tw/tw-status.sh | head -5          # reports member vs admin explicitly
```

### If `token issue` fails but reads work

`openstack token issue` asks Keystone for a *scoped* token, which some deployments refuse under application-credential auth. If ordinary reads succeed and only `token issue` fails, the credential is fine — prefer `openstack catalog list` as an auth probe. (`tw_check` and `tw-status.sh` already fall back this way.)

---

## 3. Rotate (delete and recreate)

Do this when a secret is exposed — pasted into a ticket, a chat, a screen share — or when the expiry approaches. Revocation is instant and affects nothing the credential created.

🛑 **You cannot rotate the credential using the credential.** Use the password entry:

```
devbox$ openstack --os-cloud techwatch-admin application credential delete tw-ochami-proto

devbox$ openstack --os-cloud techwatch-admin application credential create \
    --description "TechWatch OpenCHAMI prototyping — member only, expires 2026-12-31" \
    --expiration 2026-12-31T00:00:00 \
    --role member \
    tw-ochami-proto
```

This needs **password authentication, not the `admin` role** — any non-credential entry as the same user works.

Then update `application_credential_id` and `application_credential_secret` in `clouds.yaml`, and verify:

```
devbox$ OS_CLOUD=techwatch openstack image list --name 'Rocky-9.6' -f value -c ID
```

> `--secret <value>` lets you supply the secret rather than have one generated, which is occasionally useful for automation. **Never reuse the old secret** — that defeats the entire point of rotating.

### What to do about the exposure itself

Deleting the credential is sufficient: it is dead immediately, and it never had your password. But note in the run log *what* was exposed and *where*, because "an application credential secret was pasted into a chat" and "my account password was" are very different incidents.

---

## 4. Audit

```
devbox$ openstack application credential list
devbox$ openstack application credential show tw-ochami-proto
```

Check periodically:

- **Expiry.** A credential without one never stops working. Every credential this project creates should have `--expiration`.
- **Strays.** Credentials from experiments, from a colleague's walkthrough, from a previous rotation that was never cleaned up. Delete them — an unused credential is unmonitored attack surface, and it costs nothing to recreate.
- **Roles.** `show` reports the roles it was frozen with. Anything holding more than `member` deserves a reason.

Also worth checking on the head node, if you have done [appendix A](../appendix-a-redfish-sushy.md): that path puts credentials on a host that other things can reach. The retired nested tutorial's libvirt-driver variant of that appendix avoided needing any, by pointing sushy-emulator at libvirt rather than at OpenStack.

---

## 5. Errors seen in practice

All of these were hit on Digital Labs during this project, and none of them says what it means.

| Error | Cause | Fix |
|---|---|---|
| `Application credentials cannot request a scope. (HTTP 401)` | the entry supplies a scope *as well as* the credential | delete `username`, `project_id`, `project_name`, `user_domain_name`, `password` from the member entry. If it is already clean, the scope is coming from the environment — `env \| grep '^OS_'` should show only `OS_CLOUD` |
| `Using method 'application_credential' is not allowed for managing additional application credentials` | you tried to rotate the credential using the credential | use `--os-cloud techwatch-admin`. This is `unrestricted: false` working correctly — see [3](#3-rotate-delete-and-recreate) |
| Authentication fails with a password you *know* is correct | 🛑 **check the VPN before touching the credential.** A dropped tunnel is reported as an auth failure, not a network one | `tw_reach`. `unreachable` → reconnect and change nothing else |
| Everything stops authenticating at once, having worked an hour ago | same cause. Credentials do not spontaneously fail; tunnels do | `tw_reach` |
| `Cloud techwatch was not found` | `OS_CLOUD` names an entry no `clouds.yaml` contains — a local nickname, nothing to do with the project name | `python3 -c 'import openstack.config as c; print("\n".join(c.OpenStackConfig().get_cloud_names()))'` |
| Auth errors naming a username or project you did not put in `clouds.yaml` | a sourced `openrc` is merging `OS_*` on top of the file | `tw_clean_os`, or start a fresh shell |
| `The request you have made requires authentication. (HTTP 401)`, intermittently, while being prompted per command | mistyped password, not a broken credential | `tw_login` once per shell, or use the member credential where no password is needed |
| `token issue` fails but `image list` works | `token issue` requests a scoped token; some deployments refuse it for app credentials | not a fault. Use `catalog list` as the probe |

---

## 6. Two things not to do

**Do not paste `openstack configuration show` unfiltered.** It masks `auth.password` but prints `auth.application_credential_secret` in full, in clear — confirmed with `osc-lib` 4.7.0. This is the command everyone reaches for when debugging auth, and its output is the thing most likely to end up in a ticket or a chat window. Before sharing:

```
devbox$ openstack configuration show | grep -vi 'secret\|password'
```

**Do not create an admin-scoped application credential.** It sounds like the convenient fix for the password prompting. It puts an admin-capable secret on disk permanently and removes the friction that makes elevation deliberate — the two things the split exists to prevent. If privileged work is frequent enough to be annoying, use `tw_admin` (prompts once, expires, marks the prompt) or ask a cloud admin to do the task.

---

## Related

- [§1.2 — why application credentials, and what they are not](../01-safety-and-access.md) — a new user, a new role, and why neither is the answer
- [§1.4 — `clouds.yaml` in full](../01-safety-and-access.md), including the four ways to supply a password and why not to mix mechanisms
- [`templates/tw-helpers-env.sh`](../templates/tw-helpers-env.sh) — `tw_reach`, `tw_check`, `tw_admin`, `tw_member`, `tw_clean_os`, `tw_config`
- [`templates/techwatch-proto-clouds.yaml`](../templates/techwatch-proto-clouds.yaml) — both entries, ready to uncomment
- [Keystone: application credentials](https://docs.openstack.org/keystone/latest/user/application_credentials.html)
