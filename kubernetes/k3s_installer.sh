#!/usr/bin/env bash
#
# K3s Installer Script
#
# Installs K3s, the lightweight single-binary Kubernetes distribution, via the
# official installer at https://get.k3s.io. The installer bundles containerd,
# so it works on any systemd-based Linux without a distro package manager.
# Kubernetes role names are used (control plane / worker); K3s' own
# "server / agent" wording is mapped internally.
#
#   Control plane:  sudo ./<script> --control-plane
#   Worker:         sudo ./<script> --worker \
#                       --url https://<control-plane-ip>:6443 --token <token>
#
# This file is kept identical in THectic-NL/Scripts (kubernetes/k3s_installer.sh)
# and Stensel8/DevOps-Security (kubernetes/install-k3s.sh); change both.
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

# ============================================================================
# Usage
# ============================================================================

# Name as invoked, so help and join hints match however the file was saved.
SCRIPT_NAME=$(basename "$0")

Show-Usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <role> [options]

Roles:
  --control-plane   Install the first K3s node (control plane)
  --worker          Join this node to an existing cluster as a worker

Options (worker):
  --url HOST[:PORT] Control-plane API endpoint; port defaults to 6443
                    (an https:// prefix is accepted)
  --token VALUE     Join value from the control plane
                    (/var/lib/rancher/k3s/server/node-token)

Other:
  -h, --help        Show this help

After a --control-plane install the summary prints the join value and the
exact --worker command to run on the other nodes.

Examples:
  sudo ./${SCRIPT_NAME} --control-plane
  sudo ./${SCRIPT_NAME} --worker --url https://10.0.0.1:6443 --token K10abc...
EOF
}

# === Settings ===
LOG_FILE="/tmp/k3s_install_$(date +%Y%m%d_%H%M%S).log"

# Pinned K3s release (Renovate-managed). get.k3s.io reads INSTALL_K3S_VERSION.
K3S_VERSION="${K3S_VERSION:-v1.37.0+k3s1}"

# === Commands ===

# Usage: Install-ControlPlane
Install-ControlPlane() {
    Write-Log INFO "Installing K3s ${K3S_VERSION} (control plane)"

    # The kubeconfig is root-only by default, so 'kubectl' fails for the sudo
    # user. Hand it to that user's group (0640) instead of making it world-
    # readable; the flags end up in the unit, so they survive k3s restarts.
    local kube_user="${SUDO_USER:-}" kube_group=""
    local -a server_args=(server)
    if [[ -n "$kube_user" && "$kube_user" != root ]]; then
        kube_group=$(id -gn "$kube_user")
        server_args+=(--write-kubeconfig-mode 0640 --write-kubeconfig-group "$kube_group")
    fi

    # get.k3s.io is Rancher's official install path; it is a remote script.
    Write-Log WARN "Fetching and running the official installer from https://get.k3s.io"
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - "${server_args[@]}" >> "$LOG_FILE" 2>&1 || \
        Stop-Script "K3s install failed. Check log: $LOG_FILE"
    Invoke-Cmd systemctl enable k3s

    Write-Log INFO "Waiting for the node to become Ready..."
    local _ ready=false
    for _ in $(seq 1 60); do
        if k3s kubectl get node --no-headers 2>/dev/null | grep -q ' Ready '; then
            ready=true; break
        fi
        sleep 2
    done
    k3s kubectl get node || true
    $ready || Stop-Script "Node not Ready after 120s. Inspect: journalctl -u k3s -n 50. Join value, once fixed: /var/lib/rancher/k3s/server/node-token"

    local node_ip node_join k3s_ver
    node_ip=$(hostname -I | awk '{print $1}')
    node_join=$(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || true)
    k3s_ver=$(k3s --version 2>/dev/null | head -n1) || k3s_ver="N/A"

    echo -e "\n${GREEN}==============================================================${NC}"
    Write-Log SUCCESS "K3s control plane ready!"
    echo -e "${GREEN}==============================================================${NC}\n"
    echo -e "${BLUE}K3s:${NC}          ${GREEN}${k3s_ver}${NC}"
    echo -e "${BLUE}API URL:${NC}      ${GREEN}https://${node_ip}:6443${NC}"
    echo -e "${BLUE}kubeconfig:${NC}   ${GREEN}/etc/rancher/k3s/k3s.yaml${NC}${kube_group:+ (readable by group ${kube_group})}"
    echo -e "${BLUE}Log:${NC}          ${GREEN}${LOG_FILE}${NC}"
    echo ""
    echo -e "${BOLD}Join a worker (run on each worker node)${NC}"
    echo -e "  sudo ./${SCRIPT_NAME} --worker \\"
    echo -e "      --url https://${node_ip}:6443 --token ${node_join:-(see /var/lib/rancher/k3s/server/node-token)}"
    echo ""
    # The installer links kubectl to k3s, which reads /etc/rancher/k3s/k3s.yaml
    # by default. It skips the link when another kubectl already exists; that
    # one looks in ~/.kube/config, so it needs KUBECONFIG.
    local kubectl_prefix=""
    if [[ "$(readlink -f "$(command -v kubectl 2>/dev/null)" 2>/dev/null)" != "$(readlink -f "$(command -v k3s)")" ]]; then
        kubectl_prefix="KUBECONFIG=/etc/rancher/k3s/k3s.yaml "
    fi
    if [[ -n "$kube_group" ]]; then
        echo -e "${BOLD}Use kubectl (as ${kube_user}, no sudo needed)${NC}"
        echo -e "  ${kubectl_prefix}kubectl get nodes"
    else
        echo -e "${BOLD}Use kubectl${NC}"
        echo -e "  sudo ${kubectl_prefix}kubectl get nodes"
    fi
    echo ""
    echo -e "${YELLOW}Cloud/firewall:${NC} nodes must reach each other on TCP 6443, TCP 10250 and"
    echo -e "     UDP 8472 (on AWS: a self-referencing 'All traffic' security group rule),"
    echo -e "     plus inbound on any NodePort you expose (30000-32767)."
}

