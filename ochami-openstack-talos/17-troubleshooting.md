# §17 — Troubleshooting

Each section has its own "common failures" table for problems local to that step. This section is for when you don't yet know *which* layer is broken.

> 🗺 **Start with the map.** [Appendix E](appendix-e-network-map.md) shows every hop between your keyboard and a Talos node in one diagram, with the command that verifies each one. Most "the cluster is broken" reports turn out to be a single identifiable hop, and finding it on the map is faster than reasoning about it.

## Diagnose by layer, from the bottom

The stack is deep, and the single most useful habit is to find the lowest broken layer before touching anything. Work down this list; the first `✗` is where to start.

```
head$ # ── Layer 6: inference ────────────────────────────────────────────────
head$ kubectl -n inference get inferenceservice
head$ # ── Layer 5: Kubernetes workloads ─────────────────────────────────────
head$ kubectl get pods -A | grep -v -E 'Running|Completed'
head$ flux get all
head$ # ── Layer 4: Kubernetes cluster ───────────────────────────────────────
head$ kubectl get nodes
head$ # ── Layer 3: Talos machines ───────────────────────────────────────────
head$ talosctl -n 172.16.0.1 health
head$ # ── Layer 2: OpenCHAMI control plane ──────────────────────────────────
head$ systemctl is-active openchami.target && ochami smd service status | jq -c .
head$ # ── Layer 1: OpenStack substrate ──────────────────────────────────────
devbox$ openstack server list -c Name -c Status
devbox$ openstack port list --network ${TW_PREFIX}-prov -c Name -c Status
```

## The five failures you are most likely to hit

Ranked by how often they bite, from our libvirt runs and the OpenStack design.

### 1. A node network-boots but never gets an address

**Symptom:** iPXE banner appears in the console log, then `Configuring (net0 …)......` and a timeout, or an address in `172.16.0.200–250`.

This is the most common failure and it has four possible causes. Check them **in this order** — each is cheap:

```
devbox$ openstack subnet show ${TW_PREFIX}-prov-subnet -c enable_dhcp -f value
        # must be False. If True, Neutron's DHCP is racing CoreDHCP (§3.2)

devbox$ openstack port show ${TW_PREFIX}-node1-prov -c port_security_enabled -f value
        # must be False, or the head's DHCP replies are dropped (§3.3)

head$   systemctl is-active coresmd-coredhcp
head$   journalctl -u coresmd-coredhcp | tail -20
        # must show "Cache updated with N EthernetInterfaces and N Components"

head$   ochami smd component get | jq -r '.Components[]|select(.Type=="Node")|.ID'
        # the node's MAC must be in SMD (§6)
```

A `172.16.0.2xx` address specifically means **CoreDHCP answered but did not recognise the MAC** — so the wire and the server are fine, and the problem is SMD (§6) or a MAC mismatch between the Neutron port and the inventory.

### 2. Talos hangs at `downloading installer`

**Symptom:** the console reaches `downloading installer image ghcr.io/…` and stays there.

Two causes, both on the head:

```
head$ sysctl net.ipv4.ip_forward                       # must be 1        (§5.2)
head$ sudo nft list chain ip nat postrouting           # or:
head$ sudo firewall-cmd --query-masquerade             # must be yes      (§5.12)
head$ grep -A3 nameservers ~/talos/worker.yaml         # 1.1.1.1 present? (§8.6)
```

And the third, easily missed: **port security on the head's own provisioning port**. Masquerading emits packets whose source IP is not the port's, which anti-spoofing drops:

```
devbox$ openstack port show ${TW_PREFIX}-head-prov -c port_security_enabled -f value
```

### 3. Everything authenticated returns `500` or `401`

