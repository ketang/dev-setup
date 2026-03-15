<#
.SYNOPSIS
    Create, destroy, or list WSL2 development VMs.

.DESCRIPTION
    One-file bootstrap for provisioned WSL2 dev environments.
    Downloads Ubuntu rootfs, creates a WSL2 instance, and runs
    Ansible to install all development tooling.

    All configuration lives in a single JSON file at
    %LOCALAPPDATA%\WSLDev\config.json. First run prompts to
    create it. Per-instance settings (SSH port) are in the
    Instances map.

    Resilient to failures: if provisioning fails partway (bad
    passphrase, network error, etc.), re-running the script
    detects the existing instance and re-provisions it.

.EXAMPLE
    .\wsl-dev.ps1                              # Prompts for hostname, creates instance
    .\wsl-dev.ps1 -Name myhost                 # Creates instance named "myhost"
    .\wsl-dev.ps1 -Action destroy -Name myhost # Destroys named instance
    .\wsl-dev.ps1 -Action list                 # Lists all WSL instances
#>

param(
    [ValidateSet("create", "destroy", "list")]
    [string]$Action = "create",

    [string]$Name
)

$ErrorActionPreference = "Stop"
$instanceRoot = "$env:LOCALAPPDATA\WSLDev"
$cacheDir     = "$instanceRoot\.cache"
$configPath   = "$instanceRoot\config.json"
$baseName     = "Ubuntu-24.04"  # Store distro used to create base tarball

# ---------------------------------------------------------------------------
# Config — single file, written incrementally as each field is collected
# ---------------------------------------------------------------------------

function Save-Config {
    param([hashtable]$Config)
    New-Item -ItemType Directory -Path (Split-Path $configPath) -Force | Out-Null
    $Config | ConvertTo-Json -Depth 5 | Set-Content $configPath
}

function New-HomeMountConfig {
    param([object]$Saved)

    if ($null -ne $Saved -and -not [string]::IsNullOrWhiteSpace([string]$Saved.Src)) {
        $src = [string]$Saved.Src
        $fsType = if ([string]::IsNullOrWhiteSpace([string]$Saved.FSType)) { "ext4" } else { [string]$Saved.FSType }
        $opts = if ([string]::IsNullOrWhiteSpace([string]$Saved.Opts)) { "defaults,nofail" } else { [string]$Saved.Opts }
        $dump = if ($null -eq $Saved.Dump -or [string]::IsNullOrWhiteSpace([string]$Saved.Dump)) { 0 } else { [int]$Saved.Dump }
        $passNo = if ($null -eq $Saved.PassNo -or [string]::IsNullOrWhiteSpace([string]$Saved.PassNo)) { 2 } else { [int]$Saved.PassNo }
        Write-Host "  HomeMount: $src -> /home ($fsType, $opts) (saved)"
        return [PSCustomObject]@{
            Src    = $src
            FSType = $fsType
            Opts   = $opts
            Dump   = $dump
            PassNo = $passNo
        }
    }

    Write-Host ""
    Write-Host "Optional separate filesystem for /home:"
    $src = Read-Host "  Source device/UUID (e.g. UUID=... or /dev/disk/by-uuid/..., empty to skip)"
    if ([string]::IsNullOrWhiteSpace($src)) {
        Write-Host "  HomeMount: (none)"
        return $null
    }

    $fsType = Read-Host "  Filesystem type [ext4]"
    if ([string]::IsNullOrWhiteSpace($fsType)) { $fsType = "ext4" }

    $opts = Read-Host "  Mount options [defaults,nofail]"
    if ([string]::IsNullOrWhiteSpace($opts)) { $opts = "defaults,nofail" }

    $dump = Read-Host "  dump value [0]"
    if ([string]::IsNullOrWhiteSpace($dump)) { $dump = 0 } else { $dump = [int]$dump }

    $passNo = Read-Host "  fsck pass number [2]"
    if ([string]::IsNullOrWhiteSpace($passNo)) { $passNo = 2 } else { $passNo = [int]$passNo }

    return [PSCustomObject]@{
        Src    = $src
        FSType = $fsType
        Opts   = $opts
        Dump   = $dump
        PassNo = $passNo
    }
}

