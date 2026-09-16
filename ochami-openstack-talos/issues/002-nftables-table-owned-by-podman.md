# 002 — `table ip nat` belongs to podman; §5.12's NAT rule must not go in it

| | |
|---|---|
| **Status** | Fixed in the tutorial and the IaC. No upstream component at fault — this was our own instruction being wrong for this image. |
| **Hit at** | §5.12 — Make the head a NAT router |
| **Observed** | 2026-08-03, `tw-head`, Rocky 9.6 cloud image, `nftables-1.0.9-7.el9_8`, `iptables v1.8.10 (nf_tables)`, podman with netavark |
| **Severity** | The original instruction *works immediately* and fails later, which is the worst shape a defect can have |

## The error

The first symptom is harmless — §5.12's firewalld branch simply isn't available on this image:

```
head$ sudo firewall-cmd --permanent --add-masquerade
sudo: firewall-cmd: command not found
```

`firewalld` is not merely inactive on the Rocky 9.6 cloud image; it is **not installed**. So the nftables branch applies. That branch said:

```
head$ sudo nft add table ip nat
head$ sudo nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }'
head$ sudo nft add rule ip nat postrouting ip saddr 172.16.0.0/24 oif "eth0" masquerade
```

The real problem shows up only if you look at the table first:

```
head$ sudo nft list table ip nat | head -1
# Warning: table ip nat is managed by iptables-nft, do not touch!
```

## Why it occurs

By §5.12 the head is already running thirteen containers, and podman has configured their networking through **netavark**, which writes its rules using the `iptables-nft` compatibility layer — `iptables` on this image is `v1.8.10 (nf_tables)`, an nftables backend wearing an iptables interface. Those rules live in `table ip nat`, and they are not incidental:

```
head$ sudo nft list table ip nat
table ip nat {
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		counter jump NETAVARK-HOSTPORT-MASQ
		ip saddr 10.88.0.0/16 counter jump NETAVARK-1D8721804F16F
		ip saddr 10.89.1.0/24 counter jump NETAVARK-2847D5E385377
	}
	chain NETAVARK-DN-1D8721804F16F {
		tcp dport 5000 counter dnat to 10.88.0.2:5000
		tcp dport 7070 counter dnat to 10.88.0.3:7070
	}
	…
}
```

Those last two lines are **the registry and the S3 gateway**. The port forwarding that makes `:5000` and `:7070` reachable at all is in the same table §5.12 told you to modify.

Adding a chain there does work — nftables permits two chains in one table, and the packets we care about are disjoint from netavark's. The hazard is ownership, not correctness:

1. **podman rewrites this table** whenever container networking changes — a container restart, a network reconfiguration, a podman upgrade. It reconciles the rules it knows about, and has no reason to preserve a chain it did not create.
2. **`iptables-nft` and native `nft` disagree about what they are looking at.** A native chain added with `nft` is invisible to `iptables -t nat -L`, so anyone debugging container networking with iptables tools sees an incomplete picture of a table they believe they own.
3. **The tutorial also said to persist it** by appending to `/etc/sysconfig/nftables.conf` and enabling `nftables.service`. That schedules a *reload of podman's table on every boot*, racing whatever netavark is doing at the time.

⚠ **The reason this is worse than an outright failure.** All three commands succeed, the masquerade works, §10 boots fine. The breakage arrives later, at a container restart or a reboot, as either lost egress for the compute nodes (Talos hanging at `downloading installer`) or lost port forwarding for the registry and S3 gateway — neither of which points at a firewall rule written days earlier.

## The fix — a table of our own

```
head$ sudo nft add table ip twnat
head$ sudo nft 'add chain ip twnat postrouting { type nat hook postrouting priority srcnat ; }'
head$ sudo nft add rule ip twnat postrouting ip saddr 172.16.0.0/24 oif "eth0" masquerade
head$ sudo nft list table ip twnat
```

Two nftables tables may both hook `postrouting`, and both are evaluated. There is no ordering question to answer because the matches are disjoint: ours is `ip saddr 172.16.0.0/24`, netavark's are `10.88.0.0/16`, `10.89.1.0/24` and a packet mark. Nothing overlaps, so nothing depends on which runs first.

`priority srcnat` is the symbolic name for `100` — the same value, written the way nftables documents it for source NAT.

To persist, declare **only our table**:

```
head$ sudo tee /etc/sysconfig/nftables.conf > /dev/null <<'EOF'
#!/usr/sbin/nft -f
# TechWatch: NAT for the OpenCHAMI provisioning wire (§5.12).
# Deliberately in its own table — `table ip nat` belongs to iptables-nft.
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

The stock `/etc/sysconfig/nftables.conf` is comments only and `nftables.service` ships `disabled`, so there is nothing to preserve — but check yours rather than assuming.

**`add` then `delete` is the idempotency idiom.** `add table` is a no-op if the table exists, which guarantees the following `delete table` cannot fail; together they give `twnat` a clean slate. Without it, re-running `nft -f` appends a duplicate rule each time.

🛑 **Never write `flush ruleset` in that file.** It is the conventional first line of a standalone nftables config, and here it would delete podman's entire NAT table on every boot — taking `:5000` and `:7070` with it. The `add`/`delete` pair is the narrow equivalent, scoped to one table.

## Verify

Both halves matter: that our rule is there, and that podman's is untouched.

```
head$ sudo nft list chain ip twnat postrouting
ip saddr 172.16.0.0/24 oif "eth0" masquerade

head$ sudo nft list table ip nat | grep -c NETAVARK     # non-zero: still intact
head$ sudo podman ps --format '{{.Names}}' | wc -l      # 13, unchanged
head$ curl -sf http://127.0.0.1:7070 > /dev/null && echo "S3 gateway still reachable"
```

The real proof of the NAT itself does not arrive until §10, when Talos nodes fetch `ghcr.io/siderolabs/installer` through the head.

## Rejected — install firewalld

`sudo dnf install -y firewalld` would give access to §5.12's other branch, and firewalld coexists with podman properly, since podman knows how to register its rules with it.

Rejected because installing and starting firewalld on a head node that is *already* running the full control plane means a firewalld reload flushing the nftables ruleset, after which podman must re-add its rules — a real risk of losing container networking to fix a problem that a separate table solves with no disruption at all. On a fresh instance, before §5, it would be a reasonable choice.

## Where the fix lives

| Place | What changed |
|---|---|
| [§5.12](../05-install-openchami.md) | branch detection now checks `command -v firewall-cmd`, not just whether the service is active; the nftables path uses `twnat`; the persistence block declares only our table, with the `flush ruleset` warning; verification now also asserts podman is intact |
| `ochami-openstack-talos-iac/ansible/playbooks/02-nat.yml` | same table change in the persistent ruleset, and a new task asserting `NETAVARK` is still present in `table ip nat` after we are done |
| [glossary](../glossary/openchami.md) | the head-as-NAT-router entry records which table to use and why |

## Wider lesson

⚠ **On a host running containers, the NAT table is not yours.** This applies to any Podman or Docker host, not just this one — both write to `table ip nat` via the iptables compatibility layer. If you need your own NAT rules alongside them, use your own table. The general form of the mistake is assuming that "the" nat table is a shared space; nftables' explicit warning exists because it isn't.