`401` is almost always an **expired token** — they last one hour:

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
```

`500` on authenticated calls while unauthenticated reads work is the **SMD/OIDC startup race** (§5.10):

```
head$ sudo podman logs smd 2>&1 | grep -i jwtauth
head$ sudo systemctl restart smd
```

### 4. A service reads its security material once, and got it wrong

A recurring OpenCHAMI theme: several services load certificates or keys **at startup only**. After any certificate change, restart them:

```
head$ sudo systemctl restart coresmd-coredhcp coresmd-coredns
head$ sudo systemctl restart opaal haproxy
head$ sudo systemctl restart smd
```

Symptom that points here: `x509: certificate signed by unknown authority` in `journalctl -u coresmd-coredhcp`, with nodes falling back to bootloop leases.

### 5. Nothing changes when you commit

**Symptom:** you push to the Flux repository and the cluster ignores it.

```
head$ flux get sources git          # is the repo being fetched?
head$ flux get kustomizations -A    # any Ready=False?
head$ flux reconcile kustomization flux-system --with-source
head$ flux logs --level=error --all-namespaces
```

Default reconcile interval is 10 minutes. `apps` staying `Ready=False` while `infrastructure` is broken is `dependsOn` working correctly, not a fault.

## Where to look, by layer

**Check this first, every time, before believing any of the below.** Two of the most alarming-looking errors in this tutorial are an unset environment variable in a fresh `ssh` session:

| Symptom | Cause |
|---|---|
| `talosctl` → `error constructing client: failed to determine endpoints` | `TALOSCONFIG` unset |
| `kubectl` → `The connection to the server localhost:8080 was refused` | `KUBECONFIG` unset; `localhost:8080` is kubectl's built-in default |

`echo $TALOSCONFIG $KUBECONFIG` costs nothing. §10.3 has the `~/.bashrc` line that stops it recurring.

| Layer | Logs / status |
|---|---|
| OpenStack | `openstack server show <n> -c fault -f json`, `openstack console log show <n>`, `openstack server event list <n>` |
| Node boot | `openstack console log show <node> --lines 200` — the *only* window into a Talos node's **network** boot. It stops at `kexec_core: Starting new kernel` and never resumes; an installed node has no serial console at all ([DL-006](DECISION-LOG.md#dl-006--installed-nodes-have-no-serial-console)). If the log is frozen there, that is not the fault — reach for `talosctl` |
| OpenCHAMI | `systemctl --failed`, `journalctl -eu <service>`, `sudo podman logs <container>`, `systemctl list-dependencies openchami.target` |
| BSS answers | `curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=<MAC>"` — impersonate the node |
| S3 assets | `curl -s -o /dev/null -r 0-0 -w "%{http_code}" http://172.16.0.254:7070/boot-images/talos/<file>` — expect `206` |
| Talos | `talosctl -n <ip> dmesg`, `… logs <service>`, `… health`, `… get members`, `… dashboard` |
| Kubernetes | `kubectl get events -A --sort-by=.lastTimestamp`, `kubectl describe pod <p>` |
| Flux | `flux get all`, `flux logs --level=error -A` |
| vLLM | `kubectl -n inference logs <pod> -c kserve-container`, and `-c storage-initializer` for download failures |

## Two habits worth adopting

**Impersonate the node.** Most of the boot chain can be tested from the head without booting anything — ask BSS what it would say, fetch the assets the way iPXE would, check the DHCP cache. §§7.5, 8 and 9's checkpoints exist for this reason. Rescuing an instance to find out takes ten minutes; `curl` takes one second.

**When in doubt after a messy start, restart the service.** OpenCHAMI services are containers with no local state worth protecting, and several of them read config once. Restarting is cheap and safe, and it fixed several problems on both of our libvirt runs.

## Things that look broken but are not

| Looks wrong | Actually fine |
|---|---|
| `A dependency job for openchami.target failed` on the very first start | expected startup race; wait and start again (§5.10) |
| PVC `Pending` with `WaitForFirstConsumer` | how local-path binds — it waits for a pod |
| `apps` Kustomization `Ready=False` while `infrastructure` is broken | `dependsOn` doing its job |
| Talos node reboots straight to disk without touching iPXE | correct after §10.2 — Talos persists |
| `openstack server stop` refused on a node | it's in RESCUE — only possible if you took a rescue-based mechanism from [appendix F](appendix-f-network-boot-investigation.md). `openstack server unrescue <name>` first |
| `ray.cluster_resources()` has no `GPU` key | correct: there are no GPUs (§15.3, §16) |
| A few tokens per second from vLLM | correct on CPU (§14) |
| `talosctl version` shows only a Client | the node's API isn't up yet — wait, or check it booted |

## The caveat that bites weeks later: `TW_ADMIN_CIDR` is not durable

Everything above is a failure you cause. This one arrives on its own, without you changing anything, and it is the single most likely reason a cluster that worked yesterday is unreachable today.

`TW_ADMIN_CIDR` (§1.5) is scoped to the network your devbox appeared from *at the moment you wrote it down*. A `/32` of your egress address is the tightest, most correct value — and the most fragile. Any of these silently invalidates it:

- a VPN disconnect and reconnect, landing you on a different exit address;
- a DHCP lease expiring on the office or home network;
- moving between networks — office to home, wired to wireless, a different site;
- your ISP rotating a dynamic address.

**The symptom is not "permission denied" — it is a timeout**, because a security group that does not match your source address drops packets silently rather than refusing them. So it presents exactly like a boot failure, a lost floating IP, or a dead head node, and the instinct is to investigate the cluster. `openstack server show tw-head` will report `ACTIVE`, the console log will look perfectly healthy, and nothing in the cluster is wrong.

**Check this before diagnosing anything else when SSH stops working:**

