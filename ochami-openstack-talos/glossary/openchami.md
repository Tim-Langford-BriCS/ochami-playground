# OpenCHAMI glossary

**The control plane we build ourselves**, on the head node, almost entirely from one release RPM. Unlike [OpenStack](openstack.md), everything here is ours: we installed it, we configured it, and when it misbehaves the cause is usually in a file we wrote.

Covers everything met through §5, including the full quadlet set installed by the release RPM at §5.6. "Installed" here means the unit exists — several are configured later in §§5.7–5.9 and started only at §5.10.

---

## What OpenCHAMI is

**OpenCHAMI** is an open-source **cluster management and provisioning** system for HPC — the thing that takes a rack of powered-off machines and turns them into a booted, inventoried, network-configured cluster. It descends from the Cray/HPE Shasta lineage (which is why some services still carry Cray names), and it is built as a set of small HTTP services rather than one monolith.

Its job in this tutorial is the **worker plane**: inventory the three Talos nodes, answer their DHCP, tell them what to boot, and serve the kernel and initramfs. Everything in §§5–10 is that.

**Not** a container platform, and not a scheduler. It provisions the machines that a scheduler like Slurm — or in our case Kubernetes — then runs on.

---

## How it is packaged

### Podman
**What** a daemonless container engine, Red Hat's alternative to Docker.
**Used for** every OpenCHAMI service is a container. We never type `podman run`, but `podman ps`, `podman logs <svc>` and `podman exec` are the diagnostic tools.
**Installed by** cloud-init on the head node.
**Check it** `sudo podman ps`
**First met** [§5](../05-install-openchami.md)

### Quadlet
**What** a small declarative unit file describing a container, from which systemd *generates* a real service. The bridge between "it's a container" and "manage it with `systemctl`".
**Used for** all ~18 OpenCHAMI services plus the registry and the S3 gateway. You get dependency ordering, restarts and journald logging for free.
**Configured in** two directories, both scanned by the generator — `/etc/containers/systemd/` for **local/admin** quadlets, `/usr/share/containers/systemd/` for **packaged** ones. The OpenCHAMI release RPM installs into `/etc/…`; the `versitygw-quadlet` RPM into `/usr/share/…`. If a service exists but its quadlet seems missing, look in the other directory.
**⚠ The generated unit is ephemeral.** `systemctl show versitygw -p FragmentPath` gives `/run/systemd/generator/versitygw.service` — regenerated on every `daemon-reload`, so never edit it. Override with a drop-in in `/etc/systemd/system/<unit>.service.d/`, which is what [issue 001](../issues/001-versitygw-bootstrap-aws-region-TLDR.md) does.
**⚠ Quirk** quadlet-generated services can be `start`ed but **not** `enable`d — the generator wires their boot behaviour instead. And a new or edited quadlet needs `systemctl daemon-reload` before systemd sees it.
**Check it** `ls /etc/containers/systemd/ /usr/share/containers/systemd/`
**First met** [§5.4](../05-install-openchami.md)

### `.volume` and `.network` quadlets
**What** quadlets are not only containers. A `.volume` unit declares a named podman volume; a `.network` unit declares a podman network. Both are created on demand by whichever container references them.
**Ours after §5.6** seven volumes — `acme-certs`, `haproxy-certs`, `step-ca-db`, `step-ca-home`, `step-root-ca`, `postgres-data`, `cloud-init-data` — and four networks.
**Why the volumes matter** they are where the *persistent* state lives: the certificate authority's keys and database, PostgreSQL's data, the issued certificates. Deleting a container is harmless; deleting these is not. `podman volume ls` is the honest answer to "what would I lose".
**Why four networks matter** `openchami-external`, `openchami-internal`, `openchami-cert-internal`, `openchami-jwt-internal` — deliberate segmentation, so that certificate traffic and JWT traffic each sit on their own bridge rather than one flat container network. Only the services that need to talk to each other can.
**Check it** `sudo podman volume ls`, `sudo podman network ls`
**First met** [§5.6](../05-install-openchami.md)

