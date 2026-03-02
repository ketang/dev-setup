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
    .\wsl-dev.ps1                              # Create default "dev" instance
    .\wsl-dev.ps1 -Name dev-2                  # Create a second instance
    .\wsl-dev.ps1 -Action destroy              # Destroy default instance
    .\wsl-dev.ps1 -Action destroy -Name dev-2  # Destroy named instance
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
        $cfg["Instances"] = [ordered]@{
            dev     = [ordered]@{ SSHPort = 2222 }
            "dev-2" = [ordered]@{ SSHPort = 2223 }
        }
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
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Check if a WSL2 instance exists (registered)
# ---------------------------------------------------------------------------

function Test-WslInstance {
    param([string]$InstanceName)
    $list = wsl --list --quiet 2>$null
    return ($list | Where-Object { $_ -match "^${InstanceName}$" }) -ne $null
}

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

function Invoke-Create {
    $config = Get-DevConfig
    $inst = Get-InstanceConfig -Config $config -InstanceName $Name
    $sshPort = $inst.SSHPort
    $user = $config.User
    $setupRepo = $config.SetupRepo

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

        # Create user and enable systemd
        Write-Host "Configuring user and systemd..."
        wsl -d $Name --exec bash -c "set -euo pipefail; useradd -m -s /bin/bash -G sudo $user 2>/dev/null || true; echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user; chmod 440 /etc/sudoers.d/$user; printf '[boot]\nsystemd=true\n[user]\ndefault=$user\n' > /etc/wsl.conf"

        # Restart to activate systemd + default user
        Write-Host "Restarting instance for systemd..."
        wsl --terminate $Name
        Start-Sleep -Seconds 3
    }

    # --- Step 2: Stage files ---
    $stageDir = "$instanceRoot\.stage"
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Copy-Item $config.SSHKeyPath "$stageDir\id_ed25519"
    Copy-Item "$($config.SSHKeyPath).pub" "$stageDir\id_ed25519.pub"

    $extraVars = [ordered]@{
        user      = $user
        git_name  = $config.GitName
        git_email = $config.GitEmail
        ssh_port  = $sshPort
        repos     = @($config.Repos | ForEach-Object { $_ })
    }
    Write-Utf8NoBom "$stageDir\extra-vars.json" ($extraVars | ConvertTo-Json -Depth 5)

    # The provision script uses ssh-agent so passphrase-protected keys work.
    # ssh-add prompts interactively; if it fails the script exits cleanly
    # and the user can re-run.
    $provisionScript = @"
#!/bin/bash
set -euo pipefail

USER_NAME="$user"
SETUP_REPO="$setupRepo"
HOME_DIR="/home/`$USER_NAME"

# --- SSH keys ---
echo '=== Installing SSH keys ==='
sudo -u `$USER_NAME mkdir -p `$HOME_DIR/.ssh
sudo -u `$USER_NAME chmod 700 `$HOME_DIR/.ssh