```
devbox$ tw_vpn
```

> 📗 **If it is the address and you just want it fixed**, [runbooks/update-tunnel-ip.md](runbooks/update-tunnel-ip.md) is the two-minute version of everything below: the laptop command, the two rules to add, and which stale ones to delete afterwards. The rest of this section is the argument.

That one command separates the two failures that look identical from the devbox. Both the Keystone endpoint and the head node are reached over the same tunnel, but **only the head is behind a security group**, so probing each in turn identifies which layer broke:

| Keystone API | head, tcp/22 | Verdict |
|---|---|---|
| ok | open | the path is fine — the fault is on the head node |
| ok | **no answer** | the tunnel is up and **your source address has changed** |
| unreachable | — | the VPN is down; reconnect before anything else |

`tw_vpn` prints the verdict and, for the middle case, the command to run **on your laptop** — the tunnel address does not exist inside the devbox VM, which sits behind the laptop's NAT. [Appendix E](appendix-e-network-map.md) explains the reasoning against the network map.

The longer form, if you want to see the evidence yourself:

```
devbox$ echo ${TW_ADMIN_CIDR}                  # what the rule was written for
devbox$ openstack security group rule list ${TW_PREFIX}-sg-head
devbox$ sudo journalctl -u sshd | grep -i accepted | tail -3   # ON THE HEAD, if you can still reach it
```

⚠ **Do not reach for `curl -s ifconfig.me` here unless the floating-IP network is publicly routable** — see §1.5. On a cloud whose `external` network is a private range (Digital Labs' is `10.3.0.0/x`) you reach the head over a VPN, and with split tunnelling `ifconfig.me` reports your *local* egress address while the head sees your *tunnel* address. Writing the first into the rule is how a working setup becomes a broken one.

The head's own `sshd` log is the authoritative answer, which is why it is worth capturing a known-good source address **while SSH still works** rather than when it has already stopped.

If you cannot get in at all, look on the **laptop**, not the devbox. The devbox is a VM behind its host's NAT, so `ip route get` there reports a source address that is private to the VM and never appears on the wire — on Lima it will say something like `src 192.168.5.15`, which is true and useless. The address the head sees is the one on the tunnel interface of the machine running the VPN client:

```
mac$ route -n get <the floating IP> | grep interface     # e.g. utun10
mac$ ifconfig utun10 | grep 'inet '                      # e.g. inet 10.11.0.49
```

On Linux the equivalent is `ip route get <the floating IP>` run on the laptop itself, where the tunnel lives.

Once you know the address the head actually sees, add the rule rather than rewriting the variable's history:

```
devbox$ export TW_ADMIN_CIDR='<THE_ADDRESS_OR_RANGE_THE_HEAD_SEES>'
devbox$ openstack security group rule create ${TW_PREFIX}-sg-head \
    --protocol tcp --dst-port 22 --remote-ip ${TW_ADMIN_CIDR} --description SSH
devbox$ sed -i "s|^export TW_ADMIN_CIDR=.*|export TW_ADMIN_CIDR='${TW_ADMIN_CIDR}'|" ~/tw/tw-vars-env.sh
```

Then delete the stale rule (`openstack security group rule list ${TW_PREFIX}-sg-head` for its ID) so the group does not accumulate every address you have ever had — an old rule pointing at a reassigned dynamic address is a genuine exposure, not just clutter.

⚠ **If you are re-issuing a `/32` often, consider the VPN pool's range instead.** At Digital Labs the F5 allocates from **`10.11.0.0/16`** (confirmed by the cloud team, 3 Aug 2026), so one rule covers every session:

```
devbox$ export TW_ADMIN_CIDR='10.11.0.0/16'
```

The trade is smaller than the mask suggests: `10.11.0.0/16` is RFC1918 and unroutable from the internet, so the set of hosts that can reach port 22 is the same as under a `/32` — those already authenticated onto the VPN or inside the University network. What the range gives up is the distinction between you-on-the-VPN and anyone-else-on-the-VPN, who would still need your private key.

**The `/32` remains the right choice in several cases** — a short attentive session, a cloud whose floating IPs are *publicly* routable, or when you want the rule list to record which sessions were permitted. It is the tightest scope the mechanism can express and it needs no argument to defend. What it costs is a re-measure per reconnect, and the danger is only that repeated friction is how a cluster ends up with `0.0.0.0/0` — not by decision, but by someone in a hurry calling it temporary. [runbooks/update-tunnel-ip.md](runbooks/update-tunnel-ip.md) argues both sides and gives both procedures.

**Never resolve this by widening to `0.0.0.0/0`** — §3.5 and the IaC both refuse it deliberately.

Next: [§18 — Teardown](18-teardown.md)
