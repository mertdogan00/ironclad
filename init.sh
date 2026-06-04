#!/usr/bin/env bash
# ==========================================================================
# ironclad — single-file Debian server provisioner
# ==========================================================================
# One script to bring a fresh Debian server to a secure, sane baseline.
# Idempotent: safe to run again and again — it checks the real state and
# only changes what's off.
#
# Usage:
#   sudo bash init.sh
#   USERNAME=mert SSH_PUBKEY="ssh-ed25519 AAAA..." sudo -E bash init.sh
# ==========================================================================

set -euo pipefail

# ==========================================================================
# Config  (every value can be overridden by an env var of the same name)
# ==========================================================================

# --- user ---
USERNAME="${USERNAME:-}"                 # sudo user to create (required)

# --- hostname ---
HOSTNAME="${HOSTNAME:-}"                 # machine name (empty = leave hostname/hosts untouched)

# --- ssh / network ---
SSH_PORT="${SSH_PORT:-22}"               # sshd port — firewall opens it, the ssh step sets it
SSH_PUBKEY="${SSH_PUBKEY:-}"             # login user's public key (required: no key = no login after hardening)

# --- firewall ---
UFW_PORTS=("${SSH_PORT}/tcp" "80/tcp" "443/tcp")  # ports ufw opens (SSH + HTTP/HTTPS); add more as needed

# --- fail2ban ---
FAIL2BAN_BANTIME="${FAIL2BAN_BANTIME:-1h}"     # how long a banned IP stays out
FAIL2BAN_FINDTIME="${FAIL2BAN_FINDTIME:-10m}"  # window in which failures are counted
FAIL2BAN_MAXRETRY="${FAIL2BAN_MAXRETRY:-5}"    # failures allowed before a ban

# --- time ---
TIMEZONE="${TIMEZONE:-UTC}"              # system timezone (UTC = global default)

# --- swap ---
SWAP_SIZE_MB="${SWAP_SIZE_MB:-}"         # swapfile size in MB (empty = auto from RAM)
SWAP_SWAPPINESS="${SWAP_SWAPPINESS:-60}" # kernel default; override lower (e.g. 10) for latency

# --- docker ---
INSTALL_DOCKER="${INSTALL_DOCKER:-yes}"            # install docker engine (set to "no" to skip step 14)
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-50m}"  # per-container log size before it rotates (json-file)
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"    # how many rotated log files to keep per container

# --- shell ---
SETUP_SHELL="${SETUP_SHELL:-yes}"        # colored prompt + aliases for the login user ("no" = skip step 15)

# ==========================================================================
# Helpers
# ==========================================================================

#region output — terminal colors + log helpers

# colors (only when writing to a terminal)
if [[ -t 1 ]]; then
  c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
  c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
else
  c_reset=''; c_blue=''; c_green=''; c_yellow=''; c_red=''
fi

step() { printf '\n%s==>%s %s\n' "$c_blue"   "$c_reset" "$*"; }   # section header
ok()   { printf '   %s✓%s %s\n'  "$c_green"  "$c_reset" "$*"; }   # something is/now correct
info() { printf '   %s\n' "$*"; }                                 # neutral note
warn() { printf '   %s!%s %s\n'  "$c_yellow" "$c_reset" "$*" >&2; }
die()  { printf '   %s✗%s %s\n'  "$c_red"    "$c_reset" "$*" >&2; exit 1; }

#endregion

#region guards — preconditions; abort early when the environment is wrong

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root:  sudo bash init.sh"
  fi
}

#endregion

#region system — reusable system operations (apt, config files, services…)

# Install whichever of the given packages aren't present yet (real-state idempotency).
# Assumes the apt lists are already fresh (update_system / step 2 runs first).
ensure_packages() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "already installed: $*"
    return
  fi
  info "installing: ${missing[*]}"
  apt-get install -y -qq "${missing[@]}"
  ok "installed: ${missing[*]}"
}

#endregion

# ==========================================================================
# Steps  (grouped into #region blocks so VSCode can fold a whole section)
# ==========================================================================

#region base — timesync · update_system · base_packages · auto_updates · swap

