#!/bin/bash
# run-case.sh <label> <AZ|NONE>
LABEL="$1"; AZ="$2"
echo "############ ${LABEL} ############"
bash ~/reset.sh
sudo pkill -f imds.py 2>/dev/null; sleep 1
if [ "$AZ" != "NONE" ]; then
  sudo python3 ~/imds.py "$AZ" >/dev/null 2>&1 &
  sleep 2
  echo "IMDS availability-zone = $(curl -s -m 2 http://169.254.169.254/latest/meta-data/placement/availability-zone/)"
else
  echo "IMDS: none running"
fi
sudo journalctl --rotate >/dev/null 2>&1; sudo journalctl --vacuum-time=1s >/dev/null 2>&1
sudo systemctl start versitygw-bootstrap.service >/dev/null 2>&1
echo "result: $(systemctl show -p Result --value versitygw-bootstrap.service)  active: $(systemctl is-active versitygw-bootstrap.service)"
echo "--- output (podman event noise stripped) ---"
sudo journalctl -u versitygw-bootstrap.service --no-pager -o cat | grep -vE "^2026-.* container (exec|exec_died) " | grep -vE "^(Starting|Finished|versitygw-bootstrap.service:)" 
sudo pkill -f imds.py 2>/dev/null
echo
