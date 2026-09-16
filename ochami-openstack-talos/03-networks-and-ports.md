# §3 — Networks, subnets and MAC-pinned ports

*(Time: ~20 minutes. This is the first section that creates anything. Everything here is inside our own project and affects nothing outside it — but read §3.3 before you run §3.4, because one flag there is the difference between a working cluster and a silent failure in §10.)*

```
devbox$ cd ~/tw && source ~/tw/tw-env.sh
```

## Concepts

Our cluster needs two very different networks, and understanding *why* teaches most of what matters about provisioning networks. [Appendix E](appendix-e-network-map.md) draws both of them, with every port and address this section creates, if you would rather see the finished shape before building it.

**The external network (`tw-ext`)** exists for us humans and for package downloads. It is routed: instances on it can reach the internet, and a floating IP on it gives us an SSH path to the head node. Neutron's own DHCP runs here, because we want the ordinary cloud behaviour.

**The provisioning network (`tw-prov`)** is the *provisioning wire*, and it is deliberately hostile to everything except OpenCHAMI. It has:

- **no DHCP** — because when a node network-boots, the *only* DHCP server answering must be OpenCHAMI's CoreDHCP on the head node. The DHCP answer is what steers the node into the boot chain; two DHCP servers on one broadcast domain is a classic provisioning failure ("who answered first?").
- **no router and no gateway** — nothing routes off this wire except the head node, which we turn into a NAT router in §5.12. Keeping Neutron out of the routing decision means the wire behaves like a real management VLAN.
- **no port security** — see §3.3.

This is the same design as the libvirt lab's isolated bridge, where the internal network's XML deliberately had no `<ip>` element at all (an `<ip>` is what makes libvirt spawn its dnsmasq). Neutron just makes you say it in more words.

**Why we pin MAC addresses.** OpenCHAMI's entire model is *MAC → identity*. CoreDHCP sees a MAC, looks it up in SMD, and leases that node its assigned IP; BSS sees a MAC and returns that node's boot script. So the MAC has to be something we chose and recorded, not something Neutron invented. Neutron lets you set a port's MAC at creation time, and a port can exist before any instance plugs into it — so we create the ports first, with our MACs, and hand them to instances later.

The MACs come from the node map in `tw-vars-env.sh` and they must match the SMD inventory in §6 and the BSS payloads in §9. **Three places, one set of values.** (This hand-synchronisation is exactly what the companion IaC exists to eliminate — see [`../ochami-openstack-talos-iac/`](../ochami-openstack-talos-iac/).)

## Step 3.1 — The external network

```
devbox$ openstack network create ${TW_PREFIX}-ext

devbox$ openstack subnet create ${TW_PREFIX}-ext-subnet \
    --network ${TW_PREFIX}-ext \
    --subnet-range ${TW_EXT_SUBNET_CIDR} \
    --dns-nameserver 1.1.1.1 --dns-nameserver 8.8.8.8
```

By default a subnet gets DHCP enabled and a gateway at the first address (`192.168.200.1`), which is what we want here — the head node's external NIC will pick up its address, route and DNS automatically, just like any cloud VM.

🔀 **Deviation — subnet range.** The upstream OpenCHAMI guide uses `192.168.122.0/24`, which is libvirt's built-in `default` network and collides on any normal libvirt host. Our libvirt lab moved to `192.168.200.0/24`; we keep that for continuity even though the collision can't happen here.

Now attach it to the outside world:

```
devbox$ openstack router create ${TW_PREFIX}-router
devbox$ openstack router set ${TW_PREFIX}-router --external-gateway ${TW_EXT_NET}
devbox$ openstack router add subnet ${TW_PREFIX}-router ${TW_PREFIX}-ext-subnet
```

Three steps because Neutron separates them: create the router, give it a way out (`--external-gateway`, using the external network you found in §1.5), then plug our subnet into it. The router now does SNAT for `192.168.200.0/24`.

🛑 **`${TW_EXT_NET}` is the only shared resource this tutorial touches.** We *attach to* it; we never modify it. Do not run `openstack network set` or `openstack subnet set` against it.

## Step 3.2 — The provisioning network

```
devbox$ openstack network create ${TW_PREFIX}-prov

devbox$ openstack subnet create ${TW_PREFIX}-prov-subnet \
    --network ${TW_PREFIX}-prov \
    --subnet-range ${TW_PROV_CIDR} \
    --no-dhcp \
    --gateway none \
    --allocation-pool start=172.16.0.1,end=172.16.0.199 \
    --allocation-pool start=172.16.0.254,end=172.16.0.254
```

