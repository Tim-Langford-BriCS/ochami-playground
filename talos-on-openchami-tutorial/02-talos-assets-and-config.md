# §2 — Talos assets and machine config

*(Time: ~15 minutes. On the head node. Replaces the base tutorials' §7
image build **and** §9 cloud-init.)*

## Concepts

There is no image to *build*. Talos publishes a ready-made **`vmlinuz`** and
**`initramfs.xz`** per architecture — the initramfs *is* a complete,
immutable OS. Our only jobs here are:

1. put those two files where booting nodes can fetch them (the head's
   object store, reused from the base tutorial), and
2. generate the **machine config** — the declarative YAML that replaces
   cloud-init. `talosctl gen config` produces three files:
   - `controlplane.yaml` — for the node that runs the Kubernetes control plane,
   - `worker.yaml` — for nodes that just run workloads,
   - `talosconfig` — your *client* credentials for talking to the cluster
     (keep this; it's how you drive everything in §4).

Both node roles are told where to install (`/dev/vda`, the virtio disk we
give the VM in §4) and which registries/DNS to use. The config is fetched at
boot via the `talos.config` kernel argument we set in §3.

Set your architecture variables first (from the README table):

```
head$ export ARCH=arm64            # arm64 (macOS base) or amd64 (Linux base)
head$ export OBJ=172.16.0.254:7070 # :7070 (macOS base) or :9000 (Linux base)
head$ export TALOS_VERSION=v1.13.0 # pick the latest v1.13.x from the releases page
```

## Step 2.1 — Get `talosctl` on the head

```
head$ curl -sL https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${ARCH} \
        -o /tmp/talosctl && sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
head$ talosctl version --client
```

(`talosctl` is the *only* way to administer Talos nodes — there is no SSH.
We also grab `kubectl` for §4:)

```
head$ curl -sL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
        -o /tmp/kubectl && sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
```

## Step 2.2 — Download the Talos boot assets and push them to the object store

The base tutorial already created the public-read `boot-images` bucket and
configured your `s3cmd` client — we reuse both. Booting nodes fetch these
anonymously over plain HTTP by raw IP (no DNS that early in boot), which is
exactly what the public-read policy is for.

```
head$ curl -sL https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/vmlinuz-${ARCH} \
        -o /tmp/vmlinuz-${ARCH}
head$ curl -sL https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/initramfs-${ARCH}.xz \
        -o /tmp/initramfs-${ARCH}.xz
head$ s3cmd put /tmp/vmlinuz-${ARCH}        s3://boot-images/talos/vmlinuz-${ARCH}
head$ s3cmd put /tmp/initramfs-${ARCH}.xz   s3://boot-images/talos/initramfs-${ARCH}.xz
```

🔀 **Deviation.** The base tutorials `dnf`-built a SquashFS triplet with
`image-builder` and pushed it to S3. Talos assets are prebuilt — we just
download and `put` them. No registry, no OCI layers, no `dracut`.

> **Where Image Factory fits.** [Image Factory](https://docs.siderolabs.com/talos/v1.13/learn-more/image-factory)
> decides *what's in the image* (a **schematic** = Talos base + system
> extensions like `iscsi-tools`/GPU drivers + extra kernel args/overlays);
> the object store decides *where it's served from*. They're orthogonal, so
> Factory is a **source for the two files above, not a replacement for this
> step.** If you need extensions, pick/create a schematic and download that
> schematic's assets instead of the GitHub ones —
> `https://factory.talos.dev/image/<schematic-id>/${TALOS_VERSION}/kernel-${ARCH}`
> and `.../initramfs-${ARCH}.xz` (the vanilla schematic is
> `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba`) — then
> `s3cmd put` them locally exactly as above. Stock assets are fine for this
> lab.
>
> **Why not point BSS straight at `factory.talos.dev` and skip the upload?**
> We tried; it does not work with the coresmd-bundled iPXE, for two reasons
> hit in order:
> 1. **DNS.** iPXE resolves names via the DHCP-supplied server
>    (`172.16.0.254` = OpenCHAMI's CoreDNS), which answers only cluster names
>    — `factory.talos.dev` fails with iPXE error `0x3e11618e` *(DNS name does
>    not exist)*. You *can* fix this by adding a `forward` to the Corefile
>    (see the box below), but then you hit:
> 2. **TLS.** Even though this iPXE reports `HTTPS` in its features, its
>    minimal TLS stack **cannot negotiate a cipher** with Factory's modern
>    server — the fetch dies with `0x410de18f` *(server sent a fatal TLS
>    alert)*. This is not fixable without rebuilding iPXE, and even then its
>    cipher support is too limited to rely on.
>
> Plus every node would re-pull ~80 MB over the internet on every boot.
> **Conclusion: let the *head* fetch from Factory (it has a full TLS stack)
> and serve to nodes over plain HTTP by raw IP** — exactly this step. iPXE
> handles plain HTTP by IP with no DNS and no TLS.
>
> If your schematic carries **system extensions**, also point the install
> image at the matching Factory installer so they persist to disk (Talos
> pulls it from *within the running system*, which has real TLS + the
> nameservers from §2.3, so HTTPS to Factory works there):
> `talosctl machineconfig patch <f> --patch` a
> `machine.install.image: factory.talos.dev/installer/<schematic-id>:${TALOS_VERSION}`.

## Step 2.3 — Generate the machine config

The control-plane endpoint is compute1's SMD-mapped IP, `172.16.0.1`, on the
Kubernetes API port `6443`. We install to `/dev/vda` (the virtio disk from
§4):

```
head$ mkdir -p ~/talos && cd ~/talos
head$ talosctl gen config ochami-talos https://172.16.0.1:6443 \
        --install-disk /dev/vda \
        --install-image ghcr.io/siderolabs/installer:${TALOS_VERSION}
created controlplane.yaml
created worker.yaml
created talosconfig
```

Now patch **DNS** into both node configs. Nodes get DNS `172.16.0.254`
(OpenCHAMI's CoreDNS) from DHCP, but CoreDNS only answers cluster names — it
won't resolve `ghcr.io`. Pin public resolvers (reachable through the §1 NAT):

```
head$ cat > ~/talos/dns-patch.yaml << 'EOF'
machine:
  network:
    nameservers:
      - 1.1.1.1
      - 8.8.8.8
EOF
head$ for f in controlplane.yaml worker.yaml; do
        talosctl machineconfig patch "$f" --patch @dns-patch.yaml -o "$f.tmp" && mv "$f.tmp" "$f"
      done
```

⚠ **Use a strategic-merge (YAML) patch, not a JSON6902 (`[{"op":…}]`) one.**
Talos v1.13 generates a **multi-document** machine config, and JSON6902
patches aren't supported for multi-doc configs (`talosctl` errors with
*"JSON6902 patches are not supported for multi-document machine
configuration"*). The YAML fragment above is a strategic-merge patch, which
applies to the matching (`machine:`) document. Writing to `$f.tmp` then
`mv` avoids truncating the file we're reading from.

⚠ **Gotcha — these files contain cluster secrets.** `controlplane.yaml`
carries the cluster CA private key and bootstrap secrets; `talosconfig`
carries your admin client cert. In §3 we serve the machine configs over
*public-read* HTTP so nodes can fetch them at boot — acceptable on this
isolated lab wire, but **never** do that in production (there, use an
authenticated per-node config endpoint, or apply configs with
`talosctl apply-config` instead of `talos.config`). Never commit these files
to git.

## Step 2.4 — Publish the machine configs to the object store

Nodes fetch their config via `talos.config` (an HTTP URL) at boot, so the
two role configs go into the same public-read bucket:

```
head$ s3cmd put controlplane.yaml s3://boot-images/talos/controlplane.yaml
head$ s3cmd put worker.yaml        s3://boot-images/talos/worker.yaml
```

## ✅ Checkpoint

All four assets present and anonymously fetchable the way a node fetches
them (a 1-byte range request → `206 Partial Content`):

```
head$ for f in vmlinuz-${ARCH} initramfs-${ARCH}.xz controlplane.yaml worker.yaml; do
        curl -s -o /dev/null -r 0-0 -w "%{http_code}  http://${OBJ}/boot-images/talos/${f}\n" \
          "http://${OBJ}/boot-images/talos/${f}";
      done
206  http://172.16.0.254:7070/boot-images/talos/vmlinuz-arm64
206  http://172.16.0.254:7070/boot-images/talos/initramfs-arm64.xz
206  http://172.16.0.254:7070/boot-images/talos/controlplane.yaml
206  http://172.16.0.254:7070/boot-images/talos/worker.yaml
```

And the config parses as valid Talos config:

```
head$ talosctl validate --config controlplane.yaml --mode metal
controlplane.yaml is valid for metal mode
```

## Common failures

| Symptom | Cause / fix |
|---|---|
| `curl` returns `403`/`AccessDenied` instead of `206` | the bucket isn't public-read — re-apply the base tutorial's §7 public-read policy to `boot-images` |
| `talosctl validate` errors on `install.disk` | wrong disk name for your VM's bus; we use virtio → `/dev/vda`. Keep §4's disk on the virtio bus |
| worried the config points at the wrong API | `grep -m1 endpoint controlplane.yaml` should show `https://172.16.0.1:6443` |

Next: [§3 — Boot parameters for Talos](03-boot-parameters.md)
