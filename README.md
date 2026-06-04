# ironclad

One idempotent bash script that hardens a fresh **Debian 13** server into a secure, rock-solid
("tank-like") host. Mini-Ansible logic, pure bash, zero dependencies on the target.

- **Idempotent** — safe to run again and again; it checks the real system state and only fixes
  what's off.
- **Opinionated** — a solid security baseline is built in; extras (docker, shell, monitoring) are
  optional.
- **Single file** — fetch one script to the box and run it. Nothing to install first.

Built for a **stateless application host**: no data or backups live here (that's handled
elsewhere, e.g. AWS) — the goal is to keep the app infrastructure solid.

## Quick start

Fetch the script onto the server and run it as **root**. With `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/mertdogan00/ironclad/main/init.sh -o init.sh
```

…or with `wget`:

```bash
wget -qO init.sh https://raw.githubusercontent.com/mertdogan00/ironclad/main/init.sh
```

Give it a quick read (it's one file, and it's about to harden your box), then run it, passing
config as environment variables:

```bash
USERNAME=mert \
SSH_PUBKEY="ssh-ed25519 AAAA... you@laptop" \
sudo -E bash init.sh
```

> **`sudo -E`** keeps your environment variables; without `-E` the `USERNAME=…`/`SSH_PUBKEY=…`
> values are dropped before the script sees them.

Re-running is safe — ironclad inspects the real system state and only changes what's off.

## Configuration

Everything is set through environment variables. **Only two are required:**

| Variable | Required | Default | What it does |
|---|:---:|---|---|
| `USERNAME` | ✅ | — | The passwordless sudo user to create. |
| `SSH_PUBKEY` | ✅ | — | That user's **public** key. The SSH step refuses to run without it, so you can't lock yourself out. |
| `HOSTNAME` | — | *(unchanged)* | Sets the hostname + a clean `/etc/hosts`. Empty = leave the system's hostname alone. |
| `SSH_PORT` | — | `22` | Port sshd listens on (the firewall opens it too). |
| `TIMEZONE` | — | `UTC` | System timezone. |
| `SWAP_SIZE_MB` | — | auto from RAM | Swapfile size in MB. Auto: ≤2G→2×RAM, 2–4G→RAM, >4G→4G cap. |
| `SWAP_SWAPPINESS` | — | `60` | `vm.swappiness` (lower, e.g. `10`, favors RAM over swap). |
| `FAIL2BAN_BANTIME` | — | `1h` | How long a banned IP stays out. |
| `FAIL2BAN_FINDTIME` | — | `10m` | Window in which failures are counted. |
| `FAIL2BAN_MAXRETRY` | — | `5` | Failures allowed before a ban. |
| `INSTALL_DOCKER` | — | `yes` | Install Docker + add the user to the `docker` group. `no` to skip. |
| `DOCKER_LOG_MAX_SIZE` | — | `50m` | Per-container log size before it rotates (`json-file` driver). |
| `DOCKER_LOG_MAX_FILE` | — | `3` | How many rotated log files to keep per container. |
| `SETUP_SHELL` | — | `yes` | Colored prompt + aliases for the login user. `no` to skip. |

> To open more firewall ports, edit the `UFW_PORTS` array near the top of `init.sh`
> (defaults to `SSH_PORT`, `80`, `443`).

## Connecting over SSH

The SSH hardening step is **key-only** (password login is disabled), so you need an SSH key first
and you pass its **public** half as `SSH_PUBKEY`.

### 1. Generate a key (on your local machine)

```bash
# create + secure the ssh directory
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# generate a new ed25519 private key
ssh-keygen -t ed25519 -C "my-server" -f ~/.ssh/myserver

# (re)derive the public key from the private key
ssh-keygen -y -f ~/.ssh/myserver > ~/.ssh/myserver.pub

# lock down the key files
chmod 600 ~/.ssh/myserver
chmod 644 ~/.ssh/myserver.pub
```

Optional tweaks:

```bash
ssh-keygen -c -f ~/.ssh/myserver   # change the key comment
ssh-keygen -p -f ~/.ssh/myserver   # add / change the passphrase
```

