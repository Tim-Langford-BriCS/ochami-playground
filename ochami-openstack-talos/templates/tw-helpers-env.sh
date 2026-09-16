# tw-helpers-env.sh — the tw_* shell helpers for this tutorial.
#
#   devbox$ cp <this-tutorial>/templates/tw-helpers-env.sh ~/tw/tw-helpers-env.sh
#
# ~/tw/tw-env.sh sources this file. Keeping them apart matters:
#
#   tw-vars-env.sh       YOUR values. Filled in over §1.5, appended to by §4.5
#                   (TW_HEAD_FIP) and §4.6 (TW_PROV_IF). NEVER replace wholesale
#                   once you have started filling it in.
#
#   tw-helpers-env.sh   No values, only functions. ALWAYS safe to replace wholesale,
#                   at any point, with no risk to anything you have set. That is
#                   the entire reason it is a separate file.
#
# So when this tutorial improves a helper, the upgrade is one `cp` — not a
# three-way merge against a file you have been editing for a week.
#
# Nothing here creates or deletes cloud resources. Each function either prints
# the command it runs or is short enough to read. Run `tw_help`.
# All named tw_* so `tw_unload` can find and remove every one of them again.
# ─────────────────────────────────────────────────────────────────────────────

# ─── tw_help — what is loaded, and where everything lives ────────────────────
tw_help() {
  cat <<'HELP'
TechWatch helpers (all functions are tw_*; all variables are TW_*)

  tw_help           this text
  tw_env            show every TW_* variable currently set
  tw_check          verify tw-vars-env.sh is fully filled in and the API answers
  tw_reach          is the Keystone endpoint reachable at all? (VPN check —
                    a dropped tunnel looks exactly like a bad password)
  tw_vpn            ssh to the head hangs — is the VPN down, or has your
                    address changed and left tw-sg-head behind? (manual §17)
  tw_login_head     ssh to the head node as rocky, key and address supplied.
                    With arguments, runs them there and returns:
                      tw_login_head 'systemctl --failed'
                    NOT the same as tw_login, which is an OpenStack password.
  tw_config         show which OpenStack config files exist and which is in use
  tw_whoami         which project and user the current credentials resolve to
  tw_tunnel_up      forward the cluster API here over ssh (§11.5). Backgrounds
                    itself; safe to run twice. Sets nothing you must clean up
                    by hand — see tw_tunnel_down
  tw_tunnel_down    close it. Uses the ssh control socket, so it closes THE
                    tunnel rather than whatever ssh happens to match a pattern
  tw_tunnel_status  is it up, and does the API answer through it? These are two
                    different failures and it reports them separately
                    TW_TUNNEL_DEBUG=1 tw_tunnel_up  runs it in the foreground
                    with -vvv, when you need ssh to say why it died
  tw_login          prompt once for a password into OS_PASSWORD (stops the
                    per-command prompting when using clouds.yaml without a
                    stored password — manual §1.4 option 3)
  tw_admin          elevate to the admin cloud entry: prompts for the password,
                    marks the prompt red, and EXPIRES after TW_ADMIN_TTL (900s).
                    Never run tofu or ansible while elevated.
  tw_member         drop back: clears OS_PASSWORD, restores OS_CLOUD and prompt
  tw_clean_os       unset every OS_* except OS_CLOUD (fixes openrc/clouds.yaml
                    mixing — manual §1.4)
  tw_flavors        show the flavors we use, and whether they carry the
                    isolation trait (manual §1.5)
  tw_nodes          print the node map: name / xname / mac / ip / role
  tw_unload         unset every TW_* variable and every tw_* function

Where configuration lives:

  ~/.config/openstack/clouds.yaml   connection settings, selected by $OS_CLOUD
  ~/.config/openstack/secure.yaml   optional; secrets only, merged over the above
  ~/tw/tw-vars-env.sh                    YOUR values — never re-copy from the template
  ~/tw/tw-helpers-env.sh                these functions — always safe to re-copy
  ~/techwatch-proto-openrc.sh       the alternative to clouds.yaml — never both

openstacksdk searches for clouds.yaml in this order, first match winning:
  $OS_CLIENT_CONFIG_FILE, ./clouds.yaml (CURRENT DIRECTORY), ~/.config/openstack/,
  /etc/openstack/

The effective, merged configuration is always:  openstack configuration show
HELP
}

