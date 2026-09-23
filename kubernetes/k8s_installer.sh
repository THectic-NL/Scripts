#!/usr/bin/env bash
#
# Kubernetes (kubeadm) Installer Script
#
# Builds an upstream Kubernetes cluster with kubeadm, containerd and the
# Flannel CNI. Both roles get the same node prep (swap off, kernel modules,
# sysctl, containerd, pinned kubeadm/kubelet/kubectl); --control-plane then
# runs "kubeadm init" + Flannel, --worker runs "kubeadm join".
#
#   Control plane:  sudo ./<script> --control-plane
#   Worker:         sudo ./<script> --worker --url <control-plane-ip>:6443 \
#                       --token <token> --ca-cert-hash sha256:<hash>
#
# Targets Ubuntu/Debian. For other systemd distros use the K3s installer.
# This file is kept identical in THectic-NL/Scripts (kubernetes/k8s_installer.sh)
# and Stensel8/DevOps-Security (kubernetes/install-k8s.sh); change both.
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

# ============================================================================
# Usage
# ============================================================================

# Name as invoked, so help and join hints match however the file was saved.
SCRIPT_NAME=$(basename "$0")

Show-Usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} <role> [options]

Roles:
  --control-plane       Prep the node, run "kubeadm init" and install Flannel
  --worker              Prep the node and join an existing cluster as a worker

Options (worker):
  --url HOST[:PORT]     Control-plane API endpoint; port defaults to 6443
                        (an https:// prefix is accepted and stripped)
  --token VALUE         Bootstrap token from the control plane (valid 24h)
  --ca-cert-hash VALUE  sha256:<hash> of the cluster CA

Other:
  -h, --help            Show this help

After a --control-plane install the summary prints the exact --worker command
to run on the other nodes. Expired token? On the control plane run:
  sudo kubeadm token create --print-join-command

Targets Ubuntu/Debian.

Examples:
  sudo ./${SCRIPT_NAME} --control-plane
  sudo ./${SCRIPT_NAME} --worker --url 10.0.0.1:6443 \\
      --token abcdef.0123456789abcdef --ca-cert-hash sha256:1234...
USAGE
}

# === Settings ===
LOG_FILE="/tmp/k8s_install_$(date +%Y%m%d_%H%M%S).log"

# Pinned releases (Renovate-managed).
K8S_VERSION="${K8S_VERSION:-v1.37.0}"
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.28.9}"

# pkgs.k8s.io repos are per minor version (v1.37); the patch release is pinned
# through the package version (1.37.0-*).
K8S_CHANNEL="${K8S_VERSION%.*}"
K8S_APT_URL="https://pkgs.k8s.io/core:/stable:/${K8S_CHANNEL}/deb/"
K8S_PKG_VERSION="${K8S_VERSION#v}-*"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
FLANNEL_MANIFEST="https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"

export DEBIAN_FRONTEND=noninteractive

# === Commands ===