# 1. Timezone (UTC) + NTP, so the clock is correct before any TLS/apt work.
timesync() {
  step "Time sync (timezone + NTP)"

  if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == "$TIMEZONE" ]]; then
    ok "timezone already ${TIMEZONE}"
  else
    timedatectl set-timezone "$TIMEZONE"
    ok "timezone set to ${TIMEZONE}"
  fi

  if [[ "$(timedatectl show -p NTP --value 2>/dev/null)" == "yes" ]]; then
    ok "NTP already enabled"
  else
    timedatectl set-ntp true
    ok "NTP enabled"
  fi
}

# 2. Refresh package lists, upgrade everything, clean up.
update_system() {
  step "System update"
  export DEBIAN_FRONTEND=noninteractive   # never prompt during apt
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get autoremove -y -qq
  apt-get clean                            # drop cached .deb files to free disk
  ok "system up to date"
}

# 3. Install baseline packages: TLS/fetch essentials + a few ops tools.
base_packages() {
  step "Base packages"

  local packages=(
    ca-certificates   # TLS trust roots (apt/curl over https)
    curl              # fetch files/APIs (the docker step uses it)
    gnupg             # apt repo keys (gpg --dearmor in the docker step)
    btop              # system monitor (cpu/ram/disk/net)
    ncdu              # interactive disk usage analyzer
    tmux              # persistent terminal sessions
    lsof              # which process holds a port/file
    jq                # JSON wrangling (health checks, docker inspect)
  )
  ensure_packages "${packages[@]}"
}

# 4. Automatic security patches (unattended-upgrades) + auto service restarts (needrestart).
#    Security-only, no auto-reboot. needrestart restarts affected services after a lib upgrade;
#    a kernel reboot stays manual (step 16 monitoring will alert via `needrestart -b`).
auto_updates() {
  step "Automatic security updates"

  # packages (idempotent: installs only what's missing)
  ensure_packages unattended-upgrades needrestart

  # turn the periodic jobs on: refresh lists daily + run the unattended upgrade
  local f_periodic="/etc/apt/apt.conf.d/20auto-upgrades" want_periodic
  printf -v want_periodic '%s\n' \
    'APT::Periodic::Update-Package-Lists "1";' \
    'APT::Periodic::Unattended-Upgrade "1";'
  want_periodic=${want_periodic%$'\n'}            # drop the trailing newline
  if [[ -f "$f_periodic" && "$(cat "$f_periodic")" == "$want_periodic" ]]; then
    ok "periodic auto-upgrade already enabled"
  else
    printf '%s\n' "$want_periodic" > "$f_periodic"
    ok "periodic auto-upgrade enabled"
  fi

  # policy: security origins only, no auto-reboot, sweep old deps + kernels
  # (${distro_codename} is left literal on purpose — apt expands it, not bash)
  local f_policy="/etc/apt/apt.conf.d/50unattended-upgrades" want_policy
  # shellcheck disable=SC2016  # ${distro_codename} must stay literal — apt expands it, not bash
  printf -v want_policy '%s\n' \
    '// managed by init.sh — security-only, no auto-reboot' \
    'Unattended-Upgrade::Origins-Pattern {' \
    '    "origin=Debian,codename=${distro_codename},label=Debian-Security";' \
    '    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";' \
    '};' \
    'Unattended-Upgrade::Remove-Unused-Dependencies "true";' \
    'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";' \
    'Unattended-Upgrade::Automatic-Reboot "false";'
  want_policy=${want_policy%$'\n'}                # drop the trailing newline
  if [[ -f "$f_policy" && "$(cat "$f_policy")" == "$want_policy" ]]; then
    ok "upgrade policy already set (security-only, no reboot)"
  else
    printf '%s\n' "$want_policy" > "$f_policy"
    ok "upgrade policy set (security-only, no reboot)"
  fi

  # needrestart: auto-restart affected services (don't block the unattended run with a prompt)
  local f_nr="/etc/needrestart/conf.d/99-init.conf"
  local want_nr="\$nrconf{restart} = 'a';"
  if [[ -f "$f_nr" && "$(cat "$f_nr")" == "$want_nr" ]]; then
    ok "needrestart already in automatic mode"
  else
    printf '%s\n' "$want_nr" > "$f_nr"
    ok "needrestart set to automatic restart"
  fi
}

