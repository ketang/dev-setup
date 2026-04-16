#!/usr/bin/env bash
# drift-check.sh — compare the Ansible-declared state of dev-setup against
# the actual state of this machine and report drift.
#
# Output buckets:
#   MISSING   — declared by the playbook but absent on the machine
#   EXTRA     — present on the machine but not declared (and we care about it)
#   MODIFIED  — declared and present, but in a different location/version/content
#
# Exit code: 0 if no drift, 1 if any drift reported.

set -u

PROJECT_DIR="${PROJECT_DIR:-/home/ketan/project/dev-setup}"
USER_NAME="${USER:-$(id -un)}"
HOME_DIR="${HOME:-/home/$USER_NAME}"

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
    C_CYA=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_CYA=''; C_DIM=''; C_RST=''
fi

missing=()
extra=()
modified=()

report_missing()  { missing+=("$1");  }
report_extra()    { extra+=("$1");    }
report_modified() { modified+=("$1"); }

# ---------- helpers ----------

declare -a NPM_GLOBAL_PACKAGES=(
    "@openai/codex"
    "playwright"
    "pnpm"
)

declare -a NPM_GLOBAL_IGNORED_PACKAGES=(
    "corepack"
    "npm"
)

declare -a PIPX_PACKAGES=(
    "headroom-ai"
)

declare -a BREW_PACKAGES=(
    "rtk"
)

apt_installed() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

snap_installed() {
    snap list "$1" >/dev/null 2>&1
}

file_exists() { [ -e "$1" ]; }

svc_active()  { systemctl is-active  --quiet "$1"; }
svc_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

check_package_inventory() {
    local manager="$1"
    local declared_name="$2"
    local installed_name="$3"
    local ignored_name="$4"

    local -n declared_packages="$declared_name"
    local -n installed_packages="$installed_name"
    local -n ignored_packages="$ignored_name"
    local package

    for package in "${declared_packages[@]}"; do
        array_contains "$package" "${installed_packages[@]}" \
            || report_missing "$manager package: $package"
    done

    for package in "${installed_packages[@]}"; do
        if array_contains "$package" "${ignored_packages[@]}"; then
            continue
        fi
        array_contains "$package" "${declared_packages[@]}" \
            || report_extra "$manager package: $package"
    done
}

# ---------- 1. apt packages ----------

declare -a APT_PACKAGES=(
    # base
    bind9-dnsutils bind9-host build-essential curl wget git git-lfs unzip jq bc
    file htop tmux ripgrep fd-find make cmake pkg-config libicu-dev ca-certificates
    gnupg lsb-release software-properties-common apt-transport-https keychain
    locales procps wamerican net-tools socat snapd bubblewrap xauth x11-apps xvfb feh
    xdg-utils strace pipx
    # docker
    docker-ce docker-ce-cli containerd.io docker-compose-plugin
    # github-cli
    gh
    # python
    python3 python3-pip python3-venv
    # rust system deps
    libz3-dev libclang-dev
    # ssh
    openssh-server
    # playwright browser deps
    libgtk-3-0t64 libgtk-4-1 libgraphene-1.0-0 libnotify4 libnss3 libxss1
    libxtst6 libatk-bridge2.0-0t64 libdrm2 libxcomposite1 libxdamage1 libxrandr2
    libgbm1 libpango-1.0-0 libcairo2 libcups2t64 libxkbcommon0 libatspi2.0-0t64
    libevent-2.1-7t64 libopus0 libgstreamer-plugins-base1.0-0
    libgstreamer-gl1.0-0 libgstreamer-plugins-bad1.0-0 gstreamer1.0-plugins-good
    flite1-dev libwebpdemux2 libavif16 libharfbuzz-icu0 libwebpmux3
    libwayland-server0 libmanette-0.2-0 libenchant-2-2 libhyphen0 libsecret-1-0
    libwoff1 libgles2 libx264-dev libasound2t64 fonts-liberation
    fonts-noto-color-emoji dbus
    # postgresql (version-specific, handled separately — libpq-dev stays here)
    libpq-dev
)

echo "${C_CYA}Checking apt packages...${C_RST}"
for pkg in "${APT_PACKAGES[@]}"; do
    apt_installed "$pkg" || report_missing "apt: $pkg"
done

