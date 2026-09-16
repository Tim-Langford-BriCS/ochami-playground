# §3 — The two networks

*(Upstream: guide §"External VM network" / §"Internal VM network". Time:
~5 minutes.)*

> **Before you define anything, confirm you're on the system daemon:**
> `virsh uri` must print `qemu:///system`. If it prints `qemu:///session`,
> `LIBVIRT_DEFAULT_URI` isn't set in this shell (§2.2) — every `net-define`
> below would land in your private, unprivileged daemon and `net-start`
> would fail with `error creating bridge interface …: Operation not
> permitted`. Fix it with `export LIBVIRT_DEFAULT_URI=qemu:///system` first.

## Concepts

Our cluster needs two very different networks, and understanding *why*
there are two teaches most of what matters about provisioning networks:

**The external network** exists for us humans: it NATs traffic out to the
internet (so the head node can download packages) and gives us an SSH path
from the host to the head node. libvirt implements it as a Linux bridge
(`br-ochami-ext`) plus NAT rules; the host owns gateway address
192.168.200.1 on it.

**The internal network** is the *provisioning wire*. It is deliberately
**isolated**: no NAT, no forwarding, and — critically — **no libvirt DHCP
or DNS**. When a compute node PXE-boots on this wire, the *only* DHCP
server answering must be OpenCHAMI's CoreDHCP on the head node, because the
DHCP answer is what steers the node into the boot chain. Two DHCP servers
on one broadcast domain is a classic provisioning failure ("who answered
first?"), which is why the upstream guide's XML for this network has no
`<ip>` element at all — an `<ip>` is what makes libvirt spawn its dnsmasq.

🔀 **Deviation — subnet.** The guide uses `192.168.122.0/24` for the
external network, but that is the subnet of libvirt's *default* network
(`virbr0`), which exists on every stock libvirt install — defining a second
network on the same range fails or blackholes traffic. The main tutorial
already moved to `192.168.200.0/24`; we follow it.

🔀 **Deviation — no DHCP on the external net either.** The guide pins the
head's external address with a libvirt DHCP static-host entry
(`<host mac=… ip=…/>`). We give the head a static IP via cloud-init in §4
instead — one mechanism fewer on the wire, same result. DNS from libvirt's
dnsmasq (at 192.168.200.1) stays on, so the head can resolve names.

## Step 3.1 — Define the external network

```
host$ mkdir -p ~/cluster && cd ~/cluster

host$ cat > openchami-net-external.xml << 'EOF'
<network>
  <name>openchami-net-external</name>
  <bridge name="br-ochami-ext"/>
  <forward mode="nat"/>
  <ip address="192.168.200.1" netmask="255.255.255.0">
  </ip>
</network>
EOF

host$ virsh net-define openchami-net-external.xml
host$ virsh net-start openchami-net-external
host$ virsh net-autostart openchami-net-external
```

Line by line: `<bridge>` names the Linux bridge libvirt creates;
`<forward mode="nat">` masquerades outbound traffic through the host;
the `<ip>` gives the *host* .1 on the bridge (and, as a side effect, makes
libvirt run dnsmasq there for DNS — but with no `<dhcp>` block, no
addresses are handed out). `net-define` loads the XML persistently,
`net-start` creates the bridge now, `net-autostart` recreates it on host
reboots.

## Step 3.2 — Define the internal (provisioning) network

```
host$ cat > openchami-net-internal.xml << 'EOF'
<network>
  <name>openchami-net-internal</name>
  <bridge name="br-ochami-int"/>
</network>
EOF

host$ virsh net-define openchami-net-internal.xml
host$ virsh net-start openchami-net-internal
host$ virsh net-autostart openchami-net-internal
```

That's the whole file — and the brevity is the lesson. No `<forward>` means
isolated (VMs on this bridge can reach each other and nothing else); no
`<ip>` means the host claims no address here and libvirt runs **no dnsmasq**
— the wire is silent until the head node's CoreDHCP speaks on it (§5).

## ✅ Checkpoint

```
host$ virsh net-list --all
 Name                     State    Autostart   Persistent
-----------------------------------------------------------
 default                  active   yes         yes
 openchami-net-external   active   yes         yes
 openchami-net-internal   active   yes         yes

host$ ip -br addr | grep br-ochami
br-ochami-ext    DOWN           192.168.200.1/24
br-ochami-int    DOWN
```

`DOWN` is normal — bridges report DOWN until a VM interface plugs into
them. Note `br-ochami-int` has **no address**: exactly as designed.

## Common failures

| Symptom | Cause / fix |
|---|---|
| `net-start` fails: bridge exists / address in use | subnet collision — check `virsh net-list --all` and `ip route`; this is why we avoid 192.168.122.0/24 |
| compute nodes later get "wrong" DHCP answers | something else is serving DHCP on the internal wire — confirm the internal XML really has no `<ip>` block |

Next: [§4 — The head node VM](04-head-node-vm.md)
