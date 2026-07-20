#!/bin/bash
#===============================================================================
# install.sh - install auto-update.sh as a system tool
#
# Installs:
#   /usr/local/bin/auto-update.sh
#   /usr/local/bin/auto-update.conf      (only if it does not already exist)
#   /etc/systemd/system/auto-update.service
#   /etc/systemd/system/auto-update.timer
#
# Usage:  sudo ./install.sh
#===============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="/usr/local/bin/auto-update.sh"
CONF="/usr/local/bin/auto-update.conf"
SERVICE="/etc/systemd/system/auto-update.service"
TIMER="/etc/systemd/system/auto-update.timer"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "Installing auto-update.sh to $BIN ..."
install -m 0755 "$SCRIPT_DIR/auto-update.sh" "$BIN"

if [ ! -f "$CONF" ]; then
  echo "Creating config at $CONF (edit it with your SMTP settings) ..."
  install -m 0600 "$SCRIPT_DIR/auto-update.conf.example" "$CONF"
else
  echo "Config $CONF already exists; leaving it untouched."
fi

echo "Installing systemd unit files ..."
install -m 0644 "$SCRIPT_DIR/auto-update.service" "$SERVICE"
install -m 0644 "$SCRIPT_DIR/auto-update.timer" "$TIMER"

if command -v systemctl >/dev/null 2>&1; then
  echo "Reloading systemd and enabling timer ..."
  systemctl daemon-reload
  systemctl enable auto-update.timer
  systemctl start auto-update.timer
  echo "Timer enabled and started. Status:"
  systemctl status auto-update.timer --no-pager || true
else
  echo "systemctl not found; skipping timer enable. The script is still usable via cron."
fi

echo "Done. Edit $CONF and then run: $BIN --help"
