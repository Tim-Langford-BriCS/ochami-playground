# §6 — Telling OpenCHAMI about our nodes

*(Upstream: guide §3.1 / tutorial Part 2.2. Time: ~5 minutes. On the head
node; you'll need a fresh token — §5.12.)*

## Concepts

**SMD is the inventory.** Everything downstream — DHCP leases, DNS names,
boot scripts, cloud-init payloads — is generated from what SMD knows. So
"adding a node to the cluster" simply means "putting a record in SMD".

**xnames** are HPC's hierarchical component names, inherited from Cray:
`x1000c0s0b0n0` reads as cabinet 1000, chassis 0, slot 0, BMC 0, node 0.
Even a virtual node needs one — it's the primary key everything else hangs
off.

**Static vs dynamic discovery.** On real hardware, `magellan` scans the
management network and asks each BMC (via the Redfish protocol) what it
is — *dynamic* discovery. Our VMs have no BMCs, so we do *static*
discovery: hand SMD a YAML file describing the nodes we intend to create.
Deterministic, reviewable, version-controllable — and exactly what an
OpenStack-hosted deployment (no Redfish there either) would do.

We register **five** nodes even though we'll only boot one: rows in a
database are free, and you can boot compute2–5 later without touching this
section again. The MACs are ours to invent — we'll assign them to VMs in
§10 — and the BMC entries are placeholders with made-up MACs/IPs that
satisfy the schema.

🔀 **Deviation — file format.** The guide shows the pre-v0.6.0 flat format
(`bmc_mac:`/`bmc_ip:` inline on each node). Current `ochami` expects
separate `bmcs:` and `nodes:` lists. Same data, new shape; the guide's
version will be rejected.

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
- name: compute1
  nid: 1
  xname: x1000c0s0b0n0
  bmc: x1000c0s0b0
  groups:
  - compute
  interfaces:
  - mac_addr: 52:54:00:be:ef:01
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.1
- name: compute2
  nid: 2
  xname: x1000c0s0b1n0
  bmc: x1000c0s0b1
  groups:
  - compute
  interfaces:
  - mac_addr: 52:54:00:be:ef:02
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.2
- name: compute3
  nid: 3
  xname: x1000c0s0b2n0
  bmc: x1000c0s0b2
  groups:
  - compute
  interfaces:
  - mac_addr: 52:54:00:be:ef:03
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.3
- name: compute4
  nid: 4
  xname: x1000c0s0b3n0
  bmc: x1000c0s0b3
  groups:
  - compute
  interfaces:
  - mac_addr: 52:54:00:be:ef:04
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.4
- name: compute5
  nid: 5
  xname: x1000c0s0b4n0
  bmc: x1000c0s0b4
  groups:
  - compute
  interfaces:
  - mac_addr: 52:54:00:be:ef:05
    ip_addrs:
    - name: management
      ip_addr: 172.16.0.5
EOF
```

Per node: a human `name`, a numeric `nid` (node ID — drives default
hostnames, §9), the `xname`, a reference to its (placeholder) BMC, group
membership `compute` (cloud-init keys config off groups, §9), and its
management interface: **MAC → IP**. That last pair is the contract with
§10 — the VM we create with MAC `52:54:00:be:ef:01` *will* receive
172.16.0.1 from CoreDHCP, because CoreDHCP asks SMD.

## Step 6.2 — Load it into SMD

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
head$ ochami discover static -f yaml -d @/etc/openchami/data/nodes.yaml
```

No output = success ("discover" here just means "populate SMD as if these
had been discovered").

⚠ **Gotcha — not idempotent.** Running `discover static` twice errors with
`409 Conflict` ("same FQDN or xname ID"). It's an *add*, not an *upsert*.
Harmless if it happens; to truly start over you'd delete the components
first (`ochami smd component delete ...`).

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

Within ~30 s (one cache refresh), CoreDHCP and CoreDNS also know: watch
`journalctl -u coresmd-coredhcp | tail` for
`Cache updated with 10 EthernetInterfaces and 10 Components` (10 = 5 nodes
+ 5 BMCs).

Next: [§7 — Building the compute node image](07-image-building.md)
