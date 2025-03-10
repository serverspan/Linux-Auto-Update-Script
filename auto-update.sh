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
#
# Author:      ENGINYRING (https://github.com/ENGINYRING)
# Repository:  https://github.com/ENGINYRING/Linux-Auto-Update-Script
# License:     MIT
#
# Usage:       ./auto-update.sh [-v|-vv]
#              -v  : Verbose output to terminal
#              -vv : Very verbose (detailed logging and terminal output)
#
# Recommended: Set up as a cron job or systemd timer for regular execution
#              (see README.md for details)
#===============================================================================

# Configuration - Change these values
ADMIN_EMAIL="admin@example.com"
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="notifications@example.com"
SMTP_PASS="your_password_here"
HOSTNAME=$(hostname)

# Verbosity level (0=normal, 1=verbose, 2=very verbose)
VERBOSITY=0

# Parse command-line arguments
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
    -*)
      echo "Error: Unsupported flag $1" >&2
      echo "Usage: $0 [-v|-vv]" >&2
      exit 1
      ;;
    *)
      echo "Error: Unexpected argument $1" >&2
      echo "Usage: $0 [-v|-vv]" >&2
      exit 1
      ;;
  esac
done

# Log file
LOG_FILE="/var/log/auto-update.log"

# Function to log messages
log() {
  local message="$1"
  local level=${2:-"INFO"}
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  # Always write to the log file
  echo "[$timestamp] $level: $message" >> "$LOG_FILE"
  
  # If verbosity is at least 1, also output to terminal
  if [ $VERBOSITY -ge 1 ]; then
    echo "[$timestamp] $level: $message"
  fi
}

# Function for verbose logging
log_verbose() {
  local message="$1"
  
  # Only log verbose messages if verbosity is at least 2
  if [ $VERBOSITY -ge 2 ]; then
    log "$message" "VERBOSE"
  # When in level 1 verbosity, just print without logging to file
  elif [ $VERBOSITY -eq 1 ]; then
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] VERBOSE: $message"
  fi
}

# Function to send email
send_email() {
  local subject="$1"
  local body="$2"
  
  log "Sending email to $ADMIN_EMAIL with subject: $subject"
  
  echo "Subject: $subject
From: System Update <$SMTP_USER>
To: Admin <$ADMIN_EMAIL>

$body" | curl --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
              --ssl-reqd \
              --mail-from "$SMTP_USER" \
              --mail-rcpt "$ADMIN_EMAIL" \
              --user "$SMTP_USER:$SMTP_PASS" \
              --upload-file - \
              --silent \
              --show-error \
              --connect-timeout 30
  
  if [ $? -eq 0 ]; then
    log "Email sent to $ADMIN_EMAIL"
  else
    log "Failed to send email to $ADMIN_EMAIL" "ERROR"
  fi
}

# Function to log and potentially email errors
log_error() {
  local message="$1"
  local send_mail=${2:-true}
  
  log "$message" "ERROR"
  
  if [ "$send_mail" = true ]; then
    send_email "[$HOSTNAME] Error during system update" "An error occurred during the system update process on $HOSTNAME:\n\n$message\n\nPlease check /var/log/auto-update.log for details."
  fi
}

# Start log
log "=== Auto-update script started at $(date) ==="
log_verbose "Script version: 1.1.0 with verbosity options"
log_verbose "Verbosity level: $VERBOSITY"

# Detect package manager
if command -v apt &> /dev/null; then
  PKG_MANAGER="apt"
  log "Detected apt package manager"
elif command -v dnf &> /dev/null; then
  PKG_MANAGER="dnf"
  log "Detected dnf package manager"
elif command -v yum &> /dev/null; then
  PKG_MANAGER="yum"
  log "Detected yum package manager"
else
  log_error "No supported package manager found"
  exit 1
fi

# Update package lists
log "Updating package lists with $PKG_MANAGER"

