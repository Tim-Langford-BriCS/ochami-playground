# tw-vars-env.sh — every value this tutorial needs that depends on your OpenStack
# cloud. On the DEVBOX, at ~/tw/tw-vars-env.sh.
#
# You do not source this file directly. ~/tw/tw-env.sh — the entry point — does,
# and §1.5 puts that in ~/.bashrc so it comes back at every login:
#
#   devbox$ cp <this-tutorial>/templates/tw-vars-env.sh ~/tw/tw-vars-env.sh
#   devbox$ source ~/tw/tw-env.sh
#
# ═════════════════════════════════════════════════════════════════════════════
# WHICH FILE IS SAFE TO RE-COPY, AND WHICH IS NOT
# ═════════════════════════════════════════════════════════════════════════════
#
#   THIS FILE (tw-vars-env.sh)  holds YOUR values. Once you have started filling
#                           it in, NEVER replace it wholesale from the template —
#                           you would lose every answer from §1.5, plus the
#                           values §4.5 and §4.6 append later.
#
#   tw-helpers-env.sh       holds only functions, no values. ALWAYS safe to
#                           re-copy wholesale, at any time, with no risk. When
#                           the tutorial improves a helper, that is a one-line
#                           `cp` and nothing of yours is touched.
#
#   tw-env.sh               a dispatcher, no values either. ALWAYS safe.
#
# That separation is the whole reason there are three files, and it is why this
# one is not called tw-env.sh: the file you re-copy without thinking and the
# file you must never re-copy should not have adjacent names.
#
# 🛑 UPGRADING FROM A SINGLE-FILE ~/tw/tw-env.sh? RENAME BEFORE YOU COPY.
#    That file held your values; the new tw-env.sh does not. Copying the new
#    one over it destroys §1.5's answers.
#
#      devbox$ mv ~/tw/tw-env.sh ~/tw/tw-vars-env.sh          # keep your values
#      devbox$ mv ~/tw/tw-helpers.sh ~/tw/tw-helpers-env.sh   # if present
#      devbox$ cp <this-tutorial>/templates/tw-env.sh ~/tw/   # now the dispatcher
#      devbox$ source ~/tw/tw-env.sh && tw_check
#
# (If your old file also defines tw_* functions, delete them from it — the later
# definition wins, so a stale copy shadows nothing, but it is confusing to read.)
#
# ═════════════════════════════════════════════════════════════════════════════
# HOW THIS FILE GETS FILLED IN — three regions, in this order
# ═════════════════════════════════════════════════════════════════════════════
#
#   REGION 1  (§1.4)   OS_CLOUD only. Needed before any OpenStack command works.
#   REGION 2  (§1.5)   Recon results. These are the OUTPUT of the §1.5 commands,
#                      so they stay <PLACEHOLDER> while you are running them.
#                      That is expected — never pass a <…> to a command.
#   REGION 3           Fixed by the tutorial. Do not change without reading §3
#                      and §5; several are hardcoded into OpenCHAMI configs.
#
# Then §4.5 appends TW_HEAD_FIP and §4.6 appends TW_PROV_IF, at the very end.
#
# Verify with:  tw_check     (from tw-helpers-env.sh)
#
# Do NOT verify with `grep -c '<' ~/tw/tw-vars-env.sh` — the comments above and below
# contain '<' of their own, so the count is never 0 even when every value is
# filled in. tw_check inspects the TW_* VALUES instead.

# ═══ REGION 1 — YOUR VALUE. Identity (§1.2-1.4) ══════════════════════════════
# Which clouds.yaml entry to use. Must be project-scoped to techwatch-proto.
#
# This has to match a key under `clouds:` in your clouds.yaml. If you get
# "Cloud techwatch was not found", the name here and the name in the file
# disagree — list what you actually have:
#
#   devbox$ python3 -c 'import openstack.config as c; \
#             print("\n".join(sorted(c.OpenStackConfig().get_cloud_names())))'
#
# and either set OS_CLOUD to one of those names, or rename the entry in
# clouds.yaml. openstacksdk looks in $OS_CLIENT_CONFIG_FILE, then ./clouds.yaml
# (relative to your CURRENT DIRECTORY — a surprising one), then
# ~/.config/openstack/clouds.yaml, then /etc/openstack/clouds.yaml.
export OS_CLOUD=techwatch

# ═══ REGION 2 — YOUR VALUES. Recon results (§1.5) ════════════════════════════
# Every line down to REGION 3 is an answer you discover and write in yourself.
# The hypervisor the project is pinned to. Used only to verify placement (§1.6).
export TW_HYPERVISOR='<HYPERVISOR>'          # e.g. compute2

# Availability zone. RECORDED ONLY - never passed to a command in this tutorial.
# At Digital Labs the zones are named per rack (ours: DL-Rack-5) and a rack holds
# several hypervisors, so the AZ is not the isolation boundary; the placement
# trait on the flavor is (§1.5). Do not pass --availability-zone anywhere.
export TW_AZ='<AZ>'                          # e.g. DL-Rack-5, or 'nova' elsewhere

