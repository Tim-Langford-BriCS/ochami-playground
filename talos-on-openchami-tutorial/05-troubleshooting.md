# §5 — Troubleshooting

*(Talos-specific snags, mapped to cause. The base tutorials' §11 still
covers the shared parts of the chain — DHCP leasing, iPXE, BSS — up to the
point the Talos kernel loads.)*

Talos has no shell, so your debug tools are the **console dashboard**
(`host$ virsh console <vm>`) and **`talosctl`** from the head once the API
is up (`talosctl -n 172.16.0.1 dmesg`, `talosctl -n 172.16.0.1 dashboard`,
`talosctl -n 172.16.0.1 logs <service>`).

## Boot / install

| Symptom | Cause / fix |
|---|---|
| Console reaches the Talos kernel then **blank** | wrong `console=` for your arch — `ttyAMA0,115200` (aarch64) vs `ttyS0,115200` (x86_64). Fix §3's payload and re-`set`, then recreate the VM |
| Stuck in **maintenance mode**, never installs | `talos.config` URL unreachable or `404`/`403`. Re-run §2's checkpoint (`206` for `controlplane.yaml`/`worker.yaml`); confirm the URL host is the raw IP + right port (`<OBJ>`), not `demo.openchami.cluster` (no DNS that early) |
| iPXE `0x3e11618e` *(DNS name does not exist)* fetching from `factory.talos.dev` | you pointed BSS at Factory directly; CoreDNS doesn't resolve external names. Host assets locally (§2.2), or add `forward . 1.1.1.1 8.8.8.8` to the head's `/etc/openchami/configs/Corefile` and `systemctl restart coresmd-coredns` — but you'll then hit the TLS row |
| iPXE `0x410de18f` *(server sent a fatal TLS alert)* fetching from `factory.talos.dev` | iPXE's TLS stack can't negotiate a cipher with Factory's server. Not fixable without rebuilding iPXE — **host the assets locally over plain HTTP instead** (§2.2), which is why the tutorial does that by default |
| Hangs at **`downloading installer`** / `pulling …` forever | no internet from the node. Re-check §1 (forwarding + masquerade on the head); then DNS — see next row |
| Reaches internet by IP but **can't resolve** `ghcr.io`/`registry.k8s.io` | CoreDNS doesn't forward external names. Confirm §2.3 patched `machine.network.nameservers` into the config and it was re-uploaded (§2.4) |
| Node **reinstalls on every reboot** (loops through PXE) | boot order is network-first. Use `--boot uefi,hd,network` (disk before NIC), not `--pxe` — see §4.1 |
| `install.disk` error in the dashboard | disk name mismatch — VM disk must be on the **virtio** bus (`/dev/vda`) to match §2.3's `--install-disk /dev/vda` |

## Cluster bring-up

| Symptom | Cause / fix |
|---|---|
| `talosctl version` shows client only, server times out | node API not up yet (still installing/rebooting), or `talosctl config endpoint/node` not set to `172.16.0.1`. Wait, then re-check §4.2 |
| `talosctl bootstrap` errors `already bootstrapped` / etcd unhealthy | bootstrap was run more than once or on a worker. `bootstrap` is once, on one control-plane node only; recover by `talosctl reset` and reprovisioning that node |
| Worker never appears in `kubectl get nodes` | control plane not bootstrapped/healthy yet (`talosctl health`), or the worker fetched the wrong config — confirm its MAC is in `talos-worker.yaml` (§3) and it pulled `worker.yaml` |
| `kubectl` connection refused | control plane still coming up; re-fetch `talosctl kubeconfig .` after `talosctl health` passes |

## Mapping to the base tutorials

Everything **before** the Talos kernel loads (getting a
`172.16.0.x` lease vs a `172.16.0.200`-range bootloop address, iPXE
chaining, BSS reachability) behaves exactly as in the base tutorials — use
their §11 table for those. From the Talos kernel onward, use this page.

Back to: [README](README.md)