### `*-init` and `*-migrate` one-shots
**What** `Type=oneshot` containers that prepare state and exit, ordered before the long-running service they belong to. Not daemons.
**Ours** `smd-init` and `bss-init` (same images as `smd`/`bss`, run to initialise their schemas), `hydra-migrate` (`migrate … sql -e --yes`, the database migration). Together with `acme-register`, `acme-deploy`, `openchami-cert-trust` and `hydra-gen-jwks` that is **seven of the nineteen units** in `openchami.target`.
**⚠ They report `active`, not `exited`**, because `RemainAfterExit=yes` — for a oneshot that means "completed successfully". This is why `podman ps` shows 13 containers against 19 units: the difference is not a fault.
**Why it matters diagnostically** when a service will not start, check whether *its* init one-shot succeeded first. A failed migration presents as a broken service several steps downstream.
**Check it** `systemctl status smd-init bss-init hydra-migrate`
**First met** [§5.6](../05-install-openchami.md)

### `hydra-gen-jwks` — the readiness gate that explains a known race
**What** despite the name it generates nothing. It is a one-shot `curl` that polls until hydra publishes its key set:
```
Exec=--retry 10 --retry-delay 5 --retry-all-errors --verbose http://hydra:4444/.well-known/jwks.json
```
**Used for** a **JWKS** (JSON Web Key Set) is the public half of the keys used to sign JWTs. Services that validate tokens must fetch it. This unit exists purely to block startup ordering until it is available — at most 10 retries × 5 s ≈ 50 s.
**⚠ Why you care** this is the mechanism behind the documented SMD race: if SMD starts before hydra has published its JWKS, every *authenticated* request fails `500` while unauthenticated reads work fine, and `podman logs smd` shows a `jwtauth … nil pointer` panic. The gate exists to prevent it and does not always win. Fix: `sudo systemctl restart smd`.
**Check it** `curl -s http://localhost:4444/.well-known/jwks.json | jq -c '.keys[0].kid'` — untested from the host; the URL above is container-internal
**First met** [§5.6](../05-install-openchami.md), symptom documented at [§5.10](../05-install-openchami.md)

### `opaal-idp` — the bundled identity provider
**What** a second `opaal` container, run with `serve --config /opaal/config/opaal.yaml`, acting as the **identity provider** behind hydra rather than as its adapter.
**Used for** giving the cluster a self-contained login source, so nothing external is needed to issue tokens. In a real deployment this is where you would instead federate to a site identity provider.
**Note** `opaal` and `opaal-idp` are the same image (`ghcr.io/openchami/opaal:v0.3.12`) in two roles — worth knowing when reading logs, since both answer to "opaal".
**First met** [§5.6](../05-install-openchami.md)

### `openchami.target`
**What** a systemd target grouping every OpenCHAMI service, so the whole control plane starts as one unit.
**Check it** `systemctl list-dependencies openchami.target --plain | grep -c '\.service'` — expect 19
**⚠ Known first-start race** the very first `start` often fails with `A dependency job for openchami.target failed` while images are still pulling. Expected, not broken: wait and start it again.
**First met** [§5.10](../05-install-openchami.md)

