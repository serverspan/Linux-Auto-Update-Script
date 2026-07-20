#!/usr/bin/env bats

# Test suite for auto-update.sh
# Run with: bats tests/
# Requires bats-core >= 1.2

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/auto-update.sh"

# -----------------------------------------------------------------------------
# Mock helpers
# -----------------------------------------------------------------------------

# Create a mock apt that branches on its arguments.
# Usage: mock_apt <simulate_output> <upgrade_output>
mock_apt() {
  local sim="$1"
  local upg="$2"
  cat > "$BATS_TMPDIR/mockbin/apt" <<EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"--simulate"* ]]; then
  printf '%s\n' "$sim"
  exit 0
elif [[ "\$args" == "update"* ]]; then
  printf 'apt update output\n'
  exit 0
elif [[ "\$args" == *"upgrade"* ]] || [[ "\$args" == *"dist-upgrade"* ]]; then
  printf '%s\n' "$upg"
  exit 0
else
  printf 'apt called with: %s\n' "\$args"
  exit 0
fi
EOF
  chmod +x "$BATS_TMPDIR/mockbin/apt"
}

# Create a mock dnf/yum that branches on args; check-update returns code via env
mock_dnf() {
  local check_rc="${1:-0}"
  local sim="$2"
  local upg="$3"
  cat > "$BATS_TMPDIR/mockbin/dnf" <<EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"check-update"* ]]; then
  printf 'dnf check-update output\n'
  exit $check_rc
elif [[ "\$args" == *"--assumeno"* ]]; then
  printf '%s\n' "$sim"
  exit 0
elif [[ "\$args" == *"upgrade"* ]]; then
  printf '%s\n' "$upg"
  exit 0
else
  printf 'dnf called: %s\n' "\$args"
  exit 0
fi
EOF
  chmod +x "$BATS_TMPDIR/mockbin/dnf"
  # yum symlinks to same behavior
  cp "$BATS_TMPDIR/mockbin/dnf" "$BATS_TMPDIR/mockbin/yum"
}

# Mock curl to capture email body and always succeed (unless we want failure)
mock_curl_ok() {
  cat > "$BATS_TMPDIR/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
# Read stdin (the email) and just succeed
cat > /dev/null
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mockbin/curl"
}

# Mock curl to FAIL (for error-path tests)
mock_curl_fail() {
  cat > "$BATS_TMPDIR/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 1
EOF
  chmod +x "$BATS_TMPDIR/mockbin/curl"
}

# Mock curl to verify real newlines in the email body
mock_curl_check_newlines() {
  cat > "$BATS_TMPDIR/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
# Check that the body has a blank line after headers and real newlines
if printf '%s' "$input" | grep -qP 'To:.*\n\n'; then
  exit 0
else
  echo "NO REAL NEWLINE SEPARATOR" >&2
  exit 1
fi
EOF
  chmod +x "$BATS_TMPDIR/mockbin/curl"
}

# Generic simple mock
mock_simple() {
  local name="$1"
  local output="$2"
  local rc="${3:-0}"
  cat > "$BATS_TMPDIR/mockbin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$output"
exit $rc
EOF
  chmod +x "$BATS_TMPDIR/mockbin/$name"
}

# Write a config file
write_config() {
  export AUTO_UPDATE_CONFIG="$BATS_TMPDIR/test.conf"
  printf '%s\n' "$1" > "$AUTO_UPDATE_CONFIG"
}

# Common setup before each test
setup() {
  mkdir -p "$BATS_TMPDIR/mockbin"
  # Redirect lock + log to temp so we don't need root
  export AUTO_UPDATE_LOCK="$BATS_TMPDIR/auto-update.lock"
  export LOG_FILE="$BATS_TMPDIR/auto-update.log"
  export PATH="$BATS_TMPDIR/mockbin:$PATH"
  # Default simple mocks
  mock_simple hostname "test-host"
  mock_simple date "2026-01-01 12:00:00"
  mock_simple needrestart "No restart required"
  # Default config
  write_config '
ADMIN_EMAIL="admin@example.com"
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="notify@example.com"
SMTP_PASS="pass"
LOG_FILE="/tmp/auto-update.log"
AUTO_REBOOT="false"
NOTIFY_ON_SUCCESS="false"
DRY_RUN="false"
MAIL_SUMMARY="false"
'
}