# Usage: Initialize-Node
# Shared node prep for both roles. Safe to re-run: every step converges on the
# pinned versions and settings, also when kubeadm or containerd already exist.
Initialize-Node() {
    local distro codename
    distro=$(Get-OsId)
    # shellcheck disable=SC1091
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")

    Write-Log STEP "Disabling swap"
    swapoff -a
    sed -i.bak '/^[^#].*\sswap\s/s/^/#/' /etc/fstab

    Write-Log STEP "Loading kernel modules (overlay, br_netfilter)"
    cat > /etc/modules-load.d/k8s.conf <<CONF
overlay
br_netfilter
CONF
    modprobe overlay
    modprobe br_netfilter

    Write-Log STEP "Applying sysctl settings"
    cat > /etc/sysctl.d/k8s.conf <<CONF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
CONF
    sysctl --system >> "$LOG_FILE" 2>&1

    # containerd.io ships from the Docker apt repo; Docker itself is not installed.
    Write-Log STEP "Installing containerd"
    Invoke-Cmd apt-get update -y
    Invoke-Cmd apt-get install -y ca-certificates curl gnupg

    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" | \
        gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>>"$LOG_FILE" || \
        Stop-Script "Failed to add the Docker GPG key."
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${distro} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    Invoke-Cmd apt-get update -y
    Invoke-Cmd apt-get install -y containerd.io

    # kubelet uses the systemd cgroup driver; containerd must match or pods
    # restart in a loop. Fail loudly if the default config layout changed.
    Write-Log INFO "Configuring containerd with the systemd cgroup driver"
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || \
        Stop-Script "Could not enable SystemdCgroup in /etc/containerd/config.toml."
    Invoke-Cmd systemctl restart containerd
    Invoke-Cmd systemctl enable containerd

    Write-Log STEP "Installing kubeadm/kubelet/kubectl ${K8S_VERSION}"
    curl -fsSL "${K8S_APT_URL}Release.key" | \
        gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>>"$LOG_FILE" || \
        Stop-Script "Failed to download the Kubernetes signing key."
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_APT_URL} /" \
        > /etc/apt/sources.list.d/kubernetes.list
    chmod 644 /etc/apt/sources.list.d/kubernetes.list

    Invoke-Cmd apt-get update -y
    Invoke-Cmd apt-get install -y --allow-change-held-packages "kubelet=${K8S_PKG_VERSION}" "kubeadm=${K8S_PKG_VERSION}" "kubectl=${K8S_PKG_VERSION}"
    apt-mark hold kubelet kubeadm kubectl >> "$LOG_FILE" 2>&1

    Invoke-Cmd systemctl enable --now kubelet
}

