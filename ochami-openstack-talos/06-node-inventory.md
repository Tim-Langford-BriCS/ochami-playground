# §6 — Telling OpenCHAMI about our nodes

*(Upstream: tutorial Part 2.2. Time: ~5 minutes. On the head node; you need a fresh token — §5.13.)*

## Concepts

**SMD is the inventory.** Everything downstream — DHCP leases, DNS names, boot scripts, cloud-init payloads — is generated from what SMD knows. So "adding a node to the cluster" simply means "putting a record in SMD".

**xnames** are HPC's hierarchical component names, inherited from Cray: `x1000c0s0b0n0` reads as cabinet 1000, chassis 0, slot 0, BMC 0, node 0. Even a virtual node needs one — it is the primary key everything else hangs off. When the PTR nodes are racked, their xnames will describe where they physically are, and this is the habit that makes that useful.

⚠ **The xnames in this tutorial are invented, and the PTR's scheme is not ours to pick.** `x1000c0s0` is a plausible-looking Cray shape chosen so the *format* is right; it encodes nothing true about any real cabinet. What the PTR actually uses depends on how the environment is built and by whom — see [DL-004](DECISION-LOG.md#dl-004--how-smd-gets-populated-on-the-ptr-and-under-whose-naming-scheme). Treat the xname as *a stable identifier of the correct shape*, not as an address to memorise.

**Static vs dynamic discovery.** On real hardware, `magellan` scans the management network and asks each BMC over Redfish what it is — *dynamic* discovery. Our Nova instances have no BMCs, so we do *static* discovery: hand SMD a YAML file describing the nodes we intend to create. Deterministic, reviewable, version-controllable.

🔀 **Deviation — and the one that matters most for the PTR.** This is the biggest single difference between this POC and the real system. On a **standard** OpenCHAMI cluster you run Magellan against real BMCs and SMD is populated *from the hardware itself*, which brings concerns this section never touches: BMC credential management, the management network reaching every BMC, and Redfish power control. That is the model everything below is measured against, and it is the one to understand — it is how OpenCHAMI is designed to be used and how most deployments you read about work. [Appendix A](appendix-a-redfish-sushy.md) closes most of the gap by giving our instances emulated BMCs with sushy-tools — do it once §10 works, because it converts this hand-written file into a real discovery.

