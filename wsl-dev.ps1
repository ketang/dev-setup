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
$rootfsUrl    = "https://cloud-images.ubuntu.com/wsl/noble/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz"
$instanceRoot = "$env:LOCALAPPDATA\WSLDev"
$cacheDir     = "$instanceRoot\.cache"
$configPath   = "$instanceRoot\config.json"

# ---------------------------------------------------------------------------
# Config — single file for all settings
# ---------------------------------------------------------------------------

function Get-DevConfig {
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        Write-Host "Using config from $configPath"
        return $cfg
    }

    Write-Host "First-time setup -- config is saved for future rebuilds.`n"

    $user     = Read-Host "Linux username"
    $gitName  = Read-Host "Git author name"
    $gitEmail = Read-Host "Git author email (for commits)"
    $sshKey   = Read-Host "Path to SSH private key (e.g., C:\Users\$user\.ssh\id_ed25519)"

    if (-not (Test-Path $sshKey)) {
        Write-Error "SSH key not found at $sshKey"
        exit 1
    }
    if (-not (Test-Path "$sshKey.pub")) {
        Write-Error "SSH public key not found at $sshKey.pub"
        exit 1
    }

    $setupRepo = Read-Host "dev-setup repo SSH URL (e.g., git@github.com:org/dev-setup.git)"

    $repos = @()
    Write-Host "`nProject repos to clone (org/repo format, empty line when done):"
    while ($true) {
        $repo = Read-Host "  repo"
        if ([string]::IsNullOrWhiteSpace($repo)) { break }
        $repos += $repo
    }

    $cfg = [ordered]@{
        User       = $user
        GitName    = $gitName
        GitEmail   = $gitEmail
        SSHKeyPath = $sshKey
        SetupRepo  = $setupRepo
        Repos      = $repos
        Instances  = [ordered]@{
            dev   = [ordered]@{ SSHPort = 2222 }
            "dev-2" = [ordered]@{ SSHPort = 2223 }
        }
    }

    New-Item -ItemType Directory -Path (Split-Path $configPath) -Force | Out-Null
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $configPath
    Write-Host "`nConfig saved to $configPath`n"
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

    # Download rootfs if not cached
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $tarball = "$cacheDir\ubuntu-noble.tar.gz"
    if (-not (Test-Path $tarball)) {
        Write-Host "Downloading Ubuntu 24.04 rootfs..."
        Invoke-WebRequest -Uri $rootfsUrl -OutFile $tarball -UseBasicParsing
    } else {
        Write-Host "Using cached rootfs."
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