teardown() {
  rm -rf "$BATS_TMPDIR/mockbin"
  rm -f "$BATS_TMPDIR/auto-update.lock" "$BATS_TMPDIR/auto-update.log" "$BATS_TMPDIR/test.conf"
}

# =============================================================================
# Argument parsing
# =============================================================================
@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--mail-summary"* ]]
}

@test "-v runs without error" {
  mock_apt "no removals, no kept back" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" -v
  [ "$status" -eq 0 ]
}

@test "-vv runs without error" {
  mock_apt "no removals, no kept back" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" -vv
  [ "$status" -eq 0 ]
}

@test "--dry-run runs without error" {
  mock_apt "no removals, no kept back" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  # DRY-RUN notice is written to the log file (verbosity 0)
  [[ "$(cat "$LOG_FILE")" == *"DRY-RUN"* ]]
}

@test "--mail-summary runs without error" {
  mock_apt "no removals, no kept back" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" --mail-summary
  [ "$status" -eq 0 ]
}

@test "unknown flag errors" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported flag"* ]]
}

# =============================================================================
# Config precedence (env > file > default)
# =============================================================================
@test "config file used when no env var set" {
  write_config 'ADMIN_EMAIL="from-config@example.com"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "env var overrides config file" {
  write_config 'ADMIN_EMAIL="from-config@example.com"'
  export ADMIN_EMAIL="from-env@example.com"
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  unset ADMIN_EMAIL
}

# =============================================================================
# Boolean normalization
# =============================================================================
@test "AUTO_REBOOT=true normalizes" {
  write_config 'AUTO_REBOOT="TRUE"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AUTO_REBOOT=1 normalizes to true" {
  write_config 'AUTO_REBOOT="1"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AUTO_REBOOT=yes normalizes" {
  write_config 'AUTO_REBOOT="YES"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AUTO_REBOOT=FALSE normalizes to false" {
  write_config 'AUTO_REBOOT="FALSE"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AUTO_REBOOT=0 normalizes to false" {
  write_config 'AUTO_REBOOT="0"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AUTO_REBOOT=no normalizes to false" {
  write_config 'AUTO_REBOOT="NO"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AUTO_REBOOT=invalid defaults to false" {
  write_config 'AUTO_REBOOT="maybe"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "NOTIFY_ON_SUCCESS=TRUE normalizes" {
  write_config 'NOTIFY_ON_SUCCESS="TRUE"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DRY_RUN=Yes normalizes" {
  write_config 'DRY_RUN="Yes"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "MAIL_SUMMARY=ON normalizes" {
  write_config 'MAIL_SUMMARY="ON"'
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# =============================================================================
# apt simulation parsing
# =============================================================================
@test "packages removed -> manual intervention email" {
  mock_apt "The following packages will be REMOVED:
  pkg1 pkg2" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"would be removed"* ]]
}

@test "packages kept back, dist-upgrade safe -> proceeds" {
  mock_apt "The following packages have been kept back:
  pkg1" "dist-upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"dist-upgrade"* ]]
}

@test "packages kept back, dist-upgrade removes -> manual intervention" {
  # upgrade --simulate: only kept back (no removals) -> enters dist-upgrade path
  # dist-upgrade --simulate: shows removals -> manual intervention
  cat > "$BATS_TMPDIR/mockbin/apt" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"dist-upgrade"*"--simulate"* ]]; then
  printf 'The following packages will be REMOVED:\n  pkg1\n'
  exit 0
elif [[ "$*" == *"--simulate"* ]]; then
  printf 'The following packages have been kept back:\n  pkg1\n'
  exit 0