Flag by flag, because every one of them is load-bearing:

- **`--no-dhcp`** — Neutron does not start a DHCP agent on this network. Without this, Neutron's dnsmasq and OpenCHAMI's CoreDHCP race for every node's DHCP request, and roughly half your boots go wrong in a way that is very hard to diagnose. This is the flag that makes the wire "silent".
- **`--gateway none`** — no default route is defined for the subnet. Nodes get their route from CoreDHCP (which advertises the head node, `172.16.0.254`), not from Neutron. It also means attaching a router to this subnet later would be an explicit act, not an accident.
- **the two `--allocation-pool`s** — Neutron still assigns fixed IPs to ports on a `--no-dhcp` subnet (it uses them for anti-spoofing bookkeeping and IPAM); it just doesn't *serve* them. We constrain where it may allocate so that it never collides with the range CoreDHCP hands out to *unknown* MACs. §5.7 configures CoreDHCP's `bootloop` plugin to lease `172.16.0.200–250` to nodes it doesn't recognise; leaving `.200–.253` outside Neutron's pools keeps those addresses free. The second, single-address pool reserves `172.16.0.254` for the head node.

```
   172.16.0.1 ────── .199   Neutron pool: node ports, assigned by us
   172.16.0.200 ──── .250   CoreDHCP "bootloop" range for unknown MACs (§5.7)
   172.16.0.251 ──── .253   unused
   172.16.0.254             the head node (§4)
```

⚠ **If Neutron rejects the two-pool form**, some deployments prefer a single pool. Use `--allocation-pool start=172.16.0.1,end=172.16.0.199` alone, and in §3.4 the head's `.254` may then be refused as out-of-pool — in which case widen to `start=172.16.0.1,end=172.16.0.254` and accept that Neutron *could* allocate into the bootloop range. It won't in practice, because every port we create names its IP explicitly, but note the compromise in your run log.

## Step 3.3 — Port security: the gotcha that eats an afternoon

⚠ **Read this before creating any port on `tw-prov`.**

Neutron applies **anti-spoofing rules** to every port by default. A port may only emit packets whose source MAC is its own and whose source IP is one of its assigned fixed IPs, and — specifically, deliberately — **a port may not serve DHCP**. The rule exists to stop a malicious tenant hijacking a shared network, and it is a good rule.

It also breaks two things we absolutely require:

1. **CoreDHCP cannot answer.** The head node's DHCP replies are dropped by its own port before they reach the wire. The symptom in §10 is nodes that network-boot, broadcast, and never get an address — with *no error logged anywhere*, because from Neutron's point of view it is working correctly.
2. **The head cannot NAT for the nodes.** In §5.12 the head forwards node traffic out to the internet, which means emitting packets with source IPs from `172.16.0.0/24` that are not its own. Anti-spoofing drops all of them, and the symptom is Talos hanging forever at `downloading installer`.

Two ways to fix it, and we use the first:

| | `--disable-port-security` (what we do) | `--allowed-address-pair` |
|---|---|---|
| What it does | turns off all filtering on the port: no anti-spoof, no security groups | keeps filtering on, but whitelists extra MAC/IP ranges |
| For the head's prov port | works | `--allowed-address-pair ip-address=172.16.0.0/24` permits the NAT traffic — but does **not** permit acting as a DHCP server on all deployments |
| Security posture | the port is unfiltered — acceptable *because this network is isolated and ours alone* | tighter |
| Verdict | **use this.** The provisioning wire has no router and no path to anything else; there is nothing to protect it from, and we need behaviour that anti-spoofing is specifically designed to prevent | try it if your site requires it; expect to fight the DHCP rule |

🛑 **Only on `tw-prov`, never on `tw-ext`.** The external port keeps its security group and its filtering. Disabling port security on a routed network with a floating IP would expose the head node completely. Every `--disable-port-security` below is on a `tw-prov` port; check the network name each time.

## Step 3.4 — The ports

**The head node's two ports.** External first — ordinary, filtered, DHCP:

```
devbox$ openstack port create ${TW_PREFIX}-head-ext \
    --network ${TW_PREFIX}-ext \
    --mac-address 52:54:00:c0:fe:01
```

⚠ **No `--security-group` here, deliberately — §3.5 attaches it.** The group this port wants (`tw-sg-head`) does not exist yet, and naming it now fails with `No SecurityGroup found for tw-sg-head`. Ports and groups are independent objects in Neutron, so the safe order is: create the port, create the group, then bind them. **Do not skip §3.5** — it is what turns this into a filtered port, and §4 attaches the floating IP that makes filtering matter.

