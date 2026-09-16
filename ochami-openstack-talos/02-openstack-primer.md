# §2 — An OpenStack primer for libvirt people

*(Reading plus a few read-only commands. ~20 minutes. If you already know OpenStack, skim the two tables and the "five things that will surprise you" list, then move on.)*

## Concepts

OpenStack is not one program. It is a family of services, each owning one kind of resource, each with its own API and its own subcommand of the `openstack` CLI. You only need five of them for this tutorial.

| Service | Owns | libvirt equivalent | CLI |
|---|---|---|---|
| **Keystone** | identity: users, projects, roles, tokens | the `libvirt` group + polkit | `openstack token`, `… application credential` |
| **Nova** | compute: instances, flavors, power state, rescue | `virsh` + `virt-install` | `openstack server`, `… flavor` |
| **Neutron** | networking: networks, subnets, ports, routers, security groups | `virsh net-define` + the bridges it makes | `openstack network`, `… subnet`, `… port`, `… router`, `… security group` |
| **Glance** | images: the bootable disk templates | that `.qcow2` you `wget`-ed | `openstack image` |
| **Cinder** | block storage: volumes you can attach and detach | `qemu-img create` + `--disk path=…` | `openstack volume` |

The whole of §§3–4 and §7 is just those five, in that order.

## The mental translation

If you did the [libvirt lab](../ochami-macos-libvirt/), you already know every concept below; only the nouns change.

| You did this in libvirt | Here you do this |
|---|---|
| `virsh net-define` an XML file with `<forward mode='nat'/>` and `<ip>` | `openstack network create` + `openstack subnet create` + `openstack router create` |
| `virsh net-define` an XML file with *no* `<ip>` (isolated, no DHCP) | `openstack subnet create --no-dhcp --gateway none`, with no router attached |
| `wget` a Rocky cloud image to `~/cluster/` | `openstack image list` — it's already there, uploaded by someone else |
| `qemu-img create -b base.qcow2 head.qcow2 40G` (copy-on-write overlay) | nothing: Nova makes the overlay for you when you `server create --image` |
| `--network network=…,mac=52:54:00:be:ef:01` | `openstack port create --mac-address 52:54:00:be:ef:01` then `server create --port` |
| `genisoimage -volid cidata` to make a seed ISO | `server create --user-data` / `--config-drive` — Nova is the cloud-init datasource |
| `--boot uefi,hd,network` | *nothing equivalent exists.* This is §0's decision 2 and §7's whole problem |
| `virsh start` / `virsh destroy` | `openstack server start` / `openstack server stop` |
| `virsh console head` | `openstack console log show` (read-only) or `openstack console url show` (interactive) |
| `setfacl -m u:qemu:x "$HOME"` so QEMU can read your files | nothing: you never touch the hypervisor's filesystem |
| `export LIBVIRT_DEFAULT_URI=qemu:///system` | `export OS_CLOUD=techwatch` |

That last line is the deepest one, and [`../ochami-macos-libvirt/appendix-c-access-models.md`](../ochami-macos-libvirt/appendix-c-access-models.md) is worth re-reading if you skipped it: the libvirt lab deliberately drove everything as an unprivileged user with an environment variable naming the endpoint, precisely because that is the habit OpenStack requires. There is no `sudo` for creating a VM on a cloud; there is only an authenticated client with a scoped identity. You have been rehearsing for this.

## Networks, subnets and ports — the one model worth understanding properly

Neutron splits into three nouns where libvirt has one, and §3 depends on the split:

- A **network** is a layer-2 broadcast domain. That's all. It has no addresses. Think "a virtual switch" — or in libvirt terms, the bridge without the `<ip>` element.
- A **subnet** attaches layer-3 to a network: a CIDR, an optional gateway, and **optionally a DHCP server**. This is where `--no-dhcp` lives, and it is the single most important flag in this tutorial. One network can carry several subnets.
- A **port** is a virtual NIC. It belongs to a network, holds a MAC address and one or more fixed IPs, and gets plugged into an instance. Crucially, **a port can exist before any instance uses it** — which is how we pin MAC addresses.

