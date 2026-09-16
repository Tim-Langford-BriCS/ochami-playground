#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tw-status.sh — "where am I in this tutorial?"
#
#   devbox$ source ~/tw/tw-env.sh
#   devbox$ bash ~/tw/tw-status.sh
#
# Probes the live state of the project and maps it onto section numbers, then
# prints the first thing that is not done yet.
#
# STRICTLY READ-ONLY. Every OpenStack call is a `list` or a `show`; there is no
# create, set, delete or reboot anywhere in this file, and nothing outside the
# ${TW_PREFIX}- namespace is inspected. Safe to run at any time, including
# mid-section, and safe to run on a shared cloud.
#
# Takes ~30 seconds: it batches one `list` per resource type rather than a
# `show` per object.
#
# Head-node checks (§§5-6) are attempted over SSH only if the head is
# reachable; if it is not, they are reported as "unknown", never as failed.
# ---------------------------------------------------------------------------

P="${TW_PREFIX:-tw}"
PASS=0; FAIL=0; UNKNOWN=0
FIRST_TODO=""; FIRST_TODO_HINT=""

c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
[ -t 1 ] || { c_g=; c_r=; c_y=; c_b=; c_0=; }

ok()   { printf '  %s[ok]%s   %-42s %s\n'   "$c_g" "$c_0" "$1" "${2-}"; PASS=$((PASS+1)); }
no()   { printf '  %s[TODO]%s %-42s %s\n'   "$c_r" "$c_0" "$1" "${2-}"; FAIL=$((FAIL+1))
         [ -z "$FIRST_TODO" ] && { FIRST_TODO="$3"; FIRST_TODO_HINT="$1 — ${2-}"; }; }
huh()  { printf '  %s[?]%s    %-42s %s\n'   "$c_y" "$c_0" "$1" "${2-}"; UNKNOWN=$((UNKNOWN+1)); }
warn() { printf '  %s[warn]%s %-42s %s\n'   "$c_y" "$c_0" "$1" "${2-}"; }
hdr()  { printf '\n%s%s%s\n' "$c_b" "$1" "$c_0"; }

# ── §1 identity ────────────────────────────────────────────────────────────
hdr "§1 — identity and reconnaissance"

# `token issue` asks for a SCOPED token, which some deployments refuse for
# application-credential auth ("Application credentials cannot request a scope").
# So try it, but fall back to an ordinary read rather than declaring auth broken.
PROJ=$(openstack token issue -c project_id -f value 2>/dev/null)
if [ -z "$PROJ" ]; then
    if openstack catalog list -f value -c Name >/dev/null 2>&1; then
        ok "credentials" "authenticated ('token issue' unavailable — normal for app creds)"
        PROJ=""
    else
        no "credentials" "openstack cannot authenticate" "§1.4"
        printf '\n%sStop here.%s Nothing else can be probed until the CLI authenticates.\n' "$c_r" "$c_0"
        printf 'Keystone said:\n'; openstack catalog list -f value -c Name 2>&1 | sed 's/^/  /' | head -5
        printf 'Then check OS_CLOUD (%s) against your clouds.yaml — see §1.4.\n' "${OS_CLOUD:-unset}"
        exit 1
    fi
else
    ok "credentials" "project $PROJ"
fi

# ── Is THIS shell admin-capable? ───────────────────────────────────────────
# §1 prescribes two identities: admin lives in your interactive login, and
# everything in this tutorial runs through a down-scoped `member` application
# credential. This probe asks Keystone about your OWN assignments in your OWN
# project — the least invasive way to tell which identity you are holding.
# A 403 here is the GOOD answer.
UID_=$(openstack token issue -c user_id -f value 2>/dev/null)
if [ -z "$UID_" ] || [ -z "$PROJ" ]; then
    ADMPROBE="skip"
else
    ADMPROBE=$(openstack role assignment list --user-id "$UID_" --project-id "$PROJ" \
                 --names -f value 2>&1)
fi
if printf '%s\n' "$ADMPROBE" | grep -qiE 'forbidden|policy .*not allow|403'; then
    ok "credential scope" "member — correct shell for this tutorial"
