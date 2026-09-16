# 003 — BSS serves `chain https://${SYSTEM_URL}/apis/bss/…`, and iPXE resolves it to nothing

| | |
|---|---|
| **Status** | ✅ **Fixed and verified on `tw-head`, 6 Aug 2026.** Root cause: `/etc/openchami/configs/openchami.env:28` set `BSS_IPXE_SERVER=${SYSTEM_URL}`, and an `EnvironmentFile=` does not expand variables, so BSS received the literal string. BSS was behaving as written. See [the fix](#the-fix--tell-bss-the-address-nodes-actually-use) and [verification](#verification) |
| **Hit at** | §7.2c — the first successful network boot. Visible from §5 onwards to anyone who reads a boot script |
| **Now prevented by** | [**§5.9b**](../05-install-openchami.md#step-59b--point-bss-at-an-address-a-node-can-reach), added 6 Aug 2026. A reader following the tutorial in order sets these three values before OpenCHAMI ever starts and never meets this. This issue is kept as the evidence and the reasoning |
| **Observed** | 2026-08-04, `tw-head`, OpenCHAMI quickstart quadlets, `iPXE 2.0.0+ (ga1992)` on `tw-probe3` |
| **Severity** | **"Works now, fails later" — the 002 shape.** Nothing in a *successful* boot touches this line. It is the retry path, so it is dormant until the moment something else goes wrong, which is exactly when you need it |
| **Blocks** | nothing in §§8–10. Do not stop to fix it if you are mid-run |

## The error

Seen first from a node, at the end of an otherwise perfect boot ([§7.2c](../appendix-f-network-boot-investigation.md#-the-result-on-techwatch-proto-4-aug-2026--test-4-passed)):

```
http://172.16.0.254:8081/boot/v1/bootscript... ok
bootscript : 127 bytes [script]
https:///apis/bss/boot/v1/bootscript... Error 0x3e11618e (https://ipxe.org/3e11618e)
Could not boot image: Error 0x3e11618e (https://ipxe.org/3e11618e)
```

`0x3e11618e` is iPXE's *DNS name does not exist* (`net/udp/dns.c`). Note the URL: `https://` followed immediately by `/apis` — **there is no hostname in it at all.**

Then from the head, asking BSS the same question the node asked:

```
head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:05"
#!ipxe
sleep 10
chain https://${SYSTEM_URL}/apis/bss/boot/v1/bootscript?mac=52:54:00:be:ef:05&arch=${buildarch}&ts=1785863055
```

BSS emitted the four characters `${SY…}` verbatim. iPXE then did what iPXE does with `${…}`: expanded it as a setting name, found no such setting, and substituted the empty string.

⚠ **Two different variable syntaxes, one line, and only one of them is a bug.** `${buildarch}` on the same line is *deliberate* — that one iPXE does know, and it is how BSS asks the node to declare its architecture. `${SYSTEM_URL}` was meant to have been substituted long before the script reached a node. That mix is why this is easy to look at and not see.

## Why it occurs

BSS builds every chain URL from three environment variables, in [`cmd/boot-script-service/default_api.go`](https://github.com/OpenCHAMI/bss/blob/main/cmd/boot-script-service/default_api.go):

```go
var ipxeServer = getEnvVal("BSS_IPXE_SERVER", "api-gw-service-nmn.local")
var chainProto = getEnvVal("BSS_CHAIN_PROTO", "https")
var gwURI      = getEnvVal("BSS_GW_URI", "/apis/bss")
…
chain := "chain " + chainProto + "://" + ipxeServer + gwURI + "/boot/v1/bootscript"
chain += "?mac=" + mac
chain += fmt.Sprintf("&arch=${buildarch}&ts=%d", ts)
```

String concatenation, no validation, no expansion. So the served script is a faithful rendering of what the container's environment says — and our container's environment says `BSS_IPXE_SERVER=${SYSTEM_URL}`, verbatim.

### Confirmed on `tw-head`, 4 Aug 2026

The running process's own environment, which is the only evidence that settles it:

```
head$ sudo podman exec bss env | grep -E 'BSS_IPXE_SERVER|BSS_CHAIN_PROTO|BSS_GW_URI'
BSS_CHAIN_PROTO=https
BSS_IPXE_SERVER=${SYSTEM_URL}
```

`BSS_GW_URI` is absent, so BSS falls back to its default `/apis/bss`. And the source of the literal:

```
head$ sudo grep -rn 'BSS_IPXE_SERVER\|SYSTEM_URL' /etc/containers/systemd/ /etc/openchami/
/etc/openchami/configs/openchami.env:5:SYSTEM_URL=demo.openchami.cluster
/etc/openchami/configs/openchami.env:28:BSS_IPXE_SERVER=${SYSTEM_URL}
/etc/openchami/configs/opaal.yaml:10:      authorization: "https://${SYSTEM_URL}/oauth2/authorize"
… three more in opaal.yaml
```

**Two faults in one line, and only one of them is about expansion.**

1. **Nothing expands `${SYSTEM_URL}`.** An `EnvironmentFile=` is parsed as literal `KEY=VALUE` pairs — systemd and podman do not perform shell-style variable substitution inside one, and there is no other layer here that would. The file was written for a `docker compose` deployment where interpolation happens while parsing the *compose YAML*; carried into quadlets, the reference survives verbatim into the process.
2. **Even expanded, it would be wrong for us.** `SYSTEM_URL` is `demo.openchami.cluster` — *our own* `TW_CLUSTER_FQDN` ([`templates/tw-vars-env.sh`](../templates/tw-vars-env.sh)), not a placeholder anyone forgot to change. But it is deliberately a name that resolves **only on the head**, via the `/etc/hosts` line §5.2 adds, because that is all the API services calling each other need. A booting node has no such entry. And `BSS_CHAIN_PROTO=https` compounds it: even given resolution, iPXE would have to complete a TLS handshake against the private CA — the same limitation that stops us chaining to `factory.talos.dev` in §8.4.

So the failure is not one missing substitution; the variable is **the wrong source of truth for this field**. What belongs there is an address a node on the provisioning wire can reach without DNS.

**The defaults tell you where this code comes from.** `api-gw-service-nmn.local` is Cray CSM's API gateway hostname and `/apis/bss` is its gateway path prefix. On a CSM system every service sits behind that gateway, so a hardcoded gateway URL was correct. OpenCHAMI inherited the code and parameterised the hostname; a deployment that does not *have* an API gateway has to say so, and ours never did.

### Which script you are looking at

Both of BSS's delayed-retry paths use the same `chain` string:

| Path | Script | When |
|---|---|---|
| `sleep <hsmRetrievalDelay>` + chain | what we saw — `sleep 10` | BSS cannot yet say what this node should boot (no boot parameters set for it, i.e. §9 not done) |
| `:boot_retry` → `sleep 30` + chain | the tail of a *real* boot script | the kernel or initramfs failed to load and the node is asking again |

So the same broken URL is the last line of every fully-working boot script too. Compare the libvirt lab, [`ochami-macos-libvirt/08-boot-parameters.md`](../../ochami-macos-libvirt/08-boot-parameters.md), which captured it eleven months ago and shipped:

```
:boot_retry
sleep 30
chain https://${SYSTEM_URL}/apis/bss/boot/v1/bootscript?mac=52:54:00:be:ef:01&retry=1
```

⚠ **It was there all along, in a tutorial that worked.** That lab's nodes booted on the first attempt every time, so `:boot_retry` was never reached and nobody noticed. This is the honest reason it took a *failing* boot to find it.

## The fix — tell BSS the address nodes actually use

We already know the working URL, because CoreDHCP hands it out and the node fetched it successfully: `http://172.16.0.254:8081/boot/v1/bootscript`. So the three variables should describe exactly that, with no gateway prefix:

| Variable | Set to | Why |
|---|---|---|
| `BSS_IPXE_SERVER` | `172.16.0.254:8081` | the head's address *on the provisioning wire*, which is the only address a node can reach, plus BSS's port |
| `BSS_CHAIN_PROTO` | `http` | nodes have no reason to trust the head's certificate, and §5.9 issued it for the head's FQDN, not for `172.16.0.254` |
| `BSS_GW_URI` | **the empty string, explicitly set** | there is no API gateway here; nodes talk to BSS directly, so the `/apis/bss` prefix has to go. **Leaving it unset does *not* work** — absent means "use the default" — see the note below |

📌 **Setting `BSS_GW_URI` to the empty string really does clear the prefix.** BSS reads these with `os.LookupEnv`, not `os.Getenv` — so *set but empty* is honoured, and only *absent* falls back to `/apis/bss`. Verified in [`default_api.go`](https://github.com/OpenCHAMI/bss/blob/main/cmd/boot-script-service/default_api.go):

```go
func getEnvVal(envVar, defVal string) string {
	if e, ok := os.LookupEnv(envVar); ok {
		return e
	}
	return defVal
}
```

All three live in **`/etc/openchami/configs/openchami.env`** on this deployment — `BSS_IPXE_SERVER` at line 28, `BSS_CHAIN_PROTO` nearby, and `BSS_GW_URI` not present and needing to be added:

```
head$ sudo cp /etc/openchami/configs/openchami.env{,.bak-$(date +%F)}
head$ sudo vi /etc/openchami/configs/openchami.env
```

```diff
-BSS_IPXE_SERVER=${SYSTEM_URL}
+# The address a node on the provisioning wire can reach BSS at, with no DNS
+# and no API gateway in front of it. Not ${SYSTEM_URL} — see issues/003.
+BSS_IPXE_SERVER=172.16.0.254:8081
-BSS_CHAIN_PROTO=https
+BSS_CHAIN_PROTO=http
+BSS_GW_URI=
```

🛑 **Do not change `SYSTEM_URL` itself.** It is referenced four more times by `opaal.yaml` for the OIDC endpoints, and it feeds the certificate subject names (§5.9). Editing it to fix a boot script would reach into authentication and TLS for no benefit — `BSS_IPXE_SERVER` is the field that is wrong, so that is the field to set.

```
head$ sudo systemctl restart bss
head$ sudo podman exec bss env | grep -E 'BSS_IPXE_SERVER|BSS_CHAIN_PROTO|BSS_GW_URI'
```

⚠ **`daemon-reload` is not needed** — the env file is read when the container starts, and the quadlet unit itself is unchanged. Reload only if you edited something under `/etc/containers/systemd/`.

🛑 **Use an IP, not a name.** A node reaching this line is a node whose boot has already gone wrong; making its recovery depend on DNS adds a second thing to fail. This is the same reasoning BSS's own `-cloud-init-address` flag states for cloud-init: *"This needs to be an IP as we do not have DNS when cloud-init runs."*

## Verification

✅ **Applied on `tw-head`, 6 Aug 2026.** Captured verbatim.

```
head$ sudo podman exec bss env | grep -E 'BSS_IPXE_SERVER|BSS_CHAIN_PROTO|BSS_GW_URI'
BSS_IPXE_SERVER=172.16.0.254:8081
BSS_GW_URI=
BSS_CHAIN_PROTO=http

head$ curl -s "http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01"
#!ipxe
sleep 10
chain http://172.16.0.254:8081/boot/v1/bootscript?mac=52:54:00:be:ef:01&arch=${buildarch}&ts=1786051781
```

Compare with [the error](#the-error) at the top: `https:///apis/bss/…` has become a reachable URL, both faults — the missing host and the `/apis/bss` gateway prefix — gone in one edit.

`${buildarch}` **must still be there** — that one is iPXE's job. If it has vanished, something is expanding too much.

📌 **`BSS_GW_URI=` proves the `os.LookupEnv` reasoning above was right.** It appears in the container's environment as an empty value and the prefix is gone from the URL. Had BSS used `os.Getenv`, an empty string would have been indistinguishable from absent and the `/apis/bss` default would still be there.

If you want the applied-by-hand version rather than an editor session, this is what was run:

```
head$ sudo cp /etc/openchami/configs/openchami.env{,.bak-$(date +%F)}
head$ sudo sed -i \
    -e 's|^BSS_IPXE_SERVER=.*|BSS_IPXE_SERVER=172.16.0.254:8081|' \
    -e 's|^BSS_CHAIN_PROTO=.*|BSS_CHAIN_PROTO=http|' \
    /etc/openchami/configs/openchami.env
head$ grep -q '^BSS_GW_URI=' /etc/openchami/configs/openchami.env \
    || echo 'BSS_GW_URI=' | sudo tee -a /etc/openchami/configs/openchami.env
head$ sudo systemctl restart bss
```

Then prove the loop actually loops, which is the whole point of the fix:

```
devbox$ openstack server create ${TW_PREFIX}-probe4 --image ${TW_PREFIX}-ipxe-disk \
    --flavor ${TW_FLAVOR_CP} --port ${TW_PREFIX}-node5-prov --wait
devbox$ sleep 60 && openstack console log show ${TW_PREFIX}-probe4 --lines 40
```

Expect the node to fetch, sleep 10, fetch again, and keep going — instead of dropping to the EFI Shell after one attempt. That is a node politely waiting to be told what to boot, which is what an un-provisioned node should do.

## Rejected alternatives

**Make `${SYSTEM_URL}` expand.** Tempting, because the name suggests one cluster-wide identity and the quickstart's env file really is built around it ([glossary](../glossary/openchami.md)). Rejected on two grounds, and the second is the decisive one: an `EnvironmentFile=` has no expansion mechanism to enable, so the substitution would have to move into whatever *writes* the file — and `SYSTEM_URL` is a head-only name over HTTPS, so a successful expansion produces a URL that is still unreachable from a node and now *looks* deliberate. A literal address is one hop, greppable, and true.

**Point it at the head's FQDN over HTTPS.** Correct-looking, and closer to what OpenCHAMI intends on a real cluster. Rejected for the provisioning wire: it needs DNS and certificate trust in a booting node's iPXE, at the exact moment the node has neither, to reach a service that is one hop away by IP. Revisit for the PTR, where the management network has real DNS.

**Leave it.** Defensible mid-run — it blocks nothing, and §9's real boot script supersedes the immediate symptom. Rejected as a permanent state because the line survives into every working boot script as `:boot_retry`, so "leave it" means shipping a cluster whose recovery path is known-broken.

## Where the fix lives

| Place | What changed |
|---|---|
| §5 | `/etc/openchami/configs/openchami.env` — `BSS_IPXE_SERVER=172.16.0.254:8081`, `BSS_CHAIN_PROTO=http`, `BSS_GW_URI=` (added). §5 should set these when it writes the file rather than leaving the quickstart defaults — **pending** |
| [§7.2c](../07-node-instances-and-ipxe.md) | the captured console shows the failure and points here |
| §9 | the checkpoint should read the *whole* script, `:boot_retry` line included, rather than checking only the kernel and initrd lines — **pending** |
| `ochami-openstack-talos-iac/` | the head-node role needs the same three variables — **pending** |

## Upstream: obsolete, and deliberately not filed

Checked against [`OpenCHAMI/release`](https://github.com/OpenCHAMI/release) on **2026-08-17**,
while preparing the reports in [`notes/`](../notes/). The conclusion is that there is nothing
left to file.

| Ref | `openchami.env` | Verdict |
|---|---|---|
| `v0.1.6` — what `tw-head` runs | `SYSTEM_URL=demo.openchami.cluster` at line 5, `BSS_IPXE_SERVER=${SYSTEM_URL}` at line 28, `BSS_CHAIN_PROTO=https` at line 29 | the fault, exactly as we found it |
| `main` (post-[#50](https://github.com/OpenCHAMI/release/pull/50), 2026-08-05) | **no `SYSTEM_URL`, no `BSS_*` of any kind** | gone |

[PR #50](https://github.com/OpenCHAMI/release/pull/50) — *"feat!: update release with new
fabrica-based services; remove old services"* — replaced BSS with
[`boot-service`](https://github.com/OpenCHAMI/boot-service) outright, along with opaal and
hydra in favour of tokensmith. `boot-service` has **no equivalent field**: its config is a
YAML file with no ipxe-server, chain-proto or gateway-URI setting, and it ships

```yaml
# Toggles enablement of legacy, BSS-compatible boot API (/boot/v1)
enable_legacy_api: false
```

so the code path that emitted the broken `chain` line is off by default.

📌 **So this issue is closed by upstream deleting the component, not by fixing the line.**
That is a real outcome and worth recording as one — but it means a bug report would land on
code that no longer exists, which is a fast way to look like we had not checked.

⚠ **The lesson is not "we wasted the analysis".** The analysis is what let us make the call in
two minutes instead of writing a report against a dead file. **Before filing anything
upstream, re-derive the bug at HEAD** — the gap between "the release we run" and "what is on
`main`" was eleven days here, and it spanned a breaking change that removed the entire
subsystem. The same check saved [`todo-001`](../notes/todo-001-openchami-cert-renewal-upstream.md)
from a different mistake on the same day.

📌 **It stays open for *us*, though.** `tw-head` runs v0.1.6, the fix in
[The fix](#the-fix--tell-bss-the-address-nodes-actually-use) is still what that cluster needs,
and the pending items in [Where the fix lives](#where-the-fix-lives) are still pending. Only
the upstream report is cancelled.

## Wider lesson

⚠ **A retry path that has never run is not a retry path.** Everything in this tutorial that works, works on the first attempt, which is precisely why an eleven-month-old defect sat in a captured code block in a *finished* tutorial without anyone reading it. When a component emits recovery instructions, the recovery instructions are output that deserves the same checkpoint as the happy path — read them, and if you can, make them run once on purpose.

The narrower, more portable version: **string-concatenated URLs made from environment variables should be validated at startup**, because an unset or unexpanded variable produces a URL that is syntactically valid and semantically empty — `https:///apis/bss/…` is a real URL, and every layer happily passed it along until a DNS resolver finally said no.