# 5. Swap file (always) + low swappiness — an OOM cushion, not a second RAM.
swap() {
  step "Swap"

  local swapfile="/swapfile"

  # size in MB: explicit override wins, else derive from RAM
  #   RAM <= 2G -> 2x RAM ;  2G < RAM <= 4G -> RAM ;  RAM > 4G -> 4G cap
  local size_mb="$SWAP_SIZE_MB"
  if [[ -z "$size_mb" ]]; then
    local ram_mb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
    if   [[ "$ram_mb" -le 2048 ]]; then size_mb=$(( ram_mb * 2 ))
    elif [[ "$ram_mb" -gt 4096 ]]; then size_mb=4096
    else                                size_mb="$ram_mb"
    fi
  fi

  # create + enable the swapfile (skip entirely if it's already swapped on)
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$swapfile"; then
    ok "swap already active (${swapfile})"
  else
    if [[ ! -f "$swapfile" ]]; then
      info "creating ${swapfile} (${size_mb} MB)…"
      # fast path: fallocate (instant on ext4); fall back to dd if the fs won't allow it
      fallocate -l "${size_mb}M" "$swapfile" 2>/dev/null \
        || dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=none
      chmod 600 "$swapfile"
      mkswap "$swapfile" >/dev/null
      ok "swapfile created (${size_mb} MB)"
    fi
    swapon "$swapfile"
    ok "swap enabled"
  fi

  # persist across reboots
  if grep -qE "^${swapfile}[[:space:]]" /etc/fstab; then
    ok "fstab entry already present"
  else
    printf '%s\n' "${swapfile} none swap sw 0 0" >> /etc/fstab
    ok "fstab entry added"
  fi

  # swappiness: prefer RAM, fall to swap only under real pressure
  local f_swappiness="/etc/sysctl.d/99-swappiness.conf"
  local want_swappiness="vm.swappiness=${SWAP_SWAPPINESS}"
  if [[ -f "$f_swappiness" && "$(cat "$f_swappiness")" == "$want_swappiness" ]]; then
    ok "swappiness already ${SWAP_SWAPPINESS}"
  else
    printf '%s\n' "$want_swappiness" > "$f_swappiness"
    sysctl -w vm.swappiness="$SWAP_SWAPPINESS" >/dev/null
    ok "swappiness set to ${SWAP_SWAPPINESS}"
  fi
}

#endregion

#region identity — hostname · create_user

# 6. Hostname + a clean /etc/hosts (only when HOSTNAME is explicitly given).
hostname() {
  step "Hostname"

  # act only when a hostname was explicitly given; otherwise leave the system alone
  if [[ -z "$HOSTNAME" ]]; then
    info "HOSTNAME not set — leaving hostname and /etc/hosts untouched"
    return
  fi

  local short="${HOSTNAME%%.*}"        # FQDN given -> short label; plain name -> itself

  # 1) static hostname — change only if different
  if [[ "$(hostnamectl --static 2>/dev/null)" == "$HOSTNAME" ]]; then
    ok "hostname already ${HOSTNAME}"
  else
    hostnamectl set-hostname "$HOSTNAME"
    ok "hostname set to ${HOSTNAME}"
  fi

  # 2) /etc/hosts — clean, minimal file (no cloud-init clutter)
  local hosts="/etc/hosts" want_hosts
  printf -v want_hosts '%s\n' \
    '127.0.0.1   localhost' \
    "127.0.1.1   ${HOSTNAME} ${short}" \
    '' \
    '::1         localhost ip6-localhost ip6-loopback' \
    "::1         ${HOSTNAME} ${short}"
  want_hosts=${want_hosts%$'\n'}       # drop trailing newline

  if [[ "$(cat "$hosts" 2>/dev/null)" == "$want_hosts" ]]; then
    ok "/etc/hosts already clean & correct"
  else
    printf '%s\n' "$want_hosts" > "$hosts"
    ok "/etc/hosts rewritten (clean)"
  fi
}

