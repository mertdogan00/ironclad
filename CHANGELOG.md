# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned

- Step 18, monitoring: cron health-check (disk / CPU / RAM / service) to a webhook or mail alert

## [1.3.0] - 2026-08-23

### Added

- **k3s** (step 17, optional): turn the hardened host into a Kubernetes node via the official
  `get.k3s.io` installer. Generic and provider-agnostic, driven entirely by env: `K3S_ROLE=server|agent`
  (empty skips k3s), `K3S_CLUSTER_INIT=yes` on the first server to start the embedded-etcd HA cluster,
  `K3S_URL` / `K3S_TOKEN` to join, `K3S_VERSION` to pin, `K3S_NODE_IP` for the provider private IP,
  `K3S_TAINT_SERVER` to keep workloads off the control-plane, `K3S_TRUSTED_CIDR` to open the cluster
  ports (6443, etcd, flannel, kubelet) to the private network only, and `K3S_EXTRA_ARGS` as an escape
  hatch. Idempotent: an already-running node service is left alone. K3s ships its own containerd, so
  set `INSTALL_DOCKER=no` on cluster nodes.
- `check.sh`: a K3s section that reports the node's server/agent state and control-plane readiness.

## [1.2.0] - 2026-06-07

### Added

- **disks** (step 6): mount + persist extra data disks via `DISK_MOUNTS` — a space-separated
  `DEVICE:MOUNTPOINT[:FSTYPE]` list (e.g. `"/dev/sdb:/data /dev/sdc:/opt:xfs"`), one entry per
  disk. Formats only a **blank** device (`DISK_FSTYPE` default `ext4`; `xfs`/`btrfs` supported),
  mounts by `UUID`, and writes an `/etc/fstab` line with `DISK_MOUNT_OPTS` (default
  `defaults,nofail`). A device that already holds a filesystem is mounted as-is and never
  reformatted; missing disks are warned and skipped. Idempotent.
- `check.sh` — read-only post-install health check (curl-and-run). Verifies what `init.sh` set
  up (NTP, firewall, SSH hardening, fail2ban, sysctl, `/tmp` lockdown, auditd, Docker) and prints
  a ✓/✗ summary; changes nothing.

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