elif printf '%s\n' "$ADMPROBE" | grep -qw admin; then
    printf '  %s[STOP]%s %-42s %s\n' "$c_r" "$c_0" "credential scope" \
        "this shell holds the ADMIN role"
    printf '        %s\n' "§1 says: run §§2-19 and ALL of the IaC through the member application"
    printf '        %s\n' "credential, and reach for admin only for one considered action at a time."
    printf '        %s\n' "  openstack --os-cloud techwatch-admin flavor create ...   # deliberate"
    printf '        %s\n' "  OS_CLOUD=techwatch                                       # everything else"
    printf '        %s\n' "Never point 'tofu apply' at the admin entry, even briefly."
    warn "  and ask your cloud admin" "is [oslo_policy] enforce_scope = true?"
    printf '        %s\n' "If not, 'admin on a project' is evaluated as CLOUD-WIDE admin by most"
    printf '        %s\n' "services — you could delete other projects' instances. Record the answer."
else
    huh "credential scope" "could not determine (harmless) — see §1's admin-role note"
fi

# tw-vars-env.sh completeness. Distinguish "unset" from "still a <placeholder>".
env_check() {
    local var="$1" need="$2" sect="$3" val="${!1-}"
    if [ -z "$val" ]; then
        if [ "$need" = required ]; then no "tw-vars-env.sh: $var" "not set at all" "$sect"
        else warn "tw-vars-env.sh: $var" "not set (needed by $sect)"; fi
    elif case "$val" in *'<'*'>'*) true;; *) false;; esac; then
        if [ "$need" = required ]; then no "tw-vars-env.sh: $var" "still a placeholder: $val" "$sect"
        else warn "tw-vars-env.sh: $var" "still a placeholder (needed by $sect)"; fi
    else
        ok "tw-vars-env.sh: $var" "$val"
    fi
}
env_check TW_EXT_NET      required "§1.5"
env_check TW_HEAD_IMAGE   required "§1.5"
env_check TW_FLAVOR_HEAD  required "§1.5 / §4.2"
env_check TW_ADMIN_CIDR   required "§1.5 / §3.5"
env_check TW_FIRMWARE     later    "§7"
env_check TW_FLAVOR_CP    later    "§7"
env_check TW_FLAVOR_WORKER later   "§7"

# One batch of listings, reused throughout.
NETS=$(openstack network list -f value -c Name 2>/dev/null)
SUBNETS=$(openstack subnet list -f value -c Name 2>/dev/null)
ROUTERS=$(openstack router list -f value -c Name 2>/dev/null)
PORTS=$(openstack port list -f value -c Name 2>/dev/null)
SGS=$(openstack security group list -f value -c Name 2>/dev/null)
SERVERS=$(openstack server list -f value -c Name -c Status 2>/dev/null)
IMAGES=$(openstack image list -f value -c Name 2>/dev/null)
VOLUMES=$(openstack volume list -f value -c Name 2>/dev/null)
KEYS=$(openstack keypair list -f value -c Name 2>/dev/null)
FIPS=$(openstack floating ip list -f value -c 'Floating IP Address' -c 'Fixed IP Address' 2>/dev/null)
FLAVORS=$(openstack flavor list -f value -c Name 2>/dev/null)

has() { printf '%s\n' "$2" | grep -qx -- "$1"; }

# Flavor existence, separately from the tw-vars-env.sh check above.
if [ -n "${TW_FLAVOR_HEAD-}" ] && case "$TW_FLAVOR_HEAD" in *'<'*) false;; *) true;; esac; then
    if has "$TW_FLAVOR_HEAD" "$FLAVORS"; then
        TRAIT=$(openstack flavor show "$TW_FLAVOR_HEAD" -c properties -f value 2>/dev/null \
                | tr ',' '\n' | grep -o "trait:${TW_TRAIT:-CUSTOM_TECHWATCH_PROTO}='\?required'\?")
        if [ -n "$TRAIT" ]; then ok "head flavor" "$TW_FLAVOR_HEAD, trait present"
        else warn "head flavor" "$TW_FLAVOR_HEAD exists but trait not readable — see §4.2"; fi
        DISK=$(openstack flavor show "$TW_FLAVOR_HEAD" -c disk -f value 2>/dev/null)
        [ -n "$DISK" ] && [ "$DISK" -lt 40 ] 2>/dev/null && \
            warn "head flavor disk" "${DISK}GB < 40GB — §4.2 wants a Cinder volume for /data"
    else
        no "head flavor" "$TW_FLAVOR_HEAD does not exist — admin must create it (§1.5)" "§1.5"
    fi
fi