# 7. Create a passwordless sudo user.
create_user() {
  step "User: ${USERNAME}"
  [[ -n "$USERNAME" ]] || die "USERNAME is not set (USERNAME=name sudo -E bash init.sh)"

  # account — created without a password
  if id "$USERNAME" >/dev/null 2>&1; then
    ok "user already exists"
  else
    adduser --disabled-password --gecos "" "$USERNAME" >/dev/null
    ok "user created"
  fi

  # sudo group
  if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx sudo; then
    ok "already in sudo group"
  else
    usermod -aG sudo "$USERNAME"
    ok "added to sudo group"
  fi

  # passwordless sudo (account has no password, so this keeps sudo usable)
  local sudoers="/etc/sudoers.d/90-${USERNAME}"
  if [[ -f "$sudoers" ]]; then
    ok "passwordless sudo already set"
  else
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "$sudoers"
    chmod 0440 "$sudoers"
    visudo -cf "$sudoers" >/dev/null || { rm -f "$sudoers"; die "invalid sudoers file"; }
    ok "passwordless sudo enabled"
  fi
}

#endregion

#region network_security — firewall · ssh · fail2ban

# 8. Firewall: default-deny incoming, allow outgoing, open only the SSH port.
firewall() {
  step "Firewall (ufw)"

  ensure_packages ufw

  # allow each port BEFORE enabling — never lock ourselves out
  # (ufw show added lists rules even while ufw is still inactive)
  local p
  for p in "${UFW_PORTS[@]}"; do
    if ufw show added | grep -qF "allow ${p}"; then
      ok "port ${p} already allowed"
    else
      ufw allow "$p" >/dev/null
      ok "port ${p} allowed"
    fi
  done

  # default policy: deny everything in, allow everything out
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ok "default policy: deny incoming / allow outgoing"

  # enable (only if not already active)
  if ufw status | grep -q "Status: active"; then
    ok "ufw already active"
  else
    ufw --force enable >/dev/null
    ok "ufw enabled"
  fi
}

# 9. SSH hardening: key-only, no root, custom port. Lockout-safe — a key is installed first.
ssh() {
  step "SSH hardening"
  [[ -n "$USERNAME" ]] || die "USERNAME is not set"

  # lockout guard: a usable key MUST exist before we kill password auth
  [[ -n "$SSH_PUBKEY" ]] || die "SSH_PUBKEY not set — refusing to harden SSH (would lock you out)"

  # install the public key into the login user's authorized_keys (append, never clobber)
  local home authkeys
  home=$(getent passwd "$USERNAME" | cut -d: -f6 || true)
  [[ -n "$home" && -d "$home" ]] || die "home directory for ${USERNAME} not found"
  authkeys="${home}/.ssh/authorized_keys"

  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "${home}/.ssh"
  if [[ -f "$authkeys" ]] && grep -qxF "$SSH_PUBKEY" "$authkeys"; then
    ok "ssh key already present for ${USERNAME}"
  else
    printf '%s\n' "$SSH_PUBKEY" >> "$authkeys"
    chmod 600 "$authkeys"
    chown "$USERNAME:$USERNAME" "$authkeys"
    ok "ssh key installed for ${USERNAME}"
  fi

  # hardening drop-in — 00- is read FIRST, so it wins over cloud-init's 50-*.conf (sshd = first-match)
  local f="/etc/ssh/sshd_config.d/00-hardening.conf" want
  printf -v want '%s\n' \
    '# managed by init.sh — key-only, no root, custom port' \
    "Port ${SSH_PORT}" \
    'PermitRootLogin no' \
    'PasswordAuthentication no' \
    'PubkeyAuthentication yes' \
    'KbdInteractiveAuthentication no'
  want=${want%$'\n'}                              # drop trailing newline

  if [[ -f "$f" && "$(cat "$f")" == "$want" ]]; then
    ok "sshd hardening already in place"
  else
    printf '%s\n' "$want" > "$f"
    sshd -t || { rm -f "$f"; die "sshd config test failed — reverted, not restarting"; }
    systemctl restart ssh
    ok "sshd hardened & restarted (port ${SSH_PORT}, key-only, no root)"
  fi
}

