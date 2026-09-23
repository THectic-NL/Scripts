#!/usr/bin/env bash
#
# Docker Installer Script
#
# Installs Docker CE on Debian/Ubuntu (apt) and RHEL/Fedora/CentOS (dnf),
# and Docker from the community repos on Arch Linux (pacman). Arch derivatives
# such as CachyOS, Manjaro and EndeavourOS are recognised through ID_LIKE.
# Afterwards it enables the service, adds a user to the docker group and runs
# a hello-world smoke test.
# Falls back to get.docker.com on failure (disable with DOCKER_FALLBACK=0).
# Run as root.
#
# Environment overrides:
#   DOCKER_USER=<name>     user to add to the docker group (default: $SUDO_USER)
#   DOCKER_GROUP_ADD=0     leave the docker group alone
#   DOCKER_SMOKE_TEST=0    skip the hello-world container test
#   DOCKER_FALLBACK=0      never fall back to get.docker.com
#

set -euo pipefail

# ============================================================================
# Common Helper Functions
# The same helpers are used in every bash script in this repo, so the
# scripts stay consistent while remaining standalone single-file downloads.
# Function names follow the PowerShell Verb-Noun convention.
# ============================================================================

# shellcheck disable=SC2034  # not every script uses every color
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' \
         BLUE='\033[0;34m' PURPLE='\033[0;35m' BOLD='\033[1m' NC='\033[0m'

# Optional plain-text logfile; set LOG_FILE after this block to enable.
LOG_FILE="${LOG_FILE:-}"

# Usage: Write-Log <INFO|SUCCESS|WARN|ERROR|STEP> "message"
Write-Log() {
    local level=$1; shift
    local color=$NC
    case $level in
        INFO)    color=$BLUE ;;
        SUCCESS) color=$GREEN ;;
        WARN)    color=$YELLOW ;;
        ERROR)   color=$RED ;;
        STEP)    color=$PURPLE ;;
    esac
    if [[ $level == ERROR ]]; then
        echo -e "${color}[$level]${NC} $*" >&2
    else
        echo -e "${color}[$level]${NC} $*"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$level] $*" >> "$LOG_FILE"
    fi
}

# Usage: Stop-Script "fatal message"
Stop-Script() {
    Write-Log ERROR "$1"
    exit 1
}

# Usage: Test-Root  (exits unless running as root)
Test-Root() {
    [[ $EUID -eq 0 ]] || Stop-Script "Run as root (sudo)."
}

# Usage: mgr=$(Get-PkgMgr)  ->  apt | dnf | pacman | unknown
Get-PkgMgr() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# Usage: os_id=$(Get-OsId)  ->  lowercase /etc/os-release ID (ubuntu, debian,
# fedora, arch, ...) or "unknown". Call in $(...) so sourcing stays contained.
Get-OsId() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        local os_id="${ID:-unknown}"
        echo "${os_id,,}"
    else
        echo "unknown"
    fi
}

# Usage: id_like=$(Get-OsIdLike)  ->  lowercase /etc/os-release ID_LIKE, or an
# empty string. Call in $(...) so sourcing stays contained.
Get-OsIdLike() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        local id_like="${ID_LIKE:-}"
        echo "${id_like,,}"
    fi
}

# Usage: Test-ArchLike <os-id>  (true for Arch Linux and its derivatives)
# Derivatives ship their own ID (cachyos, manjaro, endeavouros, ...) and only
# advertise the family through ID_LIKE, so matching on ID alone is not enough.
Test-ArchLike() {
    case " $(Get-OsIdLike) " in
        *" arch "*) return 0 ;;
    esac
    case "$1" in
        arch|archarm|cachyos|manjaro|endeavouros|garuda|arcolinux|artix) return 0 ;;
    esac
    return 1
}

# Usage: Invoke-Cmd command [args...]
# Logs the command, sends its output to LOG_FILE when set, aborts on failure.
Invoke-Cmd() {
    Write-Log INFO "Executing: $*"
    if [[ -n "$LOG_FILE" ]]; then
        "$@" >> "$LOG_FILE" 2>&1 || Stop-Script "Command failed: '$*'. Check log: $LOG_FILE"
    else
        "$@" || Stop-Script "Command failed: '$*'"
    fi
}

# Usage: Show-Intent "headline" "detail" ["detail" ...]
# Prints what the script is about to do, before it changes anything. It never
# asks a question and never waits, so unattended runs (cloud-init, EC2 user
# data) are unaffected.
Show-Intent() {
    local headline=$1; shift
    local detail
    echo
    echo -e "${BOLD}${headline}${NC}"
    for detail in "$@"; do
        echo -e "  ${BLUE}-${NC} ${detail}"
    done
    echo
}

# === Settings ===
LOG_FILE="/tmp/docker_install_$(date +%Y%m%d_%H%M%S).log"
CODENAME=""
DOCKER_USER="${DOCKER_USER:-${SUDO_USER:-}}"
DOCKER_GROUP_ADD="${DOCKER_GROUP_ADD:-1}"
DOCKER_SMOKE_TEST="${DOCKER_SMOKE_TEST:-1}"