# The external network that hands out floating IPs (openstack network list --external)
export TW_EXT_NET='<EXT_NET>'

# The network YOUR DEVBOX APPEARS FROM, as the HEAD NODE sees it. Every SSH and
# ICMP rule in §3.5 is scoped to this, and §11.5's tunnel comes from here too.
#
# ⚠ `curl -s ifconfig.me` IS ONLY THE RIGHT ANSWER IF THE FLOATING-IP NETWORK IS
#   PUBLICLY ROUTABLE. Check first:
#
#     devbox$ openstack subnet list --network ${TW_EXT_NET} -c Subnet -f value
#
#   - public range   -> curl -s ifconfig.me is correct; use it, as a /32
#   - private range (10.x / 172.16-31.x / 192.168.x) -> it is NOT correct
#
#   At Digital Labs it is PRIVATE: the router's external_fixed_ips sits on
#   10.3.0.0/x, so floating IPs are 10.3.0.x and you reach them over the F5 VPN.
#   With a split-tunnel VPN, ifconfig.me goes out your local line and reports
#   your home/office address, while traffic to 10.3.0.x goes down the tunnel and
#   arrives from a University address. A /32 of the wrong one blocks the only
#   path you use, and the symptom is an SSH TIMEOUT in §4.6 against a head node
#   that booted perfectly. See §1.5 for how to find the tunnel-side address.
#
#   AT DIGITAL LABS THE ANSWER IS 10.11.0.0/16 — the range the F5 concentrator
#   (run by UoB IT Services) is understood to allocate client addresses from.
#   Consistent with every address we have measured, but it is somebody else's
#   service and we have not seen its configuration: treat it as a well-supported
#   belief, not a verified boundary. On another cloud, ask whoever runs the VPN.
#
#   Confirm empirically after your first successful login:
#     head$ sudo journalctl -u sshd | grep -i accepted | tail -3
#
# ⚠ Never 0.0.0.0/0. An open SSH port is found by scanners within minutes, and
#   the IaC's variables.tf refuses this value deliberately.
#
# ⚠ A /32 HERE GOES STALE ON ITS OWN. It records where you appeared from when
#   you wrote it, so a VPN reconnect, an expired DHCP lease, or moving between
#   networks invalidates it without you changing anything. The symptom is an
#   SSH *timeout* to a head node that is perfectly healthy — see §17 and
#   runbooks/update-tunnel-ip.md.
#
#   TWO DEFENSIBLE CHOICES, see §1.5 and runbooks/update-tunnel-ip.md:
#     - THE POOL RANGE (the default here): 10.11.0.0/16 at Digital Labs. One
#       value that survives every reconnect. RFC1918 and unroutable from the
#       internet, so it does not widen who can reach port 22 — only the VPN's
#       own authentication does that.
#     - THE /32 YOU MEASURED: the actual dynamic address the F5 client assigned
#       to your laptop this session. Tightest scope, records each session in the
#       rule list, depends on nobody else's facts — but re-issue every reconnect.
#   Measure the address either way: that is how you know you are on the tunnel,
#   and an address outside the pool range means the pool assumption has changed.
#
#   Write masks out in full: 10.11.0.0/16, never 10.11/16.
export TW_ADMIN_CIDR='<YOUR_ADMIN_CIDR>'     # 10.11.0.0/16 at DL, or a measured /32

# Glance image for the head node: Rocky Linux 9, x86_64.
# Use the image's *exact* name as it appears in `openstack image list`, e.g.
# 'Rocky-9.6'. Names with spaces are why this is quoted.
#
# ⚠ USE THE UUID INSTEAD IF THE NAME IS NOT UNIQUE. Glance does not enforce
#   unique image names, and clouds routinely end up with several — a maintained
#   one plus somebody's upload, or two revisions of the same release. The symptom
#   is confirmed on Digital Labs, 31 Jul 2026:
#
#     $ openstack image show Rocky-9.6 -c properties -f value
#     More than one Image exists with the name 'Rocky-9.6'.
#
#   `server create --image <ambiguous name>` fails the same way in §4.4. Pick one
#   deliberately and pin it by ID:
#
#     $ openstack image list --name 'Rocky-9.6' -f value -c ID -c Name -c Status
#     $ for i in $(openstack image list --name 'Rocky-9.6' -f value -c ID); do
#         openstack image show $i -c name -c visibility -c owner -c created_at \
#           -c min_disk -c properties -f yaml; done
#
#   Prefer the newer, and check `owner`: an image owned by our own project is
#   somebody's upload, not the cloud's maintained one. An ID also cannot start
#   silently resolving to a different image later, which a name can.
export TW_HEAD_IMAGE='<ROCKY9_IMAGE_NAME_OR_UUID>'

# Firmware type of that image — from `openstack image show … -c properties`,
# look for hw_firmware_type. Decides which iPXE artifact §7 builds.
#   'bios' → ipxe.iso        'uefi' → ipxe.efi in an ESP image
export TW_FIRMWARE='<bios|uefi>'