# 10. fail2ban: ban brute-force SSH IPs. Reads journald (no rsyslog/auth.log on this host).
fail2ban() {
  step "fail2ban (SSH brute-force protection)"

  ensure_packages fail2ban

  # jail settings — drop-in that MERGES with Debian's defaults-debian.conf; we add only the delta
  # (defaults-debian.conf already sets backend=systemd + journalmatch; we re-affirm backend as insurance)
  local f_jail="/etc/fail2ban/jail.d/init.local" want_jail
  printf -v want_jail '%s\n' \
    '# managed by init.sh' \
    '[DEFAULT]' \
    "bantime  = ${FAIL2BAN_BANTIME}" \
    "findtime = ${FAIL2BAN_FINDTIME}" \
    "maxretry = ${FAIL2BAN_MAXRETRY}" \
    '' \
    '[sshd]' \
    'enabled = true' \
    "port    = ${SSH_PORT}" \
    'backend = systemd'
  want_jail=${want_jail%$'\n'}

  # daemon log target — drop-in so fail2ban logs to journald, not /var/log/fail2ban.log
  local f_log="/etc/fail2ban/fail2ban.d/init.local" want_log
  printf -v want_log '%s\n' \
    '# managed by init.sh' \
    '[Definition]' \
    'logtarget = SYSTEMD'
  want_log=${want_log%$'\n'}

  local changed=0
  if [[ -f "$f_jail" && "$(cat "$f_jail")" == "$want_jail" ]]; then
    ok "jail config already set"
  else
    printf '%s\n' "$want_jail" > "$f_jail"
    ok "jail config written (sshd on port ${SSH_PORT})"
    changed=1
  fi

  if [[ -f "$f_log" && "$(cat "$f_log")" == "$want_log" ]]; then
    ok "log target already journald"
  else
    printf '%s\n' "$want_log" > "$f_log"
    ok "log target set to journald"
    changed=1
  fi

  # enable at boot; (re)start only when config changed, otherwise just make sure it's running
  systemctl enable fail2ban >/dev/null 2>&1
  if [[ "$changed" -eq 1 ]]; then
    systemctl restart fail2ban
    ok "fail2ban (re)started"
  else
    systemctl start fail2ban
    ok "fail2ban running"
  fi
}

#endregion

#region system_hardening — sysctl_hardening · tmp_lockdown · auditd

# 11. Kernel/network sysctl hardening — anti-spoof, anti-flood, info-leak.
#     NB: ip_forward is left untouched on purpose (Docker needs it = 1).
sysctl_hardening() {
  step "Sysctl hardening"

  local f="/etc/sysctl.d/99-hardening.conf" want
  printf -v want '%s\n' \
    '# managed by init.sh' \
    '' \
    '# SYN flood protection' \
    'net.ipv4.tcp_syncookies = 1' \
    '' \
    '# TIME_WAIT hardening' \
    'net.ipv4.tcp_rfc1337 = 1' \
    '' \
    '# drop source-routed packets' \
    'net.ipv4.conf.all.accept_source_route = 0' \
    'net.ipv6.conf.all.accept_source_route = 0' \
    '' \
    '# do not accept ICMP redirects' \
    'net.ipv4.conf.all.accept_redirects = 0' \
    'net.ipv6.conf.all.accept_redirects = 0' \
    '' \
    '# do not send ICMP redirects' \
    'net.ipv4.conf.all.send_redirects = 0' \
    '' \
    '# reduce kernel info leaks' \
    'kernel.kptr_restrict = 2' \
    'kernel.dmesg_restrict = 1' \
    '' \
    '# restrict ptrace (process isolation)' \
    'kernel.yama.ptrace_scope = 1'
  want=${want%$'\n'}                              # drop trailing newline

  if [[ -f "$f" && "$(cat "$f")" == "$want" ]]; then
    ok "sysctl hardening already in place"
  else
    printf '%s\n' "$want" > "$f"
    sysctl -p "$f" >/dev/null
    ok "sysctl hardening applied"
  fi
}

