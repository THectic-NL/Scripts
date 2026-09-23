#!/usr/bin/env bash
#
# Terraform Installer Script
#
# Installs Terraform from the HashiCorp repos on Debian/Ubuntu (apt) and
# RHEL/Fedora (dnf), and from the community repos on Arch Linux (pacman).
# Run as root.
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

# === Root check ===
Test-Root

Show-Intent "This script will install Terraform on this machine." \
    "Add the HashiCorp package repository (apt and dnf only)" \
    "On Arch-based systems this upgrades all system packages (pacman -Syu)" \
    "Install the terraform package"

# === Already installed? ===
if command -v terraform >/dev/null 2>&1; then
    Write-Log WARN "Terraform is already installed. Skipping installation."
    exit 0
fi

# === Install ===
PKG_MANAGER=$(Get-PkgMgr)
case $PKG_MANAGER in
    apt)
        Write-Log INFO "APT-based system detected."

        Write-Log INFO "Updating package lists..."
        Invoke-Cmd apt-get update -y

        Write-Log INFO "Installing prerequisites..."
        Invoke-Cmd apt-get install -y gnupg software-properties-common curl

        Write-Log INFO "Adding HashiCorp GPG key..."
        curl -fsSL https://apt.releases.hashicorp.com/gpg | \
            gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null || \
            Stop-Script "Failed to add HashiCorp GPG key."

        DISTRO_CODENAME=""
        if [[ -r /etc/os-release ]]; then
            # shellcheck disable=SC1091
            DISTRO_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
        fi
        [[ -n "$DISTRO_CODENAME" ]] || DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || true)
        [[ -n "$DISTRO_CODENAME" ]] || Stop-Script "Could not determine the distribution codename."
        Write-Log INFO "Adding HashiCorp repository for '${DISTRO_CODENAME}'..."
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${DISTRO_CODENAME} main" | \
            tee /etc/apt/sources.list.d/hashicorp.list || Stop-Script "Failed to add HashiCorp repository."

        Invoke-Cmd apt-get update -y
        Invoke-Cmd apt-get install -y terraform
        ;;

    dnf)
        Write-Log INFO "DNF-based system detected."

        Invoke-Cmd dnf install -y dnf-plugins-core

        # HashiCorp publishes separate repos for Fedora and RHEL-compatible distros
        case $(Get-OsId) in
            fedora) HASHICORP_REPO="https://rpm.releases.hashicorp.com/fedora/hashicorp.repo" ;;
            *)      HASHICORP_REPO="https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo" ;;
        esac

        # dnf5 (Fedora 41+) and dnf4 (RHEL) use different config-manager syntax
        dnf config-manager addrepo --overwrite --from-repofile="$HASHICORP_REPO" 2>/dev/null || \
            dnf config-manager --add-repo "$HASHICORP_REPO" || \
            Stop-Script "Failed to add HashiCorp repository."
        Invoke-Cmd dnf install -y terraform
        ;;

    pacman)
        Write-Log INFO "Pacman-based system detected."
        # HashiCorp has no vendor repo for Arch; this is the community package.
        Invoke-Cmd pacman -Syu --noconfirm terraform
        ;;

    *)
        Stop-Script "Unsupported package manager. Only apt, dnf and pacman are supported."
        ;;
esac

Write-Log SUCCESS "Terraform installation completed successfully!"
