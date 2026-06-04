#!/usr/bin/env bash
# ==========================================================================
# ironclad check — read-only health check for an ironclad-hardened host.
# Verifies what init.sh set up; changes NOTHING. Run as root for full results:
#   curl -fsSL https://raw.githubusercontent.com/mertdogan00/ironclad/main/check.sh | sudo bash
# ==========================================================================
set -u

# colors (only on a terminal)
if [[ -t 1 ]]; then
  grn=$'\e[1;32m'; red=$'\e[1;31m'; ylw=$'\e[1;33m'; blu=$'\e[1;34m'; rst=$'\e[0m'
else
  grn=''; red=''; ylw=''; blu=''; rst=''
fi

passed=0; failed=0; skipped=0

pass()    { printf '  %s✓%s %s\n' "$grn" "$rst" "$1"; passed=$((passed+1)); }
fail()    { printf '  %s✗%s %s\n' "$red" "$rst" "$1"; failed=$((failed+1)); }
skip()    { printf '  %s•%s %s (skipped)\n' "$ylw" "$rst" "$1"; skipped=$((skipped+1)); }
section() { printf '\n%s== %s ==%s\n' "$blu" "$1" "$rst"; }

# check "label" cmd args...  ->  ✓ if the command succeeds, ✗ otherwise
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

# predicates for the non-trivial checks
sysctl_equals()  { [[ "$(sysctl -n "$1" 2>/dev/null)" == "$2" ]]; }
mount_hardened() { local o; o=$(findmnt -no OPTIONS "$1" 2>/dev/null) || return 1
                   [[ "$o" == *noexec* && "$o" == *nosuid* && "$o" == *nodev* ]]; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || \
  printf '%s! not root — some checks need sudo and may show as ✗%s\n' "$ylw" "$rst"

section "Time"
check "NTP time sync enabled"        bash -c 'timedatectl show -p NTP --value | grep -q yes'

section "Packages"
for p in curl jq tmux lsof; do check "installed: $p" command -v "$p"; done

section "Auto-updates"
check "unattended-upgrades present"  dpkg -s unattended-upgrades
check "periodic upgrades enabled"    test -f /etc/apt/apt.conf.d/20auto-upgrades

section "Swap"
check "swap active"                  bash -c 'swapon --show=NAME --noheadings | grep -q .'

section "User / sudo"
check "passwordless sudo set"        bash -c 'grep -rlq NOPASSWD /etc/sudoers.d/ 2>/dev/null'

section "Firewall"
check "ufw active"                   bash -c 'ufw status 2>/dev/null | grep -q "Status: active"'
check "default-deny incoming"        bash -c 'ufw status verbose 2>/dev/null | grep -qi "deny (incoming)"'

section "SSH hardening"
check "root login disabled"          bash -c 'sshd -T 2>/dev/null | grep -qi "^permitrootlogin no"'
check "password auth disabled"       bash -c 'sshd -T 2>/dev/null | grep -qi "^passwordauthentication no"'
port=$(sshd -T 2>/dev/null | awk '/^port /{print $2}')
[[ -n "$port" ]] && printf '  %s•%s sshd listening on port %s\n' "$blu" "$rst" "$port"

section "fail2ban"
check "fail2ban running"             systemctl is-active --quiet fail2ban

section "Kernel hardening"
check "tcp_syncookies = 1"           sysctl_equals net.ipv4.tcp_syncookies 1
check "ptrace restricted (=1)"       sysctl_equals kernel.yama.ptrace_scope 1

section "Temp lockdown"
check "/tmp noexec,nosuid,nodev"     mount_hardened /tmp
check "/dev/shm noexec,nosuid,nodev" mount_hardened /dev/shm

section "Audit"
check "auditd running"               systemctl is-active --quiet auditd

section "Docker (optional)"
if command -v docker >/dev/null 2>&1; then
  check "docker running"             systemctl is-active --quiet docker
  check "log rotation set"           bash -c 'grep -q json-file /etc/docker/daemon.json 2>/dev/null'
else
  skip "docker not installed"
fi

printf '\n%s── %d passed · %d failed · %d skipped ──%s\n' "$blu" "$passed" "$failed" "$skipped" "$rst"
if [[ "$failed" -eq 0 ]]; then
  printf '%sAll checks passed — looks ironclad.%s\n' "$grn" "$rst"; exit 0
else
  printf '%s%d check(s) failed — review the ✗ items above.%s\n' "$red" "$failed" "$rst"; exit 1
fi
