#!/usr/bin/env bash
# =============================================================================
# Expose the loopback-bound Oracle listener to the Azure VNet -- and only the
# VNet -- so the deployed API can reach it over VNet integration.
#
# Runs ON the Azure dev VM:   ./scripts/remote.sh run './scripts/setup-oracle-vnet-forward.sh'
#
# Design decision 9 holds: the container keeps its 127.0.0.1:1521 binding and
# nothing is published to the internet. This adds a socat forwarder on the VM's
# private VNet address (10.0.0.4). The NSG has no internet rule for 1521, so
# the only things that can reach the forwarder are peers inside the VNet --
# which is the App Service's integration subnet.
#
# Idempotent: re-running rewrites the unit and restarts it.
# =============================================================================
set -euo pipefail

PRIVATE_IP="${PRIVATE_IP:-10.0.0.4}"

command -v socat >/dev/null || sudo apt-get install -y -qq socat >/dev/null

sudo tee /etc/systemd/system/oracle-vnet-forward.service >/dev/null <<EOF
[Unit]
Description=Forward VNet-private ${PRIVATE_IP}:1521 to the loopback-bound Oracle listener
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:1521,bind=${PRIVATE_IP},fork,reuseaddr TCP:127.0.0.1:1521
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now oracle-vnet-forward
sudo systemctl restart oracle-vnet-forward
systemctl is-active oracle-vnet-forward
