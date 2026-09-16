#!/bin/bash
# Return the host to a pre-bootstrap state so each run is a clean reproduction.
sudo systemctl stop versitygw-bootstrap.service 2>/dev/null
sudo systemctl reset-failed versitygw-bootstrap.service 2>/dev/null
sudo sh -c 'rm -f /etc/versitygw/users.d/*.env'
sudo rm -rf /var/lib/versitygw/data/* /var/lib/versitygw/iam/*
sudo rm -rf /root/.aws
sudo systemctl restart versitygw.service
for i in $(seq 30); do curl -sf http://127.0.0.1:7070/health >/dev/null 2>&1 && break; sleep 1; done
