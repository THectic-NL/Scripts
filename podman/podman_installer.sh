#!/usr/bin/env bash
#
# Podman Installer Script (standalone)
#
# Installs or removes Podman from the distro repos on Debian/Ubuntu (apt),
# RHEL/Fedora (dnf) and Arch Linux (pacman).
# https://podman.io/docs/installation
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

# Usage: Test-MutableOs "<tool>" "<alternative>" ["<alternative>" ...]
# Exits when the root filesystem is image-based or read-only. A package manager
# install there is either refused outright (rpm-ostree) or discarded on the next
# system update, so stop with alternatives rather than failing halfway through.
Test-MutableOs() {
    local tool=$1; shift
    local kind="" alt
    if [[ -f /run/ostree-booted ]]; then
        # The marker rpm-ostree itself uses. Do not test /run/ostree: that
        # directory also shows up on ordinary systems.
        kind="an ostree/bootc image (Fedora Silverblue, Kinoite, Bazzite, CoreOS)"
    elif command -v transactional-update >/dev/null 2>&1; then
        kind="a transactional-update system (openSUSE MicroOS, Aeon)"
    elif [[ -e /etc/NIXOS ]]; then
        kind="NixOS, where packages belong in your configuration.nix"
    elif command -v steamos-readonly >/dev/null 2>&1; then
        kind="SteamOS, whose root filesystem is read-only by default"
    elif findmnt -no OPTIONS /usr 2>/dev/null | grep -qw ro; then
        kind="a system with a read-only /usr"
    else
        return 0
    fi
    Write-Log ERROR "${tool} cannot be installed with the system package manager here."
    Write-Log WARN  "Detected ${kind}."
    Write-Log WARN  "Installs would be refused, or lost on the next system update."
    if [[ $# -gt 0 ]]; then
        Write-Log INFO "Use one of these instead:"
        for alt in "$@"; do
            Write-Log INFO "  - ${alt}"
        done
    fi
    exit 1
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

Show-Usage() {
    echo "Usage: $0 [install|remove]"
    exit 1
}

Install-Podman() {
    Write-Log STEP "Installing Podman..."
    if command -v podman &>/dev/null; then
        Write-Log SUCCESS "Podman is already installed."
        return 0
    fi
    case $(Get-PkgMgr) in
        apt)
            Write-Log INFO "APT-based system detected. Installing via apt."
            Invoke-Cmd apt-get update
            Invoke-Cmd apt-get install -y podman
            ;;
        dnf)
            Write-Log INFO "DNF-based system detected. Installing via dnf."
            Invoke-Cmd dnf -y install podman
            ;;
        pacman)
            Write-Log INFO "Pacman-based system detected. Installing via pacman."
            # -Syu rather than -Sy: partial upgrades break Arch-based systems.
            Invoke-Cmd pacman -Syu --noconfirm podman
            ;;
        *)
            Stop-Script "Unsupported system. Please install Podman manually."
            ;;
    esac
    Write-Log SUCCESS "Podman installation complete."
}

Remove-Podman() {
    Write-Log STEP "Removing Podman..."
    if ! command -v podman &>/dev/null; then
        Write-Log WARN "Podman is not installed."
        return 0
    fi
    case $(Get-PkgMgr) in
        apt)
            Invoke-Cmd apt-get remove -y podman
            ;;
        dnf)
            Invoke-Cmd dnf -y remove podman
            ;;
        pacman)
            Invoke-Cmd pacman -Rns --noconfirm podman
            ;;
        *)
            Stop-Script "Unsupported system. Please remove Podman manually."
            ;;
    esac
    Write-Log SUCCESS "Podman removal complete."
}

Invoke-Main() {
    if [[ $# -ne 1 ]]; then
        Show-Usage
    fi
    case "$1" in
        install)
            Test-MutableOs "Podman" \
                "Podman is already part of the base image on most image-based systems" \
                "Layer it onto the image: rpm-ostree install podman"
            Show-Intent "This script will install Podman on this machine." \
                "Install the podman package from your distro's repositories" \
                "On Arch-based systems this upgrades all system packages (pacman -Syu)"
            Install-Podman ;;
        remove)
            Show-Intent "This script will remove Podman from this machine." \
                "Uninstall the podman package and its dependencies"
            Remove-Podman ;;
        *)       Show-Usage ;;
    esac
}

Invoke-Main "$@"
