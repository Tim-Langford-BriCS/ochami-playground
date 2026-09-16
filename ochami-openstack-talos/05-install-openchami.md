# §5 — Installing OpenCHAMI

*(Upstream: [OpenCHAMI tutorial](https://openchami.org/docs/tutorial/) Part 1. Time: ~30–45 minutes, mostly container downloads. **Everything in this section runs on the head node** — `ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}` — except the one `scp` below that seeds the head's variables from the devbox.)*

This section builds the **OpenCHAMI control plane** (§0): the services that will provision the worker plane in §§7–10. The substrate is already in place — the head instance and the two networks from §§3–4.

🔀 **Deviation: none of substance.** This is the one section of the tutorial that is essentially unchanged from the [libvirt lab's §5](../ochami-macos-libvirt/05-install-openchami.md). That is the point of the two-plane model: the OpenCHAMI layer does not care whether the head node is a libvirt VM, an OpenStack instance or a bare-metal server. The only differences are **x86_64 instead of aarch64** in two download filters, the **interface name** in the CoreDHCP config, and one **extra step** (§5.12, NAT) which the lab's Talos follow-on needed too.

## Concepts

**Podman Quadlets.** OpenCHAMI's services run as containers, but you won't type `podman run` once. A *quadlet* is a small unit file in `/etc/containers/systemd/` describing a container; systemd generates a normal service from it. You manage OpenCHAMI with `systemctl`, and get dependency ordering, restarts and journald logging for free. The **release RPM** (from [`github.com/OpenCHAMI/release`](https://github.com/OpenCHAMI/release)) installs ~18 quadlet files plus their configs under `/etc/openchami/`, all grouped under one systemd *target*: `openchami.target`.

**Two non-OpenCHAMI helpers** come first, as their own quadlets:

- a plain **OCI registry** (`:5000`) — a private Docker-Hub-alike. In the lab this held intermediate OS-image layers from `image-builder`; we don't build images (Talos is prebuilt), but the release ecosystem expects it and it costs nothing;
- the **Versity S3 Gateway** (`:7070`) — an S3-compatible object store where the bootable artifacts live, because "fetch over HTTP from S3" is how network-booting nodes download their OS. §8 puts the Talos kernel and initramfs here.

🔀 **Deviation — S3 backend.** The older upstream *guide* deploys MinIO on `:9000` with hardcoded credentials; the current *tutorial* and the release RPM ecosystem use Versity on `:7070` with generated credentials. We follow the tutorial, and **every S3 URL in this document says `:7070`**. Stale `:9000` URLs are the single biggest trap in the upstream documentation.

**The certificate pipeline.** OpenCHAMI's APIs sit behind haproxy with TLS. A private CA (`step-ca`) issues the certificate over ACME — the same protocol as Let's Encrypt, running entirely inside your head node: `step-ca` → `acme-register`/`acme-deploy` → `openchami-cert-trust`. All of it keys off the cluster's FQDN, which is why setting the FQDN correctly *before first start* matters.

**Auth.** Write operations need a **JWT** from the built-in OIDC stack (hydra/opaal). The release RPM ships a helper, `gen_access_token`, and tokens expire after **one hour** — remember that when a command suddenly says "unauthorized" tomorrow.

> **`sudo` here is ordinary Unix.** You're on the head node; `sudo` appears only to touch root-owned paths (`/data`, `/etc`, `dnf`). `rocky` has passwordless sudo from §4.3's cloud-config, so it won't prompt.

Set your variables. Every one of them is in `tw-vars-env.sh` on the devbox already (§1.5, §4.6), so **generate the head's copy from it rather than retyping** — a mistyped `TW_PROV_IF` is the commonest cause of §5.7 failing, and it fails silently.

Write all eleven now, not just the six this section needs: §5.12 and §§8–10 also run on the head and want the rest.

**Two files go across, and they do different jobs.** `tw-head-vars-env.sh` is *generated* from your values and is the only one that will ever change. `tw-head-env.sh` is a fixed **entry point** — it holds no values at all, and its only job is to source whichever `tw-head-*-env.sh` files exist beside it. Copying it now, three sections before the first of its dependants exists, is what lets §10 and §14 install a helper by writing a file rather than by editing one.

```
devbox$ cat > ~/tw/tw-head-vars-env.sh <<EOF
# Generated from tw-vars-env.sh on the devbox — see §5. Do not edit by hand.
export TW_CLUSTER_NAME=${TW_CLUSTER_NAME}
export TW_CLUSTER_FQDN=${TW_CLUSTER_FQDN}
export TW_HEAD_PROV_IP=${TW_HEAD_PROV_IP}
export TW_PROV_IF=${TW_PROV_IF}
export TW_PROV_CIDR=${TW_PROV_CIDR}
export TW_OBJ=${TW_OBJ}
export TW_ARCH_RPM=${TW_ARCH_RPM}
export TW_ARCH=${TW_ARCH}
export TW_CONSOLE=${TW_CONSOLE}
export TW_TALOS_VERSION=${TW_TALOS_VERSION}
export TW_CP_IP=${TW_CP_IP}
EOF
devbox$ cat ~/tw/tw-head-vars-env.sh                    # read it before sending it
devbox$ cp <this-tutorial>/templates/tw-head-env.sh ~/tw/tw-head-env.sh
devbox$ scp -i ~/.ssh/tw_ed25519 ~/tw/tw-head-vars-env.sh ~/tw/tw-head-env.sh \
            rocky@${TW_HEAD_FIP}:~/
```

The unquoted `EOF` is deliberate: the devbox's shell expands each `${...}` as it writes, so the file that lands on the head holds the *values*, not the names. (Quoting it — `<<'EOF'` — would ship eleven literal `${TW_...}` strings and every later step would silently substitute nothing. An empty variable fails the same way: §5.12's `nft` command becomes `ip saddr oif eth0` and nftables rejects it with `syntax error, unexpected oif`.) The `cat` is there because this is the one file whose contents the rest of §5 assumes without re-checking.

Then on the head, source the **entry point** — not the values file — and make it stick:

```
head$ source ~/tw-head-env.sh
head$ echo '[ -f ~/tw-head-env.sh ] && . ~/tw-head-env.sh' >> ~/.bashrc
head$ echo "${TW_CLUSTER_FQDN} on ${TW_PROV_IF}, objects at ${TW_OBJ}"
demo.openchami.cluster on eth1, objects at 172.16.0.254:7070
```

📌 **`.bashrc` names the entry point, and never anything else.** That one line is the last shell-startup edit this tutorial asks you to make on the head: §10 and §14 each add a file that `tw-head-env.sh` is already looking for, so neither of them touches `.bashrc` again. The `[ -f … ] &&` guard matters because `.bashrc` runs on **every** shell — if the file is ever missing, an unguarded `source` prints an error into the stream that `scp`, `rsync` and `ssh head '…'` are reading, and they fail with `protocol error` rather than anything that names this line.

Persisting it is not tidiness. This section takes 30–45 minutes, and an F5 tunnel reconnect (→ [`runbooks/update-tunnel-ip.md`](runbooks/update-tunnel-ip.md)) drops the SSH session and every exported variable with it — mid-quadlet, the failure looks like a broken config rather than an empty variable. `.bashrc` rather than `.bash_profile` because Rocky's login shells source `.bashrc`, and so do the non-interactive `ssh head '…'` commands that later sections use.

**The naming rule, once, for the whole tutorial.** `tw-*` is a file of ours on the **devbox**, `tw-head-*` a file of ours on the **head**; anything ending `-env.sh` is **sourced**, and anything else is **run**. So `ls ~/tw-head-*-env.sh` on the head is a complete inventory of what a login shell loads — which is worth having on a machine where these files will one day sit next to somebody else's.

§5.12 discovers a seventh variable, `TW_EXT_IF`, by reading it off the running head; append that one to `~/tw-head-vars-env.sh` — the values file, not the entry point — when you get there.

## Step 5.1 — Storage directories

```
head$ sudo mkdir -p /data/oci /opt/workdir
head$ sudo chown -R rocky: /data/oci /opt/workdir
```

`/data/oci` backs the registry's volume; `/opt/workdir` is scratch space for downloads. (Upstream keeps work outside `$HOME` to avoid SELinux and container friction with home directories.)

⚠ **`/data` is not where the bulk ends up**, despite its name and despite what §4.7 used to claim. Measured on a completed head node: `/var/lib/containers` holds 2.1 GB of images, `/var/lib/versitygw/data` holds the S3 buckets, and **`/data` holds nothing** — the registry stays empty because we never push to it. The confusion is that `podman inspect versitygw` shows `bind /var/lib/versitygw/data -> /data`, so the *container's* `/data` and the host's `/data` are different directories sharing a name. If you added a Cinder volume for room, see the corrected guidance in [§4.7](04-head-node-instance.md#step-47--more-room-for-data-only-if-you-need-it) — it belongs on `/var/lib/containers`, not here.

## Step 5.2 — IP forwarding and the cluster name

```
head$ echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-forward.conf
head$ sudo sysctl --system | grep 90-forward -A1
```

The head routes between the provisioning wire and the world — compute nodes have no other way out. (§5.12 completes this with masquerading.)

```
head$ echo "${TW_HEAD_PROV_IP} ${TW_CLUSTER_FQDN}" | sudo tee -a /etc/hosts
```

`demo.openchami.cluster` is the cluster FQDN — the name on the TLS certificate and in every API URL. It must resolve *on the head itself*, because the APIs call each other by it, hence the hosts entry pointing at the provisioning address.

## Step 5.3 — The Versity S3 gateway quadlet

```
head$ cd /opt/workdir
head$ latest_versity_url=$(curl -s https://api.github.com/repos/openchami/versitygw-quadlet/releases/latest \
        | jq -r '.assets[] | select(.name | endswith("'"$(rpm --eval '%dist')"'.noarch.rpm")) | .browser_download_url')
head$ curl -L "$latest_versity_url" -o versitygw.rpm
head$ sudo dnf install -y ./versitygw.rpm
```

The `jq` line asks GitHub for the newest release and picks the `.el9.noarch.rpm` asset (`rpm --eval '%dist'` expands to `.el9` here). `noarch` because a quadlet is just text files — this one is architecture-independent, unlike §5.11's CLI.

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

Read it as: "run `registry:latest`, persist its data in `/data/oci`, publish port 5000, restart always." The `:Z` suffix relabels the volume for SELinux. This file *is* the service definition — that's a quadlet.

## Step 5.5 — Start the S3 gateway and registry

🔀 **Deviation — do this first, or the last command fails.** `versitygw-bootstrap` creates its buckets with the `aws` CLI and supplies no region, so botocore falls through its resolution chain to the **EC2 instance metadata service** — which on OpenStack answers, with the availability zone. botocore then derives a region by stripping the AZ's last character, correct for `us-east-1a` → `us-east-1` and useless for a DL zone name:

```
Provided region_name 'DL-Rack-' doesn't match a supported format.
```

`DL-Rack-5` minus its last character is `DL-Rack-`, and a trailing hyphen is an illegal DNS label — the region is substituted into an endpoint hostname, so botocore refuses it. The service exits 255 and, because the script runs under `set -euo pipefail`, stops at the first bucket. This is an assumption in the AWS SDK meeting OpenStack's AZ naming; nothing is wrong with OpenCHAMI. Pre-empt it with a drop-in:

```
head$ sudo mkdir -p /etc/systemd/system/versitygw-bootstrap.service.d
head$ sudo tee /etc/systemd/system/versitygw-bootstrap.service.d/10-aws-region.conf <<'EOF'
[Service]
Environment=AWS_EC2_METADATA_DISABLED=true
Environment=AWS_REGION=us-east-1
Environment=AWS_DEFAULT_REGION=us-east-1
EOF
```

`AWS_EC2_METADATA_DISABLED=true` is the fix that matters — it stops botocore consulting the metadata service at all, so no AZ name can be mangled into a region. The region variables then supply the value the **gateway** expects: versitygw runs with `VGW_REGION=us-east-1`, and because the region forms part of the SigV4 credential scope, a mismatch is rejected as `AuthorizationHeaderMalformed`. So `us-east-1` is not a placeholder you may substitute freely — it is the same value §8.3 sets for your interactive shell, and all of them must agree. Both spellings because CLI v1 reads `AWS_DEFAULT_REGION` and v2 reads `AWS_REGION`.

⚠ **Only the systemd unit needs this.** §8.3's `aws configure set region us-east-1` already covers commands you type yourself. The unit is exposed precisely because it runs with systemd's environment rather than yours.

📗 The full write-up — why it is availability-zone-dependent, so a colleague on another rack may never see it, plus the alternatives and a read-only proof that the fix cascades nowhere — is [`issues/001`](issues/001-versitygw-bootstrap-aws-region.md).

```
head$ sudo systemctl daemon-reload
head$ sudo systemctl start registry.service
head$ sudo systemctl enable --now versitygw-gensecrets.service
head$ sudo systemctl start versitygw.service
head$ sudo systemctl enable --now versitygw-bootstrap.service
```

**If you hit the failure before adding the drop-in**, add it now and `sudo systemctl restart versitygw-bootstrap.service`. Re-running is safe — the script is idempotent by design: per-user credentials persist in `/etc/versitygw/users.d/<user>.env`, and both the IAM user and the bucket are existence-checked before creation.

In order: `daemon-reload` makes systemd generate services from the quadlet files; `versitygw-gensecrets` is a one-shot that mints S3 credentials into `/etc/versitygw/secrets.env` (§8 reads them); then the gateway; then a one-shot that bootstraps its users. Quadlet-generated services can be `start`ed but not `enable`d — the generator wires their boot-time behaviour instead.

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

Look at what arrived before starting anything:

```
head$ ls /etc/containers/systemd/    # ~18 quadlets: smd, bss, coresmd-*, haproxy,
                                     # postgres, step-ca, hydra*, opaal*, acme-*,
                                     # cloud-init-server…
head$ ls /etc/openchami/configs/     # coredhcp.yaml, Corefile, openchami.env
```

## Step 5.7 — Configure CoreDHCP

Replace `/etc/openchami/configs/coredhcp.yaml` wholesale. **Note the interface name** — this is the one line that differs from the libvirt lab:

```
head$ sudo tee /etc/openchami/configs/coredhcp.yaml > /dev/null << EOF
server4:
  listen:
    - "%${TW_PROV_IF}"
  plugins:
    - server_id: ${TW_HEAD_PROV_IP}
    - dns: ${TW_HEAD_PROV_IP}
    - router: ${TW_HEAD_PROV_IP}
    - netmask: 255.255.255.0
    - coresmd: https://${TW_CLUSTER_FQDN}:8443 http://${TW_HEAD_PROV_IP}:8081 /root_ca/root_ca.crt 30s 1h false
    - bootloop: /tmp/coredhcp.db default 5m 172.16.0.200 172.16.0.250
EOF
head$ cat /etc/openchami/configs/coredhcp.yaml    # confirm real values, not empty strings
```

Field by field — this file is the heart of the provisioning wire:

- **`listen: "%eth1"`** — bind to the provisioning NIC **only**, using whatever `TW_PROV_IF` you discovered in §4.6. Never let a provisioning DHCP server face a network you don't own. 🔀 The libvirt lab also said `%eth1`, having pinned the name via the seed ISO's `network-config`; on OpenStack the Rocky cloud image happens to produce the same name, but we *read* it rather than assuming it — a different image would silently bind this to nothing.
- **`server_id`/`dns`/`router`** — the head is everything on this wire: DHCP server, DNS server, default gateway. The `router` line is what makes §5.12's NAT reachable: nodes send off-subnet traffic to `172.16.0.254` because this told them to.
- **`coresmd: <SMD-url> <bootscript-url> <CA-path> 30s 1h false`** — the OpenCHAMI plugin. It caches SMD's inventory (refreshing every 30 s) and, when a known MAC asks, leases it *its* IP for 1 h and points its network boot at the boot-script service on `:8081`.
- **`bootloop:`** — the fallback for *unknown* MACs: a short 5-minute lease from `172.16.0.200–250` that keeps them cycling until someone registers them. A brand-new rack can be powered on and simply *wait* here. This range is why §3.2 kept those addresses outside Neutron's allocation pools.

## Step 5.8 — Configure CoreDNS

```
head$ sudo tee /etc/openchami/configs/Corefile > /dev/null << EOF
.:53 {
    ready
    prometheus 0.0.0.0:9153
    bind ${TW_HEAD_PROV_IP}

    coresmd {
        smd_url https://${TW_CLUSTER_FQDN}:8443
        ca_cert /root_ca/root_ca.crt
        cache_duration 30s
        zone openchami.cluster {
            nodes de{02d}
        }
    }
}
EOF
```

Same idea as DHCP, for names: DNS records are *generated from SMD*. The `nodes de{02d}` rule renders node 1 as `de01.openchami.cluster`.

⚠ **CoreDNS answers cluster names only.** It has no `forward` clause, so it cannot resolve `ghcr.io` or `registry.k8s.io`. Talos needs those, and §8.4 solves it by pinning public resolvers in the Talos machine config rather than by widening CoreDNS. Resist the temptation to add a `forward` here: the boot-time iPXE resolver would then be able to reach the internet, and §8 explains why that turns out not to help.

## Step 5.9 — Set the FQDN for certificates

```
head$ sudo openchami-certificate-update update ${TW_CLUSTER_FQDN}
```

This rewrites the ACME and haproxy configs to issue for our FQDN instead of the machine's hostname. It suggests restart commands — ignore them, nothing is running yet.

## Step 5.9b — Point BSS at an address a *node* can reach

The release RPM ships `/etc/openchami/configs/openchami.env` with `BSS_IPXE_SERVER=${SYSTEM_URL}`. Fix it before first start:

```
head$ sudo cp /etc/openchami/configs/openchami.env{,.bak-$(date +%F)}
head$ sudo sed -i \
    -e "s|^BSS_IPXE_SERVER=.*|BSS_IPXE_SERVER=${TW_HEAD_PROV_IP}:8081|" \
    -e 's|^BSS_CHAIN_PROTO=.*|BSS_CHAIN_PROTO=http|' \
    /etc/openchami/configs/openchami.env
head$ grep -q '^BSS_GW_URI=' /etc/openchami/configs/openchami.env \
    || echo 'BSS_GW_URI=' | sudo tee -a /etc/openchami/configs/openchami.env
head$ grep -E '^BSS_(IPXE_SERVER|CHAIN_PROTO|GW_URI)=' /etc/openchami/configs/openchami.env
BSS_IPXE_SERVER=172.16.0.254:8081
BSS_CHAIN_PROTO=http
BSS_GW_URI=
```

**What these three do.** When BSS tells a node "come back and ask again in ten seconds", it has to build a URL for the node to come back *to*. It assembles that from these three values, and every default is wrong here:

| Variable | Shipped default | Why it fails | Set to |
|---|---|---|---|
| `BSS_IPXE_SERVER` | `${SYSTEM_URL}` | an `EnvironmentFile=` performs **no variable expansion** — BSS receives the literal seven characters `${SYSTEM_URL}`, and iPXE then expands it as one of *its own* variables, which is empty. You get `https:///…` | `172.16.0.254:8081` |
| `BSS_CHAIN_PROTO` | `https` | a node has no reason to trust the head's certificate, and §5.9 issued it for the FQDN, not for a bare IP | `http` |
| `BSS_GW_URI` | *absent* → `/apis/bss` | Cray CSM's API gateway path. We have no gateway; nodes talk to BSS directly | **empty, but explicitly set** |

📌 **`BSS_GW_URI=` must be present and empty, not deleted.** BSS reads it with `os.LookupEnv`, so *set-but-empty* is honoured and only *absent* falls back to `/apis/bss`.

🛑 **Do not "fix" this by changing `SYSTEM_URL`.** It is right for what it does — it is `TW_CLUSTER_FQDN`, and `opaal.yaml` uses it four more times for OIDC endpoints while §5.9 puts it in the certificate subject names. It is simply the wrong source of truth for *this* field: it resolves only on the head, via §5.2's `/etc/hosts` line, and a node has no such entry.

⚠ **This is a "works now, fails later" fault, which is why it is fixed here rather than when you meet it.** Nothing in a *successful* boot reads this URL — it is the retry path. It stays invisible until the first time a node boots before its BSS payload exists, which is precisely when you are already debugging something else. Full write-up, including the captured failure: [issues/003](issues/003-bss-ipxe-server-unexpanded-system-url.md).

## Step 5.10 — Start OpenCHAMI

```
head$ sudo systemctl start openchami.target
```

First start pulls ~18 container images, so it can take many minutes — **be patient, and don't panic at a slow prompt**. Watch it converge in another terminal (or a `tmux` pane):

```
head$ watch systemctl list-dependencies openchami.target
```

**How you know it worked.** Two values, and only these two:

```
head$ systemctl is-active openchami.target && systemctl --failed --no-legend | wc -l
active
0
```

`active` means every dependency of the target was satisfied; `0` means nothing failed. Together, that is the control plane up.

⚠ **Do not use a count of units as the test.** `systemctl list-dependencies … | grep -c '\.service'` returns **19 whether the services are running or dead** — it lists what is *declared*, not what is up. It is a useful check that the release RPM installed the right set, and no kind of check that the set works. The §5 checkpoint says more about this, including why `podman ps` shows 13 containers rather than 19.

⚠ **Gotcha.** If `systemctl start` times out or your SSH session dies, the start usually *continues server-side* — check `systemctl is-active openchami.target` before assuming failure or re-running anything.

⚠ **Gotcha.** The *very first* start quite often fails with `A dependency job for openchami.target failed` — a startup race while images are still being pulled. It happened on **both** of our clean libvirt runs, so expect it. Nothing is broken: check `systemctl --failed` (usually empty), wait a minute, and run `sudo systemctl start openchami.target` again. The stragglers — typically the certificate chain and haproxy — come up on the second attempt.

⚠ **Gotcha — SMD can come up before the auth keys exist.** If the first start was messy, SMD may have started before the OIDC stack published its signing keys. Then every *authenticated* request (e.g. §6's discovery) fails with `500 Internal Server Error` while unauthenticated reads work fine, and `podman logs smd` shows a `jwtauth … nil pointer` panic. Fix: `sudo systemctl restart smd`.

⚠ **Gotcha — restart coresmd after any certificate change.** The coresmd containers read the root CA **once at startup**. If you re-run the certificate update (or step-ca regenerates its CA) while they're running, they fail TLS to SMD forever after. The symptom is the one you'll meet in §10: nodes get `172.16.0.200`-range *bootloop* leases instead of their real IPs, and `journalctl -u coresmd-coredhcp` shows `x509: certificate signed by unknown authority`. Fix: `sudo systemctl restart coresmd-coredhcp coresmd-coredns`.

A theme is emerging: several OpenCHAMI services read security material **once at startup**. After a rocky first start, restarting the confused service is cheap and safe.

## Step 5.11 — Install the `ochami` CLI

```
head$ ochami_url=$(curl -s https://api.github.com/repos/OpenCHAMI/ochami/releases/latest \
        | jq -r '.assets[] | select(.name | endswith("amd64.rpm")) | .browser_download_url')
head$ curl -L -o ochami.rpm "$ochami_url"
head$ sudo dnf install -y ./ochami.rpm
head$ ochami version | head -1
```

🔀 **Deviation from the libvirt lab.** The lab filtered for `arm64.rpm`; we are x86_64, so `amd64.rpm` — which is also what the upstream tutorial says. This is the first of several places where the lab's aarch64-isms flip back.

Point it at our cluster (`echo y` answers its "create the config file?" prompt):

```
head$ echo y | sudo ochami config cluster set --system --default \
        ${TW_CLUSTER_NAME} cluster.uri https://${TW_CLUSTER_FQDN}:8443
head$ ochami config show
clusters:
    - cluster:
        enable-auth: true
        uri: https://demo.openchami.cluster:8443
      name: demo
default-cluster: demo
log:
    color: auto
    format: rfc3339
    level: warning
timeout: 30s
```

Three things in that output are worth reading rather than skimming:

- **`name: demo` and the URI** come from `TW_CLUSTER_NAME` and `TW_CLUSTER_FQDN`. If either is wrong here, every `ochami` call in §§6 and 9 goes to the wrong place or fails TLS.
- **`default-cluster: demo`** is what `--default` bought: without it every command would need `--cluster demo`.
- **`enable-auth: true`** is why §5.13 exists. The CLI will attach a bearer token to writes, and refuse without one.

**`--system` writes `/etc/ochami/config.yaml`, not `~/.config/ochami/`** — which is why the command needs `sudo` and why the config is visible to any user on the head. Check with `ls -la /etc/ochami/`; a per-user file would silently take precedence if one ever appeared.

Recorded from a real run: `ochami version` → `0.10.0`.

## Step 5.12 — Make the head a NAT router

🔀 **Deviation — this step does not exist in the libvirt lab's §5.** It comes from [the lab's Talos follow-on §1](../ochami-macos-libvirt-talos/01-network-prerequisite.md), because **Talos is not self-contained**: on first boot it must pull its installer image (`ghcr.io/siderolabs/installer`) and all the Kubernetes images (`registry.k8s.io`). None of those live on the head. §5.7 already told every node that its default route and DNS are `172.16.0.254`; the head just isn't forwarding yet.

Identify the external interface — the one with the `192.168.200.x` address:

```
head$ ip -brief addr | grep -E '192\.168\.200'
head$ export TW_EXT_IF=eth0          # YOUR value
head$ echo "export TW_EXT_IF=${TW_EXT_IF}" >> ~/tw-head-vars-env.sh
head$ ping -c1 1.1.1.1
```

This is a **head-node** variable — it names an interface on the head, discovered here rather than in §4, so it is not in the devbox's `tw-vars-env.sh` and should not be added there.

Forwarding is already on from §5.2. Add masquerading. **Check which mechanism you have first** — the firewalld branch needs the tools *installed* as well as the service *running*, and on the Rocky 9.6 cloud image neither is true:

```
head$ command -v firewall-cmd    # silent = not installed
head$ systemctl is-active firewalld
inactive
```

Take the firewalld branch only if the first command prints a path **and** the second says `active`. Anything else, use nftables. (Don't chain these with `||`: `is-active` exits non-zero for `inactive`, so you get the status *and* the fallback message and it reads like a contradiction.)

**If `firewalld` is running:**

```
head$ sudo firewall-cmd --permanent --add-masquerade
head$ sudo firewall-cmd --reload
```

`--add-masquerade` both enables masquerading and permits forwarding for the default zone, where both interfaces sit.

**Otherwise, use nftables — but not the `ip nat` table.** Podman's container networking (netavark, via the `iptables-nft` compatibility layer) already owns that table, and `nft` says so itself:

```
head$ sudo nft list table ip nat | head -1
# Warning: table ip nat is managed by iptables-nft, do not touch!
```

Adding our chain there would work today and is a latent hazard: podman rewrites those rules whenever container networking changes, and the DNAT entries for `:5000` and `:7070` live in the same table. Put our rule in **its own table** instead:

```
head$ sudo nft add table ip twnat
head$ sudo nft 'add chain ip twnat postrouting { type nat hook postrouting priority srcnat ; }'
head$ sudo nft add rule ip twnat postrouting ip saddr ${TW_PROV_CIDR} oif "${TW_EXT_IF}" masquerade
head$ sudo nft list table ip twnat
```

Two tables may both hook `postrouting`; both are evaluated. There is no ambiguity because ours matches only `172.16.0.0/24` sources while netavark's match `10.88.0.0/16` and `10.89.1.0/24` — disjoint sets, so no ordering question arises.

To persist across reboots, write a ruleset that declares **only our table**:

```
head$ sudo tee /etc/sysconfig/nftables.conf > /dev/null <<'EOF'
#!/usr/sbin/nft -f
# TechWatch: NAT for the OpenCHAMI provisioning wire (§5.12).
# Deliberately in its own table — `table ip nat` belongs to iptables-nft.
# add-then-delete makes this file idempotent without flushing anything else.
add table ip twnat
delete table ip twnat
table ip twnat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    ip saddr 172.16.0.0/24 oif "eth0" masquerade
  }
}
EOF
head$ sudo systemctl enable --now nftables
```

⚠ **Never put `flush ruleset` in that file.** It is the conventional first line of a standalone nftables config and here it would delete podman's rules on every boot, taking the registry and S3 gateway's port forwarding with them. The `add`-then-`delete` pair above is the narrow equivalent: it guarantees a clean slate for `twnat` alone. Substitute your own `TW_PROV_CIDR` and `TW_EXT_IF` — the heredoc is quoted, so it does **not** expand variables.

📗 Full write-up of why the `ip nat` table is off limits: [`issues/002`](issues/002-nftables-table-owned-by-podman.md).

⚠ **This step only works because §3.4 disabled port security** on the head's provisioning port. Masquerading means emitting packets whose source IP is not the port's own — precisely what Neutron's anti-spoofing drops. If you skipped that flag, everything here will appear to succeed and Talos will still hang at `downloading installer` in §10.

Verify what you can now (the real proof comes in §10):

```
head$ sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 1
```

**Run only the check for the branch you took.** The other one is not a failure, it is a different mechanism:

```
head$ sudo firewall-cmd --query-masquerade        # firewalld path only
yes
```

```
head$ sudo nft list chain ip twnat postrouting    # nftables path only
table ip twnat {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr 172.16.0.0/24 oif "eth0" masquerade
	}
}
```

On the Rocky 9.6 cloud image the first prints `sudo: firewall-cmd: command not found`, because firewalld is not installed — see the branch check at the top of this step.

⚠ **And confirm you did not disturb podman**, since the whole point of the separate table was to leave it alone:

```
head$ sudo nft list table ip nat | grep -c NETAVARK   # -> non-zero: podman's rules intact
head$ sudo podman ps --format '{{.Names}}' | wc -l    # -> 13, unchanged
head$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7070
403
```

⚠ **`403` is the healthy answer**, and do not test this with `curl -f`. An unauthenticated `GET /` on an S3 endpoint is *supposed* to be refused, so `-f` (fail on status ≥ 400) reports a working gateway as broken. Test that it *answers*, not that it answers 200 — or use the authenticated call, which is the real proof:

```
head$ sudo AWS_EC2_METADATA_DISABLED=true AWS_REGION=us-east-1 \
        aws --profile vgw-root --endpoint-url http://127.0.0.1:7070 s3 ls
2026-08-03 16:03:48 fabricmanager-bucket
2026-08-03 16:03:46 slurmd-bucket
```

## Step 5.13 — Get an access token

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
```

The variable name is `<CLUSTERNAME>_ACCESS_TOKEN` upper-cased — the CLI finds it automatically. **Tokens last one hour**: whenever `ochami` complains about authentication, re-run this line. It appears again at the start of §6 and §9 for exactly that reason.

## ✅ Checkpoint

```
head$ systemctl list-dependencies openchami.target --plain | grep -c '\.service'
19
```

⚠ **That count proves the RPM installed the right units — not that any of them run.** `list-dependencies` prints *declared* dependencies, so it returns 19 just as happily with every service dead. Two commands that do check state:

```
head$ systemctl is-active openchami.target && systemctl --failed --no-legend | wc -l
active
0
```

An empty `--failed` is the assertion that matters. To see them individually:

```
head$ systemctl list-dependencies openchami.target --plain | grep '\.service' \
    | tr -d ' |─├└' \
    | while read -r u; do printf '%-34s %s\n' "$u" "$(systemctl is-active $u)"; done
acme-deploy.service                active
…
step-ca.service                    active
```

⚠ **Seven of the nineteen are `Type=oneshot`** — `acme-register`, `acme-deploy`, `openchami-cert-trust`, `smd-init`, `bss-init`, `hydra-migrate`, `hydra-gen-jwks`. They ran, succeeded and exited; they read `active` only because `RemainAfterExit=yes`. So `podman ps` shows **13** containers, not 20:

```
head$ sudo podman ps --format '{{.Names}}' | sort | tr '\n' ' '
bss cloud-init-server coresmd-coredhcp coresmd-coredns haproxy hydra
opaal opaal-idp postgres registry smd step-ca versitygw
```

Eleven long-running OpenCHAMI containers plus `registry` and `versitygw` from §5.5 — those two are **not** part of `openchami.target`, which is why §5.5 checks them separately. For a oneshot, `active` means "completed successfully", not "running": don't read the difference as a fault.

Finally, the two APIs — the only check that exercises TLS, haproxy, the certificate chain and the database together:

```
head$ ochami bss service status | jq -c .
{"bss-status":"running"}

head$ ochami smd service status | jq -c .
{"code":0,"message":"HSM is healthy"}
```

Eighteen services and two healthy APIs: the OpenCHAMI control plane is up. (`HSM` = Hardware State Manager, SMD's original Cray name.)

## Common failures

| Symptom | Cause / fix |
|---|---|
| `versitygw-bootstrap` exits 255 with `Provided region_name 'DL-Rack-' doesn't match a supported format` | botocore derived an AWS region from the OpenStack AZ via the metadata service — add §5.5's drop-in and restart the service. Full write-up: [`issues/001`](issues/001-versitygw-bootstrap-aws-region.md) |
| haproxy fails: `could not resolve address 'opaal'` | startup race, documented upstream: `sudo systemctl restart opaal haproxy` |
| TLS errors from `ochami` | FQDN mismatch: re-run §5.9, then `sudo systemctl restart acme-deploy`, and see the coresmd gotcha in §5.10 |
| a service stays `activating` for ages | it's pulling its image. `journalctl -eu <service>` to confirm, then wait |
| `500 Internal Server Error` on any authenticated call | the SMD/OIDC race in §5.10: `sudo systemctl restart smd` |
| `coredhcp` won't start: `no such device` | `TW_PROV_IF` is wrong in §5.7 — check `ip -brief addr` and rewrite the file |
| CoreDHCP starts but the wire is silent | it bound to the wrong interface, or Neutron's DHCP is still enabled on the subnet (§3 checkpoint) |

Next: [§6 — Telling OpenCHAMI about our nodes](06-node-inventory.md)