# 12. Lock down world-writable tmpfs: /tmp + /dev/shm -> noexec,nosuid,nodev.
#     noexec = no running dropped payloads, nosuid = setuid bits ignored, nodev = no device nodes.
#     On Debian 13 both are already tmpfs (systemd); we only add the hardening options.
tmp_lockdown() {
  step "Temp lockdown (/tmp + /dev/shm)"

  local fstab="/etc/fstab" mnt opts
  for mnt in /tmp /dev/shm; do
    # 1) persist: add a tmpfs line for this mount point if fstab doesn't have one yet
    if awk -v m="$mnt" '$1!~/^#/ && $2==m {found=1} END{exit !found}' "$fstab"; then
      ok "fstab entry already present (${mnt})"
    else
      printf '%s\n' "tmpfs ${mnt} tmpfs defaults,noexec,nosuid,nodev 0 0" >> "$fstab"
      ok "fstab entry added (${mnt})"
    fi

    # 2) apply now: skip if already live, remount if mounted, else mount fresh from fstab
    opts=$(findmnt -no OPTIONS "$mnt" 2>/dev/null || true)
    if [[ "$opts" == *noexec* && "$opts" == *nosuid* && "$opts" == *nodev* ]]; then
      ok "already noexec,nosuid,nodev (${mnt})"
    elif mountpoint -q "$mnt"; then
      mount -o remount,noexec,nosuid,nodev "$mnt"
      ok "remounted noexec,nosuid,nodev (${mnt})"
    else
      mount "$mnt"        # not mounted yet -> fstab line mounts it with our options
      ok "mounted noexec,nosuid,nodev (${mnt})"
    fi
  done
}

# 13. Audit logging: kernel-level trail of who touched the security-critical files.
#     Focused baseline (high signal, low noise) — auditd keeps its own file, self-rotated.
auditd() {
  step "Audit logging (auditd)"

  ensure_packages auditd

  local changed=0

  # focused ruleset — file watches on identity/privilege/ssh/network + a couple of syscalls.
  # mutable on purpose (no `-e 2`): re-runs must be able to reload rules.
  local f_rules="/etc/audit/rules.d/10-init.rules" want_rules
  printf -v want_rules '%s\n' \
    '# managed by init.sh — focused audit baseline' \
    '' \
    '# identity / account files' \
    '-w /etc/passwd  -p wa -k identity' \
    '-w /etc/shadow  -p wa -k identity' \
    '-w /etc/group   -p wa -k identity' \
    '-w /etc/gshadow -p wa -k identity' \
    '' \
    '# privilege escalation' \
    '-w /etc/sudoers   -p wa -k scope' \
    '-w /etc/sudoers.d -p wa -k scope' \
    '' \
    '# ssh + network config' \
    '-w /etc/ssh/sshd_config -p wa -k sshd' \
    '-w /etc/hosts    -p wa -k network' \
    '-w /etc/hostname -p wa -k network' \
    '' \
    '# clock tampering' \
    '-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change' \
    '-a always,exit -F arch=b32 -S adjtimex,settimeofday,clock_settime -k time-change' \
    '' \
    '# kernel module load/unload (rootkits)' \
    '-a always,exit -F arch=b64 -S init_module,delete_module -k modules' \
    '-a always,exit -F arch=b32 -S init_module,delete_module -k modules'
  want_rules=${want_rules%$'\n'}                  # drop trailing newline

  if [[ -f "$f_rules" && "$(cat "$f_rules")" == "$want_rules" ]]; then
    ok "audit rules already in place"
  else
    printf '%s\n' "$want_rules" > "$f_rules"
    ok "audit rules written"
    changed=1
  fi

  # built-in log rotation (auditd writes its own /var/log/audit, not journald) — keep disk bounded
  local conf="/etc/audit/auditd.conf" before
  before=$(cat "$conf")
  sed -i -E \
    -e 's/^max_log_file[[:space:]]*=.*/max_log_file = 50/' \
    -e 's/^num_logs[[:space:]]*=.*/num_logs = 5/' \
    -e 's/^max_log_file_action[[:space:]]*=.*/max_log_file_action = ROTATE/' \
    "$conf"
  if [[ "$(cat "$conf")" == "$before" ]]; then
    ok "log rotation already set (50M x 5, ROTATE)"
  else
    ok "log rotation set (50M x 5, ROTATE)"
    changed=1
  fi

  # service up + reload only what changed (avoid a blind restart — auditd dislikes it)
  systemctl enable auditd >/dev/null 2>&1
  if ! systemctl is-active --quiet auditd; then
    systemctl start auditd
    ok "auditd started"
  fi
  if [[ "$changed" -eq 1 ]]; then
    systemctl reload auditd 2>/dev/null || true   # SIGHUP re-reads auditd.conf
    augenrules --load >/dev/null                  # compile rules.d -> load into kernel
    ok "config reloaded & rules loaded"
  else
    ok "auditd running, config current"
  fi
}

