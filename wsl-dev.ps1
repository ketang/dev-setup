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
    .\wsl-dev.ps1                              # Create instance (prompts for hostname)
    .\wsl-dev.ps1 -Name myhost                 # Create instance named "myhost"
    .\wsl-dev.ps1 -Action destroy -Name myhost # Destroy named instance
    .\wsl-dev.ps1 -Action list                 # List all WSL instances
#>

param(
    [ValidateSet("create", "destroy", "list")]
    [string]$Action = "create",

    [string]$Name = "dev"
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
        $required = @("User", "GitName", "GitEmail", "SSHKeyPath", "SetupRepo", "Repos", "Instances")
        $missing = $required | Where-Object { -not $cfg.Contains($_) -or [string]::IsNullOrWhiteSpace($cfg[$_]) }
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

    $sshKey = Prompt-Field $cfg "SSHKeyPath" "Path to SSH private key (e.g., C:\Users\$($cfg["User"])\.ssh\id_ed25519)" $cfg["SSHKeyPath"]
    if (-not (Test-Path $sshKey)) {
        Write-Error "SSH key not found at $sshKey"
        exit 1
    }
    if (-not (Test-Path "$sshKey.pub")) {
        Write-Error "SSH public key not found at $sshKey.pub"
        exit 1
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
    return [PSCustomObject]@{ SSHPort = $basePort + $existing }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    # Ensure Unix line endings (LF only) — bash chokes on \r\n
    $Content = $Content -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
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
    # If using the default "dev", prompt for a real hostname (unless "dev" already exists in config)
    if ($Name -eq "dev") {
        $hasExisting = $config.Instances.PSObject.Properties | Where-Object { $_.Name -eq "dev" }
        if (-not $hasExisting) {
            $Name = Read-Host "Hostname for this instance (used as WSL name and Linux hostname)"
            if ([string]::IsNullOrWhiteSpace($Name)) {
                Write-Error "Hostname is required."
                exit 1
            }
        }
    }

    $inst = Get-InstanceConfig -Config $config -InstanceName $Name
    $sshPort = $inst.SSHPort

    # Save instance config if new
    $existingInst = $config.Instances.PSObject.Properties | Where-Object { $_.Name -eq $Name }
    if (-not $existingInst) {
        $config.Instances | Add-Member -NotePropertyName $Name -NotePropertyValue ([PSCustomObject]@{ SSHPort = $sshPort }) -Force
        $cfg = [ordered]@{}
        foreach ($prop in $config.PSObject.Properties) { $cfg[$prop.Name] = $prop.Value }
        Save-Config $cfg
    }

    $hostname = $Name

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

    # Ensure user exists (idempotent — runs on both new and re-provision)
    Write-Host "Ensuring user '$user' exists..."
    wsl -d $Name -u root --exec bash -c "set -euo pipefail; id $user &>/dev/null || useradd -m -s /bin/bash $user; usermod -aG sudo $user; echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user; chmod 440 /etc/sudoers.d/$user; grep -q '^\[user\]' /etc/wsl.conf || printf '\n[user]\ndefault=$user\n' >> /etc/wsl.conf"

    # --- Step 2: Stage files ---
    $stageDir = "$instanceRoot\.stage"
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Copy-Item $config.SSHKeyPath "$stageDir\id_ed25519"
    Copy-Item "$($config.SSHKeyPath).pub" "$stageDir\id_ed25519.pub"

    $dotfilesRepo = if ($config.Dotfiles) { $config.Dotfiles } else { "" }

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
    }
    Write-Utf8NoBom "$stageDir\extra-vars.json" ($extraVars | ConvertTo-Json -Depth 5)

    # Two provision scripts:
    #   1. provision-root.sh — runs as root: installs SSH keys, apt packages, Ansible
    #   2. provision-user.sh — runs as the user: ssh-agent, git clones, Ansible
    #
    # Splitting avoids the sudo-strips-SSH_AUTH_SOCK problem.

    $rootScript = @"
#!/bin/bash
set -euo pipefail

USER_NAME="$user"
HOME_DIR="/home/`$USER_NAME"

# --- SSH keys ---
echo '=== Installing SSH keys ==='
mkdir -p `$HOME_DIR/.ssh
chmod 700 `$HOME_DIR/.ssh

cp /tmp/stage/id_ed25519     `$HOME_DIR/.ssh/id_ed25519
cp /tmp/stage/id_ed25519.pub `$HOME_DIR/.ssh/id_ed25519.pub
cp /tmp/stage/id_ed25519.pub `$HOME_DIR/.ssh/authorized_keys

chown -R `$USER_NAME:`$USER_NAME `$HOME_DIR/.ssh
chmod 600 `$HOME_DIR/.ssh/id_ed25519
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

# --- Start ssh-agent and load key ---
echo '=== Loading SSH key ==='
echo 'You may be prompted for your SSH key passphrase.'
echo ''
eval "`$(ssh-agent -s)" > /dev/null
ssh-add ~/.ssh/id_ed25519

# Verify the agent is working
echo ''
echo '=== Verifying SSH agent ==='
ssh-add -l
echo '  Agent has key loaded.'

# --- Clone dev-setup repo ---
echo ''
echo '=== Cloning dev-setup repo ==='
if [ -d ~/dev-setup ]; then
    echo '  Repo exists, pulling latest...'
    cd ~/dev-setup && git pull --ff-only
else
    echo "  Cloning `$SETUP_REPO ..."
    git clone --depth 1 "`$SETUP_REPO" ~/dev-setup
fi

# --- Dotfiles ---
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

# --- Run Ansible (needs sudo, but preserves SSH_AUTH_SOCK) ---
echo ''
echo '=== Running Ansible playbook ==='
cd ~/dev-setup
sudo --preserve-env=SSH_AUTH_SOCK ansible-playbook playbook.yml --diff -e @/tmp/stage/extra-vars.json

# --- Cleanup ---
kill `$SSH_AGENT_PID 2>/dev/null
sudo rm -rf /tmp/stage

echo ''
echo '========================================='
echo '  Provisioning complete.'
echo '========================================='
echo ''
echo 'Remaining manual steps:'
echo '  1. netbird up         (authenticate to mesh VPN)'
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

    # --- Step 4: Port forwarding (non-fatal, elevates for netsh) ---
    Write-Host "`nSetting up SSH port forwarding (port $sshPort)..."
    try {
        $netshCmd = "netsh interface portproxy delete v4tov4 listenport=$sshPort listenaddress=0.0.0.0 2>`$null; " +
                    "netsh interface portproxy add v4tov4 listenport=$sshPort listenaddress=0.0.0.0 connectport=$sshPort connectaddress=localhost"
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

    Write-Host ""
    Write-Host "Instance '$Name' is ready."
    Write-Host "  Enter:  wsl -d $Name"
    Write-Host "  SSH:    ssh -p $sshPort $user@localhost"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Destroy
# ---------------------------------------------------------------------------

function Invoke-Destroy {
    $config = Get-DevConfig
    $inst = Get-InstanceConfig -Config $config -InstanceName $Name
    $sshPort = $inst.SSHPort

    Write-Host "Destroying instance '$Name'..."
    wsl --unregister $Name 2>$null
    $instancePath = "$instanceRoot\$Name"
    if (Test-Path $instancePath) {
        Remove-Item -Recurse -Force $instancePath
    }
    try {
        $netshCmd = "netsh interface portproxy delete v4tov4 listenport=$sshPort listenaddress=0.0.0.0 2>`$null"
        Start-Process powershell -Verb RunAs -ArgumentList "-Command", $netshCmd -Wait -WindowStyle Hidden
    } catch {
        Write-Host "  WARNING: Could not remove port forwarding (requires admin)."
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
