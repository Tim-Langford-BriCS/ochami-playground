# §8 — Talos assets and machine config

*(Time: ~20 minutes. On the head node. This replaces both the upstream tutorial's image build **and** its cloud-init configuration — Talos needs neither.)*

This section reads seven variables, all already in the `tw-head-vars-env.sh` §5 put on the head. Source the entry point and check they arrived — a heredoc built from an empty variable produces a file that looks plausible and boots nothing:

```
head$ source ~/tw-head-env.sh
head$ echo "${TW_ARCH} ${TW_OBJ} ${TW_TALOS_VERSION} ${TW_CONSOLE} ${TW_CP_IP}"
amd64 172.16.0.254:7070 v1.13.0 ttyS0,115200 172.16.0.1

head$ echo "${TW_CLUSTER_FQDN} ${TW_HEAD_PROV_IP}"
demo.openchami.cluster 172.16.0.254
```

The second pair is easy to overlook and fails quietly: `TW_CLUSTER_FQDN` builds the S3 client config in §8.2, and `TW_HEAD_PROV_IP` becomes a certificate SAN in §8.6 — an empty one gives you a config that validates and a Talos API you cannot reach.

(`TW_TALOS_VERSION` is `v1.13.0`, the latest stable v1.13.x. If §5's `.bashrc` line is in place the `source` is redundant — run it anyway; it costs nothing and the `echo` is the part that matters.)

## Concepts

**There is no image to build.** Talos publishes a ready-made `vmlinuz` and `initramfs.xz` per architecture, and the initramfs *is* a complete, immutable operating system. Compare with the libvirt lab's §7, which spent 30–60 minutes running `image-builder` over `dnf` repositories to produce a SquashFS. We download two files.

Our jobs here are only:

1. put those two files where booting nodes can fetch them — the head's object store from §5.5;
2. generate the **machine config**: the declarative YAML that replaces cloud-init. `talosctl gen config` produces three files:
   - `controlplane.yaml` — for the node running the Kubernetes control plane,
   - `worker.yaml` — for nodes that just run workloads,
   - `talosconfig` — your *client* credentials for talking to the cluster.

The config is fetched at boot via the `talos.config` kernel argument, which §9 puts into the BSS payload.

🔀 **Deviation — everything here is x86_64.** The libvirt lab was aarch64 throughout: `arm64` assets, `ttyAMA0` console, `:7070` object store. We keep `:7070` (Versity, §5.5) but flip the architecture and console to match the PTR's Intel and AMD hardware. Those two substitutions are the entire difference.

## Step 8.1 — Get `talosctl` and `kubectl` on the head

```
head$ curl -sL https://github.com/siderolabs/talos/releases/download/${TW_TALOS_VERSION}/talosctl-linux-${TW_ARCH} \
        -o /tmp/talosctl && sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
head$ talosctl version --client
```

`talosctl` is the *only* way to administer Talos nodes — there is no SSH, no console login and no shell. Grab `kubectl` too, for §10 onwards:

```
head$ curl -sL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/${TW_ARCH}/kubectl" \
        -o /tmp/kubectl && sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
head$ kubectl version --client
```

> **Why on the head and not the devbox?** The Talos API (:50000) and the Kubernetes API (:6443) are served by nodes on the provisioning wire, which has no route from outside. The head is the only machine that can reach them. If you want `kubectl` on your laptop later, tunnel through the head — §11 shows how.

## Step 8.2 — S3 client credentials

The Versity gateway minted credentials in §5.5. Pull them into your shell and write the client configs:

```
head$ sudo dnf install -y epel-release && sudo dnf install -y s3cmd awscli
head$ source <(sudo cat /etc/versitygw/secrets.env)
head$ cat > ~/.s3cfg << EOF
host_base = ${TW_CLUSTER_FQDN}:7070
host_bucket = ${TW_CLUSTER_FQDN}:7070
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

(EPEL first: that's where `s3cmd` lives. The `aws` CLI is needed for exactly one ACL operation below, because Versity's ACL XML dialect is incompatible with `s3cmd setacl` — an upstream-documented quirk.)

## Step 8.3 — The `boot-images` bucket, public-read

```
head$ s3cmd mb s3://boot-images
head$ s3cmd setownership s3://boot-images BucketOwnerPreferred
head$ aws s3api put-bucket-acl --bucket boot-images --acl public-read \
        --endpoint-url http://localhost:7070
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
        --host=${TW_CLUSTER_FQDN}:7070 --host-bucket=${TW_CLUSTER_FQDN}:7070
```

**Public-read matters.** A booting node fetches its kernel over plain HTTP, by raw IP, with no credentials and no DNS — because at that point in the boot it has none of those things. Anonymous read is not laziness; it is the only thing that works.

⚠ **And it is a real exposure, which is acceptable only here.** Anyone on the provisioning wire can read this bucket, and §8.6 puts *cluster secrets* in it. The wire is isolated and ours alone, so the blast radius is nil. On the PTR, don't do this — see the ⚠ in §8.6.

## Step 8.4 — Download the Talos assets and publish them

```
head$ curl -sL https://github.com/siderolabs/talos/releases/download/${TW_TALOS_VERSION}/vmlinuz-${TW_ARCH} \
        -o /tmp/vmlinuz-${TW_ARCH}
head$ curl -sL https://github.com/siderolabs/talos/releases/download/${TW_TALOS_VERSION}/initramfs-${TW_ARCH}.xz \
        -o /tmp/initramfs-${TW_ARCH}.xz
head$ s3cmd put /tmp/vmlinuz-${TW_ARCH}      s3://boot-images/talos/vmlinuz-${TW_ARCH}
head$ s3cmd put /tmp/initramfs-${TW_ARCH}.xz s3://boot-images/talos/initramfs-${TW_ARCH}.xz
```

> **Where Image Factory fits.** [Image Factory](https://docs.siderolabs.com/talos/v1.13/learn-more/image-factory) decides *what's in the image* — a **schematic** is Talos base plus system extensions (`iscsi-tools`, GPU drivers, `qemu-guest-agent`) plus extra kernel args. The object store decides *where it's served from*. They are orthogonal, so Factory is **a source for the two files above, not a replacement for this step**. When §16 adds accelerator drivers, you build a schematic and download *its* assets instead of the GitHub ones: `https://factory.talos.dev/image/<schematic-id>/${TW_TALOS_VERSION}/kernel-${TW_ARCH}` and `.../initramfs-${TW_ARCH}.xz` (the vanilla schematic is `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba`), then `s3cmd put` them exactly as above.
>
> **Why not point BSS straight at `factory.talos.dev` and skip the upload?** We tried this in the libvirt lab. It does not work, for two reasons hit in order:
> 1. **DNS.** iPXE resolves names using the DHCP-supplied server — which is OpenCHAMI's CoreDNS, and it answers only cluster names (§5.8). `factory.talos.dev` fails with iPXE error `0x3e11618e` *(DNS name does not exist)*. You could add a `forward` clause to the Corefile, but then you hit:
> 2. **TLS.** This iPXE build reports `HTTPS` in its features but its minimal TLS stack cannot negotiate a cipher with Factory's modern server — the fetch dies with `0x410de18f` *(server sent a fatal TLS alert)*. Not fixable without rebuilding iPXE, and its cipher support is too limited to rely on even then.
>
> Plus every node would re-pull ~80 MB over the internet on every boot. **Conclusion: let the head fetch from Factory — it has a real TLS stack — and serve to nodes over plain HTTP by raw IP.** That is this step. It is also why §5.8 tells you to resist adding a `forward` to CoreDNS.

## Step 8.5 — Generate the machine config

The Kubernetes control-plane endpoint is `tw-cp1`'s SMD-mapped address on the Kubernetes API port:

```
head$ mkdir -p ~/talos && cd ~/talos
head$ talosctl gen config ochami-talos https://${TW_CP_IP}:6443 \
        --install-image ghcr.io/siderolabs/installer:${TW_TALOS_VERSION}
generating PKI and tokens
Created /home/rocky/talos/controlplane.yaml
Created /home/rocky/talos/worker.yaml
Created /home/rocky/talos/talosconfig
```

🔀 **Deviation — no `--install-disk`.** The libvirt lab passed `--install-disk /dev/vda`. Our node does have exactly one disk, so a fixed name would probably work — but that disk is the one currently running iPXE (§7), and getting this wrong doesn't fail loudly: it leaves the node booting iPXE for ever. We state the intent as a *disk selector* instead, in the next step, and say explicitly that it must be wiped. (`gen config` still writes a default `disk: /dev/sda` into the output — harmless, and explained at the checkpoint.)

## Step 8.6 — Patch the config: disk selection, DNS, and the console

Three patches. Write them all, then apply them together.

**Disk selection**, and — the part that actually matters here — **wiping**:

```
head$ cat > ~/talos/install-patch.yaml << 'EOF'
machine:
  install:
    # One disk, 30 GB, and it is the disk currently holding iPXE (§7).
    # Match on size rather than /dev/vda so this survives a bus change.
    diskSelector:
      size: '>= 10GB'
    # MUST be true. This is what erases the iPXE bootloader and ends the
    # network-boot loop. Talos defaults it to true; we set it anyway,
    # because the whole design of §7 rests on it.
    wipe: true
EOF
```

🛑 **`wipe: false` here would give you a node that reinstalls itself for ever.** `ipxe.usb` is a *hybrid* image: an MBR with SYSLINUX for BIOS, plus a FAT16 partition holding `/EFI/BOOT/BOOTX64.EFI` for UEFI. Without a wipe, that partition can survive alongside Talos's own ESP, the firmware's removable-media fallback finds the old `BOOTX64.EFI` first, and the node boots iPXE again — chains to BSS, reinstalls, reboots, repeats. §7's "the awkward part solves itself" is true *because of this one field*.

Note also that `type:` takes a single value — `ssd`, `hdd`, `nvme` or `sd` — not an expression. It is omitted deliberately: a virtio disk's reported rotational flag is not worth depending on when size alone is unambiguous.

**Nameservers.** Nodes get DNS `172.16.0.254` from CoreDHCP, but CoreDNS answers only cluster names (§5.8) — it will not resolve `ghcr.io` or `registry.k8s.io`, which Talos must reach to pull its installer and the Kubernetes images. Pin public resolvers, reachable through §5.12's NAT:

```
head$ cat > ~/talos/dns-patch.yaml << 'EOF'
machine:
  network:
    nameservers:
      - 1.1.1.1
      - 8.8.8.8
EOF
```

**API access.** (No kernel arguments here. §9's `console=` and `talos.platform=metal` apply to the boot BSS serves; the installed system's command line comes from the UKI and is not ours to set — see the console note after §8.7.)

```
head$ cat > ~/talos/extra-patch.yaml << EOF
machine:
  # Let the head node (and only it) reach the Talos API by IP without a
  # certificate name mismatch.
  certSANs:
    - ${TW_CP_IP}
    - ${TW_HEAD_PROV_IP}
cluster:
  apiServer:
    certSANs:
      - ${TW_CP_IP}
      - ${TW_HEAD_PROV_IP}
EOF
```

Apply all three to both role configs. `--patch` can be repeated, so this is two commands:

```
head$ talosctl machineconfig patch controlplane.yaml \
        --patch @install-patch.yaml --patch @dns-patch.yaml --patch @extra-patch.yaml \
        -o controlplane.yaml.tmp && mv controlplane.yaml.tmp controlplane.yaml

head$ talosctl machineconfig patch worker.yaml \
        --patch @install-patch.yaml --patch @dns-patch.yaml --patch @extra-patch.yaml \
        -o worker.yaml.tmp && mv worker.yaml.tmp worker.yaml
```

⚠ **Use strategic-merge (YAML) patches, not JSON6902 (`[{"op":…}]`).** Talos v1.13 generates a **multi-document** machine config, and JSON6902 patches are not supported for multi-doc configs — `talosctl` errors with *"JSON6902 patches are not supported for multi-document machine configuration"*. The fragments above are strategic-merge patches, which apply to the matching document. Writing to `$f.tmp` then `mv` avoids truncating the file being read.

🛑 **These patches apply once, to a freshly generated config. They are not re-appliable.** Re-running `install-patch.yaml` against a config that already carries it fails:

```
merge field v1alpha1.InstallDiskSelector.Size: merge field
v1alpha1.InstallDiskSizeMatcher.condition: merge not possible,
left >= 10GB is not settable
```

`diskSelector.size` is a custom type that Talos can parse but not merge onto an existing value. So when you need to change something later — and you will, this section is where iteration happens — **write a new patch containing only the field you are changing**, or delete the three generated files and re-run §8.5 from scratch. Do not try to re-apply the originals.

⚠ **Re-generating from scratch mints a new cluster CA**, which invalidates the `talosconfig` you are holding and any node already installed. Fine before §10, expensive after it. Once nodes are running, the one-field patch is the only sane route.

⚠ **These files contain cluster secrets.** `controlplane.yaml` carries the cluster CA **private key** and bootstrap secrets; `talosconfig` is an admin client certificate. In §8.7 we serve the role configs over *public-read* HTTP so nodes can fetch them at boot. That is acceptable on this isolated wire and **wrong in production**. On the PTR, either:
- use an authenticated per-node config endpoint, or
- skip `talos.config` entirely and apply configs with `talosctl apply-config` against nodes in maintenance mode.

Never commit these files. The tutorial's `.gitignore` lists all three by name.

## Step 8.7 — Publish the machine configs

Nodes fetch their config via the `talos.config` kernel argument (an HTTP URL), so the two role configs go into the same public-read bucket:

```
head$ s3cmd put controlplane.yaml s3://boot-images/talos/controlplane.yaml
head$ s3cmd put worker.yaml       s3://boot-images/talos/worker.yaml
```

### An installed node has no serial console, and you cannot patch one on

🛑 **Expect `openstack console log show` to stop working the moment Talos installs.** It freezes at `kexec_core: Starting new kernel` and never updates again. The node is fine — `talosctl` answers normally — but the console window closes, and it does so permanently. Know this before §10 rather than discovering it while debugging something else.

The reason is worth understanding, because the obvious fixes all fail:

| | |
|---|---|
| **Why** | §9's `console=ttyS0,115200` belongs to the boot **BSS serves**. Once Talos installs, the node boots a UKI whose command line is baked in — `talos.platform=metal console=tty0 …` — and nothing of ours survives |
| **Not `machine.install.extraKernelArgs`** | UEFI x86_64 and arm64 install **systemd-boot**, and with systemd-boot that field is *ignored*: "kernel arguments are embedded in the UKI and cannot be modified without upgrading the UKI" ([Sidero](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/bare-metal-platforms/bootloader), [talos#10339](https://github.com/siderolabs/talos/issues/10339)) |
| **Not `grubUseUKICmdline: false`** | GRUB-only, and we are not on GRUB. `gen config` sets it to `true`; leave it. Setting `extraKernelArgs` alongside it fails validation outright — *"install.extraKernelArgs and install.grubUseUKICmdline can't be used together"* |
| **What would work** | an [Image Factory](https://docs.siderolabs.com/talos/v1.13/learn-more/image-factory) schematic carrying `customization.extraKernelArgs: [console=ttyS0,115200]`, used as `machine.install.image`. §8.4 already explains where Factory fits, and §16 needs a schematic anyway — so this is deferred, not rejected. [DL-006](DECISION-LOG.md#dl-006--installed-nodes-have-no-serial-console) |

📌 **What you lose is narrower than it sounds.** The console covers the *network* boot — iPXE, DHCP, BSS, the kernel fetch, the install — which is where almost every failure in this tutorial happens, and §9's `console=` still applies there. What goes dark is an already-installed node, and that is precisely when `talosctl` works. The gap is a node that installs successfully and then fails to come up.

## ✅ Checkpoint

All four assets present and **anonymously fetchable the way a node fetches them** — a 1-byte range request, which should return `206 Partial Content`:

```
head$ for f in vmlinuz-${TW_ARCH} initramfs-${TW_ARCH}.xz controlplane.yaml worker.yaml; do
        curl -s -o /dev/null -r 0-0 -w "%{http_code}  http://${TW_OBJ}/boot-images/talos/${f}\n" \
          "http://${TW_OBJ}/boot-images/talos/${f}";
      done
206  http://172.16.0.254:7070/boot-images/talos/vmlinuz-amd64
206  http://172.16.0.254:7070/boot-images/talos/initramfs-amd64.xz
206  http://172.16.0.254:7070/boot-images/talos/controlplane.yaml
206  http://172.16.0.254:7070/boot-images/talos/worker.yaml
```

A `403` here means §8.3's public-read policy didn't take, and every node will fail to boot with an HTTP error from iPXE.

The configs parse, and point at the right place:

```
head$ talosctl validate --config controlplane.yaml --mode metal
controlplane.yaml is valid for metal mode

head$ talosctl validate --config worker.yaml --mode metal
worker.yaml is valid for metal mode

head$ grep -m1 endpoint controlplane.yaml
⟨expect: https://172.16.0.1:6443⟩

head$ grep -A2 -B1 'diskSelector\|wipe:' controlplane.yaml
        disk: /dev/sda
        diskSelector:
            size: '>= 10GB'
        image: ghcr.io/siderolabs/installer:v1.13.0
        wipe: true
        grubUseUKICmdline: true
```

**Check `wipe: true` with your own eyes before moving on.** It is the one value in this section whose failure mode is a node that looks like it is working — booting, installing, rebooting — on a loop.

**`disk: /dev/sda` is there, it is wrong, and it is ignored.** `talosctl gen config` writes that default even though we passed no `--install-disk`, and our nodes have a *virtio* disk at `/dev/vda`. It does not matter: the installer takes the selector if one is present and never looks at `disk`, per [`v1alpha1_sequencer_tasks.go`](https://github.com/siderolabs/talos/blob/v1.13.0/internal/app/machined/pkg/runtime/v1alpha1/v1alpha1_sequencer_tasks.go#L1524):

```go
switch {
case matchExpr != nil:
    …
    disk = matchedDisks[0].TypedSpec().DevPath
case r.Config().Machine().Install().Disk() != "":
    disk = r.Config().Machine().Install().Disk()
}
```

Two things follow that are worth knowing before §10. A selector matching nothing is a **loud** failure — `no disks matched the expression` — not a silent fallback to `/dev/sda`. And the installer logs `using disk match expression:` followed by the resolved device, so §10's console tells you which disk it actually chose.

📌 **`size: '>= 10GB'` is shorthand, and the installer prints what it expands to** — captured from `tw-cp1` on 7 Aug 2026:

```
[talos] task install (1/1): using disk match expression: disk.size >= 10000000000u && disk.transport != "" && !disk.readonly && !disk.cdrom
[talos] task install (1/1): installing Talos to disk /dev/vda
```

Three clauses come for free, and all three are ones you would want: no read-only devices, no CD-ROMs, and nothing without a transport. That is why the size shorthand is safe to use on its own.

`--mode metal` is the right mode even though these are cloud instances: as far as Talos is concerned it was PXE-booted onto bare metal, which is exactly the fiction we are maintaining (and §9 passes `talos.platform=metal` to make it official).

## Common failures

| Symptom | Cause / fix |
|---|---|
| `curl` returns `403`/`AccessDenied` instead of `206` | the bucket isn't public-read — re-run §8.3, including the `aws s3api put-bucket-acl` line |
| `s3cmd` fails with a signature error | `~/.s3cfg` host doesn't match how you're connecting — it must be `${TW_CLUSTER_FQDN}:7070`, and that name must resolve on the head (§5.2's `/etc/hosts` line) |
| `talosctl validate` errors on `install` | the disk selector syntax varies slightly between Talos minor versions — check the [config reference](https://docs.siderolabs.com/talos/v1.13/reference/configuration/v1alpha1/config) for your `TW_TALOS_VERSION`. `type` in particular is an enum (`ssd`/`hdd`/`nvme`/`sd`), not an expression |
| Node keeps re-installing on every reboot (§10) | `wipe` is not `true` — the iPXE partition survived the install and the firmware still finds it. Fix the patch, re-publish, and `openstack server rebuild` the node |
| `JSON6902 patches are not supported…` | you used an `[{"op":…}]` patch — use the YAML form above |
| `talosctl machineconfig patch` truncates the file | you redirected output to the file being read; use the `-o "$f.tmp" && mv` form |
| Worried the endpoint is wrong | `grep -m1 endpoint controlplane.yaml` must show `https://172.16.0.1:6443` — the SMD-mapped IP of `tw-cp1`, not the head |

Next: [§9 — Boot parameters](09-boot-parameters.md)
