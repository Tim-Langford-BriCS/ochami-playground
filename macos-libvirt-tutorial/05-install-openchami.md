# §5 — Installing OpenCHAMI

*(Upstream: guide §2 / tutorial Part 1. Time: ~30–45 minutes, mostly
container downloads. Everything in this section runs **on the head node**
— `ssh rocky@192.168.200.2` from the host.)*

This section builds the **control plane** (§0): the OpenCHAMI services that
will provision the worker plane in §10. The substrate it runs on is already
in place (the head VM + networks from §§3–4).

## Concepts

**Podman Quadlets.** OpenCHAMI's services run as containers, but you won't
type `podman run` once. A *quadlet* is a small unit file in
`/etc/containers/systemd/` describing a container; systemd generates a
normal service from it. You manage OpenCHAMI with `systemctl`, get
dependency ordering, restarts and journald logging for free, and the
containers survive reboots like any other service. The **release RPM**
(from `github.com/OpenCHAMI/release`) installs ~18 quadlet files plus their
configs under `/etc/openchami/`, all grouped under one systemd *target*:
`openchami.target`.

**Two non-OpenCHAMI helpers** come first, as their own quadlets:

- a plain **OCI registry** (`:5000`) — §7's image builder stores
  intermediate OS-image *layers* here, like a private Docker Hub;
- the **Versity S3 Gateway** (`:7070`) — an S3-compatible object store
  where the bootable artifacts (kernel, initramfs, SquashFS) live, because
  "fetch over HTTP from S3" is how diskless nodes download their OS.

🔀 **Deviation.** The upstream *guide* deploys MinIO on :9000 with
hardcoded credentials; the current *tutorial* (and the release RPM
ecosystem) uses Versity on :7070 with generated credentials. We follow the
tutorial — and every S3 URL for the rest of this document says `:7070`.
Don't mix conventions: stale `:9000` URLs are the guide's biggest trap.

**The certificate pipeline.** OpenCHAMI's APIs sit behind haproxy with TLS.
A private CA (`step-ca`) issues the certificate via the ACME protocol —
the same protocol as Let's Encrypt, running entirely inside your head
node: `step-ca` → `acme-register`/`acme-deploy` (get + deploy the cert) →
`openchami-cert-trust` (install the CA into the system trust store). All
of it keys off the cluster's FQDN, which is why setting the FQDN correctly
*before first start* matters.

**Auth.** Write operations against the APIs need a **JWT** issued by the
built-in OIDC stack (hydra/opaal). The release RPM ships a shell helper,
`gen_access_token`, and tokens expire after **one hour** — remember that
when a command suddenly replies "unauthorized" tomorrow.

> **NB — `sudo` here is ordinary Unix, not the host's libvirt/polkit story
> (§2).** You're on the head node now; `sudo` appears only to touch
> root-owned paths (`/data`, `/etc`, `dnf`). `rocky` has passwordless sudo
> (the §4.3 cloud-init `NOPASSWD` line), so it won't prompt.

## Step 5.1 — Storage directories

```
head$ sudo mkdir -p /data/oci /opt/workdir
head$ sudo chown -R rocky: /data/oci /opt/workdir
```

`/data/oci` backs the registry's volume; `/opt/workdir` is our scratch
space for downloads. (Upstream keeps work outside `$HOME` to avoid
SELinux/container friction with home directories.)

## Step 5.2 — IP forwarding and the cluster name

```
head$ echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-forward.conf
head$ sudo sysctl --system | grep 90-forward -A1
```

The head routes between the internal wire and the world (compute nodes
have no other way out).

```
head$ echo "172.16.0.254 demo.openchami.cluster" | sudo tee -a /etc/hosts
```

`demo.openchami.cluster` is the cluster FQDN — the name on the TLS
certificate and in every API URL. It must resolve *on the head itself*
(the APIs call each other by it), hence the hosts entry pointing at the
internal address.

## Step 5.3 — The Versity S3 gateway quadlet

```
head$ cd /opt/workdir
head$ latest_versity_url=$(curl -s https://api.github.com/repos/openchami/versitygw-quadlet/releases/latest \
        | jq -r '.assets[] | select(.name | endswith("'"$(rpm --eval '%dist')"'.noarch.rpm")) | .browser_download_url')
head$ curl -L "$latest_versity_url" -o versitygw.rpm
head$ sudo dnf install -y ./versitygw.rpm
```

(The `jq` line asks GitHub's API for the newest release and picks the
`.el9.noarch.rpm` asset — `rpm --eval '%dist'` expands to `.el9` on this
box. `noarch` because a quadlet is just text files.)

