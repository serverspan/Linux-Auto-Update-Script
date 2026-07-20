[![ENGINYRING](https://cdn.enginyring.com/img/logo_dark.png)](https://www.enginyring.com)

# Auto System Update Script

A robust BASH script that automates system updates on Linux servers while intelligently handling scenarios that require manual intervention.

**Author:** ENGINYRING ([@ENGINYRING](https://github.com/ENGINYRING)) — maintained fork: [@serverspan](https://github.com/serverspan)

## Features

- **Cross-distribution compatibility**: Works with both apt-based (Debian/Ubuntu) and yum/dnf-based (RHEL/CentOS/Fedora) systems
- **Intelligent update handling**: Automatically detects when updates are safe to apply
- **Configuration preservation**: Always preserves existing config files
- **Non-interactive operation**: Handles all prompts automatically for true unattended operation
- **Admin notifications**: Sends email alerts when manual intervention is required
- **Detailed logging**: Maintains comprehensive logs of all update activities
- **Safe operation**: Never removes packages without admin approval
- **External configuration**: Credentials and behaviour live in `auto-update.conf` next to the script (no more editing the script itself)
- **Concurrent-run guard**: `flock` prevents overlapping runs from corrupting the package database
- **Reboot awareness**: Detects when a reboot is required and can reboot automatically
- **Summary emails**: Optional reports of what changed and whether a reboot is needed
- **Verbosity options**: Control output with verbose modes for troubleshooting
- **Dry-run mode**: Simulate updates without applying them

## Requirements

- Bash shell
- sudo/root access
- `curl` for sending emails
- `flock` (usually part of `util-linux`)
- SMTP server access for notifications
- Compatible with:
  - Debian-based systems (Debian, Ubuntu, etc.)
  - RedHat-based systems (RHEL, CentOS, Fedora, etc.)

## Installation

### Quick install (recommended)

The bundled `install.sh` copies the script, creates a config, and installs the
systemd timer for you:

```bash
sudo ./install.sh
```

Then edit `/usr/local/bin/auto-update.conf` with your SMTP settings.

### Manual install

1. **Download the script and config example**:

```bash
curl -O https://raw.githubusercontent.com/serverspan/Linux-Auto-Update-Script/main/auto-update.sh
curl -O https://raw.githubusercontent.com/serverspan/Linux-Auto-Update-Script/main/auto-update.conf.example
```

2. **Make it executable and move to system path**:

```bash
chmod +x auto-update.sh
sudo mv auto-update.sh /usr/local/bin/auto-update.sh
```

3. **Create the configuration file in the same directory**:

The script automatically loads a config file named `auto-update.conf` from the
**same directory as the script**. Copy the example and edit it:

```bash
sudo cp auto-update.conf.example /usr/local/bin/auto-update.conf
sudo chmod 600 /usr/local/bin/auto-update.conf
sudo nano /usr/local/bin/auto-update.conf
```

Configuration options:

```bash
ADMIN_EMAIL="admin@example.com"
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="notifications@example.com"
SMTP_PASS="your_password_here"

# Behaviour
AUTO_REBOOT="false"        # reboot automatically when required
NOTIFY_ON_SUCCESS="false"  # email a brief "all good" report
DRY_RUN="false"            # simulate only, never apply
MAIL_SUMMARY="false"       # email a full summary after a successful run
```

> **Note:** Environment variables override the config file, which overrides the
> built-in defaults. You can also keep credentials out of any file entirely by
> exporting them (e.g. from `/etc/environment` or a secret manager).

## Usage

### Basic Usage

Run the script with no arguments for quiet operation (logs only to file):

```bash
sudo /usr/local/bin/auto-update.sh
```

### Verbose Mode

Use the `-v` flag to see detailed output in the terminal:

```bash
sudo /usr/local/bin/auto-update.sh -v
```

### Very Verbose Mode

Use the `-vv` flag for maximum verbosity (detailed terminal output and enhanced logging):

```bash
sudo /usr/local/bin/auto-update.sh -vv
```

### Dry Run

Simulate everything without applying updates (useful for testing):

```bash
sudo /usr/local/bin/auto-update.sh --dry-run -v
```

### Mail a Summary After Success

After a successful run, email the admin a summary of what changed and whether a
reboot is required:

```bash
sudo /usr/local/bin/auto-update.sh --mail-summary
```

This can also be enabled permanently by setting `MAIL_SUMMARY="true"` in the
config file.

### Help

```bash
sudo /usr/local/bin/auto-update.sh --help
```

## Setting Up Automated Runs

### Using Cron

```bash
sudo crontab -e
```

Example (run at 3 AM daily):

```
0 3 * * * /usr/local/bin/auto-update.sh
```

To always mail a summary from cron, enable `MAIL_SUMMARY="true"` in the config
or call the script with the flag:

```
0 3 * * * /usr/local/bin/auto-update.sh --mail-summary
```

### Using Systemd Timer

If you used `install.sh`, the timer is already enabled. Otherwise:

1. **Install the unit files** (`auto-update.service`, `auto-update.timer`) to
   `/etc/systemd/system/`.
2. **Enable and start the timer**:

```bash
sudo systemctl enable auto-update.timer
sudo systemctl start auto-update.timer
```

The bundled `auto-update.timer` runs weekly on Mondays at 03:00 with a random
delay.

## How It Works

### For Debian/Ubuntu Systems:

1. Forces `LC_ALL=C` and `DEBIAN_FRONTEND=noninteractive` to prevent interactive prompts and ensure stable output parsing
2. Updates package lists with `apt update`
3. Simulates an upgrade with `apt upgrade --simulate` to check for:
   - Packages that would be removed
   - Packages held back
   - Other conditions requiring manual intervention
4. If packages would be removed → Sends email notification and stops
5. If packages are held back → Checks if `dist-upgrade` would remove packages
   - If yes → Sends email notification and stops
   - If no → Performs `dist-upgrade` with `--force-confold` to preserve configs
6. If no issues → Performs regular upgrade with `--force-confold`

### For RHEL/CentOS/Fedora Systems:

1. Forces `LC_ALL=C`
2. Checks for updates with `yum/dnf check-update`
3. Simulates an upgrade with `yum/dnf upgrade --assumeno` to check for:
   - Packages that would be removed
   - Conflicts or errors
4. If issues found → Sends email notification and stops
5. If no issues → Performs upgrade

### Reboot Handling

After applying updates, the script checks whether a reboot is required
(`/var/run/reboot-required`, `needrestart`, or a newer installed kernel on
RHEL/CentOS/Fedora). With `AUTO_REBOOT=true` it reboots automatically; otherwise
it logs a reminder. The reboot status is included in summary emails.

## Verbosity Levels

| Mode | Flag | Description |
|------|------|-------------|
| Normal | (none) | Runs silently, logs to `/var/log/auto-update.log` |
| Verbose | `-v` | Prints operation details to the terminal while running |
| Very Verbose | `-vv` | Maximum detail in terminal output and enhanced logging |

## Configuration Options

| Parameter | Description |
|-----------|-------------|
| `ADMIN_EMAIL` | Email address for notifications |
| `SMTP_SERVER` | SMTP server for sending emails |
| `SMTP_PORT` | SMTP port (usually 25, 465, or 587) |
| `SMTP_USER` | Username for SMTP authentication |
| `SMTP_PASS` | Password for SMTP authentication |
| `LOG_FILE` | Path to the log file (default: `/var/log/auto-update.log`) |
| `AUTO_REBOOT` | `true`/`false` — reboot automatically when required |
| `NOTIFY_ON_SUCCESS` | `true`/`false` — email a brief "all good" report |
| `DRY_RUN` | `true`/`false` — simulate only, never apply |
| `MAIL_SUMMARY` | `true`/`false` — email a full summary after success |

All options can also be passed as environment variables (they take precedence
over the config file).

## Log File

The script logs all activities to `/var/log/auto-update.log` (by default). Each run is clearly marked with timestamps and detailed information about the update process.

## Email Notifications

When manual intervention is required, an email is sent with:

- Server hostname
- Reason for manual intervention
- Details of packages that would be removed or other issues
- Timestamp

With `--mail-summary` (or `MAIL_SUMMARY=true`), a successful run also emails:

- What packages changed
- Whether a reboot is required

## Troubleshooting

### No Emails Being Sent

1. Check SMTP configuration in `auto-update.conf`
2. Verify network connectivity to SMTP server
3. Check if `curl` is installed
4. Review logs for SMTP errors
5. Run with `-vv` flag to see detailed output

### Script Not Running from Cron

1. Check cron logs: `grep CRON /var/log/syslog`
2. Ensure script has proper permissions
3. Check for PATH issues in the cron environment
4. Try running with `-v` flag to identify issues

### Updates Not Being Applied

1. Check `/var/log/auto-update.log` for errors
2. Verify the script is detecting the correct package manager
3. Check if the user running the script has sufficient permissions
4. Run with `-vv` flag to get maximum diagnostic information

### False-positive manual intervention emails (older versions)

Earlier versions matched "Need to get ... of archives" as a trigger, producing
emails on every normal upgrade. This was fixed in 1.2.0 — upgrade to avoid it.

## Security Considerations

- The config file contains SMTP credentials — keep it at `chmod 600` and owned by root.
- Prefer environment variables or a secret manager over a plaintext file when possible.
- The script never removes packages automatically; it only notifies and stops.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a versioned history of changes.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Commit your changes: `git commit -m 'Add some feature'`
4. Push to the branch: `git push origin feature-name`
5. Submit a pull request

---
© 2025 ENGINYRING. All rights reserved.

* * *

[Web hosting](https://www.enginyring.com/en/webhosting) | [VPS hosting](https://www.enginyring.com/en/virtual-servers) | [Free DevOps tools](https://www.enginyring.com/tools)
