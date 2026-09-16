# Appendix E — the complete network map

*(Reference. Nothing here is a step; every fact below is created by §§3, 4 and 7 and is reproduced here in one picture so that you can find a hop when something breaks.)*

Nine components sit between your keyboard and a Talos node, and each one can fail on its own. When a boot hangs or an SSH session times out, the useful question is not "what is wrong" but "which hop is wrong" — and that is much easier to answer against a map than against a memory of five tutorial sections.

![The complete network map: the macOS laptop and its Lima devbox VM, the F5 VPN tunnel, and inside the OpenStack project the shared external network, tw-router, tw-ext, the tw-head instance with both Neutron ports and the OpenCHAMI services, the silent tw-prov wire with its IP allocation bands, and the three Talos node instances each with a single MAC-pinned provisioning port.](diagrams/full-network-map.svg)

*Values measured on Digital Labs, 2 Aug 2026. §4's [smaller version](diagrams/04-head-node-path.svg) stops at the head node.*

## The two colours

The diagram uses exactly two, and the distinction is the single most important thing in this tutorial's networking:

**Green — `tw-ext`, routed and filtered.** DHCP on, a default gateway, a router to the outside, port security on, a security group. An ordinary cloud network. You SSH in over it and the head downloads several gigabytes through it.

**Amber — `tw-prov`, the silent wire.** No DHCP agent, no router, `--gateway none`, and port security *disabled* on every port. Three deliberate absences, each load-bearing:

| Absence | Why | What happens without it |
|---|---|---|
| no DHCP agent (`--no-dhcp`) | OpenCHAMI's CoreDHCP must be the only DHCP server on the wire | Neutron's dnsmasq races CoreDHCP for every node's request; roughly half your boots go wrong, differently each time |
| no router, `--gateway none` | nodes take their default route from CoreDHCP, pointing at the head | a second path out that OpenCHAMI does not know about, so the model in SMD stops matching reality |
| port security disabled | the head must serve DHCP and NAT for addresses that are not its own | anti-spoofing drops the replies; Talos hangs forever at `downloading installer` (§3.3) |

`--disable-port-security` belongs **only** on `tw-prov` ports. On the routed network with a floating IP attached it would expose the head node completely.

## Hop by hop

| # | Hop | Identity it presents | Created by | Verify with |
|---|---|---|---|---|
| 1 | Lima devbox VM | `192.168.5.15` — private to the VM, never on the wire | §1.3 | `ip -br addr` |
| 2 | macOS routing + NAT | — | your laptop | `route -n get <FIP>` |
| 3 | F5 VPN tunnel `utunN` | the pool address, e.g. `10.11.0.49` — **this is what the head sees** | your VPN client | `ifconfig utun10` |
| 4 | `external` network | `10.3.0.0/24`, RFC1918, shared | the cloud admins — **attach only** | `openstack subnet list --network external` |
| 5 | floating IP | `10.3.0.185` | §4.5 | `openstack floating ip list` |
| 6 | `tw-router` | DNAT in, SNAT out for `192.168.200.0/24` | §3.1 | `openstack router show tw-router` |
| 7 | `tw-ext` | `192.168.200.0/24`, DHCP on | §3.1 | `openstack subnet show tw-ext-subnet` |
| 8 | `tw-head-ext` port | `52:54:00:c0:fe:01`, filtered by `tw-sg-head` | §3.4, §3.5 | `openstack port show tw-head-ext` |
| 9 | `tw-head-prov` port | `52:54:00:be:ef:ff` at `172.16.0.254`, unfiltered | §3.4 | `openstack port show tw-head-prov` |
| 10 | `tw-prov` | `172.16.0.0/24`, silent | §3.2 | `openstack subnet show tw-prov-subnet` |
| 11 | node ports | `52:54:00:be:ef:0N` at `172.16.0.N` | §3.4 | `openstack port list --network tw-prov` |

## When the path breaks: which hop?

Almost every failure along this path produces the same symptom — **a hang**, never a refusal — because both the VPN and a non-matching security group *drop* packets rather than rejecting them. So the symptom tells you nothing, and the instinct to investigate the cluster is usually wrong.

There is a clean discriminator, and it comes from something the diagram makes obvious: **the OpenStack API and the head node are reached over the same tunnel, but only the head is behind a security group.** The API endpoint accepts you from any source address; `tw-sg-head` does not. So probing both separates the two failures:

```
devbox$ tw_vpn
```