if [ "$PKG_MANAGER" = "apt" ]; then
  # Set environment variables to handle interactive prompts
  export DEBIAN_FRONTEND=noninteractive
  
  log_verbose "Running: apt update -y"
  
  # Capture the output to show in verbose mode
  if [ $VERBOSITY -ge 1 ]; then
    APT_UPDATE_OUTPUT=$(apt update -y 2>&1)
    echo "$APT_UPDATE_OUTPUT"
    if [ $VERBOSITY -eq 2 ]; then
      log_verbose "apt update output: $APT_UPDATE_OUTPUT"
    fi
    UPDATE_RESULT=$?
  else
    # Original behavior if not in verbose mode
    apt update -y >> "$LOG_FILE" 2>&1
    UPDATE_RESULT=$?
  fi
  
  if [ $UPDATE_RESULT -ne 0 ]; then
    log_error "Failed to update package lists (exit code: $UPDATE_RESULT)"
    exit 1
  fi
  
  # Check for packages that would be removed or held back
  log "Checking for packages that would be removed or held back"
  log_verbose "Running: apt upgrade --simulate"
  
  # Always capture the output for analysis
  APT_UPGRADE_SIMULATION=$(apt upgrade --simulate 2>&1)
  
  # In verbose mode, show this output
  if [ $VERBOSITY -ge 1 ]; then
    echo "$APT_UPGRADE_SIMULATION"
  fi
  
  # Log the full simulation output in very verbose mode
  if [ $VERBOSITY -eq 2 ]; then
    log_verbose "apt upgrade simulation output: $APT_UPGRADE_SIMULATION"
  fi
  
  PKGS_TO_REMOVE=$(echo "$APT_UPGRADE_SIMULATION" | grep "The following packages will be REMOVED")
  PKGS_KEPT_BACK=$(echo "$APT_UPGRADE_SIMULATION" | grep "The following packages have been kept back")
  
  # Also check if there are any packages that need manual intervention
  MANUAL_INTERVENTION=$(echo "$APT_UPGRADE_SIMULATION" | grep -E "You should explicitly select|The following packages require|Need to get .* of archives")
  
  if [ -n "$PKGS_TO_REMOVE" ] || [ -n "$MANUAL_INTERVENTION" ]; then
    log "Packages would be removed or require manual intervention. Sending email."
    UPGRADE_DETAILS=$(echo "$APT_UPGRADE_SIMULATION" | grep -A 100 "The following packages")
    send_email "[$HOSTNAME] Manual intervention required for system update" "The system update on $HOSTNAME requires manual intervention because packages would be removed or require manual handling.\n\nDetails:\n$UPGRADE_DETAILS"
  elif [ -n "$PKGS_KEPT_BACK" ]; then
    # Some packages kept back - check if dist-upgrade would remove packages
    log "Some packages kept back. Checking if dist-upgrade would remove packages."
    log_verbose "Running: apt dist-upgrade --simulate"
    
    # Always capture the output for analysis
    APT_DISTUPGRADE_SIMULATION=$(apt dist-upgrade --simulate 2>&1)
    
    # In verbose mode, show this output
    if [ $VERBOSITY -ge 1 ]; then
      echo "$APT_DISTUPGRADE_SIMULATION"
    fi
    
    # Log the full simulation output in very verbose mode
    if [ $VERBOSITY -eq 2 ]; then
      log_verbose "apt dist-upgrade simulation output: $APT_DISTUPGRADE_SIMULATION"
    fi
    
    DISTUPGRADE_REMOVE=$(echo "$APT_DISTUPGRADE_SIMULATION" | grep "The following packages will be REMOVED")
    
    if [ -n "$DISTUPGRADE_REMOVE" ]; then
      log "dist-upgrade would remove packages. Sending email."
      send_email "[$HOSTNAME] Manual intervention required for system update" "The system update on $HOSTNAME has packages kept back, and using dist-upgrade would remove packages.\n\nKept back:\n$PKGS_KEPT_BACK\n\ndist-upgrade details:\n$APT_DISTUPGRADE_SIMULATION"
    else
      # No packages would be removed with dist-upgrade, so we can proceed to fully upgrade all packages
      log "dist-upgrade would not remove packages. Proceeding with dist-upgrade."
      log_verbose "Running: apt dist-upgrade -y -o Dpkg::Options::=\"--force-confold\""
      
      # Set options to always keep existing config files
      # --force-confold: always keep the old config files
      if [ $VERBOSITY -ge 1 ]; then
        APT_DISTUPGRADE_OUTPUT=$(apt dist-upgrade -y -o Dpkg::Options::="--force-confold" 2>&1)
        echo "$APT_DISTUPGRADE_OUTPUT"
        if [ $VERBOSITY -eq 2 ]; then
          log_verbose "apt dist-upgrade output: $APT_DISTUPGRADE_OUTPUT"
        fi
        UPGRADE_RESULT=$?
      else
        apt dist-upgrade -y -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1
        UPGRADE_RESULT=$?
      fi
      
      if [ $UPGRADE_RESULT -eq 0 ]; then
        log "dist-upgrade completed successfully"
      else
        log_error "dist-upgrade failed with exit code $UPGRADE_RESULT"
      fi
    fi
  else
    log "No packages would be removed. Proceeding with automatic upgrade."
    log_verbose "Running: apt upgrade -y -o Dpkg::Options::=\"--force-confold\""
    
    if [ $VERBOSITY -ge 1 ]; then
      APT_UPGRADE_OUTPUT=$(apt upgrade -y -o Dpkg::Options::="--force-confold" 2>&1)
      echo "$APT_UPGRADE_OUTPUT"
      if [ $VERBOSITY -eq 2 ]; then
        log_verbose "apt upgrade output: $APT_UPGRADE_OUTPUT"
      fi
      UPGRADE_RESULT=$?
    else
      apt upgrade -y -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1
      UPGRADE_RESULT=$?
    fi
    
    if [ $UPGRADE_RESULT -eq 0 ]; then
      log "Upgrade completed successfully"
    else
      log_error "Upgrade failed with exit code $UPGRADE_RESULT"
    fi
  fi

elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
  # Both yum and dnf have similar interfaces
  log_verbose "Running: $PKG_MANAGER check-update"
  
  if [ $VERBOSITY -ge 1 ]; then
    CHECK_UPDATE_OUTPUT=$($PKG_MANAGER check-update 2>&1)
    echo "$CHECK_UPDATE_OUTPUT"
    if [ $VERBOSITY -eq 2 ]; then
      log_verbose "$PKG_MANAGER check-update output: $CHECK_UPDATE_OUTPUT"
    fi
    CHECK_UPDATE_RESULT=$?
  else
    $PKG_MANAGER check-update >> "$LOG_FILE" 2>&1
    CHECK_UPDATE_RESULT=$?
  fi
  
  # yum/dnf check-update returns 100 when updates are available, 0 when no updates are available
  if [ $CHECK_UPDATE_RESULT -ne 0 ] && [ $CHECK_UPDATE_RESULT -ne 100 ]; then
    log_error "Failed to check for updates (exit code: $CHECK_UPDATE_RESULT)"
    exit 1
  fi
  
  # Check if there are any updates available
  if [ $CHECK_UPDATE_RESULT -eq 0 ]; then
    log "No updates available"
    exit 0
  fi
  
  # Check for packages that would be removed
  log "Checking for packages that would be removed"
  log_verbose "Running: $PKG_MANAGER upgrade --assumeno"
  
  # Always capture the output for analysis
  UPGRADE_SIMULATION=$($PKG_MANAGER upgrade --assumeno 2>&1)
  
  # In verbose mode, show this output
  if [ $VERBOSITY -ge 1 ]; then
    echo "$UPGRADE_SIMULATION"
  fi
  
  # Log the full simulation output in very verbose mode
  if [ $VERBOSITY -eq 2 ]; then
    log_verbose "$PKG_MANAGER upgrade simulation output: $UPGRADE_SIMULATION"
  fi
  
  PKGS_TO_REMOVE=$(echo "$UPGRADE_SIMULATION" | grep -i "removing")
  
  # Also check for other conditions requiring manual intervention
  MANUAL_INTERVENTION=$(echo "$UPGRADE_SIMULATION" | grep -i -E "error:|warning:|conflict|failed|is needed by")
  
  if [ -n "$PKGS_TO_REMOVE" ] || [ -n "$MANUAL_INTERVENTION" ]; then
    log "Packages would be removed or require manual intervention. Sending email."
    send_email "[$HOSTNAME] Manual intervention required for system update" "The system update on $HOSTNAME requires manual intervention because packages would be removed or there are conflicts.\n\nDetails:\n$UPGRADE_SIMULATION"
  else
    log "No packages would be removed. Proceeding with automatic upgrade."
    log_verbose "Running: $PKG_MANAGER upgrade -y"
    
    if [ $VERBOSITY -ge 1 ]; then
      UPGRADE_OUTPUT=$($PKG_MANAGER upgrade -y 2>&1)
      echo "$UPGRADE_OUTPUT"
      if [ $VERBOSITY -eq 2 ]; then
        log_verbose "$PKG_MANAGER upgrade output: $UPGRADE_OUTPUT"
      fi
      UPGRADE_RESULT=$?
    else
      $PKG_MANAGER upgrade -y >> "$LOG_FILE" 2>&1
      UPGRADE_RESULT=$?
    fi
    
    if [ $UPGRADE_RESULT -eq 0 ]; then
      log "Upgrade completed successfully"
    else
      log_error "Upgrade failed with exit code $UPGRADE_RESULT"
    fi
  fi
fi

log "=== Auto-update script completed at $(date) ==="