## Step 5.4 — The OCI registry quadlet

```
head$ sudo tee /etc/containers/systemd/registry.container > /dev/null << 'EOF'
[Unit]
Description=Image OCI Registry
After=network-online.target
Requires=network-online.target

[Container]
ContainerName=registry
HostName=registry
Image=docker.io/library/registry:latest
Volume=/data/oci:/var/lib/registry:Z
PublishPort=5000:5000

[Service]
TimeoutStartSec=0
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```

Read it as: "run `registry:latest`, persist its data in `/data/oci`,
publish port 5000, restart it always." The `:Z` suffix relabels the volume
for SELinux. This file *is* the service definition — that's a quadlet.

## Step 5.5 — Start the S3 gateway and registry

```
head$ sudo systemctl daemon-reload
head$ sudo systemctl start registry.service
head$ sudo systemctl enable --now versitygw-gensecrets.service
head$ sudo systemctl start versitygw.service
head$ sudo systemctl enable --now versitygw-bootstrap.service
```

In order: `daemon-reload` makes systemd generate services from the quadlet
files; `versitygw-gensecrets` is a one-shot that mints S3 credentials into
`/etc/versitygw/secrets.env` (we'll read them in §7); then the gateway
itself; then a one-shot that bootstraps its users. (Quadlet-generated
services like `versitygw.service` can be started but not `enable`d — the
generator wires their boot-time behaviour instead.)

✅ Quick check — both must say `active`:

```
head$ for s in versitygw registry; do echo -n "$s: "; systemctl is-active $s; done
versitygw: active
registry: active
```

## Step 5.6 — Install the OpenCHAMI release RPM

```
head$ release_json=$(curl -s https://api.github.com/repos/openchami/release/releases/latest)
head$ rpm_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' | head -n1)
head$ curl -L -o openchami-release.rpm "$rpm_url"
head$ sudo dnf install -y ./openchami-release.rpm
```

Have a look at what arrived before starting anything:

```
head$ ls /etc/containers/systemd/          # ~18 quadlets: smd, bss, coresmd-*, haproxy, postgres, step-ca, hydra*, opaal*, acme-*, cloud-init-server...
head$ ls /etc/openchami/configs/           # coredhcp.yaml, Corefile, openchami.env
```

## Step 5.7 — Configure CoreDHCP

Replace `/etc/openchami/configs/coredhcp.yaml` wholesale:

```
head$ sudo tee /etc/openchami/configs/coredhcp.yaml > /dev/null << 'EOF'
server4:
  listen:
    - "%eth1"
  plugins:
    - server_id: 172.16.0.254
    - dns: 172.16.0.254
    - router: 172.16.0.254
    - netmask: 255.255.255.0
    - coresmd: https://demo.openchami.cluster:8443 http://172.16.0.254:8081 /root_ca/root_ca.crt 30s 1h false
    - bootloop: /tmp/coredhcp.db default 5m 172.16.0.200 172.16.0.250
EOF
```

Field by field — this file is the heart of the provisioning wire:

- `listen: "%eth1"` — bind to the internal NIC only (this is why §4 pinned
  the name `eth1`). Never let a provisioning DHCP server face a network
  you don't own.
- `server_id`/`dns`/`router` — the head is everything on this wire:
  DHCP server, DNS server, default gateway.
- `coresmd: <SMD-url> <bootscript-url> <CA-path> 30s 1h false` — the
  OpenCHAMI plugin. It caches SMD's inventory (refreshing every `30s`),
  and when a known MAC asks, leases it *its* IP for `1h` and points its
  PXE firmware at the boot-script service on `:8081`. The CA path is where
  the container finds the root certificate for verifying SMD's TLS.
- `bootloop:` — the fallback for *unknown* MACs: a short (5m) lease from
  172.16.0.200–250 that keeps them cycling until someone registers them.
  A brand-new rack of servers can be powered on and simply *waits* here.

## Step 5.8 — Configure CoreDNS

```
head$ sudo tee /etc/openchami/configs/Corefile > /dev/null << 'EOF'
.:53 {
    ready
    prometheus 0.0.0.0:9153
    bind 172.16.0.254

    coresmd {
        smd_url https://demo.openchami.cluster:8443
        ca_cert /root_ca/root_ca.crt
        cache_duration 30s
        zone openchami.cluster {
            nodes de{02d}
        }
    }
}
EOF
```

Same idea as DHCP, for names: DNS records are *generated from SMD*. The
`nodes de{02d}` rule renders node 1 as `de01.openchami.cluster` — remember
`de`/2-digits, it must match the cloud-init naming in §9.

## Step 5.9 — Set the FQDN for certificates

```
head$ sudo openchami-certificate-update update demo.openchami.cluster
```

This rewrites the ACME/haproxy configs to issue for our FQDN instead of
the machine's hostname. It suggests restart commands — ignore them,
nothing is running yet.

## Step 5.10 — Start OpenCHAMI

```
head$ sudo systemctl start openchami.target
```

First start pulls ~18 container images, so it can take many minutes —
**be patient, and don't panic at a slow prompt**. Watch it converge in
another terminal:

```
head$ watch systemctl list-dependencies openchami.target
```

⚠ **Gotcha.** If `systemctl start` times out or your SSH session dies,
the start usually *continues server-side* — check
`systemctl is-active openchami.target` before assuming failure or
re-running anything.

⚠ **Gotcha.** The *very first* start quite often fails with
`A dependency job for openchami.target failed` — a startup race while
images are still being pulled (it happened on both of our clean runs).
Nothing is actually broken: check `systemctl --failed` (usually empty),
wait a minute, and simply run `sudo systemctl start openchami.target`
again — the stragglers (typically the certificate chain and haproxy)
come up on the second attempt.

⚠ **Gotcha — SMD can come up before the auth keys exist.** If the first
start was messy (previous gotcha), SMD may have started before the OIDC
stack published its signing keys — then every *authenticated* request
(e.g. §6's discovery) fails with `500 Internal Server Error`, while
unauthenticated reads work fine, and `podman logs smd` shows a
`jwtauth ... nil pointer` panic. Fix: `sudo systemctl restart smd`. A
theme is emerging: several OpenCHAMI services read security material
**once at startup** — when in doubt after a rocky first start, restarting
the confused service is cheap and safe.

⚠ **Gotcha — restart coresmd after certificate changes.** The coresmd
containers read the root CA **once at startup**. If you ever re-run the
certificate update (or step-ca regenerates its CA) while they're running,
they'll fail TLS to SMD forever after — symptom: compute nodes get
172.16.0.200-range "bootloop" leases instead of their real IPs, and
`journalctl -u coresmd-coredhcp` shows
`x509: certificate signed by unknown authority`. Fix:
`sudo systemctl restart coresmd-coredhcp coresmd-coredns`.

## Step 5.11 — Install the `ochami` CLI

```
head$ ochami_url=$(curl -s https://api.github.com/repos/OpenCHAMI/ochami/releases/latest \
        | jq -r '.assets[] | select(.name | endswith("arm64.rpm")) | .browser_download_url')
head$ curl -L -o ochami.rpm "$ochami_url"
head$ sudo dnf install -y ./ochami.rpm
head$ ochami version | head -1
```

🔀 **Deviation.** The tutorial's command filters for `amd64.rpm`; we're on
ARM, so `arm64.rpm`.

Point it at our cluster (system-wide config; the `echo y` answers its
"create the config file?" prompt):

```
head$ echo y | sudo ochami config cluster set --system --default demo cluster.uri https://demo.openchami.cluster:8443
head$ ochami config show
```

## Step 5.12 — Get an access token

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
```

The variable name is `<CLUSTERNAME>_ACCESS_TOKEN` upper-cased — the CLI
looks for it automatically. **Tokens last one hour**: whenever `ochami`
starts complaining about authentication, re-run this line.

## ✅ Checkpoint

```
head$ systemctl list-dependencies openchami.target --plain | grep -c '\.service'
19

head$ ochami bss service status | jq -c .
{"bss-status":"running"}

head$ ochami smd service status | jq -c .
{"code":0,"message":"HSM is healthy"}
```

Eighteen OpenCHAMI services (the 19th line is
`NetworkManager-wait-online`) and two healthy APIs: the control plane is
up. (`HSM` = Hardware State Manager, SMD's original Cray name.)

## Common failures

| Symptom | Cause / fix |
|---|---|
| haproxy fails: `could not resolve address 'opaal'` | startup race, documented upstream: `sudo systemctl restart opaal haproxy` |
| TLS errors from ochami | FQDN mismatch: re-run step 5.9 then `sudo systemctl restart acme-deploy`, and see the coresmd gotcha above |
| a service stays `activating` for ages | it's pulling its image; `journalctl -eu <service>` to confirm it's downloading, then wait |

Next: [§6 — Telling OpenCHAMI about our nodes](06-node-discovery.md)