# ── §3 networks and ports ──────────────────────────────────────────────────
hdr "§3 — networks, subnets and ports"

has "$P-ext" "$NETS"        && ok "network $P-ext" || no "network $P-ext" "missing" "§3.1"
has "$P-ext-subnet" "$SUBNETS" && ok "subnet $P-ext-subnet" || no "subnet $P-ext-subnet" "missing" "§3.1"

if has "$P-router" "$ROUTERS"; then
    GW=$(openstack router show "$P-router" -c external_gateway_info -f value 2>/dev/null)
    case "$GW" in
        *network_id*) ok "router $P-router" "external gateway set" ;;
        *)            no "router $P-router" "exists but no external gateway" "§3.1" ;;
    esac
else
    no "router $P-router" "missing" "§3.1"
fi

has "$P-prov" "$NETS" && ok "network $P-prov" || no "network $P-prov" "missing" "§3.2"
if has "$P-prov-subnet" "$SUBNETS"; then
    DHCP=$(openstack subnet show "$P-prov-subnet" -c enable_dhcp -f value 2>/dev/null)
    if [ "$DHCP" = False ]; then ok "subnet $P-prov-subnet" "enable_dhcp=False"
    else no "subnet $P-prov-subnet" "enable_dhcp=$DHCP — MUST be False (§3.2)" "§3.2"; fi
else
    no "subnet $P-prov-subnet" "missing" "§3.2"
fi

if has "$P-head-prov" "$PORTS"; then
    PS=$(openstack port show "$P-head-prov" -c port_security_enabled -f value 2>/dev/null)
    IP=$(openstack port show "$P-head-prov" -c fixed_ips -f value 2>/dev/null)
    [ "$PS" = False ] && ok "port $P-head-prov" "port security off" \
                      || no "port $P-head-prov" "port_security_enabled=$PS — must be False (§3.3)" "§3.3"
    case "$IP" in
        *"${TW_HEAD_PROV_IP:-172.16.0.254}"*) ok "  its fixed IP" "${TW_HEAD_PROV_IP:-172.16.0.254}" ;;
        *) no "  its fixed IP" "not ${TW_HEAD_PROV_IP:-172.16.0.254} — this is how the head gets its address (§4)" "§3.4" ;;
    esac
else
    no "port $P-head-prov" "missing" "§3.4"
fi

NODEPORTS=$(printf '%s\n' "$PORTS" | grep -c "^${P}-node[0-9]*-prov$")
[ "$NODEPORTS" -ge 1 ] && ok "node ports" "$NODEPORTS of 5" \
                       || no "node ports" "none found" "§3.4"

# §3.5 — the group, and the binding, which is the failure that looks like something else.
if has "$P-sg-head" "$SGS"; then
    RULES=$(openstack security group rule list "$P-sg-head" -f value 2>/dev/null)
    SSHR=$(printf '%s\n' "$RULES" | grep -c '22:22\|22 ')
    OPEN=$(printf '%s\n' "$RULES" | grep -c '0\.0\.0\.0/0.*22:22')
    ok "security group $P-sg-head" "$SSHR SSH rule(s)"

    # Show WHICH source addresses are permitted. The rule existing tells you
    # nothing useful; the CIDR it is scoped to is the whole question, and it is
    # what §4.6 succeeds or times out on.
    SSHCIDRS=$(printf '%s\n' "$RULES" | grep '22:22\|tcp' \
               | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | sort -u | tr '\n' ' ')
    if [ -n "$SSHCIDRS" ]; then
        printf '  %s[ok]%s   %-42s %s\n' "$c_g" "$c_0" "  SSH permitted from" "$SSHCIDRS"
        # tw-vars-env.sh must AGREE with reality, or §17's diagnosis starts from a lie.
        if [ -z "${TW_ADMIN_CIDR-}" ] || case "${TW_ADMIN_CIDR-}" in *'<'*'>'*) true;; *) false;; esac; then
            warn "  but TW_ADMIN_CIDR" "unset/placeholder — tw-vars-env.sh does not record the above"
            printf '        %s\n' "Backfill it so §17's check has something true to compare against:"
            printf '        %s\n' "  sed -i \"s|^export TW_ADMIN_CIDR=.*|export TW_ADMIN_CIDR='${SSHCIDRS%% *}'|\" ~/tw/tw-vars-env.sh"
        else
            case "$SSHCIDRS" in
                *"$TW_ADMIN_CIDR"*) ok "  TW_ADMIN_CIDR agrees" "$TW_ADMIN_CIDR" ;;
                *) warn "  TW_ADMIN_CIDR disagrees" "tw-vars-env.sh says $TW_ADMIN_CIDR, rule says $SSHCIDRS" ;;
            esac
        fi
    fi
    [ "$OPEN" -gt 0 ] && printf '  %s[STOP]%s %-42s %s\n' "$c_r" "$c_0" \
        "SSH open to 0.0.0.0/0" "delete that rule — §3.5"
    printf '%s\n' "$RULES" | grep -q 'tcp' || \
        warn "  its rules" "no tcp rule found — SSH will time out in §4.6"