# Usage: Enable-DockerService
# docker.service starts the daemon at boot; docker.socket would start it on
# first use instead. Only one of the two should be enabled.
Enable-DockerService() {
    Write-Log STEP "Enabling and starting Docker service..."
    # /run/systemd/system only exists when systemd is the running init, so this
    # also covers containers and WSL images that merely ship the systemctl binary.
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        Write-Log WARN "systemd is not the running init (container or WSL?)."
        Write-Log WARN "Start the daemon yourself with 'dockerd'."
        return 0
    fi
    Invoke-Cmd systemctl enable docker.service
    Invoke-Cmd systemctl start docker.service
}

# Usage: Add-DockerGroupMember <username>
# Lets the user run docker without sudo. Never fatal: a failed group edit
# should not undo a working installation.
Add-DockerGroupMember() {
    local user=$1

    if [[ "$DOCKER_GROUP_ADD" != "1" ]]; then
        Write-Log INFO "Skipping docker group setup (DOCKER_GROUP_ADD=0)."
        return 0
    fi
    if [[ -z "$user" ]]; then
        Write-Log WARN "No target user known; run via sudo or set DOCKER_USER=<name>."
        Write-Log WARN "Add one later with: usermod -aG docker <name>"
        return 0
    fi
    if [[ "$user" == "root" ]]; then
        Write-Log INFO "Target user is root; docker group membership is not needed."
        return 0
    fi
    if ! id -u "$user" >/dev/null 2>&1; then
        Write-Log WARN "User '${user}' does not exist. Skipping docker group setup."
        return 0
    fi

    Write-Log STEP "Configuring docker group membership for '${user}'..."
    if ! getent group docker >/dev/null 2>&1; then
        Invoke-Cmd groupadd docker
    fi
    if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
        Write-Log SUCCESS "User '${user}' is already in the docker group."
        return 0
    fi
    if usermod -aG docker "$user" >> "$LOG_FILE" 2>&1; then
        Write-Log SUCCESS "Added '${user}' to the docker group."
        Write-Log WARN "Members of the docker group have root-equivalent access to this host."
        Write-Log WARN "Log out and back in, or run 'newgrp docker', to pick up the group."
    else
        Write-Log WARN "Could not add '${user}' to the docker group. Check log: $LOG_FILE"
    fi
}

# Usage: Test-DockerInstall
# Verifies the daemon answers and optionally runs the hello-world container.
# Warns instead of failing: an unreachable registry is not an install error.
Test-DockerInstall() {
    Write-Log STEP "Verifying the installation..."
    if ! docker info >> "$LOG_FILE" 2>&1; then
        Write-Log WARN "'docker info' failed; the daemon is not reachable yet."
        Write-Log WARN "Inspect it with: systemctl status docker.service"
        return 0
    fi
    Write-Log SUCCESS "Docker daemon is reachable."

    if [[ "$DOCKER_SMOKE_TEST" != "1" ]]; then
        Write-Log INFO "Skipping the hello-world test (DOCKER_SMOKE_TEST=0)."
        return 0
    fi
    Write-Log INFO "Running the hello-world test container..."
    if docker run --rm hello-world >> "$LOG_FILE" 2>&1; then
        Write-Log SUCCESS "hello-world ran successfully."
    else
        Write-Log WARN "hello-world failed (no network, or registry unreachable)."
        Write-Log WARN "Check log: $LOG_FILE"
    fi
}

# Usage: Show-Summary
Show-Summary() {
    local docker_ver group_state="not configured"
    docker_ver=$(docker --version 2>/dev/null) || docker_ver="N/A"
    if [[ -n "$DOCKER_USER" ]] && id -nG "$DOCKER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        group_state="${DOCKER_USER} is in group docker"
    fi

    echo -e "\n${GREEN}==============================================================${NC}"
    Write-Log SUCCESS "Docker installation complete!"
    echo -e "${GREEN}==============================================================${NC}\n"
    echo -e "${BLUE}Docker:${NC}       ${GREEN}${docker_ver}${NC}"
    echo -e "${BLUE}Distro:${NC}       ${GREEN}${DISTRO} (${CODENAME:-n/a})${NC}"
    echo -e "${BLUE}Group:${NC}        ${GREEN}${group_state}${NC}"
    echo -e "${BLUE}Log:${NC}          ${GREEN}${LOG_FILE}${NC}"
    echo ""
    echo -e "${BLUE}Socket start:${NC} systemctl disable --now docker.service && systemctl enable --now docker.socket"
    echo -e "${BLUE}Rootless:${NC}     dockerd-rootless-setuptool.sh install"
    echo -e "${BLUE}Uninstall:${NC}    sudo apt-get remove docker-ce docker-ce-cli containerd.io  # apt"
    echo -e "              sudo dnf remove docker-ce docker-ce-cli containerd.io     # dnf"
    echo -e "              sudo pacman -Rns docker docker-buildx docker-compose      # pacman"
}

