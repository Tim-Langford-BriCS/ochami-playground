#!/bin/bash
# Model the acme-register -> acme-deploy -> haproxy dependency graph at two upstream refs
# and ask: does "systemctl restart acme-register" propagate down the chain?
#
# Faithful to the real units: the acme pair are Type=oneshot RemainAfterExit=yes, and
# haproxy is a long-running service with Restart=always.
#
# NOTE: no '%' anywhere in ExecStart -- systemd would treat it as a specifier (%H is the
# hostname), which silently mangles the command. Logging goes through a helper script.

LOG=/tmp/order.log

sudo tee /usr/local/bin/t-log >/dev/null <<'HELPER'
#!/bin/sh
echo "  $1 ran at $(date +%H:%M:%S.%3N)" >> /tmp/order.log
HELPER
sudo chmod +x /usr/local/bin/t-log

write_units() {
  VARIANT="$1"
  if [ "$VARIANT" = main ]; then
    REG_EXTRA='Upholds=t-deploy.service'
    DEP_PARTOF='PartOf=t-target.target t-register.service'
    DEP_EXTRA='Upholds=t-proxy.service'
    PROXY_PARTOF='PartOf=t-target.target t-deploy.service'
  else
    REG_EXTRA=''
    DEP_PARTOF='PartOf=t-target.target'
    DEP_EXTRA=''
    PROXY_PARTOF='PartOf=t-target.target'
  fi

  sudo tee /etc/systemd/system/t-target.target >/dev/null <<'EOF'
[Unit]
Description=test stand-in for openchami.target
EOF

  sudo tee /etc/systemd/system/t-register.service >/dev/null <<EOF
[Unit]
Description=t-register (acme-register)
PartOf=t-target.target
${REG_EXTRA}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/t-log t-register
EOF

  sudo tee /etc/systemd/system/t-deploy.service >/dev/null <<EOF
[Unit]
Description=t-deploy (acme-deploy)
Requires=t-register.service
After=t-register.service
${DEP_PARTOF}
${DEP_EXTRA}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/t-log t-deploy
EOF

  sudo tee /etc/systemd/system/t-proxy.service >/dev/null <<EOF
[Unit]
Description=t-proxy (haproxy)
Requires=t-deploy.service
After=t-deploy.service
${PROXY_PARTOF}

[Service]
Restart=always
ExecStartPre=/usr/local/bin/t-log t-proxy
ExecStart=/bin/sleep infinity
EOF

  sudo systemctl daemon-reload
}

teardown() {
  sudo systemctl stop t-proxy.service t-deploy.service t-register.service 2>/dev/null
  sudo rm -f /etc/systemd/system/t-register.service /etc/systemd/system/t-deploy.service \
             /etc/systemd/system/t-proxy.service /etc/systemd/system/t-target.target
  sudo systemctl daemon-reload
  sudo systemctl reset-failed 2>/dev/null
}

count_ran() { sudo grep -c ran "${LOG}" 2>/dev/null | head -1 || true; }

run_variant() {
  VARIANT="$1"
  echo "=================== VARIANT: ${VARIANT} ==================="
  teardown
  write_units "${VARIANT}"

  echo "--- dependencies as modelled ---"
  for u in t-register t-deploy t-proxy; do
    printf "  %-11s PartOf=[%s]  Upholds=[%s]\n" "$u" \
      "$(systemctl show $u.service -p PartOf --value)" \
      "$(systemctl show $u.service -p Upholds --value)"
  done

  echo "--- bring the chain up, as openchami.target does ---"
  sudo rm -f "${LOG}"; sudo touch "${LOG}"; sudo chmod 666 "${LOG}"
  sudo systemctl start t-proxy.service >/dev/null 2>&1
  sleep 2
  sudo cat "${LOG}"
  for u in t-register t-deploy t-proxy; do
    printf "  [%s: %s]\n" "$u" "$(systemctl is-active $u.service)"
  done

  echo "--- now: systemctl restart t-register   (what openchami-cert-renewal.service does) ---"
  sudo truncate -s 0 "${LOG}"
  sudo systemctl restart t-register.service >/dev/null 2>&1
  sleep 3
  if [ -s "${LOG}" ]; then sudo cat "${LOG}"; else echo "  (nothing else ran)"; fi

  n=$(count_ran)
  echo "--- verdict: ${n} unit(s) ran on that one restart ---"
  if [ "${n:-0}" -ge 3 ] 2>/dev/null; then
    echo "  >>> propagation REACHES haproxy: the shipped ExecStart order self-corrects here"
  elif [ "${n:-0}" -eq 2 ] 2>/dev/null; then
    echo "  >>> propagation reaches deploy but NOT haproxy"
  else
    echo "  >>> NO propagation: deploy-before-issue is a real defect on this ref"
  fi
  echo
}

run_variant v016
run_variant main
teardown
sudo rm -f /usr/local/bin/t-log
exit 0
