# Changelog

All notable changes to this project are documented here.

## [1.2.0] - 2026-07-20

### Added
- External configuration file (`auto-update.conf`) loaded from the same directory
  as the script, with environment-variable overrides and safe built-in defaults.
- `--dry-run` flag: simulate updates without applying them.
- `--mail-summary` flag: after a successful run, email the admin a summary of
  what changed and whether a reboot is required.
- `--help` / `-h` flag.
- Concurrent-run guard using `flock` so overlapping runs cannot corrupt the
  package database.
- Reboot detection (`/var/run/reboot-required`, `needrestart`, and kernel
  version comparison on RHEL/CentOS/Fedora) with optional `AUTO_REBOOT`.
- `NOTIFY_ON_SUCCESS` option to receive a brief "all good" report.
- `LC_ALL=C` is now forced for all package-manager commands so output parsing is
  stable across locales.
- `printf`-based email body generation for correct newlines.
- Example config (`auto-update.conf.example`), systemd unit files, and an
  `install.sh` helper.

### Fixed
- Removed the false-positive manual-intervention trigger caused by matching
  "Need to get ... of archives" (present in every normal upgrade).
- `send_email` now reliably captures and reports curl's real exit code.

### Changed
- Strict mode (`set -uo pipefail`) for safer execution.
- Configuration is no longer edited directly in the script; use the external
  config file or environment variables.

## [1.1.0] - 2025
- Verbosity options (`-v`, `-vv`).

## [1.0.0] - 2025
- Initial release: cross-distribution (apt/yum/dnf) auto-update with email
  notifications and config preservation.