#endregion

#region optional — docker · shell · monitoring

# 14. Docker engine (optional) — official get.docker.com installer, then add the login user
#     to the docker group. NB: docker `-p` publishing bypasses ufw (writes iptables directly);
#     left as-is on purpose (caller is aware). `type -P` is used (not `command -v`) because this
#     function is named `docker` and would otherwise shadow the lookup.
docker() {
  step "Docker"

  if [[ "$INSTALL_DOCKER" != "yes" ]]; then
    info "INSTALL_DOCKER != yes — skipping docker"
    return
  fi

  # engine — official convenience script (enables + starts the service itself)
  if type -P docker >/dev/null 2>&1; then
    ok "docker already installed"
  else
    info "installing docker via get.docker.com…"
    curl -fsSL https://get.docker.com | sh >/dev/null
    ok "docker installed"
  fi

  # log rotation — cap container logs so they can't fill the disk. Critical on a
  # stateless host: by default json-file logs grow unbounded until the box is full.
  # Written wholesale (fresh-host assumption); applies to newly created containers,
  # picked up by the daemon restart below.
  local daemon_changed=0
  install -d -m 755 /etc/docker
  local f_daemon="/etc/docker/daemon.json" want_daemon
  printf -v want_daemon '%s\n' \
    '{' \
    '  "log-driver": "json-file",' \
    '  "log-opts": {' \
    "    \"max-size\": \"${DOCKER_LOG_MAX_SIZE}\"," \
    "    \"max-file\": \"${DOCKER_LOG_MAX_FILE}\"" \
    '  }' \
    '}'
  want_daemon=${want_daemon%$'\n'}                 # drop trailing newline
  if [[ -f "$f_daemon" && "$(cat "$f_daemon")" == "$want_daemon" ]]; then
    ok "log rotation already set (json-file ${DOCKER_LOG_MAX_SIZE} x${DOCKER_LOG_MAX_FILE})"
  else
    printf '%s\n' "$want_daemon" > "$f_daemon"
    ok "log rotation set (json-file ${DOCKER_LOG_MAX_SIZE} x${DOCKER_LOG_MAX_FILE})"
    daemon_changed=1
  fi

  # enable at boot; restart only when daemon.json changed, else just ensure it's up
  systemctl enable docker >/dev/null 2>&1
  if [[ "$daemon_changed" -eq 1 ]]; then
    systemctl restart docker
    ok "docker enabled & restarted (applied log rotation)"
  else
    systemctl start docker >/dev/null 2>&1 || true
    ok "docker service enabled & running"
  fi

  # add the login user to the docker group (docker group ~= root — intended trade-off)
  if [[ -n "$USERNAME" ]] && id "$USERNAME" >/dev/null 2>&1; then
    if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx docker; then
      ok "${USERNAME} already in docker group"
    else
      usermod -aG docker "$USERNAME"
      ok "${USERNAME} added to docker group (re-login to take effect)"
    fi
  fi
}

