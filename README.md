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

Give it a quick read (it's one file, and it's about to harden your box), then run it, passing config as environment variables:

```bash
USERNAME=mert \
SSH_PUBKEY="ssh-ed25519 AAAA... you@laptop" \
sudo -E bash init.sh
```

> **`sudo -E`** keeps your environment variables; without `-E` the `USERNAME=…`/`SSH_PUBKEY=…` values are dropped before the script sees them.

### Run from an init script

If your hosting provider supports init scripts, cloud-init, user-data, or first-boot provisioning, you can automatically fetch and run ironclad during server initialization:

```bash
#!/bin/bash
set -e

curl -fsSL https://raw.githubusercontent.com/mertdogan00/ironclad/main/init.sh -o /root/ironclad-init.sh

USERNAME=myuser \
SSH_PUBKEY="ssh-ed25519 AAAA..." \
HOSTNAME=my-server \
SSH_PORT=3742 \
DISK_MOUNTS="/dev/sdb:/data /dev/sdc:/opt:xfs" \
bash /root/ironclad-init.sh
```

Override any default the same way — e.g. `SSH_PORT=3742` moves sshd off the default
port 22, and ironclad opens the new port in the firewall for you (so you won't lock
yourself out).

Re-running is safe — ironclad inspects the real system state and only changes what's off.

## Verify it worked

After a run, fetch the **read-only** checker and see what passed — it changes nothing:

```bash
curl -fsSL https://raw.githubusercontent.com/mertdogan00/ironclad/main/check.sh | sudo bash
```

It walks the same ground `init.sh` covers — NTP, firewall, SSH hardening, fail2ban,
sysctl, `/tmp` lockdown, auditd, Docker — and prints a ✓/✗ per item plus a
`passed · failed · skipped` summary, so you can tell at a glance what's solid and
what needs a look. (Run it with `sudo`; several checks read root-only config.)

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
| `DISK_MOUNTS` | — | *(none)* | Extra data disks to mount + persist. Space-separated `DEVICE:MOUNTPOINT[:FSTYPE]` list — e.g. `"/dev/sdb:/data /dev/sdc:/opt:xfs"`. See [Data disks](#data-disks) below. |
| `DISK_FSTYPE` | — | `ext4` | Filesystem used when formatting a **blank** disk (`ext4`, `xfs`, or `btrfs`). |
| `DISK_MOUNT_OPTS` | — | `defaults,nofail` | fstab mount options. `nofail` lets the box still boot if a disk is detached. |
| `FAIL2BAN_BANTIME` | — | `1h` | How long a banned IP stays out. |
| `FAIL2BAN_FINDTIME` | — | `10m` | Window in which failures are counted. |
| `FAIL2BAN_MAXRETRY` | — | `5` | Failures allowed before a ban. |
| `INSTALL_DOCKER` | — | `yes` | Install Docker + add the user to the `docker` group. `no` to skip. |
| `DOCKER_LOG_MAX_SIZE` | — | `50m` | Per-container log size before it rotates (`json-file` driver). |
| `DOCKER_LOG_MAX_FILE` | — | `3` | How many rotated log files to keep per container. |
| `SETUP_SHELL` | — | `yes` | Colored prompt + aliases for the login user. `no` to skip. |

> To open more firewall ports, edit the `UFW_PORTS` array near the top of `init.sh`
> (defaults to `SSH_PORT`, `80`, `443`).

### Data disks

Cloud providers (AWS, Azure, GCP, …) hand you a raw block device when you attach a volume and
let you decide where it lands — ironclad does the in-server half: format (only if blank), mount,
and persist in `/etc/fstab` so it survives reboots. Add as many disks as you like; `DISK_MOUNTS`
is a space-separated list of `DEVICE:MOUNTPOINT[:FSTYPE]` entries, one per disk:

```bash
USERNAME=mert \
SSH_PUBKEY="ssh-ed25519 AAAA..." \
DISK_MOUNTS="/dev/sdb:/data /dev/sdc:/opt:xfs" \
sudo -E bash init.sh
```

For each entry ironclad:

1. **Checks the device is attached** — a missing `/dev/sdX` is warned about and skipped (the run
   keeps going), so the whole hardening pass never fails just because a disk isn't there yet.
2. **Formats only a blank disk.** If the device already holds a filesystem it's mounted as-is and
   **never reformatted** — re-running is safe and can't wipe your data. `FSTYPE` (per-entry, or the
   `DISK_FSTYPE` default) is used only when formatting a fresh disk. Supported: `ext4`, `xfs`, `btrfs`.
3. **Mounts by `UUID`** (not `/dev/sdX`, which the kernel can reshuffle on reboot) and writes one
   `/etc/fstab` line with `DISK_MOUNT_OPTS` (`defaults,nofail` by default — `nofail` keeps the box
   bootable even if the disk is later detached).

The step is idempotent like the rest: existing fstab entries and already-mounted points are left
alone. To mount one disk as `/data` and another as `/opt`, that's just
`DISK_MOUNTS="/dev/sdb:/data /dev/sdc:/opt"`.

## Connecting over SSH

The SSH hardening step is **key-only** (password login is disabled), so you need an SSH key first
and you pass its **public** half as `SSH_PUBKEY`.

### 1. Generate a key (on your local machine)

```bash
# create + secure the ssh directory
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# generate a new ed25519 private key
#
# -C adds a comment/label to the public key, useful for identifying where/why it was created
# -a sets KDF rounds for passphrase protection; default is usually 16, use 100 for stronger protection
# -f sets the output path for the private key
ssh-keygen -t ed25519 -a 100 -C "my-server" -f ~/.ssh/myserver

# (re)derive the public key from the private key
# note: ssh-keygen already creates .pub automatically during key generation
ssh-keygen -y -f ~/.ssh/myserver > ~/.ssh/myserver.pub

# lock down the key files
chmod 600 ~/.ssh/myserver
chmod 644 ~/.ssh/myserver.pub
```

Optional tweaks:

```bash
# optional: change the key comment later
ssh-keygen -c -f ~/.ssh/myserver

# optional: add/change the passphrase later
ssh-keygen -p -f ~/.ssh/myserver

# optional: add/change the passphrase later and set KDF rounds
ssh-keygen -p -a 100 -f ~/.ssh/myserver
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
| 6 | disks | format (if blank) + mount + persist extra data disks by UUID (optional, set `DISK_MOUNTS`) |
| 7 | hostname | hostname + clean `/etc/hosts` (set `HOSTNAME`; empty = skip) |
| 8 | user | passwordless sudo user |
| 9 | firewall | ufw default-deny + allow `UFW_PORTS` (SSH + 80/443 by default) |
| 10 | ssh | sshd hardening (port, no root, key-only) — needs `SSH_PUBKEY` |
| 11 | fail2ban | SSH brute-force protection |
| 12 | sysctl | kernel/network hardening |
| 13 | tmp lockdown | `/tmp` + `/dev/shm` noexec,nosuid,nodev |
| 14 | auditd | audit logging |
| 15 | docker | Docker engine + log rotation (`daemon.json`) + user in docker group (optional, `INSTALL_DOCKER=no` to skip) |
| 16 | shell | colored prompt + aliases for the login user (optional, `SETUP_SHELL=no` to skip) |
| 17 | monitoring | cron health-check → webhook/mail (optional) |

> Status: built incrementally. Steps 1–16 are implemented so far (only step 17 monitoring left).
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
