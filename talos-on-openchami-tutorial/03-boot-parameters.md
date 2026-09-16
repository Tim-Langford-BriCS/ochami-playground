# §3 — Boot parameters for Talos

*(Time: ~5 minutes. On the head node; fresh token needed. Replaces base §8.)*

## Concepts

Same machinery as the base tutorials' §8: **BSS answers "a machine with MAC
X is asking how to boot — what do I tell it?"** with a kernel, an initrd,
and a kernel command line, keyed by MAC. Only the *answer* changes.

We store **two** answers, because our nodes have two roles:

- compute1 (`52:54:00:be:ef:01`) → **control plane**, fetching
  `controlplane.yaml`;
- compute2–5 (`…:02`–`…:05`) → **workers**, fetching `worker.yaml`.

The Talos kernel command line is much shorter than Rocky's — dissected:

| Token | Meaning |
|---|---|
| `talos.platform=metal` | tell Talos it's on bare metal (PXE), not a cloud — **required** |
| `slab_nomerge` `pti=on` | kernel hardening Talos requires on metal — **required** |
| `console=tty0 console=<CONSOLE>` | serial console so `virsh console` shows the Talos dashboard (`ttyS0,115200` on x86_64 / `ttyAMA0,115200` on aarch64) |
| `talos.config=http://<OBJ>/boot-images/talos/<role>.yaml` | where Talos fetches its machine config — this is what replaces §9's cloud-init datasource |

Everything from the base tutorials' Rocky command line is **gone**: no
`root=live:…`, no `overlayroot=…`, no `cloud-init=…`/`ds=nocloud-net`, no
`apparmor=0 selinux=0 nomodeset`. Talos is not a dracut live image.

Re-export your arch variables if this is a new shell:

```
head$ export ARCH=arm64            # or amd64
head$ export OBJ=172.16.0.254:7070 # or 172.16.0.254:9000
head$ export CONSOLE=ttyAMA0,115200 # or ttyS0,115200
```

## Step 3.1 — Write the two BSS payloads

Control-plane node (`compute1`):

```
head$ sudo mkdir -p /etc/openchami/data/boot/bss
head$ cat << EOF | sudo tee /etc/openchami/data/boot/bss/talos-controlplane.yaml
---
kernel: 'http://${OBJ}/boot-images/talos/vmlinuz-${ARCH}'
initrd: 'http://${OBJ}/boot-images/talos/initramfs-${ARCH}.xz'
params: 'talos.platform=metal slab_nomerge pti=on console=tty0 console=${CONSOLE} talos.config=http://${OBJ}/boot-images/talos/controlplane.yaml'
macs:
  - 52:54:00:be:ef:01
EOF
```

Worker nodes (`compute2`–`compute5`):

```
head$ cat << EOF | sudo tee /etc/openchami/data/boot/bss/talos-worker.yaml
---
kernel: 'http://${OBJ}/boot-images/talos/vmlinuz-${ARCH}'
initrd: 'http://${OBJ}/boot-images/talos/initramfs-${ARCH}.xz'
params: 'talos.platform=metal slab_nomerge pti=on console=tty0 console=${CONSOLE} talos.config=http://${OBJ}/boot-images/talos/worker.yaml'
macs:
  - 52:54:00:be:ef:02
  - 52:54:00:be:ef:03
  - 52:54:00:be:ef:04
  - 52:54:00:be:ef:05
EOF
```

(The `<< EOF` heredoc is unquoted so your `${OBJ}`/`${ARCH}`/`${CONSOLE}`
expand into the files. `cat` the files afterward to confirm real values
landed, not empty strings.)

## Step 3.2 — Load both into BSS

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
head$ ochami bss boot params set -f yaml -d @/etc/openchami/data/boot/bss/talos-controlplane.yaml
head$ ochami bss boot params set -f yaml -d @/etc/openchami/data/boot/bss/talos-worker.yaml
head$ ochami bss boot params get -F yaml
```

(`set` replaces idempotently — re-run freely as you tweak the command line.
Repointing a node between roles later = change which payload lists its MAC
and `set` again.)

## ✅ Checkpoint — pretend to be each node

Ask BSS what it would tell the control-plane MAC and a worker MAC:

```
head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01" | grep -o 'talos.config=[^ ]*'
talos.config=http://172.16.0.254:7070/boot-images/talos/controlplane.yaml

head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:02" | grep -o 'talos.config=[^ ]*'
talos.config=http://172.16.0.254:7070/boot-images/talos/worker.yaml
```

The full script for `…:01` is the real iPXE that compute1 will run in §4 —
it shows the Talos `vmlinuz`/`initramfs.xz` and the
`talos.platform=metal … talos.config=…` command line, plus BSS's own
`xname=`/`nid=` and retry logic appended. (Talos ignores the extra
`xname=`/`nid=` tokens — harmless.)

## Common failures

| Symptom | Cause / fix |
|---|---|
| bootscript shows empty `kernel:`/blank params | the heredoc variables were unset when you wrote the file — re-export `OBJ`/`ARCH`/`CONSOLE` and rewrite |
| `set` fails `401`/token error | token expired — re-run the `gen_access_token` export |
| node later boots but never fetches config | `talos.config` URL wrong or not public-read — re-check §2.4 and the §2 checkpoint |

Next: [§4 — Booting the Talos cluster](04-boot-the-cluster.md)