# ─── tw_env — what is set right now ──────────────────────────────────────────
tw_env() {
  # compgen is a bash builtin; the `env` fallback keeps this working elsewhere.
  local names
  names=$(compgen -v 2>/dev/null | grep '^TW_' | sort) \
    || names=$(env | sed -n 's/^\(TW_[A-Za-z0-9_]*\)=.*/\1/p' | sort)
  local n
  for n in $names; do
    printf '  %-22s %s\n' "$n" "${!n}"
  done
  printf '  %-22s %s\n' OS_CLOUD "${OS_CLOUD:-(unset)}"
  printf '  %-22s %s\n' OS_PASSWORD \
    "$([ -n "${OS_PASSWORD:-}" ] && echo '(set)' || echo '(unset)')"
}

# ─── tw_reach — is the endpoint even reachable? ──────────────────────────────
# Distinguishing "cannot reach Keystone" from "Keystone rejected me" matters more
# than it sounds. On Digital Labs the API is reached over the F5 VPN, and when
# that tunnel drops the CLI does NOT say "network down" — it reports an
# authentication failure. Confirmed on 31 Jul 2026, after three attempts at
# retyping a password that was correct all along.
#
# Prints ok | unreachable | ? and returns 0 | 1 | 2. TCP-only, no auth, no deps
# beyond bash — deliberately, so it works when everything else is failing.
tw_reach() {
  local url host port
  url="${1:-$(openstack configuration show -c auth.auth_url -f value 2>/dev/null)}"
  [ -n "$url" ] || { echo "?"; return 2; }
  host=${url#*://}; host=${host%%/*}
  case "$host" in
    *:*) port=${host##*:}; host=${host%%:*} ;;
    *)   case "$url" in https:*) port=443 ;; *) port=80 ;; esac ;;
  esac
  if timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    echo "ok"; return 0
  fi
  echo "unreachable"; return 1
}

# ─── tw_vpn — ssh to the head hangs: is it the tunnel, or your address? ──────
# The two failures look identical from here (a hang, never a refusal), but they
# have different fixes, and one of them cannot be diagnosed from this VM at all.
#
# The trick is that the Keystone endpoint and the head node are reached over the
# SAME tunnel, but only the head is filtered by a security group. So:
#
#   API ok + head ok    nothing wrong with the network; look at the head itself
#   API ok + head DEAD  the tunnel is up and your source address changed
#   API dead            the VPN is down; reconnect
#
# Probes TCP/22 rather than pinging, because a project that allowed tcp/22 but
# not icmp would otherwise look broken when it is fine.
tw_vpn() {
  local api fip head_state
  api=$(tw_reach)
  fip="${TW_HEAD_FIP:-}"

  printf '  %-22s %s\n' 'Keystone endpoint' "$api"
  printf '  %-22s %s\n' 'TW_ADMIN_CIDR'     "${TW_ADMIN_CIDR:-(unset)}"

  if [ -z "$fip" ]; then
    printf '  %-22s %s\n\n' 'TW_HEAD_FIP' '(unset)'
    echo "  Cannot probe the head until TW_HEAD_FIP is set — that is manual §4.5."
    return 2
  fi

  if timeout 5 bash -c "exec 3<>/dev/tcp/$fip/22" 2>/dev/null; then
    head_state=open
  else
    head_state=NO_ANSWER
  fi
  printf '  %-22s %s\n\n' "$fip tcp/22" "$head_state"

  if [ "$api" != ok ]; then
    echo "  ✗ The Keystone endpoint is unreachable — the VPN itself is down."
    echo "    Reconnect it, then re-run. Note that once it is down the openstack"
    echo "    CLI reports an AUTHENTICATION failure, not a network error, so do"
    echo "    not go looking for a bad password."
    return 3
  fi

  if [ "$head_state" = open ]; then
    echo "  ✓ Tunnel up, and tw-sg-head still matches your source address."
    echo "    If ssh still hangs, the problem is on the head node, not the path."
    return 0
  fi

  echo "  ✗ The tunnel is UP but the head does not answer on tcp/22."
  echo "    Almost always: your VPN address changed and tw-sg-head, which is"
  echo "    scoped to a /32, no longer matches you. F5 hands out a different"
  echo "    pool address on every reconnect."
  echo
  echo "    That address exists only on your LAPTOP — this VM sits behind its"
  echo "    NAT and cannot see it. Run this THERE, not here:"
  echo
  printf "      ifconfig \$(route -n get %s | awk '/interface/{print \$2}') \\\\\n" "$fip"
  echo   "        | awk '/inet /{print \$2}'"
  echo
  echo "    Then add a rule for it, confirm ssh works, and only then delete the"
  echo "    stale one — manual §17, 'TW_ADMIN_CIDR is not durable'."
  return 1
}

