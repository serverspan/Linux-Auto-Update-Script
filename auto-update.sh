#!/bin/bash
#===============================================================================
# Script Name: auto-update.sh
# Description: Automatically updates Linux systems (Debian/Ubuntu, RedHat/CentOS/Fedora)
#              and handles situations requiring manual intervention by notifying
#              system administrators via email.
#
# Features:    - Cross-distribution compatibility (apt and yum/dnf)
#              - Safe updates (no package removal without approval)
#              - Configuration preservation (always keeps existing config files)
#              - Non-interactive operation (handles all prompts automatically)
#              - Email notifications for issues requiring manual intervention
#              - Detailed logging
#              - Verbosity options (-v for verbose output, -vv for verbose logging)
#              - External/per-directory configuration file (auto-update.conf)
#              - Concurrent-run guard (flock)
#              - Reboot detection and optional automatic reboot
#              - Optional success / summary email reports
#
# Author:      ENGINYRING (https://github.com/ENGINYRING)
# Repository:  https://github.com/serverspan/Linux-Auto-Update-Script
# License:     MIT
#
# Usage:       ./auto-update.sh [options]
#   -v            Verbose output to terminal
#   -vv           Very verbose (detailed logging and terminal output)
#   --dry-run     Simulate only; never apply updates
#   --mail-summary  After a successful run, email the admin a summary of
#                  what changed and whether a reboot is required
#   --help, -h     Show this help
#
# Recommended: Set up as a cron job or systemd timer for regular execution
#              (see README.md for details)
#===============================================================================

#-------------------------------------------------------------------------------
# Strict mode: catch unset variables and pipeline failures. We intentionally do
# NOT use `set -e` because several package-manager commands (e.g. apt simulate,
# yum/dnf check-update) return non-zero exit codes that we handle explicitly.
#-------------------------------------------------------------------------------
set -uo pipefail

#-------------------------------------------------------------------------------
# Resolve the directory this script lives in, so the config file can sit next to
# the script regardless of the current working directory.
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${AUTO_UPDATE_CONFIG:-$SCRIPT_DIR/${SCRIPT_NAME%.*}.conf}"

#-------------------------------------------------------------------------------
# Plain built-in defaults. These are applied with a leading underscore so that
# the precedence order can be: environment variables > config file > defaults.
#-------------------------------------------------------------------------------
_D_ADMIN_EMAIL="admin@example.com"
_D_SMTP_SERVER="smtp.example.com"
_D_SMTP_PORT="587"
_D_SMTP_USER="notifications@example.com"
_D_SMTP_PASS="your_password_here"
_D_LOG_FILE="/var/log/auto-update.log"
_D_AUTO_REBOOT="false"
_D_NOTIFY_ON_SUCCESS="false"
_D_DRY_RUN="false"
_D_MAIL_SUMMARY="false"

# Verbosity level (0=normal, 1=verbose, 2=very verbose)
VERBOSITY=0

#-------------------------------------------------------------------------------
# Load configuration from the file next to the script (if present). The file
# overrides the built-in defaults. Environment variables take precedence over
# both the file and the defaults.
#
# To honor env > file > default, we record which variables were already present
# in the environment BEFORE sourcing the file, then restore those after.
#-------------------------------------------------------------------------------
_ENV_VARS=(ADMIN_EMAIL SMTP_SERVER SMTP_PORT SMTP_USER SMTP_PASS LOG_FILE \
           AUTO_REBOOT NOTIFY_ON_SUCCESS DRY_RUN MAIL_SUMMARY)
declare -A _ENV_VAL
for _v in "${_ENV_VARS[@]}"; do
  if [ -n "${!_v:-}" ]; then
    _ENV_VAL["$_v"]="${!_v}"
  fi
done

if [ -f "$CONFIG_FILE" ]; then
  if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  else
    echo "Warning: config file $CONFIG_FILE exists but is not readable; using defaults/env." >&2
  fi
fi

