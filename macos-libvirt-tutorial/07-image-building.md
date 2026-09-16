# §7 — Building the compute node image

*(Upstream: guide §3.2 / tutorial Part 2.3–2.4. Time: ~30–60 minutes,
almost all of it package downloads inside the builds. On the head node.)*

## Concepts

**Diskless means the OS is a file.** Our compute node has no disk: at boot
it downloads a **SquashFS** (a compressed, read-only filesystem image) over
HTTP, keeps it in RAM, and lays a **tmpfs overlay** on top so the running
system *feels* writable — but every write vanishes at reboot. One image
file, any number of identical nodes; "state drift" becomes impossible. The
initramfs does the magic via dracut's `dmsquash-live` + `livenet` modules —
which is why you'll see us add them explicitly below.

**Images are built in layers, like containers.** OpenCHAMI's
[image-builder](https://github.com/OpenCHAMI/image-builder) takes a YAML
recipe (packages, repos, commands), builds a rootfs with `dnf
--installroot` inside a container, and can publish the result two ways:

- to the **OCI registry** (:5000) as a container image — so a later recipe
  can say `parent: <that image>` and build *on top* of it;
- to **S3** (:7070) as the bootable triplet: SquashFS + kernel + initramfs.

We build three layers — the upstream tutorial's own stack:

| Layer | Parent | Published to | Adds |
|---|---|---|---|
| `rocky-base` | scratch | registry | minimal Rocky 9 + kernel + boot-capable initramfs |
| `compute-base` | rocky-base | registry + S3 | a few cluster tools (also: proof layering works) |
| `compute-debug` | compute-base | S3 | a **console-loginable user** (`testuser`/`testuser`) |

Why a debug layer? Until cloud-init works end-to-end (§9–10) you cannot
SSH into a booted node. A baked-in console user is your foothold for
debugging the boot chain itself. Boot debug first, switch to clean images
later — deliberate upstream practice.

## Step 7.1 — `regctl`, a registry client

```
head$ curl -sL https://github.com/regclient/regclient/releases/latest/download/regctl-linux-arm64 \
        -o /tmp/regctl && sudo install -m 0755 /tmp/regctl /usr/local/bin/regctl
head$ /usr/local/bin/regctl registry set --tls disabled demo.openchami.cluster:5000
```

(Used only to *inspect* the registry; the builds push on their own. TLS
disabled because our registry is plain HTTP. 🔀 upstream fetches the
`amd64` binary — we need `arm64`. We call it by full path throughout:
`sudo`'s `secure_path` on Rocky doesn't include `/usr/local/bin`.)

## Step 7.2 — S3 client configuration

The Versity gateway minted credentials in §5.5; pull them into your shell
and write the two client configs (`s3cmd` for everyday use, `aws` for one
ACL operation below):

```
head$ source <(sudo cat /etc/versitygw/secrets.env)
head$ cat > ~/.s3cfg << EOF
host_base = demo.openchami.cluster:7070
host_bucket = demo.openchami.cluster:7070
bucket_location = us-east-1
use_https = False
access_key = ${ROOT_ACCESS_KEY}
secret_key = ${ROOT_SECRET_KEY}
signature_v2 = False
EOF
head$ aws configure set aws_access_key_id "${ROOT_ACCESS_KEY}"
head$ aws configure set aws_secret_access_key "${ROOT_SECRET_KEY}"
head$ aws configure set region us-east-1
```

Wait — `aws` isn't installed yet:

```
head$ sudo dnf install -y epel-release && sudo dnf install -y s3cmd awscli
```

(EPEL first: that's where `s3cmd` lives.)

## Step 7.3 — The `boot-images` bucket

```
head$ s3cmd mb s3://boot-images
head$ s3cmd setownership s3://boot-images BucketOwnerPreferred
head$ aws s3api put-bucket-acl --bucket boot-images --acl public-read --endpoint-url http://localhost:7070
head$ cat > /opt/workdir/s3-public-read-boot.json << 'EOF'
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Effect":"Allow",
      "Principal":"*",
      "Action":["s3:GetObject"],
      "Resource":["arn:aws:s3:::boot-images/*"]
    }
  ]
}
EOF
head$ s3cmd setpolicy /opt/workdir/s3-public-read-boot.json s3://boot-images \
        --host=demo.openchami.cluster:7070 --host-bucket=demo.openchami.cluster:7070
```

Public-read matters: booting nodes fetch kernels anonymously. (The `aws`
detour exists because Versity's ACL XML dialect is incompatible with
`s3cmd setacl` — an upstream-documented quirk. 🔀 The guide also creates an
`efi` bucket; nothing ever reads it, we skip it.)

## Step 7.4 — The three recipes

```
head$ sudo mkdir -p /etc/openchami/data/images
```

Layer 1 — `rocky-base`:

```
head$ sudo tee /etc/openchami/data/images/rocky-base-9.yaml > /dev/null << 'EOF'
options:
  layer_type: 'base'
  name: 'rocky-base'
  publish_tags: '9'
  pkg_manager: 'dnf'
  parent: 'scratch'
  publish_registry: 'demo.openchami.cluster:5000/demo'
  registry_opts_push:
    - '--tls-verify=false'

repos:
  - alias: 'Rocky_9_BaseOS'
    url: 'https://rockylinux.mirrorservice.org/pub/rocky/9/BaseOS/aarch64/os/'
    gpg: 'https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9'
  - alias: 'Rocky_9_AppStream'
    url: 'https://rockylinux.mirrorservice.org/pub/rocky/9/AppStream/aarch64/os/'
    gpg: 'https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9'

package_groups:
  - 'Minimal Install'
  - 'Development Tools'

packages:
  - chrony
  - cloud-init
  - dracut-live
  - kernel
  - rsyslog
  - sudo
  - wget

cmds:
  - cmd: 'dracut --add "dmsquash-live livenet network-manager" --kver $(basename /lib/modules/*) -N -f --logfile /tmp/dracut.log 2>/dev/null'
  - cmd: 'echo DRACUT LOG:; cat /tmp/dracut.log'
EOF
```

The important lines: `parent: scratch` (built from nothing but the repos);
**aarch64** repo URLs (🔀 upstream hardcodes x86_64 — this is the single
most important ARM edit in the whole tutorial); `dracut-live` + the
`dracut --add "dmsquash-live livenet …"` command, which rebuild the
initramfs so it *can* fetch a SquashFS over the network at boot; and
`cloud-init`, so the booted node can talk to §9's server.

Layer 2 — `compute-base`:

```
head$ sudo tee /etc/openchami/data/images/compute-base-rocky9.yaml > /dev/null << 'EOF'
options:
  layer_type: 'base'
  name: 'compute-base'
  publish_tags:
    - 'rocky9'
  pkg_manager: 'dnf'
  parent: 'demo.openchami.cluster:5000/demo/rocky-base:9'
  registry_opts_pull:
    - '--tls-verify=false'

  publish_s3: 'http://demo.openchami.cluster:7070'
  s3_prefix: 'compute/base/'
  s3_bucket: 'boot-images'

  publish_registry: 'demo.openchami.cluster:5000/demo'
  registry_opts_push:
    - '--tls-verify=false'

repos:
  - alias: 'Epel9'
    url: 'https://www.mirrorservice.org/sites/dl.fedoraproject.org/pub/epel/9/Everything/aarch64/'
    gpg: 'https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9'

packages:
  - boxes
  - cowsay
  - figlet
  - fortune-mod
  - git
  - nfs-utils
  - tcpdump
  - traceroute
  - vim
EOF
```

Note `parent:` pointing at layer 1 *in our registry*, and the new
`publish_s3` block — this layer is the first bootable one. (Yes, `cowsay`:
upstream's package list, kept for fidelity and morale.)

Layer 3 — `compute-debug`:

```
head$ sudo tee /etc/openchami/data/images/compute-debug-rocky9.yaml > /dev/null << 'EOF'
options:
  layer_type: base
  name: compute-debug
  publish_tags:
    - 'rocky9'
  pkg_manager: dnf
  parent: 'demo.openchami.cluster:5000/demo/compute-base:rocky9'
  registry_opts_pull:
    - '--tls-verify=false'

  publish_s3: 'http://demo.openchami.cluster:7070'
  s3_prefix: 'compute/debug/'
  s3_bucket: 'boot-images'

packages:
  - shadow-utils

cmds:
  - cmd: "useradd -mG wheel -p '$6$VHdSKZNm$O3iFYmRiaFQCemQJjhfrpqqV7DdHBi5YpY6Aq06JSQpABPw.3d8PQ8bNY9NuZSmDv7IL/TsrhRJ6btkgKaonT.' testuser"
EOF
```

The hash is upstream's, for the password `testuser`.

## Step 7.5 — Build, three times

```
head$ source <(sudo cat /etc/versitygw/secrets.env)   # if you opened a new shell
head$ for cfg in rocky-base-9 compute-base-rocky9 compute-debug-rocky9; do
        sudo podman run --rm --device /dev/fuse --network host \
          -e S3_ACCESS="${ROOT_ACCESS_KEY}" -e S3_SECRET="${ROOT_SECRET_KEY}" \
          -v /etc/openchami/data/images/${cfg}.yaml:/home/builder/config.yaml \
          ghcr.io/openchami/image-build-el9:v0.1.2 \
          image-build --config config.yaml --log-level DEBUG || break
      done
```

What the flags do: `--device /dev/fuse` lets the builder mount overlay
filesystems; `--network host` lets it reach the registry and S3 on
localhost addresses; the `-e S3_*` pass the credentials for pushing.

Expectations while it runs: layer 1 downloads ~700 packages (the
`Development Tools` group is chunky) and takes tens of minutes; the others
are quicker. **Log lines prefixed `ERROR -` are mostly not errors** —
upstream routes dnf's whole output through the error logger (e.g.
`ERROR - Unable to detect release version` is normal). A real failure ends
with `Error building layer` and a non-zero exit.

## ✅ Checkpoint

```
head$ /usr/local/bin/regctl repo ls demo.openchami.cluster:5000
demo/compute-base
demo/rocky-base

head$ s3cmd ls -Hr s3://boot-images | awk '{print $3, $4}'
1439M s3://boot-images/compute/base/rocky9.8-compute-base-rocky9
1439M s3://boot-images/compute/debug/rocky9.8-compute-debug-rocky9
  58M s3://boot-images/efi-images/compute/base/initramfs-5.14.0-...aarch64.img
  12M s3://boot-images/efi-images/compute/base/vmlinuz-5.14.0-...aarch64
  58M s3://boot-images/efi-images/compute/debug/initramfs-5.14.0-...aarch64.img
  12M s3://boot-images/efi-images/compute/debug/vmlinuz-5.14.0-...aarch64
```

Two OCI layers in the registry; in S3, per bootable layer: the SquashFS
plus its kernel and initramfs (sizes/versions will drift with Rocky
updates — `aarch64` in the names is what you're checking for).

## Common failures

| Symptom | Cause / fix |
|---|---|
| downloads crawl / `No more mirrors to try` mid-build | your network path to a mirror is congested; see §11 (this is why our recipes already point at the UK Mirror Service rather than dl.rockylinux.org) |
| `manifest unknown` pulling the parent | previous layer never pushed — check its build actually succeeded before rebuilding |
| build dies instantly, `config.yaml not found` | the `-v` mount path doesn't exist — recheck step 7.4 paths |

Next: [§8 — Boot parameters](08-boot-parameters.md)