# ─── tw_login_head — ssh to the head node, and diagnose it when it won't ─────
# Interactive with no arguments; with arguments, runs them on the head and comes
# straight back — tw_login_head 'systemctl --failed' is the common case.
tw_login_head() {
  local user="${TW_HEAD_USER:-rocky}"
  local key="${TW_SSH_KEY:-$HOME/.ssh/tw_ed25519}"

  if [ -z "${TW_HEAD_FIP:-}" ]; then
    echo "TW_HEAD_FIP is not set — source ~/tw/tw-env.sh (§4.5 appends it)." >&2
    return 1
  fi
  if [ ! -f "$key" ]; then
    echo "No SSH key at $key. Override with TW_SSH_KEY, or see §1.5." >&2
    return 1
  fi

  # ConnectTimeout is here for one specific reason: a security group that no
  # longer matches your VPN address DROPS packets rather than refusing them, so
  # without it this hangs indefinitely and is indistinguishable from a dead
  # instance. Ten seconds turns a mystery into a diagnosis.
  ssh -o ConnectTimeout=10 -i "$key" "${user}@${TW_HEAD_FIP}" "$@"
  local rc=$?

  # 255 is ssh's own "could not connect", as opposed to a command that ran on the
  # head and exited non-zero. Only the former implicates the tunnel.
  if [ "$rc" -eq 255 ]; then
    echo "" >&2
    echo "ssh could not reach ${TW_HEAD_FIP}. If it timed out rather than being" >&2
    echo "refused, your F5 address has probably changed: run tw_vpn, then see" >&2
    echo "runbooks/update-tunnel-ip.md." >&2
  fi
  return $rc
}

# ─── tw_tunnel_* — reach the cluster API from here (§11.5) ───────────────────
# The provisioning wire has no external route. 172.16.0.x is reachable only
# from the head node, and §11.5 argues at length against changing that: an
# API server on a campus network is a liability. So we forward two ports over
# the SSH connection we already trust.
#
#   6443 -> the Kubernetes API on the control plane
#   8080 -> port 80 on the control plane, where a Gateway will eventually listen
#
# The state handle is an SSH CONTROL SOCKET, not a PID file. That distinction
# matters: -O check asks the running master directly, so there is nothing to go
# stale. A PID file survives reboots, gets reused by an unrelated process, and
# then confidently reports a tunnel that does not exist.
TW_TUNNEL_SOCK="${TW_TUNNEL_SOCK:-$HOME/.ssh/tw-tunnel.sock}"

# DEBUGGING: set TW_TUNNEL_DEBUG=1 to run in the FOREGROUND with -vvv. Use this
# when the tunnel appears to die and you want ssh to say why rather than guess:
#
#   devbox$ TW_TUNNEL_DEBUG=1 tw_tunnel_up 2>&1 | tee /tmp/tun.log
#
# Read it for these, which mean different things:
#   channel N: new direct-tcpip / free    one connection through the tunnel,
#                                         opened and closed. Normal churn — you
#                                         get a pair of these per kubectl call
#   read failed ... Broken pipe           the LOCAL end went away (kubectl
#                                         finished or was interrupted). Normal
#   Connection to ... closed by remote    the head's sshd hung up
#   client_loop: send disconnect          the path dropped it (VPN/NAT)
#   Killed by signal 2                    something sent it SIGINT — usually a
#                                         Ctrl-C in the terminal it was running in
#
# The port-listener channel (opened once, at startup) staying alive is what
# proves the tunnel is up. Per-connection channels coming and going is the
# tunnel WORKING, and is the single most misread thing in this output.

# kubectl has to be told where the cluster is. Set this only when the file is
# actually present, so sourcing before §11.5 does not leave KUBECONFIG pointing
# at a path that is not there — which fails in a way that reads like a broken
# cluster rather than a missing file.
if [ -f "${TW_KUBECONFIG:-$HOME/tw/kubeconfig}" ]; then
  export KUBECONFIG="${TW_KUBECONFIG:-$HOME/tw/kubeconfig}"