cp /tmp/stage/id_ed25519     `$HOME_DIR/.ssh/id_ed25519
cp /tmp/stage/id_ed25519.pub `$HOME_DIR/.ssh/id_ed25519.pub
cp /tmp/stage/id_ed25519.pub `$HOME_DIR/.ssh/authorized_keys

chown `$USER_NAME:`$USER_NAME `$HOME_DIR/.ssh/*
chmod 600 `$HOME_DIR/.ssh/id_ed25519
chmod 644 `$HOME_DIR/.ssh/id_ed25519.pub `$HOME_DIR/.ssh/authorized_keys

sudo -u `$USER_NAME ssh-keyscan github.com >> `$HOME_DIR/.ssh/known_hosts 2>/dev/null

# --- Verify SSH key works with GitHub ---
echo '=== Verifying SSH key with GitHub ==='
echo 'You may be prompted for your SSH key passphrase.'
echo ''

# Start ssh-agent and add the key (prompts for passphrase if needed)
eval "`$(sudo -u `$USER_NAME ssh-agent -s)"
sudo -u `$USER_NAME SSH_AUTH_SOCK="`$SSH_AUTH_SOCK" ssh-add `$HOME_DIR/.ssh/id_ed25519

# Test the connection
if ! sudo -u `$USER_NAME SSH_AUTH_SOCK="`$SSH_AUTH_SOCK" ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo ''
    echo 'ERROR: SSH authentication to GitHub failed.'
    echo 'Check that your SSH key is added to your GitHub account.'
    echo 'Re-run this script to try again.'
    kill `$SSH_AGENT_PID 2>/dev/null
    exit 1
fi
echo '  GitHub SSH authentication successful.'

# --- Ansible ---
echo ''
echo '=== Installing git and Ansible ==='
apt-get update -qq
apt-get install -y -qq git software-properties-common > /dev/null
add-apt-repository --yes --update ppa:ansible/ansible > /dev/null 2>&1
apt-get install -y -qq ansible > /dev/null

# --- Clone dev-setup repo ---
echo '=== Cloning dev-setup repo ==='
if [ -d `$HOME_DIR/dev-setup ]; then
    echo '  Repo exists, pulling latest...'
    cd `$HOME_DIR/dev-setup
    sudo -u `$USER_NAME SSH_AUTH_SOCK="`$SSH_AUTH_SOCK" git pull --ff-only
else
    echo "  Cloning `$SETUP_REPO ..."
    sudo -u `$USER_NAME SSH_AUTH_SOCK="`$SSH_AUTH_SOCK" git clone --depth 1 "`$SETUP_REPO" `$HOME_DIR/dev-setup
fi

# --- Run Ansible ---
echo '=== Running Ansible playbook ==='

# Export SSH_AUTH_SOCK so Ansible's git module can use it for cloning repos
export SSH_AUTH_SOCK

cd `$HOME_DIR/dev-setup
ansible-playbook playbook.yml --diff -e @/tmp/stage/extra-vars.json

# --- Cleanup ---
kill `$SSH_AGENT_PID 2>/dev/null
rm -rf /tmp/stage

echo ''
echo '========================================='
echo '  Provisioning complete.'
echo '========================================='
echo ''
echo 'Remaining manual steps:'
echo '  1. netbird up         (authenticate to mesh VPN)'
echo ''
"@
    Write-Utf8NoBom "$stageDir\provision.sh" $provisionScript

    # --- Step 3: Copy staging files in and run provisioning ---
    Write-Host "`nProvisioning (this takes a few minutes)..."

    $wslStageDir = wsl -d $Name --exec wslpath -a "$stageDir"
    wsl -d $Name --exec bash -c "cp -r $wslStageDir /tmp/stage && chmod +x /tmp/stage/provision.sh && sudo -E /tmp/stage/provision.sh"

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Provisioning failed. The instance '$Name' still exists."
        Write-Host "Fix the issue and re-run this script to retry."
        Write-Host "  Or destroy it:  .\wsl-dev.ps1 -Action destroy -Name $Name"
        # Clean up staging dir
        Remove-Item -Recurse -Force $stageDir -ErrorAction SilentlyContinue
        exit 1
    }

    # Clean up staging dir on Windows side
    Remove-Item -Recurse -Force $stageDir -ErrorAction SilentlyContinue

    # --- Step 4: Port forwarding (non-fatal) ---
    Write-Host "`nSetting up SSH port forwarding (port $sshPort)..."
    try {
        netsh interface portproxy delete v4tov4 listenport=$sshPort listenaddress=0.0.0.0 2>$null
        netsh interface portproxy add v4tov4 `
            listenport=$sshPort listenaddress=0.0.0.0 `
            connectport=$sshPort connectaddress=localhost
    } catch {
        Write-Host "  WARNING: Port forwarding requires admin. Run as Administrator to enable SSH access."
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
    netsh interface portproxy delete v4tov4 `
        listenport=$sshPort listenaddress=0.0.0.0 2>$null
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
