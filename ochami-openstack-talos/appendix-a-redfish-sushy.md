# Appendix A — Virtual BMCs and Redfish discovery

*(Time: ~1 hour. Do this **after** §10 works. Dynamic Redfish discovery is the biggest difference between this POC and a standard OpenCHAMI cluster — though possibly not between this POC and the PTR; see the note below.)*

## Why this appendix exists

§6 wrote a YAML file by hand and told SMD "these are the nodes". On a **standard** OpenCHAMI cluster you would not do that. Real servers have **BMCs** — baseboard management controllers, the small always-on computer inside every server that speaks [Redfish](https://www.dmtf.org/standards/redfish) over HTTP. OpenCHAMI's **Magellan** scans the management network, asks each BMC what it is, and populates SMD *from the hardware itself*.

📌 **The PTR may not work this way.** As of **4 Aug 2026** the working expectation is that the PTR will populate SMD from **statically configured metadata** rather than Redfish discovery — in which case §6's hand-written file is the rehearsal and this appendix is background. That is an expectation and not a decision, and it is why this appendix stays: whichever way the PTR goes, the mechanism below is how OpenCHAMI is designed to work and you cannot reason about SMD without it. [DL-004](DECISION-LOG.md#dl-004--how-smd-gets-populated-on-the-ptr-and-under-whose-naming-scheme) has the detail.

That difference brings three things this POC otherwise never touches:

1. **Dynamic discovery** — SMD is populated by asking, not by asserting. MACs are discovered, not invented.
2. **BMC credentials** — a real secret-management problem, per chassis.
3. **Redfish power control** — power on/off/cycle and boot-device selection through a standard API, replacing `openstack server rescue`.

[sushy-tools](https://opendev.org/openstack/sushy-tools) closes the gap. It is OpenStack's own Redfish BMC emulator, used throughout OpenStack's CI to make virtual machines look like bare metal. Its **OpenStack driver** maps Redfish Systems onto Nova instances — which is exactly our situation.

And here is the pleasing part, already noted in §0 and §7: sushy-tools implements Redfish "set boot device to PXE, then reset" **by putting the Nova instance into rescue mode with an iPXE image**. Everything you did in §7 was the manual form of what this appendix automates. There is no new mechanism to learn — only a standard API in front of it.

```
   §7 / §10 (manual)                    this appendix
   ─────────────────                    ─────────────
   openstack server rescue      ←→      Redfish: BootSourceOverrideTarget=Pxe + Reset
   openstack server unrescue    ←→      Redfish: BootSourceOverrideTarget=Hdd + Reset
   openstack server start/stop  ←→      Redfish: Reset On / ForceOff
   hand-written nodes.yaml      ←→      magellan scan + collect → SMD
```

## The design: one BMC per node

A real server has one BMC serving one system. sushy-tools, by default, exposes *every* instance it can see at a single endpoint — which is convenient but not faithful, and Magellan expects to talk to one BMC per machine.

`SUSHY_EMULATOR_ALLOWED_INSTANCES` fixes this. Run **one emulator process per node**, each restricted to one instance UUID, each on its own port. Now each node has a distinct BMC endpoint, exactly like the real thing:

```
   head node 172.16.0.254
   ├── sushy-emulator :8000  → allowed: tw-cp1  → "BMC" for x1000c0s0b0
   ├── sushy-emulator :8001  → allowed: tw-w1   → "BMC" for x1000c0s0b1
   └── sushy-emulator :8002  → allowed: tw-w2   → "BMC" for x1000c0s0b2
```

🔀 **Deviation from reality, acknowledged.** On the PTR each BMC has its own IP on the management network. Here they are ports on the head node. You could bind additional addresses to the head's provisioning interface (`172.16.0.101`, `.102`, … — the very addresses §6's placeholder `bmcs:` entries already claim) and listen on port 443 on each, which would be closer still. Ports are simpler; the addresses are more faithful. Either works for Magellan. Pick one and note it.

## Step A.1 — Credentials for the emulator

sushy-emulator needs to call the Nova API, which means OpenStack credentials on the head node.

🛑 **Think about this before doing it.** Until now the head node held no cloud credentials, so compromising it gained an attacker nothing outside the cluster. Adding credentials changes that: the head can now create and destroy instances in the project. Mitigate:

- Create a **separate** application credential for this purpose, not the one from §1.2. Then revoking it doesn't break your own workflow.
- Scope it to `member` only and give it an expiry.
- `chmod 600` the `clouds.yaml` on the head, owned by the service user.
- Note in your run log that the head is now a privileged host. On the PTR the equivalent is BMC credentials, which is the same class of problem — this appendix is a rehearsal for that too.

```
devbox$ openstack application credential create \
    --description "sushy-emulator on tw-head — virtual BMCs" \
    --expiration 2026-12-31T00:00:00 --role member \
    tw-sushy
```

On the head:

```
head$ mkdir -p ~/.config/openstack && chmod 700 ~/.config/openstack
head$ cat > ~/.config/openstack/clouds.yaml << 'EOF'
clouds:
  techwatch:
    auth_type: v3applicationcredential
    auth:
      auth_url: <AUTH_URL>
      application_credential_id: <TW_SUSHY_ID>
      application_credential_secret: <TW_SUSHY_SECRET>
    region_name: <REGION>
    interface: public
    identity_api_version: 3
EOF
head$ chmod 600 ~/.config/openstack/clouds.yaml
```

## Step A.2 — Install sushy-tools

```
head$ sudo dnf install -y python3-pip
head$ python3 -m venv ~/sushy && ~/sushy/bin/pip install --upgrade pip
head$ ~/sushy/bin/pip install sushy-tools openstacksdk
head$ ~/sushy/bin/sushy-emulator --help | head -20
```

## Step A.3 — Configuration, one file per node

Get the instance UUIDs — these are what Redfish will call Systems:

```
devbox$ openstack server list -c Name -c ID -f value | grep "^tw-"
```

Then on the head, one config per node:

```
head$ mkdir -p ~/sushy/etc /var/lib/sushy-emulator
head$ cat > ~/sushy/etc/tw-cp1.conf << 'EOF'
# sushy-emulator config — virtual BMC for ONE node (appendix A)

# Enable the OpenStack driver: Redfish Systems become Nova instances.
SUSHY_EMULATOR_OS_CLOUD = 'techwatch'

# Expose exactly one instance, so this endpoint is a faithful single-system BMC.
SUSHY_EMULATOR_ALLOWED_INSTANCES = ['<TW_CP1_INSTANCE_UUID>']

# Implement Redfish "boot device = Pxe" via Nova rescue with an iPXE image —
# precisely what §7.5 did by hand.
SUSHY_EMULATOR_OS_RESCUE_PXE_BOOT = True
SUSHY_EMULATOR_OS_RESCUE_PXE_IMAGE_BIOS = 'tw-ipxe'
SUSHY_EMULATOR_OS_RESCUE_PXE_IMAGE_UEFI = 'tw-ipxe'

# Persist boot-override state across restarts.
SUSHY_EMULATOR_STATE_DIR = '/var/lib/sushy-emulator/tw-cp1'

# Listen on the provisioning wire only — this is a management interface.
SUSHY_EMULATOR_LISTEN_IP = '172.16.0.254'
SUSHY_EMULATOR_LISTEN_PORT = 8000
EOF
```

Both `_BIOS` and `_UEFI` point at the same image because iPXE's `ipxe.iso` boots under either firmware (§7.1). If §1.5 found your cloud uses one specifically, you can set just that one.

Copy for the workers, changing the UUID, the state dir and the port:

```
head$ sed -e 's/tw-cp1/tw-w1/g' -e 's/8000/8001/' \
        -e 's/<TW_CP1_INSTANCE_UUID>/<TW_W1_INSTANCE_UUID>/' \
        ~/sushy/etc/tw-cp1.conf > ~/sushy/etc/tw-w1.conf
head$ sed -e 's/tw-cp1/tw-w2/g' -e 's/8000/8002/' \
        -e 's/<TW_CP1_INSTANCE_UUID>/<TW_W2_INSTANCE_UUID>/' \
        ~/sushy/etc/tw-cp1.conf > ~/sushy/etc/tw-w2.conf
```

⚠ **Check the `sed` results.** Substituting UUIDs with `sed` is exactly the kind of thing that silently produces three emulators all pointing at the same instance. `grep ALLOWED_INSTANCES ~/sushy/etc/*.conf` and confirm three different values.

There is a documented template at [`templates/sushy-emulator.conf`](templates/sushy-emulator.conf).

## Step A.4 — Run them as services

```
head$ sudo tee /etc/systemd/system/sushy-emulator@.service > /dev/null << 'EOF'
[Unit]
Description=Virtual Redfish BMC for %i
After=network-online.target
Wants=network-online.target

[Service]
User=rocky
Environment=SUSHY_EMULATOR_CONFIG=/home/rocky/sushy/etc/%i.conf
ExecStart=/home/rocky/sushy/bin/sushy-emulator --config /home/rocky/sushy/etc/%i.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

head$ sudo systemctl daemon-reload
head$ for n in tw-cp1 tw-w1 tw-w2; do
        sudo systemctl enable --now sushy-emulator@$n; done
head$ systemctl is-active sushy-emulator@tw-cp1 sushy-emulator@tw-w1 sushy-emulator@tw-w2
```

⚠ **No TLS and no authentication here.** sushy-emulator supports `SUSHY_EMULATOR_SSL_CERT`/`_KEY` and can sit behind an authenticating proxy. We run it plain because the provisioning wire is isolated — but note that on the PTR, BMC credentials and TLS are mandatory, and Magellan expects to *use* them. Consider adding them here anyway, to rehearse that half.

## Step A.5 — Talk to a virtual BMC

```
head$ curl -s http://172.16.0.254:8000/redfish/v1/Systems | jq .
⟨captured on first run — expect exactly ONE member, /redfish/v1/Systems/<uuid>⟩

head$ UUID=<TW_CP1_INSTANCE_UUID>
head$ curl -s http://172.16.0.254:8000/redfish/v1/Systems/$UUID \
        | jq '{PowerState, Boot, MemorySummary, ProcessorSummary}'
```

Now the interesting part — **network-boot the node over Redfish**:

```
head$ curl -s -X PATCH http://172.16.0.254:8000/redfish/v1/Systems/$UUID \
    -H 'Content-Type: application/json' \
    -d '{"Boot":{"BootSourceOverrideEnabled":"Once","BootSourceOverrideTarget":"Pxe"}}'

head$ curl -s -X POST \
    http://172.16.0.254:8000/redfish/v1/Systems/$UUID/Actions/ComputerSystem.Reset \
    -H 'Content-Type: application/json' -d '{"ResetType":"ForceRestart"}'
```

✅ **Checkpoint — the whole appendix in one observation**

```
devbox$ openstack server show tw-cp1 -c status -f value
RESCUE
```

**You set a Redfish boot override and a Nova instance went into rescue mode.** The node is now network-booting through the exact chain from §10 — CoreDHCP, BSS, Talos — but nothing in this tutorial issued an `openstack` command. That is the same API call you will make to a real Dell iDRAC or HPE iLO.

And back to disk:

```
head$ curl -s -X PATCH http://172.16.0.254:8000/redfish/v1/Systems/$UUID \
    -H 'Content-Type: application/json' \
    -d '{"Boot":{"BootSourceOverrideEnabled":"Disabled","BootSourceOverrideTarget":"Hdd"}}'
head$ curl -s -X POST \
    http://172.16.0.254:8000/redfish/v1/Systems/$UUID/Actions/ComputerSystem.Reset \
    -H 'Content-Type: application/json' -d '{"ResetType":"ForceRestart"}'
```

## Step A.6 — Magellan: discovery for real

Now replace §6's hand-written inventory with discovery.

```
head$ curl -sL https://github.com/OpenCHAMI/magellan/releases/latest/download/magellan_Linux_x86_64.tar.gz \
        | tar xz -C /tmp && sudo install -m0755 /tmp/magellan /usr/local/bin/magellan
head$ magellan --help
```

⚠ **Check the flags against `magellan --help` rather than trusting the shape below.** Magellan is under active development and its CLI has changed between releases; the workflow is stable but the flag names are not. The three phases are:

**Scan** — find BMC endpoints on the wire:

```
head$ magellan scan --subnet 172.16.0.0/24 --port 8000 --port 8001 --port 8002 \
        --scheme http --cache /tmp/magellan.db
```

**Collect** — ask each one what it is, over Redfish:

```
head$ magellan collect --cache /tmp/magellan.db \
        --username '' --password '' \
        --output /tmp/magellan-inventory
```

(Empty credentials because §A.4 runs the emulators without authentication. On the PTR these are real BMC credentials — and this is the line where credential management becomes a design problem.)

**Send to SMD:**

```
head$ export DEMO_ACCESS_TOKEN=$(sudo bash -lc 'gen_access_token')
head$ magellan send --host https://demo.openchami.cluster --port 8443 \
        --cache /tmp/magellan.db \
        --cacert /etc/openchami/certs/root_ca.crt
```

🛑 **Do this on a fresh SMD, or expect conflicts.** §6 already populated SMD with the same xnames, and `discover static` was an *add*, not an upsert. To do this properly, delete the static components first (`ochami smd component delete …`) — or, better, rebuild the head node and skip §6 entirely, which is the honest test of whether discovery works.

✅ **Checkpoint**

```
head$ ochami smd component get | jq '[.Components[]|select(.Type=="Node")]|length'
⟨expect your node count — populated by discovery, not by hand⟩

head$ ochami smd component get | jq '.Components[]|select(.Type=="NodeBMC")'
⟨expect BMC components with the emulator endpoints⟩
```

If the MACs SMD now holds came from Nova rather than from §6's invented list, **§9's BSS payloads must be updated to match** — which is the whole three-way contract again, now with discovered values. This is exactly the situation you will be in on the PTR.

## What this rehearses, and what it still doesn't

| Rehearsed | Still not rehearsed |
|---|---|
| Redfish as the power and boot-device API | real vendor Redfish quirks — Dell iDRAC and HPE iLO differ from each other and from the spec |
| Magellan scan → collect → SMD, end to end | BMC discovery across a real switched management VLAN |
| One BMC endpoint per machine | BMC firmware versions, and updating them |
| Credentials being needed at all | real credential storage, rotation and per-chassis scoping |
| Discovered MACs feeding the boot payloads | discovered *hardware inventory* — CPU, memory, NIC models — which real BMCs report and the emulator largely invents |

That last row matters for the PTR: standardising Redfish inventory is an active OpenCHAMI RFD topic (#69), and it is one of the places Bristol could usefully contribute.

## Common failures

| Symptom | Cause / fix |
|---|---|
| Emulator won't start, `Could not find cloud techwatch` | `clouds.yaml` not readable by the service user, or the cloud name doesn't match `SUSHY_EMULATOR_OS_CLOUD` |
| `/redfish/v1/Systems` lists more than one member | `SUSHY_EMULATOR_ALLOWED_INSTANCES` not applied — check your `sed` output |
| `/redfish/v1/Systems` is empty | the UUID is wrong, or the credential can't see the instance |
| Boot override accepted but the instance never enters RESCUE | `SUSHY_EMULATOR_OS_RESCUE_PXE_BOOT` not `True`, or the named image doesn't exist. Check the emulator's log: `journalctl -u sushy-emulator@tw-cp1` |
| `magellan scan` finds nothing | wrong `--scheme` (we serve plain `http`), or the emulators are bound to an address the scan doesn't cover |
| `magellan send` → `409 Conflict` | SMD already holds those xnames from §6 — see the 🛑 above |
| Nodes stop booting correctly after discovery | discovered MACs differ from §6's invented ones; update §9's BSS payloads |

## Related

- [§0 — decision 2](00-introduction.md), which introduced the rescue/Redfish mapping
- [§7 — the manual version of everything here](07-node-instances-and-ipxe.md)
- [Appendix B — lineage](appendix-b-lineage.md), where this row changes from "?" to "done"
- [sushy-tools documentation](https://docs.openstack.org/sushy-tools/latest/user/dynamic-emulator.html)
- [Magellan](https://openchami.org/docs/software/magellan/)