# ---------- 2. postgresql version-pinned packages ----------

# Read declared postgresql_version from vars/main.yml
PG_VERSION=$(awk -F'"' '/^postgresql_version:/ {print $2}' "$PROJECT_DIR/vars/main.yml")
echo "${C_CYA}Checking postgresql-$PG_VERSION...${C_RST}"
for pkg in "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION"; do
    apt_installed "$pkg" || report_missing "apt: $pkg (declared pg version=$PG_VERSION)"
done
# Flag any installed server of a different major version
for newer in $(dpkg-query -W -f='${Package}\n' 'postgresql-[0-9]*' 2>/dev/null | grep -E '^postgresql-[0-9]+$'); do
    ver="${newer#postgresql-}"
    if [ "$ver" != "$PG_VERSION" ] && apt_installed "$newer"; then
        report_extra "apt: $newer installed (declared postgresql-$PG_VERSION)"
    fi
done

# ---------- 3. snap packages ----------

declare -a SNAP_PACKAGES=(glow doctl opentofu firefox chromium)
echo "${C_CYA}Checking snap packages...${C_RST}"
for s in "${SNAP_PACKAGES[@]}"; do
    snap_installed "$s" || report_missing "snap: $s"
done

# ---------- 4. Go toolchain + tools ----------

echo "${C_CYA}Checking Go toolchain...${C_RST}"
GO_VERSION=$(awk -F'"' '/^go_version:/ {print $2}' "$PROJECT_DIR/vars/main.yml")
if [ -x /usr/local/go/bin/go ]; then
    actual_go=$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
    if [ "$actual_go" != "$GO_VERSION" ]; then
        report_modified "go: /usr/local/go is $actual_go, declared $GO_VERSION"
    fi
else
    report_missing "go: /usr/local/go/bin/go (declared $GO_VERSION)"
fi

file_exists /etc/profile.d/go.sh || report_missing "file: /etc/profile.d/go.sh"

for bin in air golangci-lint bd; do
    [ -x "$HOME_DIR/go/bin/$bin" ] || report_missing "go tool: ~/go/bin/$bin"
done
[ -x "$HOME_DIR/go/bin/windows_amd64/npiperelay.exe" ] \
    || report_missing "go tool: ~/go/bin/windows_amd64/npiperelay.exe"

# ---------- 5. Rust ----------

echo "${C_CYA}Checking Rust...${C_RST}"
[ -x "$HOME_DIR/.cargo/bin/rustc" ]  || report_missing "rust: ~/.cargo/bin/rustc"
[ -x "$HOME_DIR/.cargo/bin/rustup" ] || report_missing "rust: ~/.cargo/bin/rustup"

# ---------- 6. Node.js, pnpm, npm globals ----------

echo "${C_CYA}Checking Node.js + npm globals...${C_RST}"
NODE_MAJOR=$(awk -F'"' '/^node_version:/ {print $2}' "$PROJECT_DIR/vars/main.yml")
PNPM_MAJOR=$(awk -F'"' '/^pnpm_version:/ {print $2}' "$PROJECT_DIR/vars/main.yml")

if command -v node >/dev/null 2>&1; then
    actual_node=$(node --version | sed 's/^v//;s/\..*//')
    [ "$actual_node" = "$NODE_MAJOR" ] \
        || report_modified "node: major $actual_node, declared $NODE_MAJOR"
else
    report_missing "node: not installed (declared v$NODE_MAJOR)"
fi

if command -v pnpm >/dev/null 2>&1; then
    actual_pnpm=$(pnpm --version 2>/dev/null | sed 's/\..*//')
    [ "$actual_pnpm" = "$PNPM_MAJOR" ] \
        || report_modified "pnpm: major $actual_pnpm, declared $PNPM_MAJOR"
else
    report_missing "pnpm: not installed (declared v$PNPM_MAJOR)"
fi

declare -a installed_npm_globals=()
if command -v npm >/dev/null 2>&1; then
    mapfile -t installed_npm_globals < <(
        npm ls -g --depth=0 --json 2>/dev/null \
            | jq -r '.dependencies // {} | keys[]' 2>/dev/null \
            | sort -u
    )
else
    report_missing "npm: not installed"
fi
check_package_inventory "npm" NPM_GLOBAL_PACKAGES installed_npm_globals NPM_GLOBAL_IGNORED_PACKAGES