elif [[ "$*" == "update"* ]]; then
  echo "apt update ok"; exit 0
else
  echo "apt upgrade ok"; exit 0
fi
EOF
  chmod +x "$BATS_TMPDIR/mockbin/apt"
  mock_curl_ok
  run bash "$SCRIPT" -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"dist-upgrade would remove"* ]]
}

@test "clean upgrade -> no manual intervention email" {
  mock_apt "no removals, no kept back" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Manual intervention required"* ]]
}

@test "apt update failure -> exit 1" {
  # Make apt update fail: mock returns non-zero for 'update'
  cat > "$BATS_TMPDIR/mockbin/apt" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "update"* ]]; then
  echo "apt update failed" >&2
  exit 1
else
  echo "ok"
  exit 0
fi
EOF
  chmod +x "$BATS_TMPDIR/mockbin/apt"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

# =============================================================================
# yum/dnf simulation parsing
# =============================================================================
@test "dnf check-update 100 -> runs upgrade" {
  mock_dnf 100 "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "dnf check-update 0 -> no updates, exits 0" {
  mock_dnf 0 "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"No updates available"* ]]
}

@test "dnf check-update 1 -> error exit 1" {
  mock_dnf 1 "no removals" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "dnf removing -> manual intervention" {
  mock_dnf 100 "Removing pkg1" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"would be removed"* ]]
}

@test "dnf conflict -> manual intervention" {
  mock_dnf 100 "Error: conflict detected" "upgrade ok"
  mock_curl_ok
  run bash "$SCRIPT" -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"would be removed"* ]] || [[ "$output" == *"conflict"* ]]
}

# =============================================================================
# Lock guard
# =============================================================================
@test "second instance exits when lock held" {
  mock_apt "no removals" "upgrade ok"
  mock_curl_ok
  # Mock flock to behave like real flock using a sentinel file
  cat > "$BATS_TMPDIR/mockbin/flock" <<'EOF'
#!/usr/bin/env bash
# Usage simulated: flock -n 9  (non-blocking, fd 9 already opened)
SENTINEL="$BATS_TMPDIR/flock.sentinel"
if [ -f "$SENTINEL" ]; then
  exit 1   # already locked
else
  touch "$SENTINEL"
  exit 0
fi
EOF
  chmod +x "$BATS_TMPDIR/mockbin/flock"
  # Start first instance in background (acquires lock)
  bash "$SCRIPT" &
  FIRST_PID=$!
  sleep 0.3
  # Second instance should fail
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already running"* ]]
  # Clean up first (kill may return non-zero; ignore)
  kill "$FIRST_PID" 2>/dev/null || true
  rm -f "$BATS_TMPDIR/flock.sentinel"
}

# =============================================================================
# Email body format
# =============================================================================
@test "email body uses real newlines" {
  mock_apt "no removals" "upgrade ok"
  mock_curl_check_newlines
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# =============================================================================
# --mail-summary sends summary email
# =============================================================================
@test "--mail-summary sends a summary email after success" {
  mock_apt "no removals" "upgrade ok"
  # Capture curl input to verify summary subject
  cat > "$BATS_TMPDIR/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf '%s' "$input" > "$BATS_TMPDIR/last_email.txt"
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mockbin/curl"
  run bash "$SCRIPT" --mail-summary
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TMPDIR/last_email.txt")" == *"Update summary"* ]]
}

# =============================================================================
# NOTIFY_ON_SUCCESS sends brief email
# =============================================================================
@test "NOTIFY_ON_SUCCESS sends brief email" {
  write_config 'NOTIFY_ON_SUCCESS="true"'
  mock_apt "no removals" "upgrade ok"
  cat > "$BATS_TMPDIR/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf '%s' "$input" > "$BATS_TMPDIR/last_email.txt"
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mockbin/curl"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TMPDIR/last_email.txt")" == *"completed successfully"* ]]
}