# Apply precedence: env (if originally set) > file > built-in default.
for _v in "${_ENV_VARS[@]}"; do
  _def="_D_$_v"
  if [ -n "${_ENV_VAL["$_v"]:-}" ]; then
    # Environment variable wins: restore it over whatever the file set.
    printf -v "$_v" '%s' "${_ENV_VAL["$_v"]}"
  elif [ -z "${!_v:-}" ]; then
    # Not in env and not in file: use built-in default.
    printf -v "$_v" '%s' "${!_def}"
  fi
  # Otherwise: set by the file only -> keep the file value.
done
unset _v _def _ENV_VARS _ENV_VAL

# Normalize boolean config values to lowercase "true"/"false" for reliable comparison.
# Accepts: true/false, TRUE/FALSE, True/False, 1/0, yes/no, on/off
_bool_normalize() {
  local var_name="$1"
  local val="${!var_name}"
  case "${val,,}" in
    true|1|yes|on)  printf -v "$var_name" 'true' ;;
    false|0|no|off) printf -v "$var_name" 'false' ;;
    *)              # If it's something unexpected, default to false for safety
                    printf -v "$var_name" 'false' ;;
  esac
}
for _bv in AUTO_REBOOT NOTIFY_ON_SUCCESS DRY_RUN MAIL_SUMMARY; do
  _bool_normalize "$_bv"
done
unset _bv _bool_normalize

HOSTNAME="$(hostname)"

#-------------------------------------------------------------------------------
# Logging (defined early so they are available to the lock guard below)
#-------------------------------------------------------------------------------
log() {
  local message="$1"
  local level=${2:-"INFO"}
  local timestamp
  timestamp="$(date "+%Y-%m-%d %H:%M:%S")"

  # Always write to the log file
  # shellcheck disable=SC2153 # LOG_FILE is assigned during config resolution above
  echo "[$timestamp] $level: $message" >> "$LOG_FILE"

  # If verbosity is at least 1, also output to terminal
  if [ $VERBOSITY -ge 1 ]; then
    echo "[$timestamp] $level: $message"
  fi
}

# Function for verbose logging
log_verbose() {
  local message="$1"

  if [ $VERBOSITY -ge 2 ]; then
    log "$message" "VERBOSE"
  elif [ $VERBOSITY -eq 1 ]; then
    local timestamp
    timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
    echo "[$timestamp] VERBOSE: $message"
  fi
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
while (( "$#" )); do
  case "$1" in
    -vv)
      VERBOSITY=2
      shift
      ;;
    -v)
      VERBOSITY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --mail-summary)
      MAIL_SUMMARY=true
      shift
      ;;
    --help|-h)
      # Print the usage block from the script header
      sed -n '/^# Usage:/,/^# Recommended:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Error: Unsupported flag $1" >&2
      echo "Usage: $0 [-v|-vv] [--dry-run] [--mail-summary] [--help]" >&2
      exit 1
      ;;
    *)
      echo "Error: Unexpected argument $1" >&2
      echo "Usage: $0 [-v|-vv] [--dry-run] [--mail-summary] [--help]" >&2
      exit 1
      ;;
  esac
done

#-------------------------------------------------------------------------------
# Concurrent-run guard: only one instance may run at a time.
# LOCK_FILE can be overridden via env (useful for testing).
#-------------------------------------------------------------------------------
LOCK_FILE="${AUTO_UPDATE_LOCK:-/var/run/${SCRIPT_NAME%.*}.lock}"
exec 9>"$LOCK_FILE" || { echo "Error: cannot open lock file $LOCK_FILE" >&2; exit 1; }
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    echo "Error: another instance of $SCRIPT_NAME is already running. Exiting." >&2
    exit 1
  fi
else
  # flock unavailable (e.g. some minimal/macOS/Git-Bash environments): degrade
  # gracefully instead of refusing to run.
  log_verbose "flock not available; skipping concurrent-run guard"
fi