# Usage: Install-ControlPlane
Install-ControlPlane() {
    [[ "$POD_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || \
        Stop-Script "POD_CIDR should look like 10.244.0.0/16."
    Initialize-Node

    Write-Log STEP "Running kubeadm init (${K8S_VERSION}, pod CIDR ${POD_CIDR})"
    kubeadm init --kubernetes-version "${K8S_VERSION}" --pod-network-cidr="${POD_CIDR}" >> "$LOG_FILE" 2>&1 || \
        Stop-Script "kubeadm init failed. Check log: $LOG_FILE (reset with 'sudo kubeadm reset -f' before retrying)"

    # admin.conf is root-only. Give root and the sudo user their own copy, so
    # both 'kubectl' and 'sudo kubectl' work.
    local kube_user="${SUDO_USER:-root}" kube_home
    kube_home=$(getent passwd "$kube_user" | cut -d: -f6)
    install -d -m 0700 /root/.kube
    install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
    if [[ "$kube_user" != root ]]; then
        install -d -m 0700 -o "$kube_user" -g "$(id -gn "$kube_user")" "${kube_home}/.kube"
        install -m 0600 -o "$kube_user" -g "$(id -gn "$kube_user")" /etc/kubernetes/admin.conf "${kube_home}/.kube/config"
    fi
    export KUBECONFIG=/etc/kubernetes/admin.conf

    # Flannel's manifest hardcodes 10.244.0.0/16; patch in POD_CIDR so a custom
    # range matches what kubeadm hands out.
    Write-Log STEP "Installing the Flannel CNI ${FLANNEL_VERSION} (network ${POD_CIDR})"
    local manifest
    manifest=$(mktemp --suffix=.yml)
    curl -fsSL "${FLANNEL_MANIFEST}" -o "$manifest" 2>>"$LOG_FILE" || \
        Stop-Script "Failed to download the Flannel manifest."
    grep -q '"Network": "10.244.0.0/16"' "$manifest" || \
        Stop-Script "Flannel manifest layout changed; cannot set the pod network."
    sed -i "s|\"Network\": \"10.244.0.0/16\"|\"Network\": \"${POD_CIDR}\"|" "$manifest"
    Invoke-Cmd kubectl apply -f "$manifest"
    rm -f "$manifest"

    # The node only turns Ready once the CNI is up.
    Write-Log INFO "Waiting for the node to become Ready..."
    local _ ready=false
    for _ in $(seq 1 60); do
        if kubectl get node --no-headers 2>/dev/null | grep -q ' Ready '; then
            ready=true; break
        fi
        sleep 2
    done
    kubectl get node || true
    $ready || Stop-Script "Node not Ready after 120s. Inspect: kubectl -n kube-flannel get pods; journalctl -u kubelet -n 50. Join command, once fixed: sudo kubeadm token create --print-join-command"

    # Split the join line into the worker flags this script takes.
    local join_line endpoint join_token ca_hash kubeadm_ver
    join_line=$(kubeadm token create --print-join-command 2>>"$LOG_FILE") || \
        Stop-Script "Could not create a join token. Check log: $LOG_FILE"
    endpoint=$(awk '{print $3}' <<< "$join_line")
    join_token=$(awk '{for (i = 1; i < NF; i++) if ($i == "--token") print $(i + 1)}' <<< "$join_line")
    ca_hash=$(awk '{for (i = 1; i < NF; i++) if ($i == "--discovery-token-ca-cert-hash") print $(i + 1)}' <<< "$join_line")
    kubeadm_ver=$(kubeadm version -o short 2>/dev/null) || kubeadm_ver="N/A"

    echo -e "\n${GREEN}==============================================================${NC}"
    Write-Log SUCCESS "Kubernetes control plane ready!"
    echo -e "${GREEN}==============================================================${NC}\n"
    echo -e "${BLUE}kubeadm:${NC}      ${GREEN}${kubeadm_ver}${NC}"
    echo -e "${BLUE}API URL:${NC}      ${GREEN}https://${endpoint}${NC}"
    echo -e "${BLUE}kubeconfig:${NC}   ${GREEN}${kube_home}/.kube/config${NC}"
    echo -e "${BLUE}Log:${NC}          ${GREEN}${LOG_FILE}${NC}"
    echo ""
    echo -e "${BOLD}Join a worker (run on each worker node; token valid 24h)${NC}"
    echo -e "  sudo ./${SCRIPT_NAME} --worker --url ${endpoint} \\"
    echo -e "      --token ${join_token} \\"
    echo -e "      --ca-cert-hash ${ca_hash}"
    echo ""
    echo -e "${BOLD}Use kubectl${NC}"
    echo -e "  kubectl get nodes"
    echo ""
    echo -e "${YELLOW}Cloud/firewall:${NC} nodes must reach each other on TCP 6443, TCP 10250 and"
    echo -e "     UDP 8472 (on AWS: a self-referencing 'All traffic' security group rule),"
    echo -e "     plus inbound on any NodePort you expose (30000-32767)."
}

# Usage: Install-Worker <endpoint> <token> <ca-cert-hash>
Install-Worker() {
    local endpoint=$1 join_token=$2 ca_hash=$3

    [[ -n "$endpoint"   ]] || Stop-Script "Worker needs --url <control-plane-ip>:6443"
    [[ -n "$join_token" ]] || Stop-Script "Worker needs --token <token from the control plane>"
    [[ -n "$ca_hash"    ]] || Stop-Script "Worker needs --ca-cert-hash sha256:<hash from the control plane>"
    endpoint=${endpoint#https://}
    endpoint=${endpoint%/}
    [[ "$endpoint" == *:* ]] || endpoint="${endpoint}:6443"
    [[ "$endpoint" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || Stop-Script "The --url value should look like 10.0.0.1:6443."
    [[ "$join_token" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] || Stop-Script "The --token value should look like abcdef.0123456789abcdef."
    [[ "$ca_hash" =~ ^sha256:[a-f0-9]{64}$ ]] || Stop-Script "The --ca-cert-hash value should look like sha256:<64 hex chars>."

    # Fail fast, before installing anything, when the API port is unreachable
    # (on AWS: security group). /livez is readable without credentials.
    Write-Log INFO "Checking that https://${endpoint} is reachable..."
    curl -ksf --max-time 5 "https://${endpoint}/livez" 2>/dev/null | grep -q ok || \
        Stop-Script "Cannot reach https://${endpoint}/livez. Check the URL, that the control plane is up, and that the security group allows TCP 6443 from this node."

    Initialize-Node

    # kubeadm join only returns after the kubelet's TLS bootstrap succeeded,
    # so a zero exit means the node registered. Not using Invoke-Cmd: it would
    # print the token.
    Write-Log STEP "Joining the cluster at ${endpoint}"
    kubeadm join "$endpoint" --token "$join_token" --discovery-token-ca-cert-hash "$ca_hash" >> "$LOG_FILE" 2>&1 || \
        Stop-Script "kubeadm join failed. Check log: $LOG_FILE (expired token? reset with 'sudo kubeadm reset -f' before retrying)"
    systemctl is-active --quiet kubelet || \
        Write-Log WARN "kubelet is not active; inspect: journalctl -u kubelet -n 50"

    local kubeadm_ver
    kubeadm_ver=$(kubeadm version -o short 2>/dev/null) || kubeadm_ver="N/A"

    echo -e "\n${GREEN}==============================================================${NC}"
    Write-Log SUCCESS "Kubernetes worker joined!"
    echo -e "${GREEN}==============================================================${NC}\n"
    echo -e "${BLUE}kubeadm:${NC}      ${GREEN}${kubeadm_ver}${NC}"
    echo -e "${BLUE}Joined:${NC}       ${GREEN}https://${endpoint}${NC}"
    echo -e "${BLUE}Log:${NC}          ${GREEN}${LOG_FILE}${NC}"
    echo ""
    echo -e "${BOLD}Verify on the control plane${NC}"
    echo -e "  kubectl get nodes        # this node turns Ready once Flannel runs on it"
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
CA_HASH=""

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
        --ca-cert-hash)
            CA_HASH=${2:-}
            [[ -n "$CA_HASH" ]] || Stop-Script "--ca-cert-hash requires a value"
            shift 2 ;;
        -h|--help)
            Show-Usage; exit 0 ;;
        *)
            Write-Log ERROR "Unknown argument: $1"; Show-Usage; exit 1 ;;
    esac
done

Test-Root
[[ -d /run/systemd/system ]] || Stop-Script "kubeadm requires a systemd-based system."

case "$(Get-OsId)" in
    ubuntu|debian) : ;;
    *) Stop-Script "This script targets Ubuntu/Debian. Detected: $(Get-OsId). Use the K3s installer instead." ;;
esac

if [[ -f /etc/kubernetes/admin.conf || -f /etc/kubernetes/kubelet.conf ]]; then
    Write-Log WARN "This node is already part of a Kubernetes cluster."
    Write-Log INFO "Remove it first: sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d \$HOME/.kube/config"
    exit 0
fi

case "$ROLE" in
    control-plane)
        Test-MutableOs "Kubernetes (kubeadm)" \
            "Use a mutable host; kubeadm writes to /usr/bin and /etc and needs a writable root" \
            "On Fedora CoreOS, provision the node through Butane/Ignition instead"
        Show-Intent "This script will turn this machine into a Kubernetes ${K8S_VERSION} control plane." \
            "Disable swap and load the required kernel modules" \
            "Install containerd, kubelet, kubeadm and kubectl" \
            "Run 'kubeadm init' and deploy a pod network"
        Install-ControlPlane ;;
    worker)
        Test-MutableOs "Kubernetes (kubeadm)" \
            "Use a mutable host; kubeadm writes to /usr/bin and /etc and needs a writable root" \
            "On Fedora CoreOS, provision the node through Butane/Ignition instead"
        Show-Intent "This script will join this machine to a Kubernetes ${K8S_VERSION} cluster as a worker." \
            "Disable swap and load the required kernel modules" \
            "Install containerd, kubelet, kubeadm and kubectl" \
            "Run 'kubeadm join' against ${SERVER_URL:-<unset>}"
        Install-Worker "$SERVER_URL" "$JOIN_VALUE" "$CA_HASH" ;;
    *)             Show-Usage; Stop-Script "Pass --control-plane or --worker." ;;
esac