### The release RPM
**What** one package from [`github.com/OpenCHAMI/release`](https://github.com/OpenCHAMI/release) that installs ~18 quadlets plus their configs.
**Configured in** everything it installs lands under `/etc/containers/systemd/` and `/etc/openchami/`.
**First met** [§5.6](../05-install-openchami.md)

---

## Storage and artifacts

### versitygw — the S3 object store
**What** the [Versity S3 Gateway](https://github.com/versity/versitygw): an S3-compatible API server backed by an ordinary filesystem.
**Used for** holding the bootable artifacts. Network-booting nodes fetch their kernel and initramfs over HTTP from here — "download your OS from S3" is the whole model.
**Installed by** the `versitygw-quadlet` RPM (§5.3), separately from and before the OpenCHAMI release RPM.
**Configured in** `/usr/share/containers/systemd/versitygw.container` — the **packaged** quadlet directory, not `/etc/…`, which is why it does not appear in `ls /etc/containers/systemd/`. Secrets in `/etc/versitygw/secrets.env`; per-user keys in `/etc/versitygw/users.d/`.
**Port** `:7070`
**⚠ `:7070`, never `:9000`.** Older upstream docs deploy MinIO on `:9000` with hardcoded credentials. Stale `:9000` URLs are the single biggest trap in the upstream documentation.
**⚠ Region** it signs with `VGW_REGION=us-east-1`, and every client must match — the region is part of the SigV4 credential scope, not decoration. See [issue 001](../issues/001-versitygw-bootstrap-aws-region-TLDR.md).
**Check it** `sudo podman exec versitygw versitygw --help`, `systemctl is-active versitygw`
**First met** [§5.3](../05-install-openchami.md)

### `versitygw-gensecrets` / `versitygw-bootstrap`
**What** two one-shot services. `gensecrets` mints the root S3 credentials; `bootstrap` creates per-user IAM identities and their buckets.
**Configured in** `gensecrets` writes `/etc/versitygw/secrets.env` (read by §8); `bootstrap` is the script `/usr/local/libexec/versitygw-bootstrap.sh`.
**Note** `bootstrap`'s user list is **hardcoded upstream** as `slurmd` and `fabricmanager` — see below. Neither is used by this tutorial.
**⚠ Known failure** [issue 001](../issues/001-versitygw-bootstrap-aws-region-TLDR.md) — fails on OpenStack until given a region.
**First met** [§5.5](../05-install-openchami.md)

### `slurmd` and `fabricmanager` (the two default S3 users)
**What** not OpenCHAMI services. **`slurmd`** is the compute-node daemon of **Slurm**, the HPC workload manager — one runs on every compute node, taking job launches from `slurmctld`. **`fabricmanager`** is **NVIDIA Fabric Manager**, which configures NVSwitch/NVLink topology on multi-GPU systems.
**Why they are here** they are hardcoded in the bootstrap script's `USERS=(…)` array. Together they reveal who OpenCHAMI assumes you are: a site provisioning bare-metal HPC running Slurm on NVIDIA hardware.
**Used for** *nothing, in this tutorial.* We substitute Talos and Kubernetes for Slurm, and create our own `boot-images` bucket in §8.3. `slurmd-bucket` and `fabricmanager-bucket` stay empty forever — they must merely be *creatable*, because the script's failure is the service's failure.
**First met** [§5.5](../05-install-openchami.md)

### OCI registry
**What** a plain container registry — a private Docker-Hub-alike.
**Used for** honestly, very little here. The upstream ecosystem expects one for intermediate OS-image layers built by `image-builder`; we don't build images because Talos is prebuilt. It costs nothing, so we run it.
**Configured in** `/etc/containers/systemd/registry.container`; data in `/data/oci`.
**Port** `:5000`
**First met** [§5.4](../05-install-openchami.md)

---

## Configuration

### `/etc/openchami/configs/`
**What** every OpenCHAMI config in one directory, installed by the release RPM.
**Contents** `openchami.env` (the central one, below), `coredhcp.yaml` (§5.7), `Corefile` (CoreDNS, §5.8), `haproxy.cfg`, `hydra.yml`, `opaal.yaml`, `configurator.yaml`.
**Useful trick** the RPM's own files are all stamped with the package build date, so `ls -la` tells you at a glance which ones **you** have changed and which are still at their defaults. A `Corefile` still showing the build date means §5.8 has not been done.
**First met** [§5.7](../05-install-openchami.md)

### Where things live on the head node
**What** the filesystem map, with measured sizes from a head node with §5 complete (2.9 GB of 59 GB used in total).

| Path | Holds | Size |
|---|---|---|
| `/var/lib/containers` | podman's image store — the ~18 OpenCHAMI images | **2.1 G** — the only large consumer |
| `/var/lib/versitygw/data` | the S3 buckets; §8's Talos kernel and initramfs land here | 8 K so far |
| `/var/lib/versitygw/iam` | versitygw's IAM database | — |
| `/data/oci` | the OCI registry's blobs | **0** — we never push to it |
| `/opt/workdir` | scratch: the three downloaded RPMs (`versitygw`, `openchami-release`, `ochami`) | 6.2 M — safe to delete |
| `/etc/openchami/configs/` | all OpenCHAMI config, incl. `openchami.env` | — |
| `/etc/containers/systemd/` | quadlets from the release RPM | — |
| `/usr/share/containers/systemd/` | quadlets from packages (`versitygw.container`) | — |
| `/etc/versitygw/` | `secrets.env` and `users.d/<user>.env` | — |
| `/etc/ochami/config.yaml` | the CLI's cluster config (`--system`) | 152 B |
| `~/tw-head-env.sh` + `~/tw-head-vars-env.sh` | the entry point, and the eleven `TW_*` variables generated on the devbox (§5) | — |
| podman volumes | step-ca's keys and DB, PostgreSQL data, issued certificates | `podman volume ls` |

**⚠ `/data` is a trap.** `podman inspect versitygw` shows `bind /var/lib/versitygw/data -> /data`, so the **container's** `/data` and the **host's** `/data` are different directories with the same name. The host's stays empty. This is why §4.7's original advice to mount a Cinder volume at `/data` would have captured none of the growth — corrected there.
**What you would actually lose** the podman volumes and `/var/lib/versitygw`. Everything else is either re-downloadable or regenerable from `tw-vars-env.sh`.
**First met** [§5.1](../05-install-openchami.md)

### `openchami.env` — the file that wires everything together
**What** ~40 environment variables shared by every service. The single place where the cluster's identity and the services' knowledge of each other live.
**What is in it** the cluster identity (`SYSTEM_NAME`, `SYSTEM_DOMAIN`, `SYSTEM_URL`); the OIDC endpoints (`URLS_SELF_ISSUER`, `URLS_LOGIN`, `URLS_CONSENT`, `URLS_LOGOUT`); Postgres connection details for both SMD and BSS (`SMD_DB*`, `BSS_DB*`); the cross-service URLs (`OPAAL_URL`, `HSM_URL`, `SMD_URL`, `BSS_JWKS_URL`, `SMD_JWKS_URL`); iPXE settings (`BSS_IPXE_SERVER`, `BSS_CHAIN_PROTO`); and step-ca's initialisation (`DOCKER_STEPCA_INIT_DNS_NAMES`, `DOCKER_STEPCA_INIT_ACME`).
**Why the FQDN must be right before first start** `SYSTEM_DOMAIN`/`SYSTEM_URL` and `DOCKER_STEPCA_INIT_DNS_NAMES` feed the certificate's subject names. Get it wrong and the certificate is issued for the wrong host — which is what §5.9 exists to repair.
**🛑 Never paste this file.** It contains `DOCKER_STEPCA_INIT_PASSWORD` and `DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD` in clear — the credentials to your cluster's certificate authority. Same rule as `openstack configuration show`: redact, or share key names only (`grep -oE '^[A-Za-z0-9_]+=' …`).
**Check it** `sudo grep -oE '^[A-Za-z0-9_]+=' /etc/openchami/configs/openchami.env`
**First met** [§5.6](../05-install-openchami.md)

### `configurator` — the config generator we bypass
**What** a service (`:3334`) that renders configuration files **from SMD inventory** using Jinja templates.
**Its targets** `configurator.yaml` lists five — `coredhcp`, `syslog`, `ansible`, `powerman`, `conman`.
**Why it is interesting** it is designed to generate the very `coredhcp.yaml` we hand-write in §5.7. Upstream's intended flow is inventory-first: register nodes in SMD, then let the configurator emit the DHCP config. We write it by hand because it is three plugins long and *explicit is better while learning* — but on a real cluster of hundreds of nodes this is the mechanism you would use.
**Another HPC trace** `powerman` (power control across many nodes) and `conman` (serial-console multiplexer) are standard HPC cluster tools we do not use — the same kind of trace as [`slurmd`](#slurmd-and-fabricmanager-the-two-default-s3-users). OpenStack gives us `openstack server reboot` and `console log show` instead.
**Also visible here** SMD's internal address is `http://smd:27779` — the port behind haproxy's `:8443`.
**Status** installed and left at its defaults. Not used by this tutorial.
**First met** [§5.6](../05-install-openchami.md)

---

## Inventory and boot

### SMD — State Management Database
**What** the inventory service: the authoritative record of what nodes exist, their MACs, their names and their state. Also called **HSM** (Hardware State Manager), its original Cray name — both appear in output.
**Used for** everything downstream reads it. DHCP leases, DNS records and boot scripts are all *derived from* SMD, which is why §6 is the hinge of the whole build.
**Check it** `ochami smd service status`
**⚠ Known race** SMD can start before the OIDC stack has published its signing keys. Then authenticated requests fail `500` while unauthenticated reads work fine. Fix: `sudo systemctl restart smd`.
**First met** [§5.6](../05-install-openchami.md), used in [§6](../06-node-inventory.md)

### BSS — Boot Script Service
**What** serves a per-node boot script: given a MAC, returns the kernel URL, initramfs URL and kernel command line.
**Used for** the thing iPXE actually talks to. §9 writes the payloads; §10 is where they get used.
**Port** `:8081`
**Check it** `ochami bss service status`, or directly `curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01"`
**First met** [§5.6](../05-install-openchami.md), used in [§9](../09-boot-parameters.md)

### CoreDHCP — the provisioning DHCP server
**What** a plugin-based DHCP server. **The only DHCP server allowed on the provisioning wire** — hence `--no-dhcp` on the Neutron subnet.
**Used for** answering node DHCP with an address *and* the boot-script URL. The DHCP answer is what steers a node into the boot chain.
**Configured in** `/etc/openchami/configs/coredhcp.yaml` — written by hand in §5.7, though upstream's [`configurator`](#configurator--the-config-generator-we-bypass) is designed to generate it from SMD.
**The plugin chain, in order** `server_id` / `dns` / `router` / `netmask` all point at the head (`172.16.0.254`) — the head is everything on this wire. `router` is specifically what makes §5.12's NAT reachable: nodes send off-subnet traffic to the head because this told them to.
**Two plugins that matter**
- `coresmd` — caches SMD's inventory (30 s refresh); a **known** MAC gets its assigned IP for 1 h and a pointer to BSS on `:8081`.
- `bootloop` — the fallback for **unknown** MACs: a 5-minute lease from `172.16.0.200–250` that keeps them cycling until someone registers them. A new rack can be powered on and simply *wait* here. This range is why §3.2 kept `.200–.253` out of Neutron's allocation pools.

**⚠ `listen: "%eth1"`** binds to the provisioning NIC only, using whatever `TW_PROV_IF` you discovered in §4.6. Never let a provisioning DHCP server face a network you don't own. Wrong value → `no such device`, or worse, a silent bind to nothing.
**Check it** `systemctl is-active coresmd-coredhcp`, `sudo ss -ulpn | grep :67`
**First met** [§5.7](../05-install-openchami.md)

### CoreDNS
**What** a plugin-based DNS server; here, cluster names generated from SMD.
**Configured in** `/etc/openchami/configs/Corefile`
**The directives** `.:53` serves the root zone on port 53; `bind 172.16.0.254` restricts it to the provisioning wire, same reasoning as CoreDHCP's `listen`; `ready` exposes a readiness endpoint for startup ordering; `cache_duration 30s` matches CoreDHCP's SMD refresh, so **a node added to SMD becomes both resolvable and leasable within ~30 s**.
**Node naming** `nodes de{02d}` renders node 1 as `de01.openchami.cluster`, node 2 as `de02`. `de` is a **literal prefix in this file**, not derived from the cluster name — renaming the cluster would not change it. (It plausibly echoes `demo` upstream; that's a guess, not a documented fact.)
**⚠ `bind` does not restrict the metrics endpoint.** `prometheus 0.0.0.0:9153` carries its own listen address and is not scoped by `bind`, so CoreDNS metrics listen on *all* interfaces including the external one, while DNS itself listens only on `172.16.0.254`. Harmless here because `tw-sg-head` permits only 22 and ICMP inbound — but it is the security group, not the Corefile, doing that work. Inferred from the plugin's syntax; not verified with `ss` (CoreDNS does not start until §5.10).
**⚠ Cluster names only — and do not add a `forward` clause.** It cannot resolve `ghcr.io` or `registry.k8s.io`, which Talos needs. §8.4 fixes that in the Talos machine config instead. The concrete reason not to widen it here: with a `forward`, boot-time DNS resolves and the fetch *still* fails, because iPXE's minimal TLS stack cannot negotiate a cipher with a modern HTTPS server (iPXE error `0x410de18f`, seen in the libvirt lab). The head fetches from upstream itself and serves to nodes over plain HTTP by raw IP.
**First met** [§5.8](../05-install-openchami.md)

### `coresmd`
**What** the OpenCHAMI plugin that teaches CoreDHCP and CoreDNS to read SMD. Runs as two containers, `coresmd-coredhcp` and `coresmd-coredns`.
**⚠ Restart after any certificate change.** The containers read the root CA **once at startup**. Change certificates while they run and they fail TLS to SMD forever, with a symptom that looks like a boot problem: nodes get `172.16.0.200`-range bootloop leases instead of their real IPs. Fix: `sudo systemctl restart coresmd-coredhcp coresmd-coredns`.
**First met** [§5.7](../05-install-openchami.md)

### cloud-init server
**What** OpenCHAMI's own metadata server, serving per-node user-data over HTTP — the same NoCloud mechanism as an OpenStack instance's, but from the head node.
**Port** `:8081`
**Status here** installed by the release RPM; **not used** by us, because Talos does not run cloud-init. It is central to the libvirt lab's compute nodes.
**First met** [§5.6](../05-install-openchami.md)

---

## Certificates and auth

### The certificate pipeline
**What** four cooperating pieces: **`step-ca`** (a private certificate authority) issues a TLS certificate over **ACME** — the Let's Encrypt protocol, running entirely inside the head node — via **`acme-register`** and **`acme-deploy`**, and **`openchami-cert-trust`** installs the root CA into the system trust store.
**Used for** every OpenCHAMI API is HTTPS. Nothing works if this doesn't.
**⚠ Keys off the cluster FQDN**, which is why setting `TW_CLUSTER_FQDN` correctly *before first start* matters, and why §5.9 exists to rewrite it if you got it wrong.
**Symptom of trouble** TLS errors from `ochami` → re-run §5.9, restart `acme-deploy`, then see the `coresmd` warning above.
**First met** [§5](../05-install-openchami.md)

### haproxy
**What** the TLS-terminating reverse proxy in front of every OpenCHAMI API.
**Port** `:8443` — the port in every API URL.
**⚠ Known startup race** fails with `could not resolve address 'opaal'` if it starts before the OIDC container. Documented upstream. Fix: `sudo systemctl restart opaal haproxy`.
**First met** [§5.6](../05-install-openchami.md)

### hydra / opaal — the OIDC stack
**What** **hydra** is an OAuth2/OIDC server; **opaal** is OpenCHAMI's adapter around it. Together they issue the tokens that authorise writes.
**Used for** every write to SMD or BSS needs a token from here.
**First met** [§5.6](../05-install-openchami.md)

### JWT and `gen_access_token`
**What** a **JWT** is a signed bearer token. `gen_access_token` is the helper the release RPM ships to get one.
**Used for** `export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')`. The variable name is `<CLUSTERNAME>_ACCESS_TOKEN` upper-cased — the `ochami` CLI finds it automatically.
**⚠ Tokens last one hour.** When `ochami` suddenly says unauthorized, this is why. Re-run the line. It reappears at the start of §6 and §9 for exactly that reason.
**First met** [§5.13](../05-install-openchami.md)

### PostgreSQL
**What** the database behind SMD and the auth stack, as its own quadlet.
**Used for** nothing we touch directly, but it is where the inventory actually lives.
**First met** [§5.6](../05-install-openchami.md)

---

## Tools

### `ochami` — the CLI
**What** the OpenCHAMI command-line client. Version `0.10.0` at the time of writing, installed from a GitHub release RPM (`amd64.rpm` on x86_64 — the libvirt lab used `arm64.rpm`).
**Used for** `ochami smd …`, `ochami bss …` in §§6 and 9.
**Configured in** `/etc/ochami/config.yaml` when set with `--system` (hence the `sudo`), holding the cluster name and its `https://<fqdn>:8443` URI. A per-user `~/.config/ochami/` would take precedence if one existed.
**Note `enable-auth: true`** in the default config: the CLI attaches a bearer token to writes and refuses without one, which is what makes §5.13's token step mandatory rather than optional.
**Check it** `ochami config show`, then `ochami bss service status | jq -c .` → `{"bss-status":"running"}`
**First met** [§5.11](../05-install-openchami.md)

### The head node as NAT router
**What** not a component, but a role: the head forwards and masquerades for `172.16.0.0/24`.
**Why** Talos is **not self-contained** — on first boot it pulls its installer image from `ghcr.io` and Kubernetes images from `registry.k8s.io`. The nodes have no other route out.
**Configured in** `net.ipv4.ip_forward` via `/etc/sysctl.d/90-forward.conf`, plus masquerading via `firewall-cmd --add-masquerade` **or** `nft`. Check with `command -v firewall-cmd`, not just `systemctl is-active firewalld` — on the Rocky 9.6 cloud image firewalld is **not installed**. Persist nftables in `/etc/sysconfig/nftables.conf`.
**🛑 Use your own nftables table, `twnat` — never `ip nat`.** That table is managed by `iptables-nft` on podman/netavark's behalf and holds the DNAT rules for the registry (`:5000`) and S3 gateway (`:7070`); `nft` prints `do not touch` when you list it. Putting our chain there works until podman next rewrites the table. See [issue 002](../issues/002-nftables-table-owned-by-podman.md).
**⚠ Depends on port security being disabled** on the head's provisioning port (§3.4). Without that, this appears to work and Talos hangs at `downloading installer`.
**First met** [§5.12](../05-install-openchami.md)