#-------------------------------------------------------------------------------
# Email sending. Uses curl's SMTP support. Real newlines are produced with
# printf so the message body is formatted correctly.
#-------------------------------------------------------------------------------
send_email() {
  local subject="$1"
  local body="$2"
  local rc=0

  log "Sending email to $ADMIN_EMAIL with subject: $subject"

  {
    printf 'Subject: %s\n' "$subject"
    printf 'From: System Update <%s>\n' "$SMTP_USER"
    printf 'To: Admin <%s>\n' "$ADMIN_EMAIL"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=utf-8\n'
    printf '\n'
    printf '%s\n' "$body"
  } | curl --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
              --ssl-reqd \
              --mail-from "$SMTP_USER" \
              --mail-rcpt "$ADMIN_EMAIL" \
              --user "$SMTP_USER:$SMTP_PASS" \
              --upload-file - \
              --silent \
              --show-error \
              --connect-timeout 30
  rc=$?

  if [ $rc -eq 0 ]; then
    log "Email sent to $ADMIN_EMAIL"
  else
    log "Failed to send email to $ADMIN_EMAIL (curl exit code: $rc)" "ERROR"
  fi
  return $rc
}

#-------------------------------------------------------------------------------
# Log and (optionally) email errors
#-------------------------------------------------------------------------------
log_error() {
  local message="$1"
  local send_mail=${2:-true}

  log "$message" "ERROR"

  if [ "$send_mail" = true ]; then
    send_email "[$HOSTNAME] Error during system update" \
      "An error occurred during the system update process on $HOSTNAME:

$message

Please check $LOG_FILE for details."
  fi
}

#-------------------------------------------------------------------------------
# Reboot detection
#-------------------------------------------------------------------------------
reboot_required() {
  # Debian/Ubuntu
  if [ -f /var/run/reboot-required ]; then
    return 0
  fi
  # needrestart (Debian/Ubuntu) - returns 0 if a reboot is required
  if command -v needrestart >/dev/null 2>&1; then
    if needrestart -k 2>/dev/null | grep -qi "System restart required"; then
      return 0
    fi
  fi
  # RHEL/CentOS/Fedora: check for a running kernel older than the installed one
  if command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    # Compare running vs latest installed kernel safely
    local running
    running="$(uname -r)"
    local latest=""
    if command -v dnf >/dev/null 2>&1; then
      latest="$(dnf -q --cacheonly list installed 'kernel*' 2>/dev/null | awk 'NR>1{print $2"-"$3}' | sort -V | tail -1)"
    elif command -v rpm >/dev/null 2>&1; then
      latest="$(rpm -q --last kernel 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-//')"
    fi
    if [ -n "$latest" ] && [ "$latest" != "$running" ]; then
      return 0
    fi
  fi
  return 1
}

#-------------------------------------------------------------------------------
# Begin
#-------------------------------------------------------------------------------
log "=== Auto-update script started at $(date) ==="
log_verbose "Script version: 1.2.0"
log_verbose "Verbosity level: $VERBOSITY"
log_verbose "Config file: $CONFIG_FILE"
[ "$DRY_RUN" = true ] && log "DRY-RUN mode enabled: no changes will be applied"
[ "$MAIL_SUMMARY" = true ] && log_verbose "Mail-summary enabled"
[ "$AUTO_REBOOT" = true ] && log_verbose "Automatic reboot enabled"
[ "$NOTIFY_ON_SUCCESS" = true ] && log_verbose "Success notifications enabled"

# Detect package manager
if command -v apt >/dev/null 2>&1; then
  PKG_MANAGER="apt"
  log "Detected apt package manager"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
  log "Detected dnf package manager"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
  log "Detected yum package manager"
else
  log_error "No supported package manager found"
  exit 1
fi

# Summary accumulators (used by --mail-summary)
SUMMARY_APPLIED=false
SUMMARY_DETAIL=""