# Flavors (openstack flavor list).
#
# ⚠ THE FLAVOR IS THE ISOLATION MECHANISM at Digital Labs (§1.5). Each of these
#   must carry `trait:CUSTOM_TECHWATCH_PROTO=required` plus the HPC properties
#   (hw:cpu_policy=dedicated, hw:mem_page_size=1GB, hw:numa_nodes=…). A flavor
#   WITHOUT the trait can be scheduled anywhere in the cloud; one without the
#   HPC properties will not schedule at all on these hosts.
#
#   Flavors are admin-created — ask, don't improvise. Verify before §4:
#     openstack flavor show "$TW_FLAVOR_HEAD" -c properties -f value 2>/dev/null \
#       | tr ',' '\n' | grep trait:
export TW_FLAVOR_HEAD='<FLAVOR_HEAD>'        # >=4 vCPU, >=16GB RAM, >=60GB disk
export TW_FLAVOR_CP='<FLAVOR_CP>'            # >=4 vCPU, >=16GB RAM, >=30GB disk
export TW_FLAVOR_WORKER='<FLAVOR_WORKER>'    # 8 vCPU, 64GB RAM (vLLM lives here)

# The trait our flavors must require. Used only by the verification above.
export TW_TRAIT=CUSTOM_TECHWATCH_PROTO

# ═══ REGION 3 — TUTORIAL CONSTANTS. Not yours; safe to take from the template ═
# Change these only after reading §3 and §5 — several are hardcoded into the
# OpenCHAMI configs, the node map and the BSS payloads.

# Resource name prefix. Everything we create carries it, so that
# `openstack server list` makes ownership obvious (§1 rules).
export TW_PREFIX=tw

# The two networks (§3).
export TW_EXT_SUBNET_CIDR=192.168.200.0/24   # our side of the routed network
export TW_PROV_CIDR=172.16.0.0/24            # the provisioning wire

# The head node's address on the provisioning wire. Hardcoded into every
# OpenCHAMI config in §5 — changing it means changing coredhcp.yaml, the
# Corefile, /etc/hosts and every BSS payload.
export TW_HEAD_PROV_IP=172.16.0.254

# Cluster FQDN: the name on the TLS certificate and in every API URL (§5.2).
export TW_CLUSTER_NAME=demo
export TW_CLUSTER_FQDN=demo.openchami.cluster

# Architecture. x86_64 throughout, matching the PTR hardware (§0).
export TW_ARCH=amd64                         # Talos/Go naming
export TW_ARCH_RPM=x86_64                    # RPM naming
export TW_CONSOLE=ttyS0,115200               # serial console for x86_64

# Object store (Versity S3 gateway) as booting nodes see it (§5.5, §8).
export TW_OBJ=172.16.0.254:7070

# Talos release to deploy (§8). Pick the latest stable v1.13.x.
export TW_TALOS_VERSION=v1.13.0

# ─── Node map — the single source of truth (§3, §6, §9) ──────────────────────
# These MAC/IP/xname/role tuples must agree in three places:
#   1. the Neutron ports we create          (§3.4)
#   2. the SMD inventory we load            (§6.1)
#   3. the BSS boot payloads we write       (§9.1)
# Keeping them in sync by hand is the single biggest error source in this
# tutorial — which is precisely what the companion IaC removes by generating
# all three from one declaration.
#
#   name      xname           nid  mac                  ip            role
#   tw-cp1    x1000c0s0b0n0   1    52:54:00:be:ef:01    172.16.0.1    controlplane
#   tw-w1     x1000c0s0b1n0   2    52:54:00:be:ef:02    172.16.0.2    worker
#   tw-w2     x1000c0s0b2n0   3    52:54:00:be:ef:03    172.16.0.3    worker
#   tw-w3     x1000c0s0b3n0   4    52:54:00:be:ef:04    172.16.0.4    worker
#   tw-w4     x1000c0s0b4n0   5    52:54:00:be:ef:05    172.16.0.5    worker
#
# We register all five in SMD (§6) but only boot as many as quota allows (§7).
export TW_CP_MAC=52:54:00:be:ef:01
export TW_CP_IP=172.16.0.1

# ═════════════════════════════════════════════════════════════════════════════
# END OF YOUR VALUES.  Everything above this line is yours; nothing below is.
# ═════════════════════════════════════════════════════════════════════════════
#
# ⚠ §4.5 and §4.6 APPEND to the end of this file (TW_HEAD_FIP, TW_PROV_IF), so
#   values may appear below this line later. That is expected and harmless — they
#   are still yours.
#
# NOTHING ELSE BELONGS BELOW THIS LINE. The tw_* helpers are in
# tw-helpers-env.sh and are loaded by tw-env.sh, the entry point, which sources
# this file first and them second. An earlier version of this file ended by
# sourcing the helpers itself; that made a file you must never re-copy also the
# file that decides what else gets loaded, so the two jobs were separated.