In the meantime Neutron gives the port your project's `default` group (that is the behaviour noted below, and why the provisioning ports say `--no-security-group` explicitly). `default` typically permits all egress and no ingress from outside the group, so nothing is exposed by this gap — but it is also not the rule set we want, and §3.5 replaces it rather than adding to it.

Then the provisioning port — pinned IP, pinned MAC, **no filtering**:

```
devbox$ openstack port create ${TW_PREFIX}-head-prov \
    --network ${TW_PREFIX}-prov \
    --mac-address 52:54:00:be:ef:ff \
    --fixed-ip subnet=${TW_PREFIX}-prov-subnet,ip-address=${TW_HEAD_PROV_IP} \
    --disable-port-security \
    --no-security-group
```

`--no-security-group` as well as `--disable-port-security`: a port with security disabled cannot carry security groups, and some clients will otherwise attach the project's `default` group and then error.

The MACs `…:c0:fe:01` (external) and `…:be:ef:ff` (internal) are the upstream OpenCHAMI guide's own values, carried through our libvirt lab. Keeping them means the cloud-init `network-config` in §4 is byte-identical to the lab's.

**The node ports.** One per node, MAC and IP straight from the node map. Five, because rows are free and you may want to boot more later:

```
devbox$ for i in 1 2 3 4 5; do
    openstack port create ${TW_PREFIX}-node${i}-prov \
      --network ${TW_PREFIX}-prov \
      --mac-address 52:54:00:be:ef:0${i} \
      --fixed-ip subnet=${TW_PREFIX}-prov-subnet,ip-address=172.16.0.${i} \
      --disable-port-security \
      --no-security-group
  done
```

⚠ **`nodeN` is a slot number, not a node name, and it will not line up with the names in §6.** These ports are numbered `node1`–`node5` because the control-plane/worker split does not exist yet — [§6](06-node-inventory.md) is what assigns roles. When it does, `node1` becomes `tw-cp1` and `node2`–`node5` become `tw-w1`–`tw-w4`, so the numbers are **offset by one from the worker names for the rest of the tutorial**. §6's checkpoint has the mapping as a table; §7 attaches the ports correctly for you. Do not rename these now — the roles genuinely are not known yet, and a port called `tw-w1-prov` created here would be a guess pretending to be a fact.

Note that we give each node port the *same* IP that SMD will tell CoreDHCP to lease it. Strictly this is redundant — with port security off, nothing enforces the fixed IP, and the address the node actually uses comes from CoreDHCP. We set it anyway for two reasons: it reserves the address in Neutron's IPAM so nothing else can take it, and `openstack port list` then reads as a legible map of the cluster.

🔀 **Deviation — if `--mac-address` is refused.** Some deployments restrict setting a port's MAC to administrators. If `openstack port create --mac-address` returns a policy error, create the ports without it and read the MACs back out:

```
devbox$ openstack port list --network ${TW_PREFIX}-prov -c Name -c 'MAC Address' -c 'Fixed IP Addresses'
```

then use *those* MACs in §6 and §9 instead of the invented ones. The tutorial works identically; you just don't get to choose memorable addresses. This is arguably closer to real hardware anyway, where MACs are discovered rather than assigned — and the companion IaC handles either case from the same node map.

## Step 3.5 — Security groups

Two groups. The first is the only one strictly required — and §3.4's external port is waiting on it, so this step is not optional.

`${TW_ADMIN_CIDR}` comes from `tw-vars-env.sh` (§1.5). Confirm it survived the source before creating rules against it, because a wrong value here is a locked-out head node in §4:

```
devbox$ echo ${TW_ADMIN_CIDR}          # an address/mask, not <YOUR_ADMIN_CIDR>
```

```
devbox$ openstack security group create ${TW_PREFIX}-sg-head \
    --description "TechWatch OpenCHAMI head node: SSH and ICMP from admin only"

devbox$ openstack security group rule create ${TW_PREFIX}-sg-head \
    --protocol tcp --dst-port 22 --remote-ip ${TW_ADMIN_CIDR} --description SSH

devbox$ openstack security group rule create ${TW_PREFIX}-sg-head \
    --protocol icmp --remote-ip ${TW_ADMIN_CIDR} --description ping
```