# ---------- 7. Python packages ----------

echo "${C_CYA}Checking Python packages...${C_RST}"
python3 -c 'import yaml' 2>/dev/null || report_missing "python: pyyaml"

declare -a installed_pipx_packages=()
declare -a pipx_ignored_packages=()
if command -v pipx >/dev/null 2>&1; then
    mapfile -t installed_pipx_packages < <(
        pipx list --json 2>/dev/null \
            | jq -r '.venvs | keys[]' 2>/dev/null \
            | sort -u
    )
else
    report_missing "pipx: not installed"
fi
check_package_inventory "pipx" PIPX_PACKAGES installed_pipx_packages pipx_ignored_packages

# ---------- 8. Sysctl ----------

EXPECTED_PERF_PARANOID=1
actual_perf=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)
if [ "$actual_perf" != "$EXPECTED_PERF_PARANOID" ]; then
    report_modified "sysctl: kernel.perf_event_paranoid is $actual_perf, expected $EXPECTED_PERF_PARANOID"
fi
if [ ! -f /etc/sysctl.d/60-perf.conf ]; then
    report_missing "file: /etc/sysctl.d/60-perf.conf"
elif ! grep -q 'kernel.perf_event_paranoid' /etc/sysctl.d/60-perf.conf 2>/dev/null; then
    report_modified "sysctl: /etc/sysctl.d/60-perf.conf exists but missing perf_event_paranoid setting"
fi

# ---------- 9. Systemd services ----------

echo "${C_CYA}Checking systemd services...${C_RST}"
for svc in docker ssh postgresql netbird; do
    svc_enabled "$svc" || report_missing "systemd: $svc not enabled"
    svc_active  "$svc" || report_missing "systemd: $svc not active"
done
# ssh.socket must be disabled (uses hardcoded port 22)
if svc_enabled ssh.socket; then
    report_modified "systemd: ssh.socket is enabled (should be disabled)"
fi

# ---------- 9. Keyrings, profile.d, sshd config ----------

echo "${C_CYA}Checking files and keyrings...${C_RST}"
for f in \
    /etc/apt/keyrings/docker.asc \
    /etc/apt/keyrings/nodesource.asc \
    /etc/apt/keyrings/postgresql.asc \
    /etc/profile.d/homebrew.sh \
    /etc/profile.d/go.sh \
    /etc/profile.d/wslg.sh \
    /etc/profile.d/wsl-ssh-agent.sh
do
    file_exists "$f" || report_missing "file: $f"
done

for setting in \
    "Port 2222" \
    "PubkeyAuthentication yes" \
    "X11Forwarding yes" \
    "X11UseLocalhost no"
do
    grep -qE "^$setting\$" /etc/ssh/sshd_config 2>/dev/null \
        || report_modified "sshd_config: missing '$setting'"
done

# ---------- 10. User / groups / git config ----------

echo "${C_CYA}Checking user config...${C_RST}"
id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx docker \
    || report_missing "group: $USER_NAME not in 'docker'"

for item in user.name user.email init.defaultBranch pull.rebase; do
    git config --global --get "$item" >/dev/null 2>&1 \
        || report_missing "git config: $item unset"
done

# ~/.bash_profile: content drift vs the Ansible template
if [ -f "$HOME_DIR/.bash_profile" ]; then
    grep -q 'wsl-ssh-agent.sh' "$HOME_DIR/.bash_profile" \
        || report_modified "~/.bash_profile: does not source wsl-ssh-agent.sh"
else
    report_missing "file: ~/.bash_profile"
fi

# ---------- 11. dev-setup clone ----------

if [ -d "$HOME_DIR/project/dev-setup/.git" ]; then
    remote=$(git -C "$HOME_DIR/project/dev-setup" remote get-url origin 2>/dev/null)
    case "$remote" in
        *ketang/dev-setup*|*dev-setup*) : ;;
        *) report_modified "dev-setup clone: unexpected remote '$remote'" ;;
    esac
else
    report_missing "repo: ~/project/dev-setup"
fi

# ---------- 12. Claude Code + Codex (user-local installs) ----------

echo "${C_CYA}Checking Claude Code + Codex...${C_RST}"

