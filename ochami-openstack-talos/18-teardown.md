# §18 — Teardown

*(Time: ~10 minutes. On the devbox. Do this whenever you are not actively using the cluster: the instances hold quota and burn power on a shared hypervisor.)*

```
devbox$ cd ~/tw && source tw-env.sh
```

## Concepts

Teardown on a shared cloud is not just tidiness, it is part of being a good tenant. It is also a **test**: if teardown and rebuild are cheap, the rig is doing its job, and §10.7 already showed that rebuilding the cluster needs no OpenCHAMI changes at all.

**Order matters**, because Neutron refuses to delete things that are in use:

```
   instances  →  floating IP  →  ports  →  router interfaces  →  router
                                        →  subnets  →  networks
                                        →  security groups, keypair, images, volumes
```

🛑 **Delete only what you created.** Everything ours carries the `tw-` prefix (§1's rules). If `openstack server list` shows something without it, leave it alone — it belongs to someone else, even if you have permission to remove it. And never touch `${TW_EXT_NET}`: we attached to it, we do not own it.

## Decide how far to go

Three useful depths:

| Depth | What it costs to come back | Do this when |
|---|---|---|
| **A. Stop the nodes** | minutes — they boot from disk | pausing for the day |
| **B. Delete the nodes, keep the head** | ~30 min (§§10.1–10.6) | done with the Kubernetes layer, still working on OpenCHAMI |
| **C. Delete everything** | ~2 hours (§§3–10) | finished, or handing quota back |

Depth **B** is the sweet spot: the head node holds all of §§5–9's work, and the nodes are the part that reinstalls in minutes.

## Depth A — stop the nodes

Shut Kubernetes down cleanly first, then stop the instances:

```
head$   talosctl -n 172.16.0.1,172.16.0.2,172.16.0.3 shutdown
devbox$ openstack server list -c Name -c Status     # wait for SHUTOFF
```

If a node does not go down by itself, stop it from Nova:

```
devbox$ for n in ${TW_PREFIX}-cp1 ${TW_PREFIX}-w1 ${TW_PREFIX}-w2; do
    openstack server stop "$n"; done
devbox$ openstack server list -c Name -c Status
```

📌 **No boot-mode dance before stopping.** Installed nodes boot Talos from their own disks (§10), so there is nothing to take them out of — and nothing to forget. Stopping and starting them is an ordinary power cycle.

To resume:

```
devbox$ for n in ${TW_PREFIX}-cp1 ${TW_PREFIX}-w1 ${TW_PREFIX}-w2; do
    openstack server start "$n"; done
head$   kubectl get nodes         # etcd recovers; give it a couple of minutes
```

⚠ **Start the control-plane node first**, or at least don't be alarmed when workers show `NotReady` until it is up.

## Depth B — delete the nodes, keep the head

```
devbox$ for n in ${TW_PREFIX}-cp1 ${TW_PREFIX}-w1 ${TW_PREFIX}-w2; do
    openstack server delete "$n" --wait; done
```

The MAC-pinned ports **survive** — they were created independently in §3.4, so `server delete` releases them rather than destroying them:

```
devbox$ openstack port list --network ${TW_PREFIX}-prov -c Name -c Status -c 'MAC Address'
⟨expect the ports still listed, Status DOWN⟩
```

That is the payoff of creating ports separately: the MAC → IP → xname contract in SMD and BSS is still valid, so coming back is just §7.3 and §10 again. Nothing on the head needs touching.

## Depth C — delete everything

Instances first:

```
devbox$ openstack server list -c Name -f value | grep "^${TW_PREFIX}-" \
          | xargs -r -n1 openstack server delete --wait
```

Then the floating IP:

```
devbox$ openstack server remove floating ip ${TW_PREFIX}-head ${TW_HEAD_FIP} 2>/dev/null || true
devbox$ openstack floating ip delete ${TW_HEAD_FIP}
```

Then ports:

```
devbox$ openstack port list -c Name -f value | grep "^${TW_PREFIX}-" \
          | xargs -r -n1 openstack port delete
```

Then the router — detach the subnet before deleting, and clear the external gateway:

```
devbox$ openstack router remove subnet ${TW_PREFIX}-router ${TW_PREFIX}-ext-subnet
devbox$ openstack router unset --external-gateway ${TW_PREFIX}-router
devbox$ openstack router delete ${TW_PREFIX}-router
```

Then subnets and networks:

```
devbox$ openstack subnet delete ${TW_PREFIX}-ext-subnet ${TW_PREFIX}-prov-subnet
devbox$ openstack network delete ${TW_PREFIX}-ext ${TW_PREFIX}-prov
```

Then everything else we made:

```
devbox$ openstack security group delete ${TW_PREFIX}-sg-head ${TW_PREFIX}-sg-api 2>/dev/null || true
devbox$ openstack keypair delete ${TW_PREFIX}-key
devbox$ openstack image list --private -c Name -f value | grep "^${TW_PREFIX}-" \
          | xargs -r -n1 openstack image delete
devbox$ openstack volume list -c Name -f value | grep "^${TW_PREFIX}-" \
          | xargs -r -n1 openstack volume delete
```

⚠ **The image list is enumerated rather than named on purpose.** Which private images exist depends on which boot mechanism your cloud gave you in §7 — `tw-ipxe-disk` on this one, plus others if you followed [appendix F](appendix-f-network-boot-investigation.md) or built appendix A's rescue image. Deleting by prefix catches all of them; an explicit list silently leaves whichever you did not have on the day the line was written. Check the output before you run it, since it is driven by a `grep` on your own prefix.

## And the things that are not in OpenStack

Easy to forget, and two of them are credentials:

```
devbox$ openstack application credential delete tw-ochami-proto     # §1.2
devbox$ rm -f ~/tw/*.sh ~/.ssh/tw_ed25519*
devbox$ sed -i '/tw\/tw-env\.sh/d' ~/.bashrc                        # §1.5's activation line
devbox$ limactl delete openstack-devbox                             # if you're done entirely
```

📌 **`rm ~/tw/*.sh` is all four devbox files** — `tw-env.sh`, `tw-vars-env.sh`, `tw-helpers-env.sh` and `tw-status.sh` — which is the practical benefit of a single prefix in one directory. Delete the `.bashrc` line too, or every future login on a devbox you kept prints a "not found" note from a tutorial you finished.

If you are keeping the head node but tearing down the cluster, the same applies there — the files are `~/tw-head-*`, and `.bashrc` has one line naming the entry point:

```
head$ rm -f ~/tw-head-*.sh
head$ sed -i '/tw-head-env\.sh/d' ~/.bashrc
```

The **Flux repository** is deliberately *not* deleted — it is the record of what was deployed, and it is what you point the next cluster at. Suspend it instead if you want it to stop trying:

```
head$ flux suspend kustomization --all
```

## ✅ Checkpoint — prove you gave it back

```
devbox$ openstack server list
devbox$ openstack port list
devbox$ openstack network list
devbox$ openstack floating ip list
devbox$ openstack volume list
devbox$ openstack image list --private
devbox$ openstack security group list
```

For depth C, every one of those should be empty of `tw-` resources. Anything left is quota somebody else can't use.

```
devbox$ openstack quota show -f value -c instances -c cores -c ram
⟨compare against §1.5's figures — usage should be back to zero⟩
```

## Common failures

| Symptom | Cause / fix |
|---|---|
| `Server is in RESCUE state and can't be stopped` | only reachable if you took a rescue-based mechanism from [appendix F](appendix-f-network-boot-investigation.md) — `openstack server unrescue <name>` first |
| `Network … has ports still in use` | delete the ports first; check `openstack port list --network <net>` |
| `Router … has ports still in use` | `router remove subnet` and `router unset --external-gateway` before deleting |
| `Port … is currently in use` | an instance still holds it — `openstack port show <p> -c device_id` |
| `Subnet has allocated IPs` | a port survives somewhere, possibly a DHCP port from before §3.2's `--no-dhcp` |
| `Image is in use` | an instance was built from it and hasn't finished deleting — wait, then retry |
| Volume `deleting` for ever | it's still attached: `openstack server remove volume <server> <volume>` |

## Coming back

| From depth | Restart at |
|---|---|
| A | `openstack server start`, control-plane node first |
| B | §7.3 (create node instances), then §10 |
| C | §3 — and consider using the [companion IaC](../ochami-openstack-talos-iac/) instead, which is exactly what it is for |

Next: [§19 — Summary](19-summary.md)