⚠ **Scope SSH to a CIDR, not `0.0.0.0/0`.** `TW_ADMIN_CIDR` is the network your devbox appears from **as the head node sees it** — which is not necessarily your internet egress address. If `${TW_EXT_NET}`'s subnet is a private range you are reaching floating IPs over a VPN, and a split tunnel means `curl -s ifconfig.me` reports the wrong one; §1.5 has the test and the fix. A default-open SSH port on a cloud is found by scanners within minutes.

At Digital Labs the value is `10.11.0.0/16`, the range the F5 VPN concentrator (UoB IT Services) is understood to allocate client addresses from. **If you would rather allow only your own address**, §1.5's laptop commands give you the single dynamic address the F5 assigned to this session, and you scope these two rules to that `/32` instead — accepting that you re-issue them on every reconnect. [runbooks/update-tunnel-ip.md](runbooks/update-tunnel-ip.md) is the procedure for both.

⚠ **Know that this rule expires by itself.** It pins access to where you are *now*, so a VPN reconnect or a new DHCP lease locks you out later without anything having changed — as an SSH timeout against a healthy head node, which is easy to misread as a cluster fault. On an F5 VPN the pool address changes on **every** reconnect; we saw two in one hour.

When that happens, one command tells you whether it is the tunnel or the rule:

```
devbox$ tw_vpn
```

It probes the Keystone endpoint and the head's tcp/22 separately — both cross the same tunnel, but only the head is behind this security group, so the pair of results identifies the fault. [Appendix E](appendix-e-network-map.md) has the truth table and §17 has the add-then-delete fix. If your address is not stable, scoping this rule to the campus or VPN **range** rather than a `/32` saves that debugging session outright.

**Now bind the group to the port from §3.4**, which is still carrying the project's `default` group:

```
devbox$ openstack port set ${TW_PREFIX}-head-ext --no-security-group
devbox$ openstack port set ${TW_PREFIX}-head-ext --security-group ${TW_PREFIX}-sg-head
```

Two commands, because `port set --security-group` **appends** to the port's list rather than replacing it — attaching without the clear leaves `default` in place alongside ours. Clear first, then attach, then confirm exactly one group:

```
devbox$ openstack port show ${TW_PREFIX}-head-ext -c security_group_ids -f value
```

🛑 **A port that reaches §4 with the wrong groups is the hard-to-diagnose case.** `default` permits no inbound SSH, so the symptom is a head node you cannot reach after a boot that looked perfectly healthy — which reads exactly like a cloud-init or floating-IP fault. Check this output now, not later.

The second group exists for the cluster APIs, and **you probably do not need it**:

```
devbox$ openstack security group create ${TW_PREFIX}-sg-api \
    --description "Cluster APIs — attach only if exposing them directly"
devbox$ for p in 6443 50000 8265 8000; do
    openstack security group rule create ${TW_PREFIX}-sg-api \
      --protocol tcp --dst-port $p --remote-ip ${TW_ADMIN_CIDR}
  done
```

Those four ports come from the TechWatch design: **6443** Kubernetes API, **50000** Talos API, **8265** Ray dashboard, **8000** vLLM's OpenAI-compatible API. But all four are served by nodes *on the provisioning wire*, which has no route to the outside — so opening them on the head's external port achieves nothing on its own.

The recommended way to reach any cluster API from your devbox is an **SSH tunnel through the head node**:

```
devbox$ ssh -L 6443:172.16.0.1:6443 -L 8000:172.16.0.1:8000 rocky@<HEAD_FLOATING_IP>
```

One authenticated path, nothing extra exposed. Create `tw-sg-api` only if you later decide to publish an endpoint deliberately, and then attach it to a specific port with a specific reason.

## ✅ Checkpoint

```
devbox$ openstack network list -c Name -c Subnets
⟨captured on first run⟩

devbox$ openstack subnet show ${TW_PREFIX}-prov-subnet \
          -c enable_dhcp -c gateway_ip -c allocation_pools -c cidr -f json
{
  "cidr": "172.16.0.0/24",
  "enable_dhcp": false,
  "gateway_ip": null,
  "allocation_pools": [
    {"start": "172.16.0.1", "end": "172.16.0.199"},
    {"start": "172.16.0.254", "end": "172.16.0.254"}
  ]
}
```

`"enable_dhcp": false` and `"gateway_ip": null` are the two values that matter. If either is wrong, fix it now — both are much harder to diagnose in §10.