# Claude: expected at ~/.local/bin/claude → ~/.local/share/claude/versions/<ver>
if [ -L "$HOME_DIR/.local/bin/claude" ] || [ -x "$HOME_DIR/.local/bin/claude" ]; then
    target=$(readlink -f "$HOME_DIR/.local/bin/claude" 2>/dev/null || echo "$HOME_DIR/.local/bin/claude")
    case "$target" in
        "$HOME_DIR"/.local/share/claude/versions/*) : ;;
        *) report_modified "claude: ~/.local/bin/claude points at unexpected target '$target'" ;;
    esac
else
    report_missing "claude: no user-local install at ~/.local/bin/claude"
fi

# Codex: expected at ~/.local/bin/codex (installed via npm with user prefix)
if [ -x "$HOME_DIR/.local/bin/codex" ]; then
    : # present
else
    report_missing "codex: no user-local install at ~/.local/bin/codex"
fi

# Homebrew: expected at the supported Linux prefix with shellenv available.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    :
else
    report_missing "homebrew: /home/linuxbrew/.linuxbrew/bin/brew"
fi

declare -a installed_brew_packages=()
declare -a brew_ignored_packages=()
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    mapfile -t installed_brew_packages < <(
        /home/linuxbrew/.linuxbrew/bin/brew list --formula 2>/dev/null | sort -u
    )
fi
check_package_inventory "brew" BREW_PACKAGES installed_brew_packages brew_ignored_packages

# ---------- 13. /home mount (optional, managed by Ansible fstab_entries) ----------

echo "${C_CYA}Checking /home mount...${C_RST}"
FSTAB_MARKER_BEGIN='# BEGIN ANSIBLE MANAGED - optional mounts'
FSTAB_MARKER_END='# END ANSIBLE MANAGED - optional mounts'

if mountpoint -q /home 2>/dev/null; then
    # /home is a separate mountpoint — verify fstab is Ansible-managed
    if grep -q "$FSTAB_MARKER_BEGIN" /etc/fstab 2>/dev/null; then
        # Markers exist — check the /home entry is inside them
        in_block=$(awk -v b="$FSTAB_MARKER_BEGIN" -v e="$FSTAB_MARKER_END" \
            '$0==b{f=1;next} $0==e{f=0} f && /\/home/' /etc/fstab)
        if [ -z "$in_block" ]; then
            report_modified "/home mount: Ansible markers exist but /home entry is outside them"
        fi
    else
        # No markers at all — check if there's a bare /home fstab entry
        if grep -qE '\s/home\s' /etc/fstab 2>/dev/null; then
            report_modified "/home mount: fstab entry exists but outside Ansible markers (re-run ansible with fstab_entries to fix)"
        else
            report_missing "/home mount: /home is mounted but has no fstab entry"
        fi
    fi
fi

# ---------- report ----------

echo
echo "========================================"
echo "          Drift Report"
echo "========================================"

print_bucket() {
    local label="$1" color="$2"; shift 2
    local -a items=("$@")
    if [ "${#items[@]}" -eq 0 ]; then
        printf "%s%s:%s none\n" "$color" "$label" "$C_RST"
        return
    fi
    printf "%s%s (%d):%s\n" "$color" "$label" "${#items[@]}" "$C_RST"
    for i in "${items[@]}"; do printf "  - %s\n" "$i"; done
}

if [ "${#missing[@]}" -gt 0 ]; then
    print_bucket "MISSING"  "$C_RED" "${missing[@]}"
else
    print_bucket "MISSING"  "$C_RED"
fi
echo
if [ "${#modified[@]}" -gt 0 ]; then
    print_bucket "MODIFIED" "$C_YEL" "${modified[@]}"
else
    print_bucket "MODIFIED" "$C_YEL"
fi
echo
if [ "${#extra[@]}" -gt 0 ]; then
    print_bucket "EXTRA"    "$C_YEL" "${extra[@]}"
else
    print_bucket "EXTRA"    "$C_YEL"
fi
echo

total=$(( ${#missing[@]} + ${#modified[@]} + ${#extra[@]} ))
if [ "$total" -eq 0 ]; then
    printf "%sNo drift detected.%s\n" "$C_GRN" "$C_RST"
    exit 0
else
    printf "%s%d drift item(s) detected.%s\n" "$C_YEL" "$total" "$C_RST"
    exit 1
fi