fi

tw_tunnel_up() {
  local user="${TW_HEAD_USER:-rocky}"
  local key="${TW_SSH_KEY:-$HOME/.ssh/tw_ed25519}"
  local cp="${TW_CP_IP:-172.16.0.1}"

  if [ -z "${TW_HEAD_FIP:-}" ]; then
    echo "TW_HEAD_FIP is not set — source ~/tw/tw-env.sh (§4.5 appends it)." >&2
    return 1
  fi
  if [ ! -f "$key" ]; then
    echo "No SSH key at $key. Override with TW_SSH_KEY, or see §1.5." >&2
    return 1
  fi

  if ssh -S "$TW_TUNNEL_SOCK" -O check "${user}@${TW_HEAD_FIP}" 2>/dev/null; then
    echo "tunnel already up — nothing to do."
    return 0
  fi

  # ExitOnForwardFailure is the important flag. Without it, a local port that is
  # already taken produces a warning and a connection that succeeds while
  # forwarding nothing — so kubectl fails against whatever else owns that port,
  # and the error blames the cluster.
  # ServerAlive* keeps the connection from being silently reaped. An idle SSH
  # session sends nothing, and NAT on the VPN path will eventually drop the
  # mapping — after which the tunnel is dead but the local listener is still
  # bound, so kubectl hangs rather than failing. Probing every 30s keeps the
  # mapping warm, and giving up after 3 missed probes turns a dead tunnel into
  # a closed socket, which fails fast and honestly.
  # TW_TUNNEL_DEBUG=1 swaps -f -M (background, control socket) for -vvv in the
  # foreground. Deliberately not both: a backgrounded ssh cannot show you its
  # own death, which is the thing you are usually trying to see.
  local mode
  if [ -n "${TW_TUNNEL_DEBUG:-}" ]; then
    mode="-vvv"
    echo "debug mode: running in the foreground. Ctrl-C ends the tunnel." >&2
  else
    mode="-f -M -S $TW_TUNNEL_SOCK"
  fi

  # shellcheck disable=SC2086  # $mode is deliberately word-split
  ssh -N $mode \
      -o ExitOnForwardFailure=yes \
      -o ConnectTimeout=10 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -i "$key" \
      -L "${TW_TUNNEL_API:-6443}:${cp}:6443" \
      -L "${TW_TUNNEL_HTTP:-8080}:${cp}:80" \
      "${user}@${TW_HEAD_FIP}" || {
    echo "tunnel failed to start. If it said 'Address already in use', something" >&2
    echo "already holds ${TW_TUNNEL_API:-6443} or ${TW_TUNNEL_HTTP:-8080} — an" >&2
    echo "earlier tunnel started outside these helpers, most likely." >&2
    return 1
  }

  echo "tunnel up:"
  echo "  localhost:${TW_TUNNEL_API:-6443}  -> ${cp}:6443  Kubernetes API"
  echo "  localhost:${TW_TUNNEL_HTTP:-8080} -> ${cp}:80    gateway (nothing listening until §13)"
  [ -n "${KUBECONFIG:-}" ] && echo "  KUBECONFIG=$KUBECONFIG"
  return 0
}

tw_tunnel_down() {
  local user="${TW_HEAD_USER:-rocky}"
  if [ -z "${TW_HEAD_FIP:-}" ]; then
    echo "TW_HEAD_FIP is not set — source ~/tw/tw-env.sh." >&2
    return 1
  fi
  if ssh -S "$TW_TUNNEL_SOCK" -O exit "${user}@${TW_HEAD_FIP}" 2>/dev/null; then
    echo "tunnel closed."
  else
    echo "no tunnel was running."
  fi
}

tw_tunnel_status() {
  local user="${TW_HEAD_USER:-rocky}" out
  if [ -z "${TW_HEAD_FIP:-}" ]; then
    echo "TW_HEAD_FIP is not set — source ~/tw/tw-env.sh." >&2
    return 1
  fi
  out=$(ssh -S "$TW_TUNNEL_SOCK" -O check "${user}@${TW_HEAD_FIP}" 2>&1)
  if [ $? -ne 0 ]; then
    echo "tunnel down — run tw_tunnel_up."
    return 1
  fi
  echo "tunnel up  ($out)"

  # An established tunnel proves ssh reached the head. It does NOT prove the
  # API answers: the control plane could be down behind a perfectly good
  # forward. Ask the API itself, and keep the two failures distinguishable.
  if command -v kubectl >/dev/null 2>&1; then
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      echo "API    ok  (readyz passed through the tunnel)"
    else
      echo "API    NOT answering — the tunnel is fine, the cluster or kubeconfig is not"
    fi
  else
    echo "kubectl not installed here — see §11.5"
  fi
}