# 15. Shell niceties (optional) — colored prompt + handy aliases for the login user only.
#     Written as a marker-delimited managed block in the user's ~/.bashrc (idempotent: the block
#     is compared and rewritten in place, never duplicated).
shell() {
  step "Shell (prompt + aliases)"

  if [[ "$SETUP_SHELL" != "yes" ]]; then
    info "SETUP_SHELL != yes — skipping shell setup"
    return
  fi
  [[ -n "$USERNAME" ]] || { warn "USERNAME not set — skipping shell setup"; return; }
  id "$USERNAME" >/dev/null 2>&1 || { warn "user ${USERNAME} not found — skipping shell setup"; return; }

  local home bashrc
  home=$(getent passwd "$USERNAME" | cut -d: -f6)
  bashrc="${home}/.bashrc"

  # desired block — tab-stripped quoted heredoc (<<-'BLOCK'): leading TABS are removed, so the
  # body stays indented/foldable here while \u $(...) $confirm land literal in the output file
  local block
  block=$(cat <<-'BLOCK'
	# init.sh:shell BEGIN
	# colored prompt: user@host:cwd
	PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

	# ls / navigation
	alias ll='ls -alhF'
	alias la='ls -A'
	alias l='ls -CF'
	alias ..='cd ..'
	alias ...='cd ../..'

	# handy
	alias df='df -h'
	alias du='du -h'
	alias grep='grep --color=auto'

	# full docker cleanup: containers, images, volumes, networks, build cache
	docker-clean() {
	  docker rm -f $(docker ps -aq) 2>/dev/null || true
	  docker rmi -f $(docker images -aq) 2>/dev/null || true
	  docker volume rm -f $(docker volume ls -q) 2>/dev/null || true
	  docker network prune -f
	  docker builder prune -a -f
	  docker system prune -a --volumes -f
	}

	# update helper: show what's upgradable, then confirm before upgrading
	sysup() {
	  sudo apt update
	  apt list --upgradable
	  read -p "Continue with upgrade? [y/N] " confirm
	  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
	    sudo apt upgrade -y && sudo apt autoremove -y && sudo apt autoclean
	  else
	    echo "Upgrade cancelled."
	  fi
	}
	# init.sh:shell END
	BLOCK
	)

  # the file normally comes from /etc/skel; create an empty one if it's somehow missing
  if [[ ! -f "$bashrc" ]]; then
    install -m 644 -o "$USERNAME" -g "$USERNAME" /dev/null "$bashrc"
  fi

  # idempotent: compare what's between the markers to the desired block
  local current
  current=$(sed -n '/# init.sh:shell BEGIN/,/# init.sh:shell END/p' "$bashrc")
  if [[ "$current" == "$block" ]]; then
    ok "shell block already current"
  else
    if [[ -n "$current" ]]; then
      sed -i '/# init.sh:shell BEGIN/,/# init.sh:shell END/d' "$bashrc"
    fi
    printf '\n%s\n' "$block" >> "$bashrc"
    chown "$USERNAME:$USERNAME" "$bashrc"   # sed -i / append ran as root — restore ownership
    ok "shell block written (${bashrc})"
  fi
}

#endregion

# ==========================================================================
# Step groups  (the roadmap — uncomment a call when its step is written)
# ==========================================================================

base() {                       # ---- base ----
  timesync                     # 1  timezone + NTP (correct clock before TLS/apt)
  update_system                # 2  apt update / upgrade / clean
  base_packages                # 3  TLS/fetch essentials + ops tools
  auto_updates                 # 4  unattended-upgrades + needrestart
  swap                         # 5  swapfile + swappiness (always)
}

identity() {                   # ---- identity ----
  hostname                     # 6  hostname + /etc/hosts
  create_user                  # 7  sudo user, passwordless
}

network_security() {           # ---- network security ----
  firewall                     # 8  ufw default-deny + allow ssh
  ssh                          # 9  harden sshd (port, no root, key-only)
  fail2ban                     # 10 ssh brute-force protection
}

system_hardening() {           # ---- system hardening ----
  sysctl_hardening             # 11 kernel/network sysctl hardening
  tmp_lockdown                 # 12 /tmp + /dev/shm noexec,nosuid,nodev
  auditd                       # 13 audit logging
}

optional() {                   # ---- optional ----
  docker                       # 14 docker engine (INSTALL_DOCKER=no to skip)
  shell                        # 15 prompt + aliases (SETUP_SHELL=no to skip)
  # monitoring                 # 16 cron health-check -> webhook/mail alert
}

# ==========================================================================
# Main
# ==========================================================================

main() {
  require_root                 # 0  must run as root
  base                         # steps 1-5
  identity                     # steps 6-7
  network_security             # steps 8-10
  system_hardening             # steps 11-13
  optional                     # steps 14-16
}

main "$@"
