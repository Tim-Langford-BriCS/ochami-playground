# §9 — Configuring cloud-init

*(Upstream: tutorial Part 2.7 / guide §3.4. Time: ~10 minutes. On the head
node; fresh token needed.)*

## Concepts

The image from §7 is identical for every node — deliberately. What makes
`compute1` *compute1* (its hostname, your SSH key, per-role software
config) is applied at boot by **cloud-init**, exactly as in §4, except the
datasource isn't a seed ISO: it's **OpenCHAMI's cloud-init server**, which
builds a personalised answer for whichever node asks, straight from SMD.

Configuration is layered, most-general first:

1. **cluster defaults** — values every node gets (naming scheme, the SSH
   public keys, the server's own base URL);
2. **group config** — cloud-config attached to an SMD *group* (remember
   `compute` from §6); templated with Jinja2, so it can reference each
   node's metadata;
3. **per-node overrides** — e.g. "node x1000c0s0b0n0 is called compute1".

When a node fetches its config, the server merges the layers for *that*
node, identified by requesting IP → SMD record.

⚠⚠ **Gotcha — the memstore.** The cloud-init server keeps all of this
**in memory only**. Restart `cloud-init-server.service` (or the whole
`openchami.target`) and everything you set in this section is silently
gone. The failure it causes later is maddeningly indirect: nodes boot fine
but their vendor-data `#include` points at the server's *internal*
container address (`http://cloud-init:27777/...`), which no node can
reach, so cloud-init errors and your SSH key never lands. **After any
OpenCHAMI restart, re-run this section** (it's four idempotent commands),
and make the `defaults get` check below a habit. This cost us an hour to
diagnose the first time — treat cloud-init config as something you
*re-assert*, not something you *did once*.

## Step 9.1 — An SSH key for reaching compute nodes

The head will SSH into booted nodes as root; cloud-init delivers the
public key:

```
head$ ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

## Step 9.2 — Cluster defaults

```
head$ sudo mkdir -p /etc/openchami/data/cloud-init
head$ cat << EOF | sudo tee /etc/openchami/data/cloud-init/ci-defaults.yaml
---
base-url: "http://172.16.0.254:8081/cloud-init"
cluster-name: "demo"
nid-length: 2
public-keys:
  - "$(cat ~/.ssh/id_ed25519.pub)"
short-name: "de"
EOF
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
head$ ochami cloud-init defaults set -f yaml -d @/etc/openchami/data/cloud-init/ci-defaults.yaml
```

`base-url` is the address the server writes into the `#include` URLs it
hands to nodes — the *node-reachable* one (see the memstore gotcha for
what happens when this is unset). `short-name: de` + `nid-length: 2` set
default hostnames `de01`…`de05` — deliberately matching §5.8's CoreDNS
rule `nodes de{02d}`, so hostnames and DNS agree.

**Verify it persisted** (this is the memstore habit):

```
head$ ochami cloud-init defaults get -F json | jq -c 'keys'
["base-url","cluster-name","nid-length","public-keys","short-name"]
```

## Step 9.3 — Group config for `compute`

```
head$ sudo tee /etc/openchami/data/cloud-init/ci-group-compute.yaml > /dev/null << 'EOF'
- name: compute
  description: "compute config"
  file:
    encoding: plain
    content: |
      ## template: jinja
      #cloud-config
      merge_how:
      - name: list
        settings: [append]
      - name: dict
        settings: [no_replace, recurse_list]
      users:
        - name: root
          ssh_authorized_keys: {{ ds.meta_data.instance_data.v1.public_keys }}
      disable_root: false
EOF
head$ ochami cloud-init group set -f yaml -d @/etc/openchami/data/cloud-init/ci-group-compute.yaml
head$ ochami cloud-init group get config compute | head -5
```

This is ordinary cloud-config with one twist: the
`{{ ds.meta_data... }}` Jinja expression is expanded *per node* by the
server, splicing the cluster `public-keys` from step 9.2 into root's
`authorized_keys`. Every node in the SMD group `compute` receives it.

## Step 9.4 — Name node 1

```
head$ ochami cloud-init node set -d '[{"id":"x1000c0s0b0n0","local-hostname":"compute1"}]'
```

A per-node override: nid 1 would default to `de01`; we prefer `compute1`.
(Purely cosmetic — and a visible proof in §10 that the whole layering
worked.)

## ✅ Checkpoint — render what compute1 will receive

```
head$ ochami cloud-init node get meta-data x1000c0s0b0n0 -F yaml | head -12
- cluster-name: demo
  hostname: de01
  instance-id: i-...
  instance_data:
    v1:
        ...
        local_ipv4: 172.16.0.1
        public_keys:
            - ssh-ed25519 AAAA... rocky@head

head$ ochami cloud-init node get vendor-data x1000c0s0b0n0
#include
http://172.16.0.254:8081/cloud-init/compute.yaml
```

Two things to eyeball: your real public key inside the metadata, and the
`#include` URL pointing at **172.16.0.254:8081** — if it says
`http://cloud-init:27777/...` instead, the defaults didn't persist (see
the memstore gotcha; re-run 9.2).

Next: [§10 — Booting the compute node](10-boot-compute-node.md)