function Prompt-Field {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$Prompt,
        [string]$Saved
    )
    if (-not [string]::IsNullOrWhiteSpace($Saved)) {
        Write-Host "  $($Key): $Saved (saved)"
        return $Saved
    }
    $value = Read-Host $Prompt
    $Config[$Key] = $value
    Save-Config $Config
    return $value
}

function Get-DevConfig {
    # Load existing config or start with an empty one
    $cfg = [ordered]@{}
    $resumed = $false
    if (Test-Path $configPath) {
        $loaded = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($prop in $loaded.PSObject.Properties) {
            $cfg[$prop.Name] = $prop.Value
        }
        # Check if config is complete
        $required = @("User", "GitName", "GitEmail", "IdentityKeyPath", "SetupRepo", "Repos", "Instances")
        $missing = $required | Where-Object { -not $cfg.Contains($_) -or [string]::IsNullOrWhiteSpace($cfg[$_]) }
        # Also treat IdentityKeyPath as missing if the files don't exist on disk
        $idkPath = $cfg["IdentityKeyPath"]
        if (-not [string]::IsNullOrWhiteSpace($idkPath) -and (-not (Test-Path $idkPath) -or -not (Test-Path "$idkPath.pub"))) {
            Write-Host "  Saved GitHub key not found: $idkPath"
            $cfg.Remove("IdentityKeyPath")
            Save-Config $cfg
            $missing = @("IdentityKeyPath")
        }
        if (-not $missing) {
            Write-Host "Using config from $configPath"
            Write-Host "  To start fresh, delete the file and re-run.`n"
            return [PSCustomObject]$cfg
        }
        $resumed = $true
        Write-Host "Resuming setup from $configPath (some fields already saved)."
        Write-Host "  To start fresh, delete the file and re-run.`n"
    } else {
        Write-Host "First-time setup -- each answer is saved immediately.`n"
    }

    # Collect fields, skipping any that are already set
    # Default Linux username to current Windows session username (lowercase)
    if (-not $cfg.Contains("User") -or [string]::IsNullOrWhiteSpace($cfg["User"])) {
        $cfg["User"] = $env:USERNAME.ToLower()
        Save-Config $cfg
    }
    $cfg["User"] = Prompt-Field $cfg "User" "Linux username" $cfg["User"]

    $cfg["GitName"] = Prompt-Field $cfg "GitName" "Git author name" $cfg["GitName"]

    $cfg["GitEmail"] = Prompt-Field $cfg "GitEmail" "Git author email (for commits)" $cfg["GitEmail"]

    $savedKey = $cfg["IdentityKeyPath"]
    $savedKeyValid = (-not [string]::IsNullOrWhiteSpace($savedKey)) -and (Test-Path $savedKey) -and (Test-Path "$savedKey.pub")
    if ($savedKeyValid) {
        Write-Host "  IdentityKeyPath: $savedKey (saved)"
        $idKey = $savedKey
    } else {
        if (-not [string]::IsNullOrWhiteSpace($savedKey)) {
            Write-Host "  Saved key not found: $savedKey -- re-selecting..."
        }
        # Discover SSH private keys (files with a matching .pub, excluding VM access keys)
        $sshDir = "$env:USERPROFILE\.ssh"
        $candidates = @()
        if (Test-Path $sshDir) {
            $candidates = @(Get-ChildItem "$sshDir\*.pub" -File |
                Where-Object { $_.Name -notmatch '_wsl_' } |
                ForEach-Object { $_.FullName -replace '\.pub$', '' } |
                Where-Object { Test-Path $_ })
        }
        Write-Host ""
        Write-Host "GitHub SSH key (used for git/GitHub auth, NOT for VM access):"
        if ($candidates.Count -gt 0) {
            for ($i = 0; $i -lt $candidates.Count; $i++) {
                Write-Host "  [$($i + 1)] $($candidates[$i])"
            }
            Write-Host "  [M] Enter path manually"
            $choice = Read-Host "Select a key"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $candidates.Count) {
                $idKey = $candidates[[int]$choice - 1]
            } elseif ($choice -match '^[Mm]$') {
                $idKey = Read-Host "Path to SSH private key"
            } else {
                Write-Error "Invalid selection."
                exit 1
            }
        } else {
            Write-Host "  No SSH keys found in $sshDir"
            $idKey = Read-Host "Path to SSH private key"
        }
        if (-not (Test-Path $idKey)) {
            Write-Error "Key not found at $idKey"
            exit 1
        }
        if (-not (Test-Path "$idKey.pub")) {
            Write-Error "Public key not found at $idKey.pub"
            exit 1
        }
        $cfg["IdentityKeyPath"] = $idKey
        Save-Config $cfg
    }

    $cfg["SetupRepo"] = Prompt-Field $cfg "SetupRepo" "dev-setup repo SSH URL (e.g., git@github.com:org/dev-setup.git)" $cfg["SetupRepo"]

    if (-not $cfg.Contains("Dotfiles")) {
        $dotfiles = Read-Host "Dotfiles repo SSH URL (empty to skip)"
        $cfg["Dotfiles"] = $dotfiles
        Save-Config $cfg
    } else {
        $df = $cfg["Dotfiles"]
        if ([string]::IsNullOrWhiteSpace($df)) {
            Write-Host "  Dotfiles: (none)"
        } else {
            Write-Host "  Dotfiles: $df (saved)"
        }
    }

    if (-not $cfg.Contains("Repos") -or $cfg["Repos"] -eq $null) {
        $repos = @()
        Write-Host "`nProject repos to clone (SSH URLs, e.g., git@github.com:org/repo.git; empty line when done):"
        while ($true) {
            $repo = Read-Host "  repo"
            if ([string]::IsNullOrWhiteSpace($repo)) { break }
            $repos += $repo
        }
        $cfg["Repos"] = $repos
        Save-Config $cfg
    } else {
        $repoList = ($cfg["Repos"] | ForEach-Object { $_ }) -join ", "
        Write-Host "  Repos: $repoList (saved)"
    }

    if (-not $cfg.Contains("Instances") -or $cfg["Instances"] -eq $null) {
        $cfg["Instances"] = [ordered]@{}
        Save-Config $cfg
    }

    Write-Host "`nConfig complete.`n"
    return [PSCustomObject]$cfg
}