```
  network  "tw-prov"                     ← layer 2: a wire, no addresses
     │
     ├── subnet 172.16.0.0/24            ← layer 3: CIDR, --no-dhcp, no gateway
     │
     ├── port  mac=…:be:ef:ff ip=.254    ← the head's second NIC
     ├── port  mac=…:be:ef:01 ip=(none)  ← tw-cp1's NIC; CoreDHCP will address it
     └── port  mac=…:be:ef:02 ip=(none)  ← tw-w1's NIC
```

Compare with the libvirt lab, where the internal network's whole definition was four lines of XML and the MACs were arguments to `virt-install`. Same result; Neutron just makes you name the parts.

## Five things that will surprise you

**1. Ports have security policy, and it will silently break your DHCP server.** Every Neutron port, by default, gets *anti-spoofing* rules: it may only send traffic from its own MAC and its own assigned IPs, and it **may not act as a DHCP server**. That last rule exists because a rogue tenant DHCP server on a shared network is a classic attack. It is also exactly what we need CoreDHCP to be. §3.3 deals with this, and if you skip it, §10 fails with nodes that never get an address and no error message anywhere. This is the number one gotcha in the whole tutorial.

**2. There is no "boot from network".** Covered in §0; solved in §7.

**3. Flavors are cloud-wide and you cannot create one.** In libvirt you wrote `--memory 4096 --vcpus 2 --disk size=40`. Here you pick from a fixed menu that an administrator defined. Sometimes nothing on the menu fits, and §4.2 shows the workaround (attach a Cinder volume instead of relying on the root disk).

**4. Deleting an instance usually deletes its disk.** `openstack server create --image` gives the instance an *ephemeral* root disk that dies with it. That's fine for us — Talos reinstalls in minutes — but it means "stop and think" is worth doing before `server delete`, and it's why §7 discusses volume-backed instances even though we can't use them.

**5. Everything is asynchronous.** `openstack server create` returns immediately with `status: BUILD`. `openstack server reboot --hard` returns before the instance has rebooted. Commands that look like they failed have often just not finished. Every step below that needs it includes an explicit wait, and `openstack server show -c status` is your friend.

## Step 2.1 — Look around, read-only

You did most of this in §1.5. Two more, to build intuition:

```
devbox$ openstack --help | head -40
devbox$ openstack server list --long
```

And the single most useful debugging habit on OpenStack — ask for the raw record, not the pretty table:

```
devbox$ openstack image show $TW_HEAD_IMAGE -f json | jq .
```

`-f json` works on every `show` and `list`. When a property matters (like `hw_firmware_type` in §1.5, or `port_security_enabled` in §3) the table view often truncates or omits it; JSON never does.

## Step 2.2 — Learn where the errors hide

Three places, in the order you should check them:

```
devbox$ openstack server show <name> -c fault -f json     # why an instance failed
devbox$ openstack console log show <name> --lines 100     # what the guest printed
devbox$ openstack server event list <name>                # what was requested, and when
```

`openstack server event list` is underused and excellent: it shows every action (create, reboot, rebuild, stop) with a timestamp and result. In §10 you will be hard-rebooting nodes and wondering whether the request took effect — this is how you find out.

✅ **Checkpoint** — you can read a machine-readable image record and you know the three error commands:

```
devbox$ openstack image show $TW_HEAD_IMAGE -f json | jq -r '.name, .disk_format'
⟨captured on first run⟩
```

## What we are deliberately not using

Named here so you know they were considered, not overlooked. The full argument is in [appendix C](appendix-c-alternatives.md).

| Service | Why not |
|---|---|
| **Ironic** (bare metal) | It *is* a provisioning system with its own PXE stack; we're testing OpenCHAMI instead. Also not exposed to us as a tenant |
| **Heat** (orchestration) | OpenStack-native templating, but the team is standardising on OpenTofu, which is portable and already in use elsewhere |
| **Magnum** (Kubernetes as a service) | Would hand us a cluster and skip the entire point — we want *OpenCHAMI* to build the cluster |
| **Octavia** (load balancers) | Kubernetes' own Gateway API handles ingress inside the cluster (§13); an OpenStack LB would sit outside it |
| **Manila / shared filesystems** | Nothing in this POC needs a shared POSIX filesystem yet. Model weights come from a registry or an emptyDir cache (§14) |
| **Nova `server rebuild`** | Not avoided — §10.7 uses it to re-provision a node, because destroying the disk in place is precisely what putting iPXE back means. Never point it at the head node |

Next: [§3 — Networks, subnets and MAC-pinned ports](03-networks-and-ports.md)