| Keystone API | head, tcp/22 | What broke | Fix |
|---|---|---|---|
| ok | open | nothing on the path | look at the head node itself — `openstack console log show ${TW_PREFIX}-head` |
| ok | **no answer** | **the tunnel is up; your source address changed** | get the new address on the laptop, add a rule, then delete the stale one |
| unreachable | — | the VPN is down or disconnected | reconnect. ⚠ Once it drops, the `openstack` CLI reports an **authentication** failure, not a network error — do not go hunting for a bad password |

`tw_vpn` prints that verdict and, in the middle case, the exact command to run **on your laptop**. It cannot read the tunnel address itself: the devbox sits behind the laptop's NAT and the tunnel does not exist inside the VM.

```
mac$ ifconfig $(route -n get <FLOATING_IP> | awk '/interface/{print $2}') | awk '/inet /{print $2}'
10.11.0.52
```

⚠ **The middle row is common, not exotic.** An F5 pool address is allocated per session, so every VPN reconnect invalidates a `/32` rule. We saw two addresses within one hour on 2 Aug 2026 — `10.11.0.49`, then `10.11.0.52` — the second of which presented as a cluster that had been working ten minutes earlier. This is the argument for asking your cloud admin for the **VPN pool's CIDR** and scoping the rule to that instead: a `/32` you must re-issue several times a day is how somebody eventually "temporarily" sets `0.0.0.0/0`. §17 has the full add-then-delete procedure.

Note that `tw_vpn` probes **tcp/22 rather than pinging**. A project that allowed SSH but not ICMP would otherwise look broken while being entirely fine.

## The address bands on `tw-prov`

`172.16.0.0/24` is divided four ways, and the division is enforced by Neutron's allocation pools rather than by convention:

```
  .1  – .199    Neutron's pool — the node ports we create, each with an explicit fixed IP
  .200 – .250   CoreDHCP's "bootloop" range, leased to MACs OpenCHAMI does not recognise (§5.7)
  .251 – .253   unused
  .254          the head node
```

Keeping the bootloop range **outside** Neutron's pools is what makes an unknown node diagnosable: a machine that appears at `172.16.0.2xx` is telling you its MAC is not in SMD, which is a different fault from one that never gets an address at all.

## The three-way MAC contract

The MAC addresses in the diagram are not decoration. Each must appear identically in three places, and nothing checks that they agree:

1. the Neutron port — `openstack port create --mac-address` (§3.4)
2. the SMD inventory — `nodes.yaml` (§6)
3. the BSS boot payloads (§9)

Disagreement fails *silently*: the node takes a bootloop lease, or boots with the wrong role — a worker's config on a control-plane node, which then fails to form etcd. §6 has the reconciliation command; §17 has the symptoms.

## What the nodes deliberately lack

One port each, on `tw-prov` only. **No floating IP, no security group, no SSH key, no cloud-init user-data.** This is [DL-003](DECISION-LOG.md) and it is a design decision, not an economy: if Nova's metadata configured the nodes, OpenCHAMI would no longer be the source of truth and the whole exercise would prove nothing. Everything a node knows arrives over the amber wire, from the head.

The consequence for you is that **the devbox can never reach a node directly.** There is no route to `172.16.0.0/24` from anywhere outside the head. Cluster APIs are reached by tunnelling through it:

```
devbox$ ssh -L 6443:172.16.0.1:6443 -L 50000:172.16.0.1:50000 -L 8000:172.16.0.1:8000 \
        -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}
```

`6443` Kubernetes · `50000` Talos · `8265` Ray dashboard · `8000` vLLM's OpenAI-compatible API.

## Traffic in both directions

**Inbound**, you to the head: devbox → Lima NAT → macOS → VPN tunnel → `external` → `tw-router` DNAT → `tw-ext` → `tw-head-ext`.

**Outbound**, a node to the internet, which is how Talos downloads its installer: node → `tw-prov` → the head's masquerade rule (§5.12) → `tw-head-ext` → `tw-router` SNAT → out. Three translations in series. It works, and the MTU is worth a thought — Digital Labs tenant networks were observed at 9092, giving headroom, but a black-holing MTU presents as large downloads stalling while `ping` succeeds.

## Regenerating the diagrams

Both are hand-written SVG in [`diagrams/`](diagrams/README.md), with no external references, so they render anywhere Markdown does and diff readably in Git. Edit the coordinates directly; there is no source format to keep in sync. [`diagrams/README.md`](diagrams/README.md) documents the colour semantics, the shape and line conventions, and how to preview a change without installing a toolchain.

Related: [§3 — networks and ports](03-networks-and-ports.md) · [§4 — the head node instance](04-head-node-instance.md) · [§7 — node instances](07-node-instances-and-ipxe.md) · [§17 — troubleshooting](17-troubleshooting.md)
