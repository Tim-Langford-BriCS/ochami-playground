# Runbook — SSH to the head hangs: update the VPN tunnel address

*Operational reference, not a tutorial. Commands first. The reasoning is [§1.5](../01-safety-and-access.md), [§4.5](../04-head-node-instance.md) and [§17](../17-troubleshooting.md); this file is what you open when SSH has just stopped working and you want it back in two minutes.*

| I want to… | Go to |
|---|---|
| **Find the address the head node sees** — always start here | [1. Measure it](#1-measure-the-address-the-head-node-sees-laptop) |
| Write the rule for **exactly that address** | [2A. A `/32`](#2a-a-32--the-exact-address) |
| Write the rule for the **whole VPN pool** | [2B. The pool range](#2b-the-vpn-pool-range) |
| Confirm it really is the address, and not the head | [3. Diagnose first](#3-diagnose-first-30-seconds) |
| Understand why this keeps happening | [4. Why](#4-why-this-happens) |
| Tidy up the rules I have accumulated | [5. Delete the rules you are no longer using](#5-delete-the-rules-you-are-no-longer-using) |
| Decide between a `/32` and a range, properly | [6. Which scope to choose](#6-which-scope-to-choose) |
| Match an error I just got | [7. Errors seen in practice](#7-errors-seen-in-practice) |

**The symptom this runbook is for:**

```
devbox$ ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}
^C                          ← hangs. No banner, no "refused", no "permission denied".
```

A **hang** is the signature. A security group that does not match your source address *drops* packets rather than refusing them, so the head node never answers and `ssh` waits until you interrupt it. Nothing is wrong with the instance.

**Two steps: measure, then write a rule.** Step 1 is the same whichever scope you choose, and is worth running even when your rule is already a range — it is how you confirm you are on the tunnel at all, and it gives you the value to compare against the head's own `sshd` log. Step 2 is where the `/32`-versus-range decision lives, and [§6](#6-which-scope-to-choose) argues both sides.

---

## 1. Measure the address the head node sees (laptop)

🛑 **This runs on your laptop, not the devbox.** The tunnel does not exist inside the Lima VM — the devbox sits behind **two** NATs (Lima → macOS → tunnel), so no command run there can see the address that arrives at the head node. [§4](#4-why-this-happens) has the three commands that claim otherwise.

One line, if you just want the answer:

```
mac$ ifconfig $(route -n get 10.3.0.185 | awk '/interface:/{print $2}') | awk '/inet /{print $2}'
10.11.0.54
```

`10.3.0.185` is the head's floating IP — substitute yours (`echo $TW_HEAD_FIP` on the devbox).

**The two-step form is worth running at least once**, because it shows you the two facts the one-liner hides — which interface carries the route, and what address that interface holds:

```
mac$ route -n get 10.3.0.185 | grep interface
  interface: utun10
mac$ ifconfig utun10 | grep 'inet '
	inet 10.11.0.54 --> 1.1.1.1 netmask 0xffffffff
```

Read that output carefully, because every part of it is telling you something:

| What you see | What it means |
|---|---|
| `interface: utun10` | macOS's routing table says traffic to the head's floating IP leaves via the **F5's tunnel**, not your wifi. This is the proof that the VPN is carrying this destination — the single most useful fact in this runbook |
| `inet 10.11.0.54` | **the address the head node will see.** This is what goes in the security group rule |
| `--> 1.1.1.1` | the tunnel's *peer* address, i.e. the far end. A point-to-point interface prints `local --> remote`. It is not your address and not something you scope a rule to |
| `netmask 0xffffffff` | `/32`. The F5 gives your client a single address, not a subnet — which is why a `/32` rule is the *exact* match and why it is also the fragile one |

Expect **several** `utun` interfaces on a Mac — iCloud Private Relay and most VPN clients each create one, and `ifconfig` alone cannot tell you which is which. That is precisely why you ask the *route* first: `route -n get <the floating IP>` names the one interface that actually carries traffic to your head node. Guessing `utun0` because it sorts first is how you end up allowing an address that never appears on the wire.

On a Linux laptop it is one command, run **on the laptop**: `ip route get 10.3.0.185` prints the interface and the `src` address together.

Now write the rule — [2A](#2a-a-32--the-exact-address) for exactly this address, or [2B](#2b-the-vpn-pool-range) for the whole pool.

---

## 2A. A `/32` — the exact address

The tightest correct scope: exactly the address you just measured, and nothing else.

```
devbox$ export TW_ADMIN_CIDR='10.11.0.54/32'                      # the address from step 1
devbox$ openstack security group rule create ${TW_PREFIX}-sg-head \
    --protocol tcp --dst-port 22 --remote-ip ${TW_ADMIN_CIDR} --description SSH
devbox$ openstack security group rule create ${TW_PREFIX}-sg-head \
    --protocol icmp --remote-ip ${TW_ADMIN_CIDR} --description ping
devbox$ sed -i "s|^export TW_ADMIN_CIDR=.*|export TW_ADMIN_CIDR='${TW_ADMIN_CIDR}'|" ~/tw/tw-vars-env.sh
devbox$ ping -c1 ${TW_HEAD_FIP} && ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}
```

**Add the new rule before deleting the old one.** If you read the wrong interface in step 1, the old rule is still there to fall back on; delete first and a mistake locks you out of your own head node with no way in but a console session. Cleanup is [§5](#5-delete-the-rules-you-are-no-longer-using) and it is not urgent.

Confirm the head agrees, while you are in. **This is the only authoritative source** — everything else is inference:

```
head$ sudo journalctl -u sshd | grep -i accepted | tail -3
Accepted publickey for rocky from 10.11.0.54 port 51234 ssh2: ED25519 SHA256:…
```

If that address is **not** the one you allowed, then the rule that let you in is an older one and you read the wrong interface in step 1. Use the log's value — it is what actually arrived.

**Accept that you will redo this.** Every VPN reconnect hands you a new address, so a `/32` is a per-session commitment. [§6](#6-which-scope-to-choose) sets out when that is the right trade — and it genuinely is, in several cases — and [2B](#2b-the-vpn-pool-range) is the alternative.

---

## 2B. The VPN pool range

One pair of rules, set once, that survives every reconnect. This is the tutorial's default (§1.5).

At Digital Labs the F5 concentrator — **run by UoB IT Services**, not by the cloud team and not by us — is understood to allocate client addresses from **`10.11.0.0/16`** (told to us 3 Aug 2026, and consistent with every address we have measured). It is somebody else's service and we have not seen its configuration, so treat the boundary as a well-supported belief: a pool can be renumbered or split across profiles without anyone telling us. That is why [step 1](#1-measure-the-address-the-head-node-sees-laptop) stays worth running even here.

```
devbox$ export TW_ADMIN_CIDR='10.11.0.0/16'
devbox$ openstack security group rule create ${TW_PREFIX}-sg-head \
    --protocol tcp --dst-port 22 --remote-ip ${TW_ADMIN_CIDR} --description "SSH from F5 VPN pool"
devbox$ openstack security group rule create ${TW_PREFIX}-sg-head \
    --protocol icmp --remote-ip ${TW_ADMIN_CIDR} --description "ping from F5 VPN pool"
devbox$ sed -i "s|^export TW_ADMIN_CIDR=.*|export TW_ADMIN_CIDR='${TW_ADMIN_CIDR}'|" ~/tw/tw-vars-env.sh
devbox$ source ~/tw/tw-env.sh && echo ${TW_ADMIN_CIDR}
10.11.0.0/16
devbox$ ping -c1 ${TW_HEAD_FIP} && ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}
```

**Step 1 still applies.** The measured address should fall *inside* the range you just wrote — check it does, because a pool address outside the CIDR you were given means either the range is wrong or you are on a different VPN profile than you think. `10.11.0.54` is inside `10.11.0.0/16`; `10.12.0.4` would not be.

⚠ **Write the mask out in full.** `10.11/16` is fine in conversation, but pass `10.11.0.0/16` to `openstack` — do not rely on Neutron normalising an abbreviated form, and if it did accept one you would be guessing at what it stored. Confirm what actually landed:

```
devbox$ openstack security group rule list ${TW_PREFIX}-sg-head -c 'IP Protocol' -c 'IP Range' -c 'Port Range'
```

Once this works, the `10.11.x.y/32` rules are redundant — every one of them is inside the range. [§5](#5-delete-the-rules-you-are-no-longer-using) sweeps them.

> If your cloud is not Digital Labs, the pool CIDR is a question for whoever runs the VPN — [§6](#6-which-scope-to-choose) has the wording. Use [2A](#2a-a-32--the-exact-address) in the meantime; it needs no one's permission.

---

> **Both scopes, same caveat:** if you also created the optional `${TW_PREFIX}-sg-api` group (§3.6), its four rules are scoped to the same variable and need the same treatment — but only if it is actually attached to a port. `openstack port show ${TW_PREFIX}-head-ext -c security_group_ids -f value` tells you. Normally it is not, and you can ignore it.

---

## 3. Diagnose first (30 seconds)

Worth doing before either rule, because two completely different failures produce the identical hang and only one of them is fixed above.

```
devbox$ tw_vpn
```

| Keystone API | head, tcp/22 | Verdict | Do this |
|---|---|---|---|
| ok | open | the path is fine | the fault is **on the head node** — nothing here applies |
| ok | **no answer** | tunnel up, **your address changed** | [measure it](#1-measure-the-address-the-head-node-sees-laptop), then [2A](#2a-a-32--the-exact-address) or [2B](#2b-the-vpn-pool-range) |
| unreachable | — | **the VPN is down** | reconnect the VPN, then re-run `tw_vpn` |

The discriminator is an asymmetry: the Keystone endpoint and the head node are reached over the *same* tunnel, but **only the head is behind a security group**. So a working API with a dead head can only be a filtering problem, and a dead API can only be the tunnel.

⚠ **When the VPN is down, the `openstack` CLI reports an *authentication* failure, not a network error.** It looks like a bad credential. Check `tw_vpn` before you go rotating application credentials.

If `tw_vpn` is missing, your `~/tw/tw-helpers-env.sh` predates it — re-copy it (the helpers file is always safe to re-copy; `tw-vars-env.sh` never is):

```
devbox$ cp ~/work/…/tutorials/ochami-openstack-talos/templates/tw-helpers-env.sh ~/tw/
devbox$ source ~/tw/tw-env.sh
```

---

## 4. Why this happens

The floating IP is `10.3.0.185` — **RFC1918**, despite the name. It is reachable only across the F5 VPN, and the F5 assigns your client an address from a pool **per session**. Reconnect and you are somebody else.

Three addresses observed in two days, with nothing changed in between but VPN sessions:

| When | Tunnel address | Effect |
|---|---|---|
| 2 Aug 2026, first connection | `10.11.0.49` | SSH worked; `sshd` logged `Accepted publickey for rocky from 10.11.0.49` |
| 2 Aug 2026, ~1 hour later | `10.11.0.52` | SSH hung. The cluster was healthy the whole time. |
| 3 Aug 2026 | `10.11.0.54` | SSH hung again. Measured with the step 1 sequence. |

So a `/32` of the tunnel address — the tightest, most correct value — is also the most fragile. Anything that ends the VPN session invalidates it: sleeping the laptop, a dropped wifi association, a client timeout, moving between networks, or an explicit reconnect.

All three sit inside `10.11.0.0/16`, which is the evidence that the pool CIDR we were given is the right one — and the reason [2B](#2b-the-vpn-pool-range) fixes the whole class rather than one instance of it. It is also the reason to keep running [step 1](#1-measure-the-address-the-head-node-sees-laptop) even on a range: an address *outside* the CIDR would mean the range is wrong.

**Three commands claim to tell you your source address and only one is right.** This is worth understanding whichever scope you use, because two of them are the natural things to reach for and both are wrong here:

| Command | Reports | Use it? |
|---|---|---|
| `curl -s ifconfig.me` on the devbox | your ISP line, e.g. `86.x.y.z` | **No** — with a split tunnel this address never carries `10.3.0.x` |
| `ip route get 10.3.0.185` on the devbox | `src 192.168.5.15` — Lima's internal NAT | **No** — true, and it never leaves the VM |
| `route -n get` + `ifconfig utunN` **on the laptop** | the F5 pool address | **Yes** — this machine holds the tunnel |

The devbox is behind **two** NATs — Lima → macOS → tunnel — which is why no command run inside it can see the address the head node sees. [Appendix E](../appendix-e-network-map.md) draws the whole path.

---

## 5. Delete the rules you are no longer using

**An old `/32` pointing at a pool address that has since been reassigned to another VPN client is a real exposure**, not just clutter — that client can reach your port 22 and you have no idea who they are. This is the one piece of housekeeping that is not optional.

On [2A](#2a-a-32--the-exact-address) it is a habit: add the new pair, verify, delete the previous pair. On [2B](#2b-the-vpn-pool-range) it is a single sweep of every `/32` you accumulated before you had the range.

```
devbox$ openstack security group rule list ${TW_PREFIX}-sg-head
```

```
+--------------------------------------+-------------+-----------+-----------+---------------+
| ID                                   | IP Protocol | Ethertype | IP Range  | Port Range    |
+--------------------------------------+-------------+-----------+-----------+---------------+
| 94daca36-aad6-4c37-9031-8215d41fe297 | tcp         | IPv4      | 10.11.0.49/32 | 22:22     |  ← spent
| a5a0c782-de1b-4753-9f57-270c8898749f | icmp        | IPv4      | 10.11.0.49/32 |           |  ← spent
| …                                    | tcp         | IPv4      | 10.11.0.52/32 | 22:22     |  ← spent
| …                                    | icmp        | IPv4      | 10.11.0.52/32 |           |  ← spent
| …                                    | tcp         | IPv4      | 10.11.0.54/32 | 22:22     |  ← current session
| …                                    | icmp        | IPv4      | 10.11.0.54/32 |           |  ← current session
+--------------------------------------+-------------+-----------+-----------+---------------+
```

Delete by ID — the pairs for addresses you are **not** connected from:

```
devbox$ openstack security group rule delete 94daca36-aad6-4c37-9031-8215d41fe297
devbox$ openstack security group rule delete a5a0c782-de1b-4753-9f57-270c8898749f
```

There are normally **two rules per address** — `tcp/22` and `icmp`. Deleting only the `tcp` one leaves a stray ping rule that will confuse the next person to read the list.

If you moved to the range, the group holds a `10.11.0.0/16` pair as well, and then *every* `/32` above is redundant — each one is inside the range, so it grants nothing the range does not already grant.

🛑 **Keep at least one rule that matches where you are right now.** On `/32`s, cross-check each against `${TW_ADMIN_CIDR}` and against the head's `sshd` log before deleting; on a range, the `/16` pair is the one to keep. Either way, **your live SSH session survives a rule deletion** — Neutron's conntrack keeps established flows — so a mistake here is invisible until you next reconnect, which is exactly when it is least welcome.

Leave the egress rules and the two default IPv4/IPv6 egress entries alone.

---

## 6. Which scope to choose

**Both `/32` and the pool range are defensible. Pick deliberately, and write down which and why.** The third option is not an option.

| | Scope | Redo it when? | Who else could match the rule |
|---|---|---|---|
| **[2A](#2a-a-32--the-exact-address)** | `10.11.0.54/32` — this session's address | every reconnect | nobody |
| **[2B](#2b-the-vpn-pool-range)** | `10.11.0.0/16` — the VPN pool | never | anyone authenticated onto the F5 VPN |
| — | `0.0.0.0/0` | never | **the entire internet.** Not on the table |

### The case for the `/32`

- **Least privilege, literally.** It is the tightest rule the mechanism can express, and it is the one you can defend in a security review without qualification. "We allow exactly the address we are connecting from" needs no argument; "we allow a /16" needs the one below.
- **It gives you an audit trail.** The rule list becomes a record of which sessions were permitted and when. On a range, the group tells you nothing about who used it.
- **It does not depend on anyone else's answer.** You measure it yourself in step 1. The pool CIDR is a fact you have to be *told*, and if that fact is wrong — a second VPN profile, a pool that gets renumbered — the range silently stops matching while the `/32` you measured never can.
- **It is free when the work is short.** For a single session, or for the initial walk through §§3–4, the two-minute cost lands once and buys you the tightest scope available.
- **It is how you learn the path.** Step 1 is not busywork: it is the only sequence that shows you the tunnel exists, which interface carries it, and that the devbox cannot see any of it. Someone who has never run it does not really know how their packets reach the head node — and will not diagnose the next hang.
- **It is the right default on a different cloud.** If the floating-IP network is *publicly* routable, the pool address is a public address and the RFC1918 argument below does not apply at all. Then a `/32` is not merely tighter, it is the only responsible choice.

### The case for the range

- **It is a private range.** `10.11.0.0/16` is RFC1918 and unroutable from the internet, so the set of hosts that can *reach* the head's port 22 is the same under either scope: those already on the VPN or inside the University network. The mask width does not move that boundary — the VPN's own authentication does.
- **What it gives up is small and specific**: the distinction between you-on-the-VPN and someone-else-on-the-VPN. They would still need your Ed25519 private key, which lives on your laptop and not on the VPN.
- **What it buys is a failure mode removed.** The `/32`'s tax lands at the worst possible moment — mid-section, cluster running, symptom indistinguishable from a dead node. Repeated friction like that is *how* clusters end up wide open: not because anyone decides `0.0.0.0/0` is acceptable, but because someone in a hurry decides it is temporary.

### So

**For a cluster you intend to keep — weeks of intermittent work — the range is the better engineering answer**, and it is what Digital Labs' cloud team pointed us at. **For a short, attentive session, or on a cloud with public floating IPs, the `/32` is better** and costs you nothing you will notice.

Whichever you choose, run [step 1](#1-measure-the-address-the-head-node-sees-laptop) at least once, and record the *reason* alongside the value in `~/tw/tw-vars-env.sh`. A range nobody can justify is a range the next reader will widen.

**Never `0.0.0.0/0`.** §3.5 and the IaC both refuse it deliberately. A default-open SSH port on a cloud is found by scanners within minutes, and this one sits on a hypervisor carrying other people's work.

If you are on a different cloud and want the pool CIDR, ask whoever runs the VPN:

> What CIDR does the VPN allocate client addresses from? I need to scope a security group to it — I've had `10.11.0.49`, `10.11.0.52` and `10.11.0.54` across two days, and re-issuing a `/32` per reconnect isn't sustainable.

---

## 7. Errors seen in practice

| What you see | What it means |
|---|---|
| `ssh` hangs with no output, `^C` to escape | the security group does not match your source address — this runbook. **Not** a dead instance |
| `ConflictException: 409 … Security group rule already exists. Rule id is 94daca36-…` | you re-created a rule that is byte-identical to an existing one. Harmless, and it names the colliding rule. Neutron only 409s on an exact protocol/port/direction/CIDR match, so a *near*-duplicate goes in silently |
| `The request you have made requires authentication` from any `openstack` command | usually the **VPN**, not the credential. Run `tw_vpn` before touching application credentials |
| `bash: YOUR_ADMIN_CIDR: No such file or directory` | you pasted a literal `<YOUR_ADMIN_CIDR>`; bash read `<` as input redirection. Set `TW_ADMIN_CIDR` and use `${TW_ADMIN_CIDR}` |
| `route -n get` names an interface but `ifconfig` shows no `inet` | that `utun` belongs to another service (iCloud Private Relay and several VPN clients each create one). Re-read the interface the *route* names, for the head's floating IP specifically |
| SSH works, then hangs again an hour later, then works | the F5 handed you a new pool address. Confirms [§4](#4-why-this-happens)'s per-session behaviour. Re-measure and re-issue the `/32`, or decide it is time for the range — [§6](#6-which-scope-to-choose) |
| `route -n get` names `utun4` today and `utun10` tomorrow | normal. The number depends on the order interfaces came up, so **never hardcode it** — always ask the route first |
| the measured address is outside your `TW_ADMIN_CIDR` range | either the range is wrong, or you are connected on a different VPN profile than the one it was measured on. Do not widen the range to make it fit; find out which |
| any complaint about `remote_ip_prefix` after passing `10.11/16` | write the mask out in full — `10.11.0.0/16`. Untested here: Neutron may reject the shorthand or may normalise it, and you do not want to find out by guessing what it stored |
| `ping` works but `ssh` hangs | only the `icmp` rule matched — you have an `icmp` rule for the current address and a `tcp/22` rule for an old one |

---

## Where the reasoning lives

| Section | What it argues |
|---|---|
| [§1.5](../01-safety-and-access.md) | how to find `TW_ADMIN_CIDR` in the first place, and the three-command comparison with real measured values |
| [§3.5](../03-networks-and-ports.md) | the two security groups, and why SSH is never scoped to `0.0.0.0/0` |
| [§4.5](../04-head-node-instance.md) | the floating IP is RFC1918, and what that implies before you first try to SSH |
| [§4.8](../04-head-node-instance.md) | the nine-step validation chain that proves the whole path, hop by hop |
| [§17](../17-troubleshooting.md) | `TW_ADMIN_CIDR` is not durable — the general form of this problem |
| [Appendix E](../appendix-e-network-map.md) | the network map: laptop, Lima VM, tunnel, Neutron, both head ports |
