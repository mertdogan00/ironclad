# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `check.sh` — read-only post-install health check (curl-and-run). Verifies what `init.sh` set
  up (NTP, firewall, SSH hardening, fail2ban, sysctl, `/tmp` lockdown, auditd, Docker) and prints
  a ✓/✗ summary; changes nothing.

### Planned

- Step 16 — monitoring: cron health-check (disk / CPU / RAM / service) → webhook or mail alert

## [1.1.0] - 2026-06-04

### Added

- **docker**: container log rotation via `/etc/docker/daemon.json` (`json-file`,
  `DOCKER_LOG_MAX_SIZE` default `50m` × `DOCKER_LOG_MAX_FILE` default `3`) — caps log growth so a
  stateless host can't fill its disk. Idempotent; restarts the daemon only when the config changes.

## [1.0.0] - 2026-06-03

### Added

- Single-file, idempotent **Debian 13** provisioner (`init.sh`) — real-state checks, no marker
  files; safe to re-run.
- **base**: timezone (UTC) + NTP, full apt update/upgrade/clean, base packages
  (`ca-certificates curl gnupg btop ncdu tmux lsof jq`), unattended security upgrades +
  `needrestart`, swapfile + swappiness.
- **identity**: clean hostname + `/etc/hosts` rewrite (acts only when `HOSTNAME` is set),
  passwordless sudo user.
- **network security**: `ufw` default-deny firewall (opens `UFW_PORTS` before enabling — no
  lockout), SSH hardening (key-only, no root, custom `SSH_PORT`, key installed before hardening),
  `fail2ban` for SSH (journald backend).
- **system hardening**: kernel/network `sysctl` hardening (anti-spoof / anti-flood / info-leak,
  container-safe), `/tmp` + `/dev/shm` lockdown (`noexec,nosuid,nodev`), `auditd` focused
  baseline with built-in log rotation.
- **optional**: Docker engine (official installer) + login user added to the `docker` group
  (`INSTALL_DOCKER=no` to skip); colored shell prompt + handy aliases for the login user
  (`SETUP_SHELL=no` to skip).
- Env-overridable config block — every value can be set via an environment variable of the same
  name.
- Project docs: `README.md` (usage + SSH setup + configuration), `LICENSE` (MIT).