#-------------------------------------------------------------------------------
# apt-based systems
#-------------------------------------------------------------------------------
if [ "$PKG_MANAGER" = "apt" ]; then
  # Force C locale so parsing of simulate output is stable across locales
  export LC_ALL=C
  export DEBIAN_FRONTEND=noninteractive

  log "Updating package lists with apt"
  log_verbose "Running: apt update -y"

  if [ $VERBOSITY -ge 1 ]; then
    APT_UPDATE_OUTPUT="$(apt update -y 2>&1)"
    UPDATE_RESULT=$?
    echo "$APT_UPDATE_OUTPUT"
    [ $VERBOSITY -eq 2 ] && log_verbose "apt update output: $APT_UPDATE_OUTPUT"
  else
    apt update -y >> "$LOG_FILE" 2>&1
    UPDATE_RESULT=$?
  fi

  if [ $UPDATE_RESULT -ne 0 ]; then
    log_error "Failed to update package lists (exit code: $UPDATE_RESULT)"
    exit 1
  fi

  log "Checking for packages that would be removed or held back"
  log_verbose "Running: apt upgrade --simulate"

  APT_UPGRADE_SIMULATION="$(apt upgrade --simulate 2>&1)"
  [ $VERBOSITY -ge 1 ] && echo "$APT_UPGRADE_SIMULATION"
  [ $VERBOSITY -eq 2 ] && log_verbose "apt upgrade simulation output: $APT_UPGRADE_SIMULATION"

  PKGS_TO_REMOVE="$(echo "$APT_UPGRADE_SIMULATION" | grep "The following packages will be REMOVED")"
  PKGS_KEPT_BACK="$(echo "$APT_UPGRADE_SIMULATION" | grep "The following packages have been kept back")"

  # NOTE: we deliberately do NOT treat "Need to get ... of archives" as manual
  # intervention - that line appears in every normal upgrade and previously
  # caused false-positive notification emails.
  MANUAL_INTERVENTION="$(echo "$APT_UPGRADE_SIMULATION" | grep -E "You should explicitly select|The following packages require")"

  if [ -n "$PKGS_TO_REMOVE" ] || [ -n "$MANUAL_INTERVENTION" ]; then
    log "Packages would be removed or require manual intervention. Sending email."
    UPGRADE_DETAILS="$(echo "$APT_UPGRADE_SIMULATION" | grep -A 100 "The following packages")"
    send_email "[$HOSTNAME] Manual intervention required for system update" \
"Manual intervention is required on $HOSTNAME because packages would be removed or require manual handling.

Details:
$UPGRADE_DETAILS"
    log "Exiting without applying updates (manual intervention required)."
    exit 0
  elif [ -n "$PKGS_KEPT_BACK" ]; then
    log "Some packages kept back. Checking if dist-upgrade would remove packages."
    log_verbose "Running: apt dist-upgrade --simulate"

    APT_DISTUPGRADE_SIMULATION="$(apt dist-upgrade --simulate 2>&1)"
    [ $VERBOSITY -ge 1 ] && echo "$APT_DISTUPGRADE_SIMULATION"
    [ $VERBOSITY -eq 2 ] && log_verbose "apt dist-upgrade simulation output: $APT_DISTUPGRADE_SIMULATION"

    DISTUPGRADE_REMOVE="$(echo "$APT_DISTUPGRADE_SIMULATION" | grep "The following packages will be REMOVED")"

    if [ -n "$DISTUPGRADE_REMOVE" ]; then
      log "dist-upgrade would remove packages. Sending email."
      send_email "[$HOSTNAME] Manual intervention required for system update" \
"Packages are kept back on $HOSTNAME and dist-upgrade would remove packages.

Kept back:
$PKGS_KEPT_BACK