# ─── tw_check — are we actually ready? ───────────────────────────────────────
tw_check() {
  local rc=0 unresolved

  # 1. Placeholders. Every <…> is a §1.5 answer nobody has written down yet.
  unresolved=$(tw_env | grep '<' || true)
  if [ -n "$unresolved" ]; then
    echo "✗ Unresolved placeholders — finish the §1.5 recon:"
    echo "$unresolved"
    rc=1
  else
    echo "✓ No placeholders left in TW_* variables"
  fi

  # 2. Can we talk to the API? This is a read-only call.
  if [ -z "${OS_CLOUD:-}" ] && [ -z "${OS_AUTH_URL:-}" ]; then
    echo "✗ Neither OS_CLOUD nor OS_AUTH_URL is set — see 'tw_config'"
    rc=1
  elif project=$(openstack token issue -c project_id -f value 2>/dev/null); then
    echo "✓ Authenticated; project_id $project"
  # `token issue` asks Keystone for a SCOPED token, which some deployments refuse
  # for application credentials ("Application credentials cannot request a
  # scope"). So a failure there is not proof that auth is broken — fall back to
  # an ordinary read before accusing the credential of anything.
  elif openstack catalog list -f value -c Name >/dev/null 2>&1; then
    echo "✓ Authenticated (via catalog list; 'token issue' is unavailable —"
    echo "  normal for application-credential auth, and harmless)"
  elif [ "$(tw_reach)" != ok ]; then
    echo "✗ Cannot REACH the Keystone endpoint — this is a network problem, not a"
    echo "  credential one. On Digital Labs that is almost always the F5 VPN"
    echo "  having dropped. Reconnect it and re-run; change nothing else."
    rc=1
  else
    echo "✗ Endpoint reachable but authentication refused. Keystone said:"
    openstack catalog list -f value -c Name 2>&1 | sed 's/^/    /' | head -5
    echo "  Then: openstack configuration show | grep -vi 'secret\\|password'"
    echo "  and see manual §1.4 'Common failures'"
    rc=1
  fi

  return $rc
}

# ─── tw_config — which files exist, and which one is winning ─────────────────
tw_config() {
  local f
  echo "Config files:"
  for f in "$OS_CLIENT_CONFIG_FILE" ./clouds.yaml \
           ~/.config/openstack/clouds.yaml ~/.config/openstack/secure.yaml \
           /etc/openstack/clouds.yaml; do
    [ -n "$f" ] || continue
    if [ -f "$f" ]; then
      printf '  %-40s exists\n' "$f"
    else
      printf '  %-40s -\n' "$f"
    fi
  done

  echo
  echo "Selected cloud: OS_CLOUD=${OS_CLOUD:-(unset)}"
  echo "Clouds the SDK can see:"
  python3 -c 'import openstack.config as c
print("\n".join("  " + n for n in sorted(c.OpenStackConfig().get_cloud_names())))' \
    2>/dev/null || echo "  (could not read — is the venv active?)"

  echo
  echo "OS_* currently in the environment (should be OS_CLOUD alone, or an"
  echo "openrc's set — never a mixture; see manual §1.4):"
  # Captured into a variable rather than piped, so the "(none)" fallback works:
  # in `env | grep … || echo`, the || binds to the last command of the pipeline,
  # which succeeds even when grep matched nothing.
  local os_vars
  os_vars=$(env | grep '^OS_' | sed 's/^\(OS_PASSWORD=\).*/\1(hidden)/' | sort)
  if [ -n "$os_vars" ]; then
    echo "$os_vars" | sed 's/^/  /'
  else
    echo "  (none)"
  fi
}

# ─── tw_whoami — whose credentials are these? ────────────────────────────────
tw_whoami() {
  openstack token issue -c project_id -c user_id -c expires -f table
}