# Usage: Install-Worker <server-url-or-ip> <join-value>
Install-Worker() {
    local endpoint=$1 join=$2 url

    [[ -n "$endpoint" ]] || Stop-Script "Worker needs --url <control-plane-ip>:6443"
    [[ -n "$join"     ]] || Stop-Script "Worker needs --token <value from the control plane>"
    endpoint=${endpoint#https://}
    endpoint=${endpoint%/}
    [[ "$endpoint" == *:* ]] || endpoint="${endpoint}:6443"
    [[ "$endpoint" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || Stop-Script "The --url value should look like 10.0.0.1:6443."
    [[ "$join" =~ ^[A-Za-z0-9:._-]+$ ]] || Stop-Script "The --token value has unexpected characters."
    url="https://${endpoint}"

    # Fail fast when the API port is unreachable (on AWS: security group).
    # /ping is served unauthenticated by the K3s supervisor and returns "pong".
    Write-Log INFO "Checking that ${url} is reachable..."
    curl -ksf --max-time 5 "${url}/ping" 2>/dev/null | grep -q pong || \
        Stop-Script "Cannot reach ${url}/ping. Check the URL, that K3s runs on the control plane, and that the security group allows TCP 6443 from this node."

    Write-Log INFO "Installing K3s ${K3S_VERSION} (worker), joining ${url}"

    # get.k3s.io is Rancher's official install path; it is a remote script.
    Write-Log WARN "Fetching and running the official installer from https://get.k3s.io"
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$K3S_VERSION" K3S_URL="$url" K3S_TOKEN="$join" \
        sh -s - agent >> "$LOG_FILE" 2>&1 || \
        Stop-Script "K3s agent install failed. Check log: $LOG_FILE"
    Invoke-Cmd systemctl enable k3s-agent

    # The installer returns as soon as the service starts, not when the join
    # succeeds. The kubelet client cert is only issued after the server accepts
    # the token, so its presence means the node registered.
    Write-Log INFO "Waiting for the control plane to accept this node..."
    local _ joined=false
    for _ in $(seq 1 30); do
        if [[ -s /var/lib/rancher/k3s/agent/client-kubelet.crt ]]; then
            joined=true; break
        fi
        sleep 2
    done
    $joined || Stop-Script "Agent did not join within 60s. Inspect: journalctl -u k3s-agent -n 50 (wrong token, or UDP 8472 / TCP 10250 blocked?)"

    local k3s_ver
    k3s_ver=$(k3s --version 2>/dev/null | head -n1) || k3s_ver="N/A"

    echo -e "\n${GREEN}==============================================================${NC}"
    Write-Log SUCCESS "K3s worker joined!"
    echo -e "${GREEN}==============================================================${NC}\n"
    echo -e "${BLUE}K3s:${NC}          ${GREEN}${k3s_ver}${NC}"
    echo -e "${BLUE}Joined:${NC}       ${GREEN}${url}${NC}"
    echo -e "${BLUE}Log:${NC}          ${GREEN}${LOG_FILE}${NC}"
    echo ""
    echo -e "${BOLD}Verify on the control plane${NC}"
    echo -e "  kubectl get nodes        # this node should be Ready within ~30s"
    echo ""
    echo -e "${YELLOW}Note:${NC} kubectl does not work on a worker (no kubeconfig here, so it"
    echo -e "      falls back to localhost:8080). Manage the cluster from the control plane."
}

# ============================================================================
# Main Entry Point
# ============================================================================

ROLE=""
SERVER_URL=""
JOIN_VALUE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --control-plane)
            ROLE="control-plane"; shift ;;
        --worker)
            ROLE="worker"; shift ;;
        --url)
            SERVER_URL=${2:-}
            [[ -n "$SERVER_URL" ]] || Stop-Script "--url requires a value"
            shift 2 ;;
        --token)
            JOIN_VALUE=${2:-}
            [[ -n "$JOIN_VALUE" ]] || Stop-Script "--token requires a value"
            shift 2 ;;
        -h|--help)
            Show-Usage; exit 0 ;;
        *)
            Write-Log ERROR "Unknown argument: $1"; Show-Usage; exit 1 ;;
    esac
done

Test-Root
[[ -d /run/systemd/system ]] || Stop-Script "K3s requires a systemd-based system."
[[ "$(Get-PkgMgr)" != "unknown" ]] || \
    Write-Log WARN "Unrecognised package manager; continuing (K3s bundles its own runtime)."

if command -v k3s &>/dev/null; then
    Write-Log WARN "K3s is already installed: $(k3s --version | head -n1)"
    Write-Log INFO "Remove it first: k3s-uninstall.sh (control plane) or k3s-agent-uninstall.sh (worker)."
    exit 0
fi

case "$ROLE" in
    control-plane)
        Show-Intent "This script will install K3s ${K3S_VERSION} as a control plane node." \
            "Download and run the official K3s installer from get.k3s.io" \
            "Start a single-node Kubernetes cluster on this machine" \
            "Write a kubeconfig to /etc/rancher/k3s/k3s.yaml"
        Install-ControlPlane ;;
    worker)
        Show-Intent "This script will install K3s ${K3S_VERSION} as a worker node." \
            "Download and run the official K3s installer from get.k3s.io" \
            "Join this machine to the cluster at ${SERVER_URL:-<unset>}"
        Install-Worker "$SERVER_URL" "$JOIN_VALUE" ;;
    *)             Show-Usage; Stop-Script "Pass --control-plane or --worker." ;;
esac