else
    no "security group $P-sg-head" "missing" "§3.5"
fi

if has "$P-head-ext" "$PORTS"; then
    SGIDS=$(openstack port show "$P-head-ext" -c security_group_ids -f value 2>/dev/null)
    NSG=$(printf '%s\n' "$SGIDS" | tr -d "[]',' " | tr ' ' '\n' | grep -c '[0-9a-f]')
    if [ -n "$SGIDS" ] && [ "$NSG" -ge 1 ]; then
        WANT=$(openstack security group show "$P-sg-head" -c id -f value 2>/dev/null)
        case "$SGIDS" in
            *"$WANT"*) ok "port $P-head-ext" "bound to $P-sg-head" ;;
            *) no "port $P-head-ext" "carrying a group that is NOT $P-sg-head (probably 'default' — §3.5)" "§3.5" ;;
        esac
    else
        no "port $P-head-ext" "no security group bound — §3.5 binds it" "§3.5"
    fi
else
    no "port $P-head-ext" "missing" "§3.4"
fi

# ── §4 the head node ───────────────────────────────────────────────────────
hdr "§4 — the head node instance"

has "$P-key" "$KEYS" && ok "keypair $P-key" || no "keypair $P-key" "missing" "§4.1"
has "$P-head-data" "$VOLUMES" && ok "volume $P-head-data" "(optional, §4.7)" || true

HEADSTATUS=$(printf '%s\n' "$SERVERS" | awk -v n="$P-head" '$1==n {print $2}')
if [ -n "$HEADSTATUS" ]; then
    if [ "$HEADSTATUS" = ACTIVE ]; then ok "instance $P-head" "ACTIVE"
    else no "instance $P-head" "status $HEADSTATUS" "§4.4"; fi

    HFIP=$(openstack server show "$P-head" -f value -c addresses 2>/dev/null)
    case "$HFIP" in
        *10.*|*,*) ok "  addresses" "$HFIP" ;;
        *)         warn "  addresses" "$HFIP" ;;
    esac
    printf '%s\n' "$FIPS" | grep -q . && ok "  floating IP allocated" \
        || no "  floating IP" "none allocated" "§4.5"
else
    no "instance $P-head" "not created" "§4.4"
fi

# ── §§5-6 on the head, only if reachable ───────────────────────────────────
hdr "§§5–6 — OpenCHAMI on the head (over SSH)"

HEAD_IP="${TW_HEAD_FIP-}"
[ -z "$HEAD_IP" ] && HEAD_IP=$(printf '%s\n' "$FIPS" | awk 'NF>1 {print $1; exit}')

if [ -z "$HEAD_IP" ] || [ -z "$HEADSTATUS" ]; then
    huh "head reachability" "no floating IP yet — nothing to probe"
elif ! timeout 8 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 -i ~/.ssh/tw_ed25519 "rocky@$HEAD_IP" true 2>/dev/null; then
    huh "head reachability" "SSH to $HEAD_IP failed — see §4.6 / §17"
    printf '        %s\n' "Not necessarily broken: TW_ADMIN_CIDR may not match the address the"
    printf '        %s\n' "head sees (§1.5), or the F5 VPN may be down. Console log still works:"
    printf '        %s\n' "  openstack console log show $P-head --lines 40"