# ─── tw_login — one password prompt per shell, not per command ───────────────
tw_login() {
  # Why this exists: every `openstack` command authenticates from scratch, so a
  # clouds.yaml with no stored password prompts EVERY time (manual §1.4 B.1).
  # Exporting OS_PASSWORD once is the fix that writes nothing to disk.
  local pw
  read -srp "OpenStack password for ${OS_USERNAME:-your account}: " pw
  echo
  if [ -z "$pw" ]; then
    echo "Nothing entered; OS_PASSWORD unchanged."
    return 1
  fi
  export OS_PASSWORD="$pw"
  echo "OS_PASSWORD set for this shell only. Verify with: tw_whoami"
}

# ─── tw_clean_os — undo openrc/clouds.yaml mixing ───────────────────────────
tw_clean_os() {
  # openstacksdk MERGES OS_* env vars on top of the cloud OS_CLOUD selects, so a
  # sourced openrc silently overrides clouds.yaml and produces errors that look
  # like cloud faults (manual §1.4).
  local keep="${1:-$OS_CLOUD}" v
  for v in $(env | sed -n 's/^\(OS_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$v"
  done
  if [ -n "$keep" ]; then
    export OS_CLOUD="$keep"
    echo "OS_* purged. Now: OS_CLOUD=$OS_CLOUD"
  else
    echo "OS_* purged. Nothing set — you will need OS_CLOUD or an openrc."
  fi
  echo "If you meant to use the openrc instead: unset OS_CLOUD; source ~/techwatch-proto-openrc.sh"
}

# ─── tw_flavors — the isolation check, in one command ────────────────────────
tw_flavors() {
  # The flavor is what pins this project to its own hypervisor (manual §1.5), so
  # "does it still carry the trait?" is the check worth having to hand.
  local f
  for f in "$TW_FLAVOR_HEAD" "$TW_FLAVOR_CP" "$TW_FLAVOR_WORKER"; do
    case "$f" in *'<'*) echo "  $f — not set yet (§1.5)"; continue ;; esac
    printf '  %-32s ' "$f"
    if openstack flavor show "$f" -c properties -f value 2>/dev/null \
         | tr ',' '\n' | grep -q "trait:${TW_TRAIT}"; then
      echo "trait:${TW_TRAIT} ✓"
    else
      echo "trait NOT confirmed — see manual §1.5 / §1.6"
    fi
  done
}

# ─── tw_nodes — the node map, as a table ─────────────────────────────────────
tw_nodes() {
  cat <<EOF
  name      xname           nid  mac                ip           role
  ${TW_PREFIX}-cp1    x1000c0s0b0n0   1    ${TW_CP_MAC}  ${TW_CP_IP}   controlplane
  ${TW_PREFIX}-w1     x1000c0s0b1n0   2    52:54:00:be:ef:02  172.16.0.2   worker
  ${TW_PREFIX}-w2     x1000c0s0b2n0   3    52:54:00:be:ef:03  172.16.0.3   worker
  ${TW_PREFIX}-w3     x1000c0s0b3n0   4    52:54:00:be:ef:04  172.16.0.4   worker
  ${TW_PREFIX}-w4     x1000c0s0b4n0   5    52:54:00:be:ef:05  172.16.0.5   worker

  These MACs must match in three places: Neutron ports (§3.4), the SMD
  inventory (§6.1) and the BSS payloads (§9.1).
EOF
}

# ─── tw_admin / tw_member — deliberate, visible, time-limited elevation ──────
#
# §1's rule is two identities: the member application credential for everything
# in the tutorial and all of the IaC, and a separate admin entry for one
# considered action at a time. These two functions make that switch explicit
# instead of remembering which shell you are in.
#
# THREE THINGS THIS DOES THAT `export OS_CLOUD=techwatch-admin` DOES NOT:
#
#   1. It marks the prompt, in red. Elevated state you cannot see is elevated
#      state you forget.
#   2. It EXPIRES. After TW_ADMIN_TTL seconds of prompts it drops you back on its
#      own, so walking away from the keyboard is not a way to stay root.
#   3. It puts OS_PASSWORD and OS_CLOUD back together, so dropping out cannot
#      leave a password behind that a later member command picks up — which is
#      the OS_*-on-top-of-clouds.yaml mixing failure in §1.4.
#
# ⚠ It still holds your password in this shell's environment for up to the TTL.
#   That is a real trade against per-command prompting, and it is the reason for
#   the TTL and the marker. For a one-off command, prefer:
#       openstack --os-cloud techwatch-admin <command>
#   For total certainty that nothing persists, prefer the subshell form in §1:
#       ( read -srp "pw: " OS_PASSWORD; echo; export OS_PASSWORD; <commands> )
#
# 🛑 NEVER run `tofu apply`, `tofu destroy` or an Ansible playbook while
#   elevated. The IaC reads the same clouds.yaml, so it would run with admin
#   policy available — which is precisely where a typo stops being local.
export TW_ADMIN_CLOUD="${TW_ADMIN_CLOUD:-techwatch-admin}"
export TW_ADMIN_TTL="${TW_ADMIN_TTL:-900}"        # seconds; 15 minutes