```
devbox$ openstack port list --network ${TW_PREFIX}-prov \
          -c Name -c 'MAC Address' -c 'Fixed IP Addresses'
⟨captured on first run — expect our 6: head-prov at .254, node1-5 at .1-.5⟩

devbox$ openstack port list --network ${TW_PREFIX}-prov -c ID -f value | while read -r id; do
    eval "$(openstack port show $id -f shell \
              -c name -c mac_address -c device_owner -c port_security_enabled)"
    printf '%-16s %-18s %-22s security=%s\n' \
      "${name:-<unnamed>}" "$mac_address" "${device_owner:-<none>}" "$port_security_enabled"
  done
```

`-f shell` emits `key="value"` lines, so one `port show` per port fills all four variables at once — a name-and-value loop calling `port show` four times per port makes four API calls where one will do.

**Iterate over IDs, not names.** Neutron creates unnamed ports of its own on this network (see below), and a name-driven loop either skips them or shifts its fields — which is exactly the port you most want to see.

Every port **we** created on `tw-prov` must report `security=False`. Any `True` is a node that will fail to boot, or a head node that cannot serve DHCP.

⚠ **A seventh, unnamed port with a `fa:16:3e:…` MAC is normal on OVN deployments** — that OUI is Neutron's own, so the port is infrastructure, not yours. `device_owner` tells you which kind, and the distinction matters:

| `device_owner` | What it is | Action |
|---|---|---|
| `network:distributed`, `network:metadata` | OVN's per-network metadata port | Leave it. `port_security_enabled: True` on it is normal and not something to change — it is not a node, and the `False` rule above does not apply to it |
| `network:dhcp` | a DHCP agent port | 🛑 **Stop.** This means `enable_dhcp` is `true` despite the check above, and §10 will fail confusingly. Fix the subnet |
| empty | an orphaned port | Yours; check `device_id` is empty, then delete it |

The `enable_dhcp: false` check is what distinguishes the benign case from the fatal one, which is why it comes first in this checkpoint.

And the one port that must have filtering *on*, with our group and only our group:

```
devbox$ openstack port show ${TW_PREFIX}-head-ext \
          -c port_security_enabled -c security_group_ids -f json
```

Expect `port_security_enabled: true` and a single ID — the one `openstack security group show ${TW_PREFIX}-sg-head -c id -f value` prints. Two IDs means §3.5's `--no-security-group` was skipped and `default` is still attached; zero means the attach never happened and §4's floating IP will be unreachable.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `Invalid input for operation: Requested subnet with cidr … overlaps` | another network in the project already uses `172.16.0.0/24` — check `openstack subnet list` and pick another range, then update `TW_PROV_CIDR` **and** every OpenCHAMI config in §5 |
| `IP address 172.16.0.254 is not a valid IP for the specified subnet` | the allocation pools don't include `.254` — see the ⚠ note in §3.2 |
| `Unable to create the port … policy` on `--mac-address` | MAC setting is admin-only here; use the 🔀 fallback in §3.4 |
| `Security group … cannot be applied to port with port security disabled` | drop `--security-group`, add `--no-security-group` |
| `No SecurityGroup found for tw-sg-head` | you are running an older copy of §3.4 that named the group on `port create`. The group is created in §3.5 — create the port without `--security-group` and let §3.5 attach it |
| `bash: YOUR_ADMIN_CIDR: No such file or directory` | you pasted a literal `<YOUR_ADMIN_CIDR>`; bash read the `<` as an input redirection. Fill `TW_ADMIN_CIDR` in `tw-vars-env.sh` (§1.5), re-source, and use `${TW_ADMIN_CIDR}` |
| `No Network found for <EXT_NET>` | `TW_EXT_NET` is still the template placeholder — §1.5 writes it back; then `source ~/tw/tw-env.sh` |
| `router set --external-gateway` fails with `not found` | `${TW_EXT_NET}` is wrong or not shared with your project — re-run §1.5's `openstack network list --external` |
| An extra unnamed port on `tw-prov`, MAC starting `fa:16:3e` | Neutron's own OUI — infrastructure, usually OVN's metadata port. Check `device_owner` against the table in the checkpoint. Benign unless it is `network:dhcp` |
| The port-security loop prints blanks or misaligned fields | you are running a name-driven loop over a network containing an unnamed port — iterate `-c ID` instead, as the checkpoint now does |
| Later: nodes never get an IP (§10) | almost always this section — either `enable_dhcp` is `true` on `tw-prov-subnet`, or a port still has `port_security_enabled: True` |

Next: [§4 — The head node instance](04-head-node-instance.md)
