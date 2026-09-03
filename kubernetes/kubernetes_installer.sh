#!/usr/bin/env bash
#
# Kubernetes (kubectl) Installer Script
#
# Installs kubectl on Debian/Ubuntu (apt), RHEL/Fedora/CentOS (dnf) and
# Arch Linux (pacman, via a checksum-verified binary download).
# Optionally installs minikube.
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
LOG_FILE="/tmp/kubernetes_install_$(date +%Y%m%d_%H%M%S).log"

K8S_VERSION="${K8S_VERSION:-v1.37.0}"
MINIKUBE_VERSION="${MINIKUBE_VERSION:-v1.39.0}"
# pkgs.k8s.io repos are per minor version (v1.36), not per patch release.
K8S_CHANNEL="${K8S_VERSION%.*}"
APT_BASE_URL="https://pkgs.k8s.io/core:/stable:/${K8S_CHANNEL}/deb/"
RPM_BASE_URL="https://pkgs.k8s.io/core:/stable:/${K8S_CHANNEL}/rpm/"

# === Root check ===
Test-Root

# === kubectl already installed? ===
if command -v kubectl &>/dev/null; then
    Write-Log WARN "kubectl is already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    exit 0
fi

Write-Log INFO "Installing kubectl ${K8S_VERSION} (channel ${K8S_CHANNEL})..."

# === Install kubectl ===
PKG_MANAGER=$(Get-PkgMgr)
case $PKG_MANAGER in
    apt)
        Write-Log INFO "APT-based system detected."

        Invoke-Cmd apt-get update -y
        Invoke-Cmd apt-get install -y apt-transport-https ca-certificates curl gnupg

        install -d -m 755 /etc/apt/keyrings
        curl -fsSL "${APT_BASE_URL}Release.key" | \
            gpg --dearmour -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>>"$LOG_FILE" || \
            Stop-Script "Failed to download Kubernetes signing key."
        chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${APT_BASE_URL} /" \
            > /etc/apt/sources.list.d/kubernetes.list
        chmod 644 /etc/apt/sources.list.d/kubernetes.list

        Invoke-Cmd apt-get update -y
        Invoke-Cmd apt-get install -y kubectl
        ;;

    dnf)
        Write-Log INFO "DNF-based system detected."

        cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=${RPM_BASE_URL}
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${RPM_BASE_URL}repodata/repomd.xml.key
exclude=kube*
EOF

        Invoke-Cmd dnf install -y kubectl --disableexcludes=kubernetes
        ;;

    pacman)
        # No pkgs.k8s.io repo for Arch; install the pinned binary directly,
        # verified against its published checksum (same pattern as minikube).
        Write-Log INFO "Pacman-based system detected. Installing kubectl as a verified binary."

        KUBECTL_ARCH=$(uname -m)
        case "$KUBECTL_ARCH" in
            x86_64)  KUBECTL_ARCH="amd64" ;;
            aarch64) KUBECTL_ARCH="arm64" ;;
            *)       Stop-Script "Unsupported architecture for kubectl: ${KUBECTL_ARCH}" ;;
        esac

        KUBECTL_URL="https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"
        curl -fSL "${KUBECTL_URL}" -o kubectl 2>>"$LOG_FILE" || Stop-Script "Failed to download kubectl."
        curl -fSL "${KUBECTL_URL}.sha256" -o kubectl.sha256 2>>"$LOG_FILE" || Stop-Script "Failed to download kubectl checksum."
        echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - >>"$LOG_FILE" 2>&1 || Stop-Script "kubectl checksum verification failed."
        install kubectl /usr/local/bin/kubectl
        rm -f kubectl kubectl.sha256
        ;;

    *)
        Stop-Script "Unsupported system. Only Debian/Ubuntu (apt), RHEL/Fedora/CentOS (dnf) and Arch Linux (pacman) are supported."
        ;;
esac

Write-Log SUCCESS "kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"

# === Minikube (optional) ===
echo ""
read -rp "Install minikube as well? (y/n): " install_minikube
if [[ "$install_minikube" == "y" ]]; then
    Write-Log INFO "Installing minikube..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  MINIKUBE_BIN="minikube-linux-amd64" ;;
        aarch64) MINIKUBE_BIN="minikube-linux-arm64" ;;
        *)       Stop-Script "Unsupported architecture for minikube: ${ARCH}" ;;
    esac

    MINIKUBE_URL="https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/${MINIKUBE_BIN}"
    curl -fSL "${MINIKUBE_URL}" -o "${MINIKUBE_BIN}" 2>>"$LOG_FILE" || Stop-Script "Failed to download minikube."
    curl -fSL "${MINIKUBE_URL}.sha256" -o "${MINIKUBE_BIN}.sha256" 2>>"$LOG_FILE" || Stop-Script "Failed to download minikube checksum."
    echo "$(cat "${MINIKUBE_BIN}.sha256")  ${MINIKUBE_BIN}" | sha256sum -c - >>"$LOG_FILE" 2>&1 || Stop-Script "Minikube checksum verification failed."
    install "${MINIKUBE_BIN}" /usr/local/bin/minikube
    rm -f "${MINIKUBE_BIN}" "${MINIKUBE_BIN}.sha256"
    Write-Log SUCCESS "minikube installed: $(minikube version --short 2>/dev/null)"
fi

# === Summary ===
KUBECTL_VER=$(kubectl version --client --short 2>/dev/null || kubectl version --client)

echo -e "\n${GREEN}==============================================================${NC}"
Write-Log SUCCESS "Kubernetes installation complete!"
echo -e "${GREEN}==============================================================${NC}\n"
echo -e "${BLUE}kubectl:${NC}      ${GREEN}${KUBECTL_VER}${NC}"
echo -e "${BLUE}Log:${NC}          ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${BLUE}Verify:${NC}       kubectl version --client"
echo -e "${BLUE}Cluster:${NC}      kubectl cluster-info"