📌 **Open question — but the PTR may well do it *this* way instead, statically.** As of **4 Aug 2026** the working expectation is that the PTR will **not** use Redfish discovery, and that SMD will be populated from statically configured metadata — that is, from a hand-maintained or generated file, much as this section does. If that holds, this "deviation" is closer to the real thing than the standard model is, and appendix A becomes an exercise in understanding rather than a rehearsal. **It is not settled**, which is why both paths stay documented: the static one here, the Redfish one in appendix A. [DL-004](DECISION-LOG.md#dl-004--how-smd-gets-populated-on-the-ptr-and-under-whose-naming-scheme) records what we know, what we don't, and what would settle it.

### The three-way contract

This file is one of **three** places the same MAC/IP/xname values appear:

![One MAC address copied into three files: the node map in tw-vars-env.sh decides each node's name, xname, NID, MAC, IP, role and Neutron port name; the Neutron port of §3.4 pins the MAC and belongs to OpenStack; the SMD inventory of §6.1 maps that MAC to an IP and an xname for CoreDHCP and CoreDNS; the BSS payload of §9.1 maps the same MAC to a kernel, initrd and command line for iPXE. The port names are offset by one from the node names, so the MAC is the only value that reliably connects the three. Neutron and OpenCHAMI cannot see each other's copy, so a mismatch is never reported — a MAC missing from SMD gives a silent bootloop, and a MAC in the wrong BSS payload boots the node as the wrong role.](diagrams/06-three-way-contract.svg)

If they disagree, the failure is silent and confusing: a node gets a bootloop lease instead of its address (MAC missing from SMD), or boots the wrong role (MAC in the wrong BSS payload). Check them against each other now, and again in §9.

<details>
<summary>The same thing in one line each, if you prefer it text-only</summary>

```
                        ┌──── §3.4  Neutron ports   ← MAC is pinned here (Neutron)
                        │
   node map ────────────┼──── §6.1  SMD inventory   ← MAC → IP → xname → group (SMD)
   (tw-vars-env.sh)          │
                        └──── §9.1  BSS payloads    ← MAC → boot script, i.e. role (BSS)
```

</details>

> This hand-synchronisation is the entire reason the companion IaC exists. [`../ochami-openstack-talos-iac/`](../ochami-openstack-talos-iac/) generates all three from a single `nodes.yaml`, which makes disagreement impossible rather than merely unlikely.

We register **five** nodes even though we may only boot two or three: rows in a database are free, and you can bring up more later without touching this section again. The BMC entries are placeholders with invented MACs and IPs that satisfy the schema — until appendix A makes them real.

🔀 **Deviation — file format.** The upstream *guide* shows the pre-v0.6.0 flat format (`bmc_mac:`/`bmc_ip:` inline on each node). Current `ochami` expects separate `bmcs:` and `nodes:` lists. Same data, new shape; the guide's version is rejected outright.

## Step 6.1 — Write the inventory

```
head$ sudo mkdir -p /etc/openchami/data
head$ sudo tee /etc/openchami/data/nodes.yaml > /dev/null << 'EOF'
bmcs:
- xname: x1000c0s0b0
  mac: de:ca:fc:0f:fe:e1
  ip: 172.16.0.101
- xname: x1000c0s0b1
  mac: de:ca:fc:0f:fe:e2
  ip: 172.16.0.102
- xname: x1000c0s0b2
  mac: de:ca:fc:0f:fe:e3
  ip: 172.16.0.103
- xname: x1000c0s0b3
  mac: de:ca:fc:0f:fe:e4
  ip: 172.16.0.104
- xname: x1000c0s0b4
  mac: de:ca:fc:0f:fe:e5
  ip: 172.16.0.105

nodes:
- name: tw-cp1
  nid: 1
  xname: x1000c0s0b0n0
  bmc: x1000c0s0b0
  groups:
  - compute
  - talos-controlplane
  interfaces:
  - mac_addr: 52:54:00:be:ef:01
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.1
- name: tw-w1
  nid: 2
  xname: x1000c0s0b1n0
  bmc: x1000c0s0b1
  groups:
  - compute
  - talos-worker
  interfaces:
  - mac_addr: 52:54:00:be:ef:02
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.2
- name: tw-w2
  nid: 3
  xname: x1000c0s0b2n0
  bmc: x1000c0s0b2
  groups:
  - compute
  - talos-worker
  interfaces:
  - mac_addr: 52:54:00:be:ef:03
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.3
- name: tw-w3
  nid: 4
  xname: x1000c0s0b3n0
  bmc: x1000c0s0b3
  groups:
  - compute
  - talos-worker
  interfaces:
  - mac_addr: 52:54:00:be:ef:04
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.4
- name: tw-w4
  nid: 5
  xname: x1000c0s0b4n0
  bmc: x1000c0s0b4
  groups:
  - compute
  - talos-worker
  interfaces:
  - mac_addr: 52:54:00:be:ef:05
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.5
EOF
```

Per node: a human `name` (matching the Nova instance name we'll use in §7), a numeric `nid` (node ID), the `xname`, a reference to its placeholder BMC, group membership, and its management interface as **MAC → IP**. That last pair is the contract with §3.4: the instance holding the port with MAC `52:54:00:be:ef:01` *will* receive `172.16.0.1` from CoreDHCP, because CoreDHCP asks SMD.

🔀 **Deviation from the libvirt lab — two groups per node.** The lab put every node in `compute`. We add `talos-controlplane` / `talos-worker` because the role split is real here: one node runs the Kubernetes control plane and the rest are workers. Groups are how you address sets of nodes in later `ochami` commands, and §9 keys the boot payloads off the same distinction.

⚠ **If §3.4 refused `--mac-address`** and Neutron assigned its own MACs, use *those* values here instead. Read them back with:

```
devbox$ openstack port list --network ${TW_PREFIX}-prov \
          -c Name -c 'MAC Address' -c 'Fixed IP Addresses' -f value
```

There is a copy of this file at [`templates/nodes.yaml`](templates/nodes.yaml).

## Step 6.2 — Load it into SMD

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
head$ ochami discover static -f yaml -d @/etc/openchami/data/nodes.yaml
```

No output means success. ("Discover" here just means "populate SMD as if these had been discovered".)

⚠ **Gotcha — not idempotent.** Running `discover static` twice errors with `409 Conflict` ("same FQDN or xname ID"). It is an *add*, not an *upsert*. Harmless if it happens; to genuinely start over you must delete the components first (`ochami smd component delete …`).

## ✅ Checkpoint

```
head$ ochami smd component get | jq '[.Components[] | select(.Type == "Node")] | length'
5

head$ ochami smd component get | jq '.Components[] | select(.ID == "x1000c0s0b0n0")'
{
  "Enabled": true,
  "ID": "x1000c0s0b0n0",
  "NID": 1,
  "Role": "Compute",
  "State": "On",
  "Type": "Node"
}
```

Within ~30 seconds — one cache refresh — CoreDHCP and CoreDNS also know. The refresh runs every 30 s regardless, so what you are looking for is the **transition**, not the last line:

```
head$ journalctl -u coresmd-coredhcp | tail -6
Aug 04 09:38:00 tw-head coresmd-coredhcp[28420]: … msg="initiating cache refresh" prefix="plugins/coresmd"
Aug 04 09:38:00 tw-head coresmd-coredhcp[28420]: … msg="Cache updated with 0 EthernetInterfaces and 0 Components" prefix="plugins/coresmd"
Aug 04 09:38:30 tw-head coresmd-coredhcp[28420]: … msg="initiating cache refresh" prefix="plugins/coresmd"
Aug 04 09:38:30 tw-head coresmd-coredhcp[28420]: … msg="Cache updated with 10 EthernetInterfaces and 10 Components" prefix="plugins/coresmd"
```

Ten of each = 5 nodes + 5 BMCs. **If this line does not appear**, CoreDHCP is not talking to SMD and no node will ever boot — see §5.10's certificate gotcha before going on.

💡 **`0 EthernetInterfaces and 0 Components` before the discover is correct, not a fault.** CoreDHCP polls SMD every 30 seconds from the moment §5 started it, so if you look at this log at any point before step 6.2 you will see a wall of zeroes stretching back to install time. That is the service working. The line that matters is the first non-zero one, and its timestamp should be within 30 seconds of your `discover static`.

And verify the three-way contract by eye, right now:

```
devbox$ openstack port list --network ${TW_PREFIX}-prov -c Name -c 'MAC Address' -f value | sort
 fa:16:3e:53:00:d2
tw-head-prov 52:54:00:be:ef:ff
tw-node1-prov 52:54:00:be:ef:01
tw-node2-prov 52:54:00:be:ef:02
tw-node3-prov 52:54:00:be:ef:03
tw-node4-prov 52:54:00:be:ef:04
tw-node5-prov 52:54:00:be:ef:05

head$   ochami smd component get | jq -r '.Components[] | select(.Type=="Node") | .ID'
x1000c0s0b0n0
x1000c0s0b1n0
x1000c0s0b2n0
x1000c0s0b3n0
x1000c0s0b4n0
```

**Five node ports with `52:54:00:be:ef:0…` MACs, and five node components.** The other two lines in the port list are expected and neither is a node: `tw-head-prov` is the head's own second NIC from §4 (MAC `…:ff`, deliberately outside the node range), and the unnamed `fa:16:3e:…` port is Neutron's own infrastructure — see §3's [checkpoint table](03-networks-and-ports.md) for how to confirm it is *not* a `network:dhcp` port, which is the one case that is fatal. §9 adds the third column.

⚠ **The port names and the node names do not correspond, and they are offset by one.** This is the single most confusing thing in this section, so read the mapping rather than inferring it:

| MAC | Neutron port (§3.4) | SMD / Nova name (§6.1, §7) | IP |
|---|---|---|---|
| `52:54:00:be:ef:01` | `tw-node1-prov` | **`tw-cp1`** | 172.16.0.1 |
| `52:54:00:be:ef:02` | `tw-node2-prov` | **`tw-w1`** | 172.16.0.2 |
| `52:54:00:be:ef:03` | `tw-node3-prov` | **`tw-w2`** | 172.16.0.3 |
| `52:54:00:be:ef:04` | `tw-node4-prov` | **`tw-w3`** | 172.16.0.4 |
| `52:54:00:be:ef:05` | `tw-node5-prov` | **`tw-w4`** | 172.16.0.5 |

§3.4 numbers the ports `node1`–`node5` because at that point the role split does not exist yet; §6 assigns roles, and the control-plane node consumes `node1`. So **`tw-node2-prov` is the port for `tw-w1`, not for `tw-w2`**, and `tw-w4` uses `tw-node5-prov`. §7's commands already account for this (`--port ${TW_PREFIX}-node${i}-prov` with `w$((i-1))`) — the risk is doing it by hand and matching the numbers that look like they match.

🔀 **Why this is worth a table rather than a rename.** Attaching the wrong port is a *silent* fault of the nastiest kind: the node still boots, because SMD keys on MAC and the MAC is in the right BSS payload, so it gets a valid IP and the correct role. What shifts is its **identity** — SMD, DNS and the eventual Kubernetes node name will all call it by the name belonging to the MAC it actually has, which will not be the Nova instance name you typed. Everything works and nothing agrees. Renaming the ports to `tw-cp1-prov`/`tw-w1-prov` would remove the trap entirely and is the right fix for the [companion IaC](../ochami-openstack-talos-iac/); it is not done here because §3 runs before roles exist, and rewriting §3.4 to know about roles would put the cart before the horse.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `500 Internal Server Error` | SMD started before the OIDC signing keys existed — `sudo systemctl restart smd` (§5.10) |
| `401 Unauthorized` | token expired: re-run the `gen_access_token` export |
| `409 Conflict` | already loaded; see the idempotency gotcha |
| `unable to read data from file: open … no such file or directory` | mistyped path, and `ochami` echoes back exactly what it tried to open — compare it character by character with the `tee` above. `nodes.yam` for `nodes.yaml` is the usual one, because the path is long and you type it twice |
| `Cache updated with 0 …` in the coresmd log | SMD is reachable but empty — the discover didn't land. Re-check the checkpoint above |
| YAML rejected with a schema error | you used the old flat `bmc_mac:` format from the upstream guide — use the `bmcs:`/`nodes:` shape above |

Next: [§7 — Node instances and the iPXE problem](07-node-instances-and-ipxe.md)