dist-upgrade details:
$APT_DISTUPGRADE_SIMULATION"
      log "Exiting without applying updates (manual intervention required)."
      exit 0
    else
      log "dist-upgrade would not remove packages. Proceeding with dist-upgrade."
      SUMMARY_APPLIED=true
      SUMMARY_DETAIL="$APT_DISTUPGRADE_SIMULATION"
      if [ "$DRY_RUN" = false ]; then
        log_verbose "Running: apt dist-upgrade -y -o Dpkg::Options::=\"--force-confold\""
        if [ $VERBOSITY -ge 1 ]; then
          APT_DISTUPGRADE_OUTPUT="$(apt dist-upgrade -y -o Dpkg::Options::="--force-confold" 2>&1)"
          UPGRADE_RESULT=$?
          echo "$APT_DISTUPGRADE_OUTPUT"
          [ $VERBOSITY -eq 2 ] && log_verbose "apt dist-upgrade output: $APT_DISTUPGRADE_OUTPUT"
        else
          apt dist-upgrade -y -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1
          UPGRADE_RESULT=$?
        fi
        if [ $UPGRADE_RESULT -eq 0 ]; then
          log "dist-upgrade completed successfully"
        else
          SUMMARY_APPLIED=false
          log_error "dist-upgrade failed with exit code $UPGRADE_RESULT"
        fi
      else
        log "DRY-RUN: would have run apt dist-upgrade -y --force-confold"
      fi
    fi
  else
    log "No packages would be removed. Proceeding with automatic upgrade."
    SUMMARY_APPLIED=true
    SUMMARY_DETAIL="$APT_UPGRADE_SIMULATION"
    if [ "$DRY_RUN" = false ]; then
      log_verbose "Running: apt upgrade -y -o Dpkg::Options::=\"--force-confold\""
      if [ $VERBOSITY -ge 1 ]; then
        APT_UPGRADE_OUTPUT="$(apt upgrade -y -o Dpkg::Options::="--force-confold" 2>&1)"
        UPGRADE_RESULT=$?
        echo "$APT_UPGRADE_OUTPUT"
        [ $VERBOSITY -eq 2 ] && log_verbose "apt upgrade output: $APT_UPGRADE_OUTPUT"
      else
        apt upgrade -y -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1
        UPGRADE_RESULT=$?
      fi
      if [ $UPGRADE_RESULT -eq 0 ]; then
        log "Upgrade completed successfully"
      else
        SUMMARY_APPLIED=false
        log_error "Upgrade failed with exit code $UPGRADE_RESULT"
      fi
    else
      log "DRY-RUN: would have run apt upgrade -y --force-confold"
    fi
  fi

#-------------------------------------------------------------------------------
# yum/dnf-based systems
#-------------------------------------------------------------------------------
elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
  export LC_ALL=C

  log_verbose "Running: $PKG_MANAGER check-update"

  if [ $VERBOSITY -ge 1 ]; then
    CHECK_UPDATE_OUTPUT="$($PKG_MANAGER check-update 2>&1)"
    CHECK_UPDATE_RESULT=$?
    echo "$CHECK_UPDATE_OUTPUT"
    [ $VERBOSITY -eq 2 ] && log_verbose "$PKG_MANAGER check-update output: $CHECK_UPDATE_OUTPUT"
  else
    $PKG_MANAGER check-update >> "$LOG_FILE" 2>&1
    CHECK_UPDATE_RESULT=$?
  fi

  # yum/dnf check-update returns 100 when updates are available, 0 when none
  if [ $CHECK_UPDATE_RESULT -ne 0 ] && [ $CHECK_UPDATE_RESULT -ne 100 ]; then
    log_error "Failed to check for updates (exit code: $CHECK_UPDATE_RESULT)"
    exit 1
  fi

  if [ $CHECK_UPDATE_RESULT -eq 0 ]; then
    log "No updates available"
    SUMMARY_APPLIED=false
  else
    log "Checking for packages that would be removed"
    log_verbose "Running: $PKG_MANAGER upgrade --assumeno"

    UPGRADE_SIMULATION="$($PKG_MANAGER upgrade --assumeno 2>&1)"
    [ $VERBOSITY -ge 1 ] && echo "$UPGRADE_SIMULATION"
    [ $VERBOSITY -eq 2 ] && log_verbose "$PKG_MANAGER upgrade simulation output: $UPGRADE_SIMULATION"

    PKGS_TO_REMOVE="$(echo "$UPGRADE_SIMULATION" | grep -i "removing")"
    MANUAL_INTERVENTION="$(echo "$UPGRADE_SIMULATION" | grep -i -E "error:|conflict|failed|is needed by")"

    if [ -n "$PKGS_TO_REMOVE" ] || [ -n "$MANUAL_INTERVENTION" ]; then
      log "Packages would be removed or require manual intervention. Sending email."
      send_email "[$HOSTNAME] Manual intervention required for system update" \
