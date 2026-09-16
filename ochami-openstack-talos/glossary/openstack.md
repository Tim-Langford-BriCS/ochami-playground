# OpenStack glossary

**The cloud below.** Almost nothing here is installed by us — these are services the Digital Labs operators run, and our side of the relationship is asking politely with the `openstack` CLI. Entries therefore say **who runs it** and **how we reach it** rather than how to install it. Where something *is* ours, it says so explicitly.

📌 **"The cloud operator" below means [StackHPC](https://www.stackhpc.com/)**, working with UoB/BriCS staff. They operate the OpenStack deployment — control plane, hypervisors, networking, storage — and the same estate also carries **BC5** and **Ceph disk arrays** among other systems, so its constraints are set by services considerably more important than this prototype. TechWatch adds hardware to this cloud rather than getting one of its own. [§1](../01-safety-and-access.md) has the full picture and why it matters.

Covers everything met through §5. See the [schema note](README.md#the-schema-and-why-the-two-files-differ) for why this file is shaped differently from [OpenCHAMI](openchami.md).

---

## The services

### Keystone — identity
**What** the authentication and service-catalogue service. Every other API call starts by getting a token from it.
**Used for** proving who we are, and discovering the endpoint URLs of everything else.
**Who runs it** the cloud operator.
**How we reach it** implicitly, on every command. Directly via `openstack token issue`, and it is the thing that fails when the VPN is down — which is why the error looks like *authentication* failure rather than a network error.
**Configured (our side)** `~/.config/openstack/clouds.yaml` on the devbox, selected by `OS_CLOUD`.
**First met** [§1.4](../01-safety-and-access.md)

### Nova — compute
**What** the service that creates and manages instances (virtual machines).
**Used for** the head node in §4 and the three Talos nodes in §7.
**How we reach it** `openstack server create|list|show|delete`, `openstack console log show`.
**Note** Nova also *generates the network metadata* cloud-init reads, which is how the head gets its static `172.16.0.254` without us telling cloud-init anything — see [§4](../04-head-node-instance.md).
**First met** [§4](../04-head-node-instance.md)

### Neutron — networking
**What** networks, subnets, ports, routers, floating IPs, security groups.
**Used for** everything in §3. Both of our networks and all four instance ports.
**How we reach it** `openstack network|subnet|port|router|floating ip|security group …`
**Why it matters most** more of this tutorial's failures live in Neutron than anywhere else, because it enforces rules invisibly — see **port security** and **security group** below.
**First met** [§3](../03-networks-and-ports.md)

### Glance — images
**What** the image registry: bootable disk images instances are created from.
**Used for** the Rocky 9.6 image the head node boots, and the iPXE image in §7.
**How we reach it** `openstack image list|show|create`.
**🛑 Constraint** images we create must be `--private` — a public image is visible to every project on the cloud.
**First met** [§1.5](../01-safety-and-access.md), used in [§4](../04-head-node-instance.md)

### Cinder — block storage
**What** volumes: virtual disks with their own lifecycle, attachable to instances.
**Used for** optional extra room for `/data` on the head node, only if the flavor's root disk is under 40 GB.
**How we reach it** `openstack volume create|list|delete`, `openstack server add|remove volume`.
**Note** a volume survives its instance being deleted, which is why §4.7 says to check for an existing one before making another.
**First met** [§4.7](../04-head-node-instance.md)

### Placement — scheduling inventory
**What** tracks what capacity and *traits* each hypervisor has, and answers "where can this flavor fit?"
**Used for** nothing we call directly — but it is the mechanism that confines this project to one hypervisor.
**How we reach it** indirectly: a flavor's `trait:CUSTOM_TECHWATCH_PROTO=required` is matched here.
**First met** [§1.5](../01-safety-and-access.md)

### Mentioned but not used
**Horizon** the web dashboard. **Ironic** bare-metal provisioning — conceptually the closest OpenStack service to what OpenCHAMI does, and [§7](../07-node-instances-and-ipxe.md) explains why we cannot use it. **Swift** object storage — we run [versitygw](openchami.md#versitygw--the-s3-object-store) on the head instead. **Magnum**, **Octavia** container orchestration and load balancing; out of scope.

---

## Identity and access

### Project (tenant) and domain
**What** a project is the ownership boundary for all resources — ours is `techwatch-proto`. A domain is the namespace above it.
**Why it matters** quota, resource visibility and naming collisions are all per-project. Two people working in one project can delete each other's things, which is why the `tw-` prefix convention exists.
**First met** [§1.1](../01-safety-and-access.md)

### Role: `member` vs `admin`
**What** what you are permitted to do within a project.
**Used for** a deliberate two-identity split: `member` for all normal work, `admin` for the few actions that require it (creating flavors, for instance).
**⚠ Constraint** never run `tofu` or `ansible` while elevated. Admin scope also *changes what listings show*, so a command that behaved one way yesterday can behave differently today purely because of which identity is active.
**First met** [§1.4](../01-safety-and-access.md) · runbook: [manage application credentials](../runbooks/manage-application-credentials.md)

### Application credential
**What** a named, revocable credential scoped to one project and role — an alternative to a password.
**Used for** `OS_CLOUD=techwatch`, the identity used for every tutorial section and all IaC.
**How we reach it** `openstack application credential create|list|delete`.
**⚠ Constraints** never create an admin-scoped one; never use `--unrestricted`; never paste unfiltered `openstack configuration show`, which prints the secret in clear.
**First met** [§1.4](../01-safety-and-access.md)

### `clouds.yaml` and `OS_CLOUD` (vs `openrc`)
**What** two ways to supply credentials. `openrc` is a shell script of `OS_*` exports; `clouds.yaml` is a file of named cloud profiles selected by one variable.
**Used for** we use `clouds.yaml`, because it holds *both* identities side by side and switching is one variable rather than re-sourcing.
**Configured in** `~/.config/openstack/clouds.yaml` on the devbox.
**First met** [§1.4](../01-safety-and-access.md)

### Quota
**What** the per-project ceiling on instances, vCPUs, RAM, volumes, floating IPs and more.
**How we reach it** `openstack quota show`.
**Why it matters here** RAM is the binding constraint: 200 GB total against head 16 + control plane 16 + two workers at 64 = 160 GB, so a third worker would need 224 GB. It is also why the flat and nested tutorials must be run **sequentially**.
**First met** [§1.5](../01-safety-and-access.md)

---

## Compute

### Instance (server)
**What** one virtual machine. `openstack server` is the noun.
**Ours** `tw-head` plus three Talos nodes.
**Check it** `openstack server list`, `openstack server show tw-head`
**First met** [§4](../04-head-node-instance.md)

### Flavor
**What** the named size template for an instance — vCPU, RAM, root disk, plus **extra specs**.
**⚠ Who runs it** the cloud operator. `openstack flavor create` is admin-only *even for private flavors*, so a flavor is something to request, not create.
**Why it matters more than it looks** at Digital Labs the flavor is what carries the placement trait, so it is the flavor — not an AZ or a host aggregate — that confines us to one hypervisor. A plain flavor does not schedule on these HPC-configured hosts **at all**.
**🛑 Never** "fix" a scheduling failure by dropping extra specs or switching AZ. That breaks the isolation the trait provides.
**Check it** `openstack flavor show <name>`
**First met** [§1.5](../01-safety-and-access.md) · runbook: [create the project's flavors](../runbooks/create-project-flavors.md)

### Extra specs
**What** key/value properties on a flavor that change how Nova places and configures the instance.
**Ones that matter here** `hw:cpu_policy=dedicated` (pin vCPUs to physical cores — makes capacity exclusive), `hw:mem_page_size=1GB` (hugepages), `hw:numa_nodes=N` (guest NUMA topology), `trait:CUSTOM_…=required` (see below).
**Check it** the `properties` field of `openstack flavor show`.
**First met** [§1.5](../01-safety-and-access.md)

### Placement trait
**What** a capability label on a hypervisor, matched by a flavor's `trait:…=required`.
**Ours** `CUSTOM_TECHWATCH_PROTO`, which pins this project to `compute2`.
**Why it matters** this is *the* isolation mechanism protecting three shared hypervisors from our experiments. Treat it as load-bearing.
**First met** [§1.5](../01-safety-and-access.md)

### Availability zone (AZ)
**What** a scheduling partition of the cloud. Digital Labs exposes `DL-Rack-5`, `DL-Rack-6`, `DL-Rack-11`, `DL-Rack-12`.
**⚠ Do not use** DL pins by **trait**, not by AZ. Passing `--availability-zone` is not how this project is isolated and can produce confidently wrong results.
**Where it bites unexpectedly** the AZ *name* leaks into the EC2 metadata service and broke the S3 gateway's bootstrap — see [issue 001](../issues/001-versitygw-bootstrap-aws-region-TLDR.md).
**Check it** `openstack availability zone list --compute`
**First met** [§1.5](../01-safety-and-access.md)

### Keypair
**What** an SSH public key registered with Nova and injected into instances by cloud-init.
**Ours** `tw_ed25519`, used as `ssh -i ~/.ssh/tw_ed25519 rocky@…`.
**Check it** `openstack keypair list`
**First met** [§1.5](../01-safety-and-access.md)

### Metadata service (`169.254.169.254`)
**What** a link-local HTTP service every instance can query for its own configuration — SSH keys, hostname, network layout, user-data. OpenStack implements both its own API and an **EC2-compatible** one.
**Used for** cloud-init reads it on first boot. That is how the head gets its keys, hostname and the static provisioning-NIC address.
**Check it** `curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
**🛑 Never firewall it.** It is not optional infrastructure; cloud-init depends on it.
**Where it bit us** the AWS CLI also treats it as a region source — [issue 001](../issues/001-versitygw-bootstrap-aws-region.md).
**First met** [§4](../04-head-node-instance.md), diagnosed in [issue 001](../issues/001-versitygw-bootstrap-aws-region.md)

### cloud-init
**What** the first-boot configuration agent in the cloud image. Reads user-data and metadata, then configures the machine.
**Used for** creating the `rocky` user with passwordless sudo, installing packages, and applying the static `172.16.0.254`.
**Configured in** `templates/head-user-data.yaml`, passed with `--user-data`.
**Check it** `sudo cloud-init status`, `sudo journalctl -u cloud-init`
**First met** [§4.3](../04-head-node-instance.md)

### Console log
**What** the instance's serial console output, captured by Nova and readable without any network access to the guest.
**Used for** the only way to watch a node boot when it has no SSH, no floating IP and no working network — which describes every Talos node in §7.
**Check it** `openstack console log show <server> --lines 300`
**First met** [§4](../04-head-node-instance.md)

---

## Networking

### Network, subnet, port
**What** three layers of one thing: a **network** is the layer-2 broadcast domain, a **subnet** adds layer-3 (CIDR, gateway, DHCP), a **port** is one NIC attached to a network with a fixed IP and a MAC.
**Ours** `tw-ext` (`192.168.200.0/24`, ordinary) and `tw-prov` (`172.16.0.0/24`, the provisioning wire).
**Why ports matter here** we create them *explicitly*, ahead of the instances, so we control the MAC and the IP — that is the contract §6 relies on.
**Check it** `openstack network list`, `openstack port list`
**First met** [§3](../03-networks-and-ports.md)

### `--no-dhcp` subnet
**What** a subnet with no Neutron DHCP agent.
**Used for** `tw-prov-subnet`. Essential: without it Neutron's dnsmasq and OpenCHAMI's CoreDHCP race for every node's DHCP request and roughly half the boots go wrong, undiagnosably.
**Side effect worth knowing** Neutron still assigns fixed IPs for its own bookkeeping — it just does not *serve* them. That is why allocation pools still matter on a `--no-dhcp` subnet.
**First met** [§3.2](../03-networks-and-ports.md)

### Allocation pool
**What** the range within a subnet Neutron may allocate from.
**Ours** `.1–.199` plus a single-address pool `.254–.254`, deliberately leaving `.200–.253` free for [CoreDHCP's bootloop range](openchami.md#coredhcp--the-provisioning-dhcp-server).
**Why** two independent allocators on one wire must not overlap, or you get an intermittent bad boot rather than an error.
**First met** [§3.2](../03-networks-and-ports.md)

### Router and floating IP
**What** a router connects a tenant subnet to an external network; a floating IP is an address on that external network, NAT'd to one port.
**Ours** `tw-head` has floating IP `10.3.0.185`.
**⚠ Local quirk** the floating-IP network here is RFC1918 (`10.3.0.0/24`) and reachable **only over the F5 VPN**. Consequence: `curl -s ifconfig.me` reports the wrong source address, which is a trap when writing security-group rules.
**Check it** `openstack floating ip list`, `openstack router show tw-router`
**First met** [§3.3](../03-networks-and-ports.md)

### Security group
**What** a stateful firewall applied per port. Default-deny inbound.
**Ours** `tw-sg-head` — SSH and ICMP from our VPN address only.
**⚠ The failure mode that costs hours** a non-matching rule **drops** packets rather than refusing them, so the symptom is an SSH *hang*, indistinguishable from a dead instance. Established flows survive a rule change (conntrack), so a mistake is invisible until the next reconnect.
**🛑 Never** scope SSH to `0.0.0.0/0`.
**Check it** `openstack security group rule list tw-sg-head`
**First met** [§3.5](../03-networks-and-ports.md) · runbook: [update the VPN tunnel address](../runbooks/update-tunnel-ip.md)

### Port security / anti-spoofing
**What** Neutron drops packets whose source MAC or IP is not the port's own.
**Why we disable it** on `tw-prov` ports only. Two things need it off: the head must **NAT** for the nodes (emitting packets with `172.16.0.x` sources that are not its own), and nodes must network-boot.
**How** `--disable-port-security` at port creation.
**⚠ The trap** with it on, §5.12's masquerade rule appears to succeed and Talos hangs forever at `downloading installer`.
**🛑 Never** disable it on `tw-ext` ports.
**First met** [§3.4](../03-networks-and-ports.md)

### Allowed address pairs
**What** a narrower alternative to disabling port security: permit specific extra IPs/MACs on a port.
**Status here** considered and documented as insufficient — it permits the NAT traffic but not, on all deployments, acting as a DHCP server.
**First met** [§3.4](../03-networks-and-ports.md)
