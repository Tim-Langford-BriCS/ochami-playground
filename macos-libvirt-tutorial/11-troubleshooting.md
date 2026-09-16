# §11 — Troubleshooting

Every entry below is a failure we actually hit while building this
tutorial and its two sibling labs. Symptoms are ordered by where in the
stack they appear.

## Reading the compute node's console when you can't log in

`virsh console` is interactive, but you can snoop it non-interactively —
useful from scripts or when the login prompt has scrolled away:

```
host$ pty=$(virsh ttyconsole compute1)
host$ sudo sh -c "printf '\n' > $pty; timeout 4 cat $pty"
compute1 login:
```

(Poke a newline in, read what comes back.) And remember the debug image's
`testuser`/`testuser` — it exists so you can *always* get a shell on a
booted node and run `cloud-init status --long`, `journalctl`, etc.

## The table

| Symptom | Diagnosis | Fix |
|---|---|---|
| `/dev/kvm` missing in the Lima VM; dmesg `HYP mode not available` | `nestedVirtualization: true` absent at instance *creation*, or Mac older than M3 | fix the YAML, `limactl delete` + re-create (§1) |
| `virsh` prompts **"System policy prevents management of local virtualized systems"** (asks for root password) | your user isn't in the `libvirt` group, so polkit demands admin auth for `qemu:///system` | `sudo usermod -aG libvirt "$USER"`, then re-login — or `newgrp libvirt` for the current shell (§2.2). `sudo virsh` also works but the tutorial assumes passwordless access |
| bare `virsh net-list` / `virsh list` is **empty** though you defined things (or `virsh uri` shows `qemu:///session`) | without `sudo`, an unprivileged `virsh` defaults to the per-user `qemu:///session` daemon, not `qemu:///system` where the cluster lives | `export LIBVIRT_DEFAULT_URI=qemu:///system` (and add it to `~/.bashrc`) — §2.2 |
| `net-define` succeeds but `net-start` fails: **`error creating bridge interface …: Operation not permitted`** | same `qemu:///session` trap — the per-user daemon can record a network but runs as you, so it can't create a system bridge | set `LIBVIRT_DEFAULT_URI=qemu:///system` (§2.2), then clean up the junk copy: `virsh -c qemu:///session net-undefine <name>`, and (re)run the define/start against the system daemon |
| `virt-install`: `Cannot access storage file ... Permission denied` | qemu's unprivileged user can't traverse your home dir | `setfacl -m u:qemu:x "$HOME"` (§4.2) |
| `virt-install`: `IDE controllers are unsupported` | something attached a CD-ROM on the (non-existent) aarch64 IDE bus | attach cdrom with `bus=scsi` + `--controller type=scsi,model=virtio-scsi` (§4.5 note) |
| head VM boots with defaults (no SSH key, DHCP addresses) | seed ISO not seen by cloud-init | `-volid cidata` missing, or cdrom not attached — `virsh dumpxml head \| grep -A3 cdrom` |
| `virsh net-start` fails / traffic blackholes | subnet collides with libvirt's `default` net (192.168.122.0/24) | use 192.168.200.0/24 (§3) |
| a quadlet service loops with `exec format error` | an amd64-only container image on our arm64 host | `journalctl -u <svc>` to find it; override the image tag — core OpenCHAMI images are multi-arch, so this points at a third-party image |
| `systemctl start openchami.target` times out / SSH died mid-start | first-start image pulls are slow; the job continues server-side | wait; check `systemctl is-active openchami.target` before retrying (§5.10) |
| haproxy: `could not resolve address 'opaal'` | startup race (documented upstream) | `sudo systemctl restart opaal haproxy` |
| `ochami` says unauthorized / token errors | JWTs expire after 1 h | `export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')` |
| authenticated API calls (discovery, boot params) all `500`, reads fine; `podman logs smd` shows `jwtauth ... nil pointer` panic | SMD started before the OIDC stack published its JWKS (messy first start) and cached a nil keyset | `sudo systemctl restart smd` (§5.10 gotcha) |
| `ochami discover static` → `409 Conflict` | it's an add, not an upsert; inventory already loaded | nothing to fix — or delete components first to reload (§6.2) |
| compute node loops with a **172.16.0.200–250 address** | bootloop lease: CoreDHCP can't read SMD, usually `x509: certificate signed by unknown authority` in `journalctl -u coresmd-coredhcp` — coresmd read a stale root CA at startup | `sudo systemctl restart coresmd-coredhcp coresmd-coredns`; expect `assigning 172.16.0.1 to 52:54:00:be:ef:01 (Node)` within seconds (§5.10 gotcha) |
| `PXE-E18: Server response timeout` at the firmware | nothing answered DHCP on the internal wire | coredhcp.yaml not applied / not listening on `%eth1`; `systemctl restart coresmd-coredhcp` (§5.7) |
| console silent after iPXE loads the kernel | wrong serial console in kernel params | `console=ttyAMA0,115200` on aarch64, not ttyS0 (§8) |
| node boots but hostname is `nid0001`/`de01` and no root SSH; `cloud-init status --long` shows `Max retries ... http://cloud-init:27777/compute.yaml` | **the memstore gotcha**: cloud-init server restarted and lost defaults/groups; vendor-data now points at its internal address | re-run §9 (four commands), power-cycle the node; verify `ochami cloud-init defaults get` non-empty first |
| image build dies: `No more mirrors to try` / downloads at KB/s | congested path to that mirror (for us: `dl.rockylinux.org`, and household bandwidth contention) | test alternatives: `curl -o /dev/null -w '%{speed_download}' <mirror-url>` against 2–3 mirrors from `mirrors.rockylinux.org/mirrorlist`; our recipes already use `rockylinux.mirrorservice.org` |
| image build: `manifest unknown` pulling parent | previous layer never actually pushed | re-run the earlier layer's build; confirm with `regctl repo ls` |
| scripted checks with `... \| grep -q` mysteriously fail under `set -o pipefail` | `grep -q` exits at first match → SIGPIPE kills the producer (classic with `s3cmd ls`) | capture to a variable, then grep the variable |

## A general debugging map

Work *down* the chain and find the first broken link:

```
SMD has the node?          ochami smd component get | jq ...
DHCP knows it?             journalctl -u coresmd-coredhcp | tail   (look for "Cache updated ... Components")
BSS answers for the MAC?   curl "http://172.16.0.254:8081/boot/v1/bootscript?mac=..."
artifacts fetchable?       curl -r 0-0 <kernel/initrd/squashfs URLs>
node's own story?          virsh console → testuser → cloud-init status --long
who did it ask?            on the head: podman logs cloud-init-server | grep 172.16.0.1
```

Next: [§12 — Teardown](12-teardown.md)
