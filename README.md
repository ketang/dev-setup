# dev-setup

Ansible-provisioned WSL2 development VMs. One PowerShell command creates a
fully configured Ubuntu instance with Go, Rust, Node.js, Python, Docker,
PostgreSQL client, Playwright GUI support, SSH, and NetBird mesh VPN.

## Prerequisites

- Windows 11 (or Windows 10 21H2+) with WSL2 enabled
- An SSH keypair (`~/.ssh/id_ed25519` + `.pub`) added to your GitHub account

To enable WSL2 if not already:

```powershell
wsl --install --no-distribution
```

## Quick start

```powershell
# Download and run (no git required on the host)
Invoke-WebRequest https://raw.githubusercontent.com/YOU/dev-setup/main/wsl-dev.ps1 -OutFile $env:TEMP\wsl-dev.ps1; & $env:TEMP\wsl-dev.ps1
```

First run prompts for:
- Linux username
- Git author name and email
- Path to your SSH private key
- SSH URL of this dev-setup repo
- Dotfiles repo SSH URL (optional — cloned to `~/dotfiles`, runs `install.sh`)
- Project repos to clone (SSH URLs)
- Optional per-instance `/home` mount (device/UUID + filesystem details)

Everything is saved to a single config file at
`%LOCALAPPDATA%\WSLDev\config.json` and reused on rebuilds.

### Config file example

```json
{
  "User": "jdoe",
  "GitName": "Jane Doe",
  "GitEmail": "jane@example.com",
  "IdentityKeyPath": "C:\\Users\\jdoe\\.ssh\\id_ed25519",
  "SetupRepo": "git@github.com:jdoe/dev-setup.git",
  "Dotfiles": "git@github.com:jdoe/dotfiles.git",
  "Repos": [
    "git@github.com:jdoe/project-alpha.git",
    "git@github.com:jdoe/project-beta.git"
  ],
  "Instances": {
    "dev": {
      "SSHPort": 2222,
      "HomeMount": {
        "Src": "UUID=01234567-89ab-cdef-0123-456789abcdef",
        "FSType": "ext4",
        "Opts": "defaults,nofail",
        "Dump": 0,
        "PassNo": 2
      }
    },
    "dev-2": { "SSHPort": 2223 }
  }
}
```

Edit this file directly to change repos, add instances, or update identity.
Delete it to re-prompt on next create.

## Usage

```powershell
.\wsl-dev.ps1                              # Create default "dev" instance
.\wsl-dev.ps1 -Name dev-2                  # Create a second instance
.\wsl-dev.ps1 -Action destroy              # Destroy default instance
.\wsl-dev.ps1 -Action destroy -Name dev-2  # Destroy named instance
.\wsl-dev.ps1 -Action list                 # List all WSL instances
```

The `-Name` parameter selects which entry in the `Instances` map to use for
SSH port assignment and optional `/home` mount settings. Unlisted names get an
auto-assigned port and will be prompted for the `/home` mount option the first
time they are created.

## What gets installed

| Role | What it provides |
|---|---|
| base | build-essential, git, curl, tmux, ripgrep, glow, jq, cmake, libicu-dev, locales |
| docker | Docker Engine + docker-compose-plugin (not Docker Desktop) |
| golang | Go (version in `vars/main.yml`), air, golangci-lint |
| rust | Rust stable via rustup, libz3-dev, libclang-dev |
| nodejs | Node.js + pnpm |
| python | Python 3 + pip + pyyaml |
| postgresql | PostgreSQL client + libpq-dev (server runs via Docker) |
| playwright | Browser GUI dependencies for headed Playwright under WSLg |
| github-cli | GitHub CLI (`gh`) via the official apt repository |
| ssh | OpenSSH server on configurable port |
| netbird | NetBird mesh VPN agent |
| project-tools | Claude CLI, beads issue tracker, doctl, OpenTofu |
| user | Git config, project directory, repo cloning via SSH |

## Nuke and rebuild

```powershell
.\wsl-dev.ps1 -Action destroy
.\wsl-dev.ps1 -Action create
# Re-clones repos, re-provisions everything. ~5-10 minutes.
```

Config is preserved across rebuilds. The Ubuntu rootfs tarball is cached at
`%LOCALAPPDATA%\WSLDev\.cache\` after first download.

## Remote access

After provisioning, run `netbird up` inside the VM to authenticate. Then
from any machine on your NetBird network:

```bash
ssh -p 2222 youruser@vm-hostname
```

## Multiple instances

Per-instance SSH ports are defined in the `Instances` map in `config.json`.
Each instance gets its own filesystem, SSH port, and NetBird identity:

```powershell
.\wsl-dev.ps1 -Name dev                   # uses SSHPort 2222
.\wsl-dev.ps1 -Name dev-2                 # uses SSHPort 2223
```

## Re-provisioning (without rebuilding)

To update an existing instance after changing the playbook:

```bash
# Inside the WSL2 instance
cd ~/dev-setup
git pull
ansible-playbook playbook.yml --diff
```

## Customizing

- **Versions**: edit `vars/main.yml`
- **Add a tool**: create a new role under `roles/`, add it to `playbook.yml`
- **Change repos or identity**: edit `%LOCALAPPDATA%\WSLDev\config.json`
- **Add an instance**: add an entry to the `Instances` map in `config.json`
- **Per-instance `/home` mount**: set `Instances.<name>.HomeMount` in `%LOCALAPPDATA%\WSLDev\config.json`; it is applied before user creation so provisioning lands on that filesystem
- **Other optional mounts**: set `fstab_entries` in `vars/main.yml` or extra-vars for machine-specific `/etc/fstab` entries that do not need first-boot handling

## File layout

```
wsl-dev.ps1           PowerShell entry point (runs on Windows)
ansible.cfg           Ansible configuration
inventory.yml         Localhost inventory
playbook.yml          Main playbook
vars/main.yml         Version pins and defaults
roles/
  base/               System packages, locale, timezone
  docker/             Docker Engine (not Desktop)
  golang/             Go + dev tools
  rust/               Rust toolchain + system libs
  nodejs/             Node.js + pnpm
  python/             Python 3 + pip + pyyaml
  postgresql/         PostgreSQL client libraries
  playwright/         Browser deps for headed mode under WSLg
  ssh/                OpenSSH server
  netbird/            NetBird mesh VPN
  project-tools/      Claude CLI, beads
  user/               Git config, repo cloning
```
