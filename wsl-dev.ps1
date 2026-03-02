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

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

function Invoke-Create {
    $instancePath = "$instanceRoot\$Name"
    if (Test-Path $instancePath) {
        Write-Error "Instance '$Name' already exists at $instancePath. Destroy it first."
        exit 1
    }

    $config = Get-DevConfig
    $inst = Get-InstanceConfig -Config $config -InstanceName $Name
    $sshPort = $inst.SSHPort

    # Get base tarball from the official Store image (cached after first run)
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $tarball = "$cacheDir\ubuntu-noble.tar.gz"
    if (-not (Test-Path $tarball)) {
        Write-Host "Creating base image from official Ubuntu Store distro..."

        # Check if the Store distro is already installed
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

    # Create instance
    Write-Host "`nCreating WSL2 instance '$Name'..."
    New-Item -ItemType Directory -Path $instancePath -Force | Out-Null
    wsl --import $Name $instancePath $tarball --version 2
    if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }

    # Read SSH keys from host
    $sshPrivKey = (Get-Content $config.SSHKeyPath -Raw) -replace "'", "'\''"
    $sshPubKey  = (Get-Content "$($config.SSHKeyPath).pub" -Raw).Trim()

    $user      = $config.User
    $setupRepo = $config.SetupRepo

    # Initial setup: user, systemd, SSH key
    Write-Host "Configuring user and systemd..."
    wsl -d $Name --exec bash -c @"
set -euo pipefail

# Create user
useradd -m -s /bin/bash -G sudo $user 2>/dev/null || true
echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user
chmod 440 /etc/sudoers.d/$user

# Enable systemd, set default user
cat > /etc/wsl.conf << 'CONF'
[boot]
systemd=true
[user]
default=$user
CONF

# Install SSH keypair
su -l $user -c '
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat > ~/.ssh/id_ed25519 << "KEYEOF"
$sshPrivKey
KEYEOF
chmod 600 ~/.ssh/id_ed25519

echo "$sshPubKey" > ~/.ssh/id_ed25519.pub
echo "$sshPubKey" >> ~/.ssh/authorized_keys
chmod 644 ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys

ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
'
"@

    # Restart to activate systemd + default user
    Write-Host "Restarting instance for systemd..."
    wsl --terminate $Name
    Start-Sleep -Seconds 3

    # Build Ansible extra-vars JSON
    $reposJson = ($config.Repos | ForEach-Object { "`"$_`"" }) -join ","
    $extraVars = @"
{"user":"$user","git_name":"$($config.GitName)","git_email":"$($config.GitEmail)","ssh_port":$sshPort,"repos":[$reposJson]}
"@
    $extraVars = $extraVars -replace "'", "'\''"

    # Provision with Ansible
    Write-Host "`nInstalling Ansible and provisioning (this takes a few minutes)..."
    wsl -d $Name --exec bash -c @"
set -euo pipefail

echo '=== Installing git and Ansible ==='
sudo apt-get update -qq
sudo apt-get install -y -qq git software-properties-common > /dev/null
sudo add-apt-repository --yes --update ppa:ansible/ansible > /dev/null 2>&1
sudo apt-get install -y -qq ansible > /dev/null

echo '=== Cloning dev-setup repo ==='
git clone --depth 1 $setupRepo ~/dev-setup 2>/dev/null || \
    (cd ~/dev-setup && git pull --ff-only)

echo '=== Running Ansible playbook ==='
cd ~/dev-setup
ansible-playbook playbook.yml --diff -e '$extraVars'

echo ''
echo '========================================='
echo '  Provisioning complete.'
echo '========================================='
echo ''
echo 'Remaining manual steps:'
echo '  1. netbird up         (authenticate to mesh VPN)'
echo '  2. Verify: wsl -d $Name'
echo ''
"@

    # Set up Windows port forwarding for SSH
    Write-Host "Setting up SSH port forwarding (port $sshPort)..."
    netsh interface portproxy delete v4tov4 listenport=$sshPort listenaddress=0.0.0.0 2>$null
    netsh interface portproxy add v4tov4 `
        listenport=$sshPort listenaddress=0.0.0.0 `
        connectport=$sshPort connectaddress=localhost

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