function Get-InstanceConfig {
    param([PSCustomObject]$Config, [string]$InstanceName)

    # Look up per-instance settings; fall back to defaults
    $inst = $Config.Instances.PSObject.Properties | Where-Object { $_.Name -eq $InstanceName }
    if ($inst) {
        return $inst.Value
    }
    # Default for unlisted instances: auto-assign port based on instance count
    $basePort = 2222
    $existing = @($Config.Instances.PSObject.Properties).Count
    return [PSCustomObject]@{
        SSHPort = $basePort + $existing
        HomeMount = $null
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    # Ensure Unix line endings (LF only) — bash chokes on \r\n
    $Content = $Content -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-BashSingleQuoted {
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\"'\"'") + "'"
}

# ---------------------------------------------------------------------------
# Check if a WSL2 instance exists (registered)
# ---------------------------------------------------------------------------

function Test-WslInstance {
    param([string]$InstanceName)
    # wsl --list output contains null characters; strip them before matching
    $raw = (wsl --list --quiet 2>$null) -join "`n"
    $clean = $raw -replace "`0", ""
    return ($clean -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $InstanceName }).Count -gt 0
}

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

function Invoke-Create {
    $config = Get-DevConfig
    $user = $config.User
    $setupRepo = $config.SetupRepo

    # Use -Name as the WSL instance name and hostname
    if ([string]::IsNullOrWhiteSpace($Name)) {
        # Reuse the existing instance name if there's exactly one
        $instances = @($config.Instances.PSObject.Properties)
        if ($instances.Count -eq 1) {
            $Name = $instances[0].Name
            Write-Host "  Using instance: $Name (from config)"
        } else {
            $Name = Read-Host "Hostname for this instance (used as WSL name and Linux hostname)"
            if ([string]::IsNullOrWhiteSpace($Name)) {
                Write-Error "Hostname is required."
                exit 1
            }
        }
    }

    $inst = Get-InstanceConfig -Config $config -InstanceName $Name
    $sshPort = $inst.SSHPort
    $homeMount = $inst.HomeMount

    $existingInst = $config.Instances.PSObject.Properties | Where-Object { $_.Name -eq $Name }
    $needsHomeMountPrompt = (-not $existingInst) -or (-not ($inst.PSObject.Properties.Name -contains "HomeMount"))
    if ($needsHomeMountPrompt) {
        $homeMount = New-HomeMountConfig
    } elseif ($null -ne $homeMount -and -not [string]::IsNullOrWhiteSpace([string]$homeMount.Src)) {
        $homeMount = New-HomeMountConfig -Saved $homeMount
    } else {
        Write-Host "  HomeMount: (none)"
    }

    # Save instance config if new or missing the current schema
    if ((-not $existingInst) -or $needsHomeMountPrompt) {
        $config.Instances | Add-Member -NotePropertyName $Name -NotePropertyValue ([PSCustomObject]@{
            SSHPort   = $sshPort
            HomeMount = $homeMount
        }) -Force
        $cfg = [ordered]@{}
        foreach ($prop in $config.PSObject.Properties) { $cfg[$prop.Name] = $prop.Value }
        Save-Config $cfg
    }

    $hostname = $Name

    # --- Verify Windows SSH agent has the GitHub key loaded ---
    $agentKeys = ssh-add -L 2>&1
    if ($LASTEXITCODE -ne 0 -or $agentKeys -match "Could not open|error") {
        Write-Error "Windows SSH agent is not running. Start it with: Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent"
        exit 1
    }
    if ($agentKeys -match "no identities") {
        Write-Error "No keys in Windows SSH agent. Add your GitHub key with: ssh-add $($config.IdentityKeyPath)"
        exit 1
    }
    Write-Host "  Windows SSH agent has keys loaded."

    # --- Generate VM access key (separate from identity key) ---
    $vmKeyPath = "$env:USERPROFILE\.ssh\id_ed25519_wsl_$Name"
    if (-not (Test-Path $vmKeyPath)) {
        Write-Host "Generating VM access key at $vmKeyPath ..."
        ssh-keygen -t ed25519 -f $vmKeyPath -N '""' -C "wsl-$Name-access"
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed" }
    } else {
        Write-Host "  VM access key exists: $vmKeyPath"
    }

    # --- Step 1: Ensure WSL2 instance exists ---
    if (Test-WslInstance $Name) {
        Write-Host "Instance '$Name' already exists. Re-provisioning..."
    } else {
        # Get base tarball from the official Store image (cached after first run)
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $tarball = "$cacheDir\ubuntu-noble.tar.gz"
        if (-not (Test-Path $tarball)) {
            Write-Host "Creating base image from official Ubuntu Store distro..."

            $installed = wsl --list --quiet 2>$null | Where-Object { $_ -match "^$baseName$" }
            if (-not $installed) {
                Write-Host "  Installing $baseName from Microsoft Store..."
                wsl --install $baseName --no-launch
                if ($LASTEXITCODE -ne 0) { throw "wsl --install $baseName failed" }
            }

            Write-Host "  Exporting to tarball (this takes a minute)..."
            wsl --export $baseName $tarball
            if ($LASTEXITCODE -ne 0) { throw "wsl --export failed" }

            Write-Host "  Removing temporary Store distro..."
            wsl --unregister $baseName
            Write-Host "  Base image cached at $tarball"
        } else {
            Write-Host "Using cached base image."
        }

        $instancePath = "$instanceRoot\$Name"
        Write-Host "`nCreating WSL2 instance '$Name'..."
        New-Item -ItemType Directory -Path $instancePath -Force | Out-Null
        wsl --import $Name $instancePath $tarball --version 2
        if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }

        # Enable systemd
        Write-Host "Enabling systemd..."
        wsl -d $Name --exec bash -c "printf '[boot]\nsystemd=true\n' > /etc/wsl.conf"

        # Restart to activate systemd
        Write-Host "Restarting instance for systemd..."
        wsl --terminate $Name
        Start-Sleep -Seconds 3
    }

    if ($null -ne $homeMount -and -not [string]::IsNullOrWhiteSpace([string]$homeMount.Src)) {
        $homeMountSrc = ConvertTo-BashSingleQuoted ([string]$homeMount.Src)
        $homeMountFsType = ConvertTo-BashSingleQuoted ([string]$homeMount.FSType)
        $homeMountOpts = ConvertTo-BashSingleQuoted ([string]$homeMount.Opts)
        $homeMountDump = [int]$homeMount.Dump
        $homeMountPassNo = [int]$homeMount.PassNo

        Write-Host "Configuring /home mount before provisioning..."
        wsl -d $Name -u root --exec bash -c @"
set -euo pipefail
FSTAB=/etc/fstab
BEGIN_MARKER='# BEGIN ANSIBLE MANAGED - optional mounts'
END_MARKER='# END ANSIBLE MANAGED - optional mounts'
HOME_MOUNT_SRC=$homeMountSrc
HOME_MOUNT_FSTYPE=$homeMountFsType
HOME_MOUNT_OPTS=$homeMountOpts
HOME_MOUNT_DUMP=$homeMountDump
HOME_MOUNT_PASSNO=$homeMountPassNo

tmp_file=`$(mktemp)
awk -v begin="`$BEGIN_MARKER" -v end="`$END_MARKER" '
  `$0 == begin { skip=1; next }
  `$0 == end { skip=0; next }
  !skip { print }
' "`$FSTAB" > "`$tmp_file"
mv "`$tmp_file" "`$FSTAB"

printf '\n%s\n%s /home %s %s %s %s\n%s\n' \
  "`$BEGIN_MARKER" \
  "`$HOME_MOUNT_SRC" \
  "`$HOME_MOUNT_FSTYPE" \
  "`$HOME_MOUNT_OPTS" \
  "`$HOME_MOUNT_DUMP" \
  "`$HOME_MOUNT_PASSNO" \
  "`$END_MARKER" >> "`$FSTAB"

mkdir -p /home
if ! mountpoint -q /home; then
  mount /home
fi
"@
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to configure and mount /home. Fix the HomeMount setting in $configPath and retry."
        }
    }

    # Ensure user exists (idempotent — runs on both new and re-provision)
    Write-Host "Ensuring user '$user' exists..."
    wsl -d $Name -u root --exec bash -c "set -euo pipefail; id $user &>/dev/null || useradd -m -s /bin/bash $user; usermod -aG sudo $user; echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user; chmod 440 /etc/sudoers.d/$user; grep -q '^\[user\]' /etc/wsl.conf || printf '\n[user]\ndefault=$user\n' >> /etc/wsl.conf"

    # --- Step 2: Stage files ---
    $stageDir = "$instanceRoot\.stage"
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Copy-Item $vmKeyPath "$stageDir\vm_access_key"
    Copy-Item "$vmKeyPath.pub" "$stageDir\vm_access_key.pub"
    Copy-Item "$($config.IdentityKeyPath).pub" "$stageDir\id_ed25519.pub"

    $dotfilesRepo = if ($config.Dotfiles) { $config.Dotfiles } else { "" }
    $fstabEntries = @()
    if ($null -ne $homeMount -and -not [string]::IsNullOrWhiteSpace([string]$homeMount.Src)) {
        $fstabEntries = @([ordered]@{
            src    = [string]$homeMount.Src
            path   = "/home"
            fstype = [string]$homeMount.FSType
            opts   = [string]$homeMount.Opts
            dump   = [int]$homeMount.Dump
            passno = [int]$homeMount.PassNo
        })
    }

    # Get IANA timezone from the WSL instance (inherits from Windows)
    $ianaTz = (wsl -d $Name -u root --exec cat /etc/timezone 2>$null)
    if (-not $ianaTz) { $ianaTz = "Etc/UTC" }

    $extraVars = [ordered]@{
        user      = $user
        git_name  = $config.GitName
        git_email = $config.GitEmail
        ssh_port  = $sshPort
        hostname  = $hostname
        timezone  = $ianaTz
        dotfiles  = $dotfilesRepo
        repos     = @($config.Repos | ForEach-Object { $_ })
        fstab_entries = $fstabEntries
    }
    Write-Utf8NoBom "$stageDir\extra-vars.json" ($extraVars | ConvertTo-Json -Depth 5)

    # Two provision scripts:
    #   1. provision-root.sh — runs as root: installs SSH keys, apt packages, Ansible
    #   2. provision-user.sh — runs as the user: git clones, Ansible (uses Windows SSH agent via ssh.exe)

    $rootScript = @"
#!/bin/bash
set -euo pipefail

USER_NAME="$user"
HOME_DIR="/home/`$USER_NAME"

# --- SSH keys ---
echo '=== Installing SSH keys ==='
mkdir -p `$HOME_DIR/.ssh
chmod 700 `$HOME_DIR/.ssh

# VM access key (from Windows) → authorized_keys
cp /tmp/stage/vm_access_key.pub `$HOME_DIR/.ssh/authorized_keys

# Identity public key only (for GitHub reference; private key stays on Windows)
cp /tmp/stage/id_ed25519.pub `$HOME_DIR/.ssh/id_ed25519.pub

chown -R `$USER_NAME:`$USER_NAME `$HOME_DIR/.ssh
chmod 644 `$HOME_DIR/.ssh/id_ed25519.pub `$HOME_DIR/.ssh/authorized_keys

ssh-keyscan github.com >> `$HOME_DIR/.ssh/known_hosts 2>/dev/null
chown `$USER_NAME:`$USER_NAME `$HOME_DIR/.ssh/known_hosts

# --- System packages ---
echo '=== Installing git and Ansible ==='
apt-get update -qq
apt-get install -y -qq git software-properties-common > /dev/null
add-apt-repository --yes --update ppa:ansible/ansible > /dev/null 2>&1
apt-get install -y -qq ansible > /dev/null

echo '=== Root setup complete ==='
"@
    Write-Utf8NoBom "$stageDir\provision-root.sh" $rootScript

    $userScript = @"
#!/bin/bash
set -euo pipefail

SETUP_REPO="$setupRepo"

# --- Use Windows SSH agent via ssh.exe (no private key copy needed) ---
echo '=== Configuring SSH for provisioning ==='
WIN_SSH="/mnt/c/Windows/System32/OpenSSH/ssh.exe"
if [ ! -x "`$WIN_SSH" ]; then
    echo "ERROR: Windows SSH not found at `$WIN_SSH"
    exit 1
fi
export GIT_SSH_COMMAND="`$WIN_SSH"
echo "  Using Windows SSH agent via `$WIN_SSH"

# --- Clone dev-setup repo ---
echo ''
echo '=== Cloning dev-setup repo ==='
echo "  Cloning `$SETUP_REPO ..."
git clone --depth 1 "`$SETUP_REPO" /tmp/dev-setup

# --- Run Ansible (installs all packages) ---
echo ''
echo '=== Running Ansible playbook ==='
cd /tmp/dev-setup
sudo --preserve-env=GIT_SSH_COMMAND ansible-playbook playbook.yml --diff -e @/tmp/stage/extra-vars.json

# --- Dotfiles (after packages so tools like stow are available) ---
DOTFILES_REPO="$dotfilesRepo"
if [ -n "`$DOTFILES_REPO" ]; then
    echo ''
    echo '=== Installing dotfiles ==='
    if [ -d ~/dotfiles ]; then
        echo '  Dotfiles repo exists, pulling latest...'
        cd ~/dotfiles && git pull --ff-only
    else
        echo "  Cloning `$DOTFILES_REPO ..."
        git clone "`$DOTFILES_REPO" ~/dotfiles
    fi
    if [ -x ~/dotfiles/install.sh ]; then
        echo '  Running install.sh...'
        cd ~/dotfiles && ./install.sh
    fi
fi

# --- Cleanup ---
sudo rm -rf /tmp/stage /tmp/dev-setup

echo ''
echo '========================================='
echo '  Provisioning complete.'
echo '========================================='
echo ''
echo 'Remaining manual steps:'
echo '  Run ~/project/dev-setup/post-provision.sh to complete interactive setup'
echo '  (GitHub auth, repo cloning, and mesh VPN authentication)'
echo ''
"@
    Write-Utf8NoBom "$stageDir\provision-user.sh" $userScript

    # --- Step 3: Copy staging files in and run provisioning ---
    Write-Host "`nProvisioning (this takes a few minutes)..."

    $wslStageDir = wsl -d $Name --exec wslpath -a "$stageDir"

    # Copy stage files in (as root)
    wsl -d $Name -u root --exec bash -c "cp -r $wslStageDir /tmp/stage && chmod +x /tmp/stage/*.sh"

    # Root phase: SSH keys + system packages (explicitly as root)
    Write-Host ""
    wsl -d $Name -u root --exec /tmp/stage/provision-root.sh
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nRoot provisioning failed. Re-run this script to retry."
        Remove-Item -Recurse -Force $stageDir -ErrorAction SilentlyContinue
        exit 1
    }

    # User phase: ssh-agent, git clones, Ansible (explicitly as the user)
    Write-Host ""
    wsl -d $Name -u $user --exec /tmp/stage/provision-user.sh
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nUser provisioning failed. Re-run this script to retry."
        Remove-Item -Recurse -Force $stageDir -ErrorAction SilentlyContinue
        exit 1
    }

    # Clean up staging dir on Windows side
    Remove-Item -Recurse -Force $stageDir -ErrorAction SilentlyContinue

    # --- Step 4: Port forwarding + hostname alias (non-fatal, elevates for netsh/hosts) ---
    Write-Host "`nSetting up SSH port forwarding (port $sshPort) and hostname alias..."
    try {
        $hostsCmd = "`$h = '$env:SystemRoot\System32\drivers\etc\hosts'; " +
                    "`$entry = '127.0.0.1 $hostname'; " +
                    "(Get-Content `$h) -notmatch '^\s*[\d\.]+\s+$hostname\s*$' | Set-Content `$h; " +
                    "Add-Content `$h `$entry"
        $netshCmd = "netsh interface portproxy delete v4tov4 listenport=$sshPort listenaddress=0.0.0.0 2>`$null; " +
                    "netsh interface portproxy add v4tov4 listenport=$sshPort listenaddress=0.0.0.0 connectport=$sshPort connectaddress=localhost; " +
                    $hostsCmd
        Start-Process powershell -Verb RunAs -ArgumentList "-Command", $netshCmd -Wait -WindowStyle Hidden
        # Verify the rule was actually created
        $proxy = netsh interface portproxy show v4tov4 2>$null
        if ($proxy -match "$sshPort") {
            Write-Host "  Port forwarding configured."
        } else {
            Write-Host "  WARNING: Port forwarding rule not found. The elevated command may have failed."
            Write-Host "  You can still access the instance via: wsl -d $Name"
        }
    } catch [System.InvalidOperationException] {
        Write-Host "  WARNING: UAC prompt was declined. Port forwarding not configured."
        Write-Host "  You can still access the instance via: wsl -d $Name"
    } catch {
        Write-Host "  WARNING: Port forwarding failed: $_"
        Write-Host "  You can still access the instance via: wsl -d $Name"
    }

    # --- Step 5: Auto-start WSL instance at logon ---
    $taskName = "WSL-AutoStart-$Name"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "  Scheduled task '$taskName' already exists."
    } else {
        Write-Host "Registering scheduled task to auto-start '$Name' at logon..."
        try {
            $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $Name -- sleep infinity"
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $trigger.UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
            Write-Host "  Scheduled task '$taskName' registered."
        } catch {
            Write-Host "  WARNING: Could not register scheduled task: $_"
            Write-Host "  WSL instance won't auto-start. You can start it manually with: wsl -d $Name"
        }
    }

    # --- Step 6: Windows SSH config + agent ---
    $sshConfigPath = "$env:USERPROFILE\.ssh\config"
    $hostBlock = @"