# Prompt hook. Not named tw_* on purpose — it is machinery, not a command you
# would run — so tw_unload removes it explicitly rather than by pattern.
_tw_admin_watch() {
  [ -n "${TW_ADMIN_SINCE-}" ] || return 0
  if [ $(( SECONDS - TW_ADMIN_SINCE )) -ge "${TW_ADMIN_TTL:-900}" ]; then
    printf '\n\033[33mtw: admin session expired after %ss — dropping to member.\033[0m\n' \
      "${TW_ADMIN_TTL}" >&2
    tw_member
  fi
}

tw_admin() {
  if [ -n "${TW_ADMIN_SINCE-}" ]; then
    echo "Already elevated (${TW_ADMIN_CLOUD}). tw_member to drop out."
    return 0
  fi

  # Fail before asking for a password if the entry does not exist — otherwise the
  # error arrives after you have typed it, which teaches people to retype blindly.
  if ! python3 -c 'import openstack.config as c; print("\n".join(c.OpenStackConfig().get_cloud_names()))' \
        2>/dev/null | grep -qx "$TW_ADMIN_CLOUD"; then
    echo "No cloud '$TW_ADMIN_CLOUD' in your clouds.yaml." >&2
    echo "§1's admin subsection has the entry to add. Cloud names available:" >&2
    python3 -c 'import openstack.config as c; print("  "+"\n  ".join(sorted(c.OpenStackConfig().get_cloud_names())))' 2>/dev/null
    return 1
  fi

  local pw
  read -srp "Password to elevate to ${TW_ADMIN_CLOUD}: " pw; echo
  [ -n "$pw" ] || { echo "Nothing entered; still member."; return 1; }

  TW_ADMIN_PREV_CLOUD="${OS_CLOUD-}"
  TW_ADMIN_PREV_PS1="${PS1-}"
  export OS_CLOUD="$TW_ADMIN_CLOUD"
  export OS_PASSWORD="$pw"
  pw=

  # Verify now, so a mistyped password fails here and not three commands later
  # as a confusing 401 (§1.4 B.2).
  #
  # SHOW the error. An earlier version of this function swallowed stderr and
  # printed "password wrong, or see §1.4", which is a guess dressed as a
  # diagnosis — and it hid a real clouds.yaml problem for three attempts.
  # Whatever Keystone says is more useful than anything we can infer.
  local err
  if ! err=$(openstack token issue -c project_id -f value 2>&1); then
    if [ "$(tw_reach)" != ok ]; then
      echo "Elevation failed: the Keystone endpoint is UNREACHABLE." >&2
      echo "  Your password is almost certainly fine. On Digital Labs this is" >&2
      echo "  nearly always the F5 VPN having dropped — reconnect and retry." >&2
      unset OS_PASSWORD
      export OS_CLOUD="$TW_ADMIN_PREV_CLOUD"
      unset TW_ADMIN_PREV_CLOUD TW_ADMIN_PREV_PS1
      return 1
    fi
    echo "Elevation failed — reverting to member. Keystone said:" >&2
    printf '  %s\n' "$err" >&2
    case "$err" in
      *"Could not find user"*|*"Could not find domain"*)
        echo "  → the admin entry is probably missing user_domain_name (§1.4)" >&2 ;;
      *"Could not find project"*|*"project_domain"*)
        echo "  → the admin entry is probably missing project_domain_name (§1.4)" >&2 ;;
      *"cannot request a scope"*)
        echo "  → that entry is an application credential; it must not also set a scope (§1.4)" >&2 ;;
      *401*|*"requires authentication"*)
        echo "  → password or username wrong. Check: openstack configuration show | grep -vi secret" >&2 ;;
    esac
    unset OS_PASSWORD
    export OS_CLOUD="$TW_ADMIN_PREV_CLOUD"
    unset TW_ADMIN_PREV_CLOUD TW_ADMIN_PREV_PS1
    return 1
  fi

  TW_ADMIN_SINCE=$SECONDS
  if [ -n "${BASH_VERSION-}" ]; then
    PS1='\[\033[41;97m\] ADMIN \[\033[0m\] '"$TW_ADMIN_PREV_PS1"
    if ! declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
      TW_ADMIN_PREV_PROMPT="${PROMPT_COMMAND-}"
      case "${PROMPT_COMMAND-}" in
        *_tw_admin_watch*) : ;;
        '')                PROMPT_COMMAND='_tw_admin_watch' ;;
        *)                 PROMPT_COMMAND="${PROMPT_COMMAND%;};_tw_admin_watch" ;;
      esac
    fi
  fi

  printf '\033[33m'
  echo "ELEVATED as ${TW_ADMIN_CLOUD}. Expires in ${TW_ADMIN_TTL}s, or run tw_member."
  echo "Do NOT run tofu or ansible in this shell while elevated."
  printf '\033[0m'
}

