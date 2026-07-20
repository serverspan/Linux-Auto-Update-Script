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
# The companion files are expected to live next to this script. If any are
# missing (e.g. when only install.sh was downloaded on its own), they are
# fetched from the project's raw GitHub URL using the branch below (override
# with AUTO_UPDATE_BRANCH or pass --branch).
#
# Usage:  sudo ./install.sh [--branch <name>]
#===============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="/usr/local/bin/auto-update.sh"
CONF="/usr/local/bin/auto-update.conf"
SERVICE="/etc/systemd/system/auto-update.service"
TIMER="/etc/systemd/system/auto-update.timer"

# Where to fetch companion files from if they are missing locally.
BRANCH="${AUTO_UPDATE_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/serverspan/Linux-Auto-Update-Script/${BRANCH}"

# Parse optional --branch
while (( "$#" )); do
  case "$1" in
    --branch) BRANCH="$2"; RAW_BASE="https://raw.githubusercontent.com/serverspan/Linux-Auto-Update-Script/${BRANCH}"; shift 2 ;;
    *) echo "Error: unexpected argument $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

# Ensure a downloader is available
if command -v curl >/dev/null 2>&1; then
  _fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  _fetch() { wget -qO "$2" "$1"; }
else
  echo "Error: neither curl nor wget is available to fetch missing files." >&2
  exit 1
fi

# Resolve a source file: use the local copy if present, otherwise fetch it.
resolve_source() {
  local name="$1"
  local local_path="$SCRIPT_DIR/$name"
  if [ -f "$local_path" ]; then
    printf '%s' "$local_path"
    return 0
  fi
  # Not present locally -> fetch into a temp file
  local tmp
  tmp="$(mktemp)"
  echo "Fetching $name from $RAW_BASE ..."
  if _fetch "$RAW_BASE/$name" "$tmp"; then
    printf '%s' "$tmp"
    return 0
  fi
  rm -f "$tmp"
  echo "Error: could not find or fetch $name (looked in $local_path and $RAW_BASE/$name)." >&2
  return 1
}

echo "Installing auto-update.sh to $BIN ..."
SRC="$(resolve_source auto-update.sh)" || exit 1
install -m 0755 "$SRC" "$BIN"
# If we fetched a temp copy, clean it up later via trap-like manual rm
[ "$SRC" != "$SCRIPT_DIR/auto-update.sh" ] && rm -f "$SRC"

if [ ! -f "$CONF" ]; then
  echo "Creating config at $CONF (edit it with your SMTP settings) ..."
  SRC="$(resolve_source auto-update.conf.example)" || exit 1
  install -m 0600 "$SRC" "$CONF"
  [ "$SRC" != "$SCRIPT_DIR/auto-update.conf.example" ] && rm -f "$SRC"
else
  echo "Config $CONF already exists; leaving it untouched."
fi

echo "Installing systemd unit files ..."
SRC="$(resolve_source auto-update.service)" || exit 1
install -m 0644 "$SRC" "$SERVICE"
[ "$SRC" != "$SCRIPT_DIR/auto-update.service" ] && rm -f "$SRC"

SRC="$(resolve_source auto-update.timer)" || exit 1
install -m 0644 "$SRC" "$TIMER"
[ "$SRC" != "$SCRIPT_DIR/auto-update.timer" ] && rm -f "$SRC"

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