"Manual intervention is required on $HOSTNAME because packages would be removed or there are conflicts.

Details:
$UPGRADE_SIMULATION"
      log "Exiting without applying updates (manual intervention required)."
      exit 0
    else
      log "No packages would be removed. Proceeding with automatic upgrade."
      SUMMARY_APPLIED=true
      SUMMARY_DETAIL="$UPGRADE_SIMULATION"
      if [ "$DRY_RUN" = false ]; then
        log_verbose "Running: $PKG_MANAGER upgrade -y"
        if [ $VERBOSITY -ge 1 ]; then
          UPGRADE_OUTPUT="$($PKG_MANAGER upgrade -y 2>&1)"
          UPGRADE_RESULT=$?
          echo "$UPGRADE_OUTPUT"
          [ $VERBOSITY -eq 2 ] && log_verbose "$PKG_MANAGER upgrade output: $UPGRADE_OUTPUT"
        else
          $PKG_MANAGER upgrade -y >> "$LOG_FILE" 2>&1
          UPGRADE_RESULT=$?
        fi
        if [ $UPGRADE_RESULT -eq 0 ]; then
          log "Upgrade completed successfully"
        else
          SUMMARY_APPLIED=false
          log_error "Upgrade failed with exit code $UPGRADE_RESULT"
        fi
      else
        log "DRY-RUN: would have run $PKG_MANAGER upgrade -y"
      fi
    fi
  fi
fi

#-------------------------------------------------------------------------------
# Reboot handling
#-------------------------------------------------------------------------------
if reboot_required; then
  log "A system reboot is REQUIRED (kernel or core library update)."
  if [ "$AUTO_REBOOT" = true ] && [ "$DRY_RUN" = false ]; then
    log "Automatic reboot enabled. Rebooting now."
    if [ "$MAIL_SUMMARY" = true ]; then
      send_email "[$HOSTNAME] Updates applied - rebooting now" \
"Updates were applied successfully on $HOSTNAME and a reboot is required.

A reboot is being performed now because AUTO_REBOOT is enabled.

-- Auto-update script"
    fi
    # Release the lock before rebooting so the next run is not blocked
    flock -u 9
    /sbin/reboot
    exit 0
  else
    log "Automatic reboot is disabled; please reboot $HOSTNAME at your convenience."
  fi
else
  log "No reboot required."
fi

#-------------------------------------------------------------------------------
# Success / summary notifications
#-------------------------------------------------------------------------------
if [ "$SUMMARY_APPLIED" = true ]; then
  REBOOT_MSG="No reboot required."
  reboot_required && REBOOT_MSG="A reboot IS required." || REBOOT_MSG="No reboot required."

  if [ "$MAIL_SUMMARY" = true ]; then
    send_email "[$HOSTNAME] Update summary - changes applied" \
"System update completed successfully on $HOSTNAME.

What changed:
$SUMMARY_DETAIL

Reboot status: $REBOOT_MSG

-- Auto-update script"
  elif [ "$NOTIFY_ON_SUCCESS" = true ]; then
    send_email "[$HOSTNAME] System update completed successfully" \
"System update completed successfully on $HOSTNAME.
$REBOOT_MSG

-- Auto-update script"
  fi
else
  # No updates were applied (e.g. none available) - optional brief notice
  if [ "$NOTIFY_ON_SUCCESS" = true ]; then
    REBOOT_MSG="No reboot required."
    reboot_required && REBOOT_MSG="A reboot IS required." || REBOOT_MSG="No reboot required."
    send_email "[$HOSTNAME] System update run - no changes" \
"System update ran on $HOSTNAME but no packages were upgraded.
$REBOOT_MSG

-- Auto-update script"
  fi
fi

log "=== Auto-update script completed at $(date) ==="