# === Fallback ===
Invoke-FallbackInstaller() {
    trap - ERR
    if [[ "${DOCKER_FALLBACK:-1}" != "1" ]]; then
        Stop-Script "Installation failed and fallback is disabled (DOCKER_FALLBACK=0)."
    fi
    # get.docker.com has no Arch support, so retrying there only fails again.
    if [[ "$(Get-PkgMgr)" == "pacman" ]]; then
        Stop-Script "Installation failed. get.docker.com does not support Arch-based systems; install the 'docker' package manually. Check log: $LOG_FILE"
    fi
    Write-Log WARN "Installation failed. Falling back to get.docker.com..."
    Write-Log WARN "This runs an unverified convenience script from get.docker.com."
    curl -fsSL https://get.docker.com | bash || Stop-Script "Fallback installer also failed."
    Enable-DockerService
    Add-DockerGroupMember "$DOCKER_USER"
    Test-DockerInstall
    Show-Summary
    exit 0
}
trap 'Invoke-FallbackInstaller' ERR

# === Root check ===
Test-Root

Show-Intent "This script will install Docker on this machine." \
    "Install Docker Engine, Buildx and Compose from your distro's repositories" \
    "On Arch-based systems this upgrades all system packages (pacman -Syu)" \
    "Enable and start docker.service" \
    "Add '${DOCKER_USER:-<none>}' to the docker group (root-equivalent access)" \
    "Run a hello-world test container"

# === Docker already installed? ===
# Still run the post-install steps, so re-running fixes a missing group entry.
DOCKER_PRESENT=0
if command -v docker &>/dev/null; then
    Write-Log WARN "Docker is already installed. Skipping the package install."
    docker --version
    DOCKER_PRESENT=1
fi

# === Detect distro ===
DISTRO=$(Get-OsId)
[[ "$DISTRO" != "unknown" ]] || Stop-Script "Cannot read /etc/os-release. Unsupported system."
Write-Log INFO "Detected distribution: ${DISTRO}"

# === Install ===
if [[ $DOCKER_PRESENT -eq 0 ]]; then
    case "$DISTRO" in
        ubuntu|debian)
            Write-Log INFO "APT-based system: ${DISTRO}"

            if command -v lsb_release &>/dev/null; then
                CODENAME=$(lsb_release -cs)
            else
                CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2)
            fi
            Write-Log INFO "Codename: ${CODENAME}"

            # Remove any broken/stale repo entry and GPG key from earlier attempts
            Write-Log INFO "Cleaning up stale Docker repo entries..."
            rm -f /etc/apt/sources.list.d/docker.list
            rm -f /etc/apt/keyrings/docker.gpg

            Invoke-Cmd apt-get update -y
            Invoke-Cmd apt-get install -y ca-certificates curl gnupg

            mkdir -p /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" | \
                gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>>"$LOG_FILE" || \
                Stop-Script "Failed to add Docker GPG key."
            chmod a+r /etc/apt/keyrings/docker.gpg

            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" \
                > /etc/apt/sources.list.d/docker.list

            Invoke-Cmd apt-get update -y
            Invoke-Cmd apt-get install -y docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin
            ;;

        fedora|rhel|centos)
            Write-Log INFO "DNF-based system: ${DISTRO}"
            command -v dnf &>/dev/null || Stop-Script "dnf not found. Only dnf is supported for ${DISTRO}."

            Invoke-Cmd dnf install -y dnf-plugins-core
            rm -f /etc/yum.repos.d/docker-ce.repo

            Invoke-Cmd dnf config-manager addrepo \
                --from-repofile="https://download.docker.com/linux/${DISTRO}/docker-ce.repo"

            Invoke-Cmd dnf install -y docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin
            ;;

        *)
            Test-ArchLike "$DISTRO" || Stop-Script "Unsupported distribution: ${DISTRO}. Only Debian/Ubuntu (apt), RHEL/Fedora/CentOS (dnf) and Arch Linux (pacman) are supported."

            Write-Log INFO "Pacman-based system: ${DISTRO}"
            command -v pacman &>/dev/null || Stop-Script "pacman not found on Arch-like system ${DISTRO}."
            # Docker has no vendor repo for Arch; these are the community packages.
            # -Syu rather than -Sy: partial upgrades break Arch-based systems.
            # docker-compose here is Compose v2, exposed as 'docker compose' too.
            Invoke-Cmd pacman -Syu --noconfirm docker docker-buildx docker-compose
            ;;
    esac
fi

# Installation succeeded; from here on failures must not trigger the fallback.
trap - ERR

# === Post-install ===
Enable-DockerService
Add-DockerGroupMember "$DOCKER_USER"
Test-DockerInstall
Show-Summary