tw_member() {
  if [ -z "${TW_ADMIN_SINCE-}" ]; then
    echo "Not elevated. OS_CLOUD=${OS_CLOUD:-unset}"
    return 0
  fi
  unset OS_PASSWORD
  export OS_CLOUD="${TW_ADMIN_PREV_CLOUD:-techwatch}"
  [ -n "${BASH_VERSION-}" ] && [ -n "${TW_ADMIN_PREV_PS1-}" ] && PS1="$TW_ADMIN_PREV_PS1"
  if [ -n "${TW_ADMIN_PREV_PROMPT+x}" ]; then
    if [ -z "$TW_ADMIN_PREV_PROMPT" ]; then unset PROMPT_COMMAND
    else PROMPT_COMMAND="$TW_ADMIN_PREV_PROMPT"; fi
  fi
  unset TW_ADMIN_SINCE TW_ADMIN_PREV_CLOUD TW_ADMIN_PREV_PS1 TW_ADMIN_PREV_PROMPT
  echo "Dropped to member. OS_CLOUD=$OS_CLOUD, OS_PASSWORD cleared."
}

# ─── tw_unload — leave no trace ──────────────────────────────────────────────
tw_unload() {
  # Drop out of admin FIRST, while tw_member and TW_ADMIN_SINCE still exist —
  # otherwise the TW_* purge below strips the saved state and you are left with a
  # red ADMIN prompt, a dangling PROMPT_COMMAND hook and no way to restore either.
  [ -n "${TW_ADMIN_SINCE-}" ] && tw_member

  # Unset the variables first (tw_env needs to still exist to find them), then
  # the functions, and tw_unload itself last.
  local v f names
  names=$(compgen -v 2>/dev/null | grep '^TW_' | sort) \
    || names=$(env | sed -n 's/^\(TW_[A-Za-z0-9_]*\)=.*/\1/p' | sort)
  for v in $names; do unset "$v"; done

  # OS_CLOUD is ours too — tw-vars-env.sh is what set it.
  unset OS_CLOUD

  # OS_PASSWORD, if tw_login put it there. Deliberately unconditional: leaving a
  # password in the environment of a shell you thought you had cleaned is worse
  # than having to type it again.
  unset OS_PASSWORD

  for f in $(compgen -A function 2>/dev/null | grep '^tw_' | grep -v '^tw_unload$'); do
    unset -f "$f"
  done
  # The prompt hook is deliberately not named tw_*, so the pattern above misses it.
  unset -f _tw_admin_watch 2>/dev/null
  echo "TW_* variables and tw_* functions removed. Re-run: source ~/tw/tw-env.sh"
  unset -f tw_unload
}

# One line on load, so it is obvious the helpers are there.
#
# ⚠ INTERACTIVE SHELLS ONLY. §1.5 puts tw-env.sh in ~/.bashrc, and bash sources
# .bashrc for non-interactive `ssh devbox '…'` too. Anything printed on stdout
# there is prepended to the stream scp and rsync are reading, and they fail with
# `protocol error` or `unexpected tag` — an error that names neither this line
# nor .bashrc. `$-` holds the shell's option letters; `i` is there only when the
# shell is interactive.
case $- in *i*) echo "TechWatch env loaded (OS_CLOUD=${OS_CLOUD:-unset}). Run 'tw_help'." ;; esac