Host $hostname
    HostName 127.0.0.1
    Port $sshPort
    User $user
    IdentityFile $vmKeyPath
"@
    # Remove any existing block for this host, then append
    if (Test-Path $sshConfigPath) {
        $content = Get-Content $sshConfigPath -Raw
        $content = $content -replace "(?m)\r?\nHost $hostname\r?\n(\s+\S[^\n]*\r?\n)*", ""
        Set-Content $sshConfigPath $content.TrimEnd()
    }
    Add-Content $sshConfigPath $hostBlock
    Write-Host "  SSH config updated: Host $hostname -> localhost:$sshPort"

    # Add VM access key to Windows SSH agent
    ssh-add $vmKeyPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  VM access key added to Windows SSH agent."
    } else {
        Write-Host "  WARNING: Could not add VM key to SSH agent. Run: ssh-add $vmKeyPath"
    }

    Write-Host ""
    Write-Host "Instance '$Name' is ready."
    Write-Host "  Enter:  wsl -d $Name"
    Write-Host "  SSH:    ssh $hostname"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Destroy
# ---------------------------------------------------------------------------

function Invoke-Destroy {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Error "Destroy requires -Name <instance>."
        exit 1
    }
    $config = Get-DevConfig
    $inst = Get-InstanceConfig -Config $config -InstanceName $Name
    $sshPort = $inst.SSHPort

    Write-Host "Destroying instance '$Name'..."
    # Remove auto-start scheduled task
    $taskName = "WSL-AutoStart-$Name"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "  Removed scheduled task '$taskName'"
    }
    wsl --unregister $Name 2>$null
    $instancePath = "$instanceRoot\$Name"
    if (Test-Path $instancePath) {
        Remove-Item -Recurse -Force $instancePath
    }
    # Remove VM access key pair
    $vmKeyPath = "$env:USERPROFILE\.ssh\id_ed25519_wsl_$Name"
    if (Test-Path $vmKeyPath) {
        Remove-Item -Force $vmKeyPath
        Write-Host "  Removed $vmKeyPath"
    }
    if (Test-Path "$vmKeyPath.pub") {
        Remove-Item -Force "$vmKeyPath.pub"
        Write-Host "  Removed $vmKeyPath.pub"
    }
    # Remove SSH config block
    $sshConfigPath = "$env:USERPROFILE\.ssh\config"
    if (Test-Path $sshConfigPath) {
        $content = Get-Content $sshConfigPath -Raw
        $content = $content -replace "(?m)\r?\nHost $Name\r?\n(\s+\S[^\n]*\r?\n)*", ""
        Set-Content $sshConfigPath $content.TrimEnd()
        Write-Host "  Removed SSH config for Host $Name"
    }
    # Remove key from Windows SSH agent
    ssh-add -d $vmKeyPath 2>$null
    try {
        $hostsCmd = "`$h = '$env:SystemRoot\System32\drivers\etc\hosts'; " +
                    "(Get-Content `$h) -notmatch '^\s*[\d\.]+\s+$Name\s*$' | Set-Content `$h"
        $netshCmd = "netsh interface portproxy delete v4tov4 listenport=$sshPort listenaddress=0.0.0.0 2>`$null; " +
                    $hostsCmd
        Start-Process powershell -Verb RunAs -ArgumentList "-Command", $netshCmd -Wait -WindowStyle Hidden
    } catch {
        Write-Host "  WARNING: Could not remove port forwarding/hosts entry (requires admin)."
    }
    Write-Host "Instance '$Name' destroyed."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

switch ($Action) {
    "create"  { Invoke-Create }
    "destroy" { Invoke-Destroy }
    "list"    { wsl --list --verbose }
}