else
    ok "head reachability" "ssh rocky@$HEAD_IP"
    R=$(timeout 25 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -i ~/.ssh/tw_ed25519 "rocky@$HEAD_IP" bash -s 2>/dev/null <<'REMOTE'
echo "PROVIF=$(ip -br addr | awk '/172\.16\.0\.254/ {print $1}')"
echo "QUADLETS=$(systemctl list-units --type=service --state=running 2>/dev/null | grep -ci 'smd\|bss\|coredhcp\|coredns\|step-ca\|hydra\|opaal\|haproxy\|postgres')"
echo "DHCP67=$(sudo ss -ulpn 2>/dev/null | grep -c ':67 ')"
echo "S3=$(sudo ss -ltn 2>/dev/null | grep -c ':7070 ')"
echo "REG=$(sudo ss -ltn 2>/dev/null | grep -c ':5000 ')"
echo "FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
echo "MASQ=$(sudo nft list ruleset 2>/dev/null | grep -c masquerade)"
echo "SMD=$(ochami smd component get 2>/dev/null | jq '[.Components[]?|select(.Type=="Node")]|length' 2>/dev/null)"
echo "TALOS=$(ls ~/talos/*.yaml 2>/dev/null | wc -l)"
REMOTE
)
    eval "$(printf '%s\n' "$R" | grep -E '^[A-Z0-9]+=')" 2>/dev/null

    [ -n "${PROVIF-}" ] && ok "  provisioning interface" "$PROVIF (this is TW_PROV_IF, §4.6)" \
                        || no "  provisioning interface" "no NIC holds 172.16.0.254" "§4.6"
    [ "${QUADLETS:-0}" -ge 5 ] && ok "  OpenCHAMI services" "$QUADLETS running" \
                              || no "  OpenCHAMI services" "${QUADLETS:-0} running" "§5"
    [ "${S3:-0}" -ge 1 ]  && ok "  Versity S3 :7070"  || no "  Versity S3 :7070" "not listening" "§5.5"
    [ "${REG:-0}" -ge 1 ] && ok "  OCI registry :5000" || warn "  OCI registry :5000" "not listening (§5)"
    [ "${DHCP67:-0}" -ge 1 ] && ok "  CoreDHCP on :67" \
                             || no "  CoreDHCP on :67" "nothing serving DHCP — no node can boot" "§5.7"
    [ "${FWD:-0}" = 1 ] && ok "  ip_forward" || no "  ip_forward" "off" "§5.12"
    [ "${MASQ:-0}" -ge 1 ] && ok "  NAT masquerade" || no "  NAT masquerade" "no rule" "§5.12"
    [ "${SMD:-0}" -ge 1 ] 2>/dev/null && ok "  SMD nodes" "${SMD} registered" \
                                      || no "  SMD nodes" "SMD empty or unreachable" "§6.1"
    [ "${TALOS:-0}" -ge 1 ] && ok "  Talos configs present" "$TALOS yaml in ~/talos" \
                            || huh "  Talos configs" "none yet (§8)"
fi

# ── §7 onward ──────────────────────────────────────────────────────────────
hdr "§7 onward — node instances"

has "$P-ipxe-disk" "$IMAGES" && ok "image $P-ipxe-disk" || huh "image $P-ipxe-disk" "not uploaded (§7.2)"
NODES=$(printf '%s\n' "$SERVERS" | grep -cE "^${P}-(cp1|w[0-9]+) ")
[ "$NODES" -ge 1 ] && ok "node instances" "$NODES created" || huh "node instances" "none yet (§7.3)"
printf '%s\n' "$SERVERS" | grep -E "^${P}-(cp1|w[0-9]+) " | grep -q RESCUE && \
    warn "a node is in RESCUE" "unexpected — §7 does not use rescue. See appendix F"

# ── verdict ────────────────────────────────────────────────────────────────
hdr "Summary"
printf '  %s%d ok%s, %s%d to do%s, %s%d unknown%s\n' \
    "$c_g" "$PASS" "$c_0" "$c_r" "$FAIL" "$c_0" "$c_y" "$UNKNOWN" "$c_0"

if [ -z "$FIRST_TODO" ]; then
    printf '\n  %sEverything probed is done.%s Next unprobed work is §8 onward — Talos assets,\n' "$c_g" "$c_0"
    printf '  BSS payloads and the cluster itself, which this script only checks shallowly.\n'
else
    printf '\n  %sStart at: %s%s\n' "$c_b" "$FIRST_TODO" "$c_0"
    printf '  Because: %s\n' "$FIRST_TODO_HINT"
fi

printf '\n  Anything marked [?] is "not reached yet or not visible from here", not a failure.\n'
printf '  Re-run after each section; it is read-only and takes ~30s.\n\n'
