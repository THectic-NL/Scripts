#!/usr/bin/env bash
#
# Ansible Installer Script
#
# Installs Ansible (with its bundled ansible-core dependency) in a Python virtual environment.
# Note: 'ansible' is the community package; 'ansible-core' is the engine it ships with.
# Supports Debian/Ubuntu (apt), RHEL/Fedora (dnf) and Arch Linux (pacman).
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

# === Settings ===
VENV_DIR="${VENV_DIR:-/opt/ansible-env}"
LOG_FILE="/tmp/ansible_install_$(date +%Y%m%d_%H%M%S).log"

# === Root check ===
Test-Root

# === Package manager detection ===
PKG_MANAGER=$(Get-PkgMgr)
[[ "$PKG_MANAGER" != "unknown" ]] || Stop-Script "Unsupported distro. Only Debian/Ubuntu (apt), RHEL/Fedora (dnf) and Arch Linux (pacman) are supported."
Write-Log INFO "Package manager: ${PKG_MANAGER}"

# === Update system packages ===
Write-Log INFO "Updating system packages..."
case $PKG_MANAGER in
    apt)    Invoke-Cmd env DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
    dnf)    Invoke-Cmd dnf upgrade -y ;;
    pacman) Invoke-Cmd pacman -Syu --noconfirm ;;
esac

# === Install Python and pip ===
Write-Log INFO "Installing Python and pip..."
case $PKG_MANAGER in
    apt)    Invoke-Cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip ;;
    dnf)    Invoke-Cmd dnf install -y python3 python3-pip ;;
    pacman) Invoke-Cmd pacman -S --noconfirm --needed python python-pip ;;
esac

# === Find Python ===
PY_CMD=$(command -v python3 || true)
[[ -z "$PY_CMD" ]] && Stop-Script "python3 not found after install."
Write-Log INFO "Using Python: ${PY_CMD} ($("$PY_CMD" --version 2>&1))"

# === Create virtual environment ===
if [[ -d "$VENV_DIR" ]]; then
    Write-Log INFO "Virtual environment already exists at ${VENV_DIR}."
else
    Write-Log INFO "Creating virtual environment at ${VENV_DIR}..."
    mkdir -p "$(dirname "$VENV_DIR")"
    Invoke-Cmd "$PY_CMD" -m venv "$VENV_DIR"
fi

# === Install Ansible ===
Write-Log INFO "Installing Ansible (community package, bundles ansible-core)..."
(
    source "$VENV_DIR/bin/activate"
    command -v pip &>/dev/null || Stop-Script "pip not found in venv."
    Invoke-Cmd pip install --upgrade pip setuptools wheel
    Invoke-Cmd pip install ansible==14.4.0
) || Stop-Script "Failed during venv operations."

# === Global symlinks ===
Write-Log INFO "Creating symlinks in /usr/local/bin..."
for tool in ansible ansible-playbook ansible-galaxy ansible-doc ansible-config \
            ansible-console ansible-inventory ansible-vault; do
    if [[ -f "$VENV_DIR/bin/$tool" ]]; then
        ln -sf "$VENV_DIR/bin/$tool" "/usr/local/bin/$tool"
    else
        Write-Log WARN "${tool} not found in venv, skipping symlink."
    fi
done

# === Global ansible.cfg ===
Write-Log INFO "Writing /etc/ansible/ansible.cfg..."
mkdir -p /etc/ansible
VENV_SITE_PACKAGES=$("$VENV_DIR/bin/python" -c "import site; print(site.getsitepackages()[0])")
[[ -z "$VENV_SITE_PACKAGES" ]] && Stop-Script "Could not determine venv site-packages."
cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
collections_path = ${VENV_SITE_PACKAGES}/ansible_collections:/usr/share/ansible/collections
EOF
Write-Log SUCCESS "Wrote /etc/ansible/ansible.cfg"

# === Summary ===
PY_VER=$("$PY_CMD" --version 2>&1)
ANSIBLE_PKG_VER=$("$VENV_DIR/bin/pip" show ansible 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || true)
[[ -n "$ANSIBLE_PKG_VER" ]] && ANSIBLE_PKG_VER="ansible ${ANSIBLE_PKG_VER}" || ANSIBLE_PKG_VER="N/A"
ANSIBLE_CORE_VER=$("$VENV_DIR/bin/pip" show ansible-core 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || true)
[[ -n "$ANSIBLE_CORE_VER" ]] && ANSIBLE_CORE_VER="ansible-core ${ANSIBLE_CORE_VER}" || ANSIBLE_CORE_VER="N/A"

echo -e "\n${GREEN}==============================================================${NC}"
Write-Log SUCCESS "Ansible installation complete!"
echo -e "${GREEN}==============================================================${NC}\n"
echo -e "${BLUE}Python:${NC}       ${GREEN}${PY_VER}${NC}"
echo -e "${BLUE}Ansible:${NC}      ${GREEN}${ANSIBLE_PKG_VER}${NC}  (community package)"
echo -e "${BLUE}Core:${NC}         ${GREEN}${ANSIBLE_CORE_VER}${NC}  (engine)"
echo -e "${BLUE}Venv:${NC}         ${GREEN}${VENV_DIR}${NC}"
echo -e "${BLUE}Log:${NC}          ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${BLUE}Activate:${NC}     source ${VENV_DIR}/bin/activate"
echo -e "${BLUE}Uninstall:${NC}    sudo rm -rf ${VENV_DIR} /usr/local/bin/ansible* /etc/ansible"
