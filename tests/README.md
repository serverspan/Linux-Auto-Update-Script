# Tests

This directory contains the [bats](https://github.com/bats-core/bats-core) test
suite for `auto-update.sh`.

## Running locally

```bash
# Install bats-core (example: user-local)
git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
/tmp/bats-core/install.sh ~/.local

# Run
~/.local/bin/bats tests/
```

## What is covered

- Argument parsing (`--help`, `-v`, `-vv`, `--dry-run`, `--mail-summary`, unknown flags)
- Configuration precedence (environment variable > config file > built-in default)
- Boolean normalization (`true`/`false`/`1`/`0`/`yes`/`no`/`on`/`off`/invalid)
- apt simulation parsing: removals, kept-back + safe dist-upgrade, kept-back +
  dist-upgrade removals, clean upgrade, update failure
- yum/dnf simulation parsing: `check-update` return codes (0/100/1), removals,
  conflicts
- Concurrent-run guard (`flock`)
- Email body formatting (real newlines)
- `--mail-summary` and `NOTIFY_ON_SUCCESS` email dispatch

External commands (`apt`, `dnf`, `yum`, `curl`, `flock`, `hostname`, `date`,
`needrestart`) are mocked per-test via `$BATS_TMPDIR/mockbin` so no root access
or live package manager is required. The `LOCK_FILE` and `LOG_FILE` paths are
overridden via `AUTO_UPDATE_LOCK` and `LOG_FILE` environment variables.