The contents of `~/.ssh/myserver.pub` is what you pass as `SSH_PUBKEY`.

### 2. Put the key on the server

ironclad installs `SSH_PUBKEY` for you. To do it by hand instead:

```bash
# copy the public key to the target user
ssh-copy-id -i ~/.ssh/myserver.pub -p 22 USER_NAME@MY_IP_ADDRESS
```

Manual alternative if `ssh-copy-id` isn't available — print the public key:

```bash
cat ~/.ssh/myserver.pub
```

Paste the output into `/home/USER_NAME/.ssh/authorized_keys` on the server, then:

```bash
chmod 700 /home/USER_NAME/.ssh
chmod 600 /home/USER_NAME/.ssh/authorized_keys
```

### 3. A handy `~/.ssh/config` shortcut

```sshconfig
# Global settings for all SSH hosts
Host *
    ServerAliveInterval 60          # send keepalive every 60s
    ServerAliveCountMax 3           # disconnect after 3 missed replies
    ControlMaster auto              # reuse an existing connection when possible
    ControlPersist 15m              # keep the master alive 15m after exit
    ControlPath ~/.ssh/mux-%r@%h:%p # socket path for the shared connection
    IdentitiesOnly yes              # only offer the IdentityFile below

# Custom VPS shortcut
Host dev-vps
    HostName MY_IP_ADDRESS          # server IP or domain
    User USER_NAME                  # remote username
    IdentityFile ~/.ssh/myserver # private key for this server
    Port 22                         # must match SSH_PORT
    Compression no
```

```bash
chmod 600 ~/.ssh/config             # secure the config file
ssh dev-vps                         # connect using the alias
```

## What it sets up

Run in this order (order matters for lockout safety):

| # | Step | What |
|---|------|------|
| 1 | timesync | Timezone (UTC) + NTP |
| 2 | update | apt update / upgrade / autoremove / clean |
| 3 | base packages | curl, ca-certificates, gnupg + handy tools |
| 4 | auto-updates | unattended-upgrades (automatic security patches) |
| 5 | swap | swapfile + swappiness |
| 6 | hostname | hostname + clean `/etc/hosts` (set `HOSTNAME`; empty = skip) |
| 7 | user | passwordless sudo user |
| 8 | firewall | ufw default-deny + allow `UFW_PORTS` (SSH + 80/443 by default) |
| 9 | ssh | sshd hardening (port, no root, key-only) — needs `SSH_PUBKEY` |
| 10 | fail2ban | SSH brute-force protection |
| 11 | sysctl | kernel/network hardening |
| 12 | tmp lockdown | `/tmp` + `/dev/shm` noexec,nosuid,nodev |
| 13 | auditd | audit logging |
| 14 | docker | Docker engine + log rotation (`daemon.json`) + user in docker group (optional, `INSTALL_DOCKER=no` to skip) |
| 15 | shell | colored prompt + aliases for the login user (optional, `SETUP_SHELL=no` to skip) |
| 16 | monitoring | cron health-check → webhook/mail (optional) |

> Status: built incrementally. Steps 1–15 are implemented so far (only step 16 monitoring left).
> See [CHANGELOG.md](CHANGELOG.md) for released versions.

## Development

This is a single bash file — edit `init.sh` directly. After changes:

```bash
bash -n init.sh      # syntax check
shellcheck init.sh   # linter (should be clean)
```

Functional testing must happen on a real Debian 13 target (no apt/systemctl on macOS).

## Changelog

See [CHANGELOG.md](CHANGELOG.md). This project follows [Semantic Versioning](https://semver.org/)
and the [Keep a Changelog](https://keepachangelog.com/) format.

## 🤝 Contributing

🚀 Contributions are welcome! Fork the repo, create a branch, and open a **pull request**.
Please keep the project's style: one focused change at a time, real-state idempotency
(no marker files), and `bash -n` + `shellcheck` clean before committing.

## 📜 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

© [Mert Dogan](https://github.com/mertdogan00)
