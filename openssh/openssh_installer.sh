#!/usr/bin/env bash
#########################################################################
# OpenSSH Hardened Configuration Installer
#
# Ed25519-only · No password auth · Post-quantum hardened
#
# Philosophy:
#   SSH keys are the only acceptable authentication method for remote
#   access. Passwords belong exclusively in sudo as a second layer,
#   never as SSH authentication.
#
#   Recommendation: store your SSH private keys in Bitwarden (SSH Agent
#   feature) or another password manager.
#
#   Crypto policy:
#     This script does not require or enforce Fedora/RHEL FUTURE crypto
#     policy. It independently applies strong, post-quantum-aware settings
#     that align with FUTURE in spirit — Ed25519, curve25519, AES-256,
#     SHA-2 — while adding ML-KEM (Kyber) key exchange to mitigate
#     store-now-decrypt-later attacks. No FUTURE policy activation needed.
#########################################################################

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

BACKUP_DIR="/root/ssh-backup-$(date +%Y%m%d-%H%M%S)"
readonly BACKUP_DIR
readonly CONFIG_FILE="/etc/ssh/sshd_config"
readonly ORIGINAL_CONFIG="${CONFIG_FILE}.original"
readonly LOG_DIR="/tmp/openssh-logs-$$"

# The systemd unit is "ssh" on Debian/Ubuntu and "sshd" on RHEL/Fedora/Arch.
# Prefer the installed unit; fall back to the package manager convention
# (the unit only exists once openssh-server is installed).
Get-SshService() {
    if systemctl list-unit-files | grep -q "^ssh\.service"; then
        echo "ssh"
    elif systemctl list-unit-files | grep -q "^sshd\.service"; then
        echo "sshd"
    elif [[ $(Get-PkgMgr) == "apt" ]]; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

SSH_SERVICE=$(Get-SshService)
mkdir -p "$LOG_DIR"

Remove-TempDir() {
    [ -n "$LOG_DIR" ] && [ -d "$LOG_DIR" ] && rm -rf "$LOG_DIR"
}
trap Remove-TempDir EXIT INT TERM

Show-Header() {
    echo
    echo -e "${BOLD}OpenSSH Hardened Configuration Installer${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "Ed25519-only · No password auth · Post-quantum hardened"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

Install-OpenSsh() {
    Write-Log STEP "Installing OpenSSH server"
    case $(Get-PkgMgr) in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq &>"$LOG_DIR/apt-update.log"
            apt-get install -y openssh-server &>"$LOG_DIR/apt-install.log"
            ;;
        dnf)
            dnf install -y openssh-server &>"$LOG_DIR/dnf-install.log"
            ;;
        pacman)
            # -Syu rather than -Sy: partial upgrades break Arch-based systems.
            pacman -Syu --noconfirm openssh &>"$LOG_DIR/pacman-install.log"
            ;;
        *)
            Stop-Script "Unsupported package manager (requires apt, dnf, or pacman)"
            ;;
    esac
    Write-Log SUCCESS "OpenSSH server installed"
}

Backup-SshConfig() {
    Write-Log STEP "Backing up existing configuration"
    mkdir -p "$BACKUP_DIR"
    [ -d "/etc/ssh" ] && cp -a /etc/ssh "$BACKUP_DIR/"
    [ -f "$CONFIG_FILE" ] && [ ! -f "$ORIGINAL_CONFIG" ] && cp "$CONFIG_FILE" "$ORIGINAL_CONFIG"
    systemctl is-active "$SSH_SERVICE" &>/dev/null \
        && echo "active"   > "$BACKUP_DIR/service_status.txt" \
        || echo "inactive" > "$BACKUP_DIR/service_status.txt"
    Write-Log SUCCESS "Backup saved to $BACKUP_DIR"
}

New-HostKeys() {
    Write-Log STEP "Generating Ed25519 host key"

    # Ed25519 — the only host key we need
    if [ ! -f "/etc/ssh/ssh_host_ed25519_key" ]; then
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N '' -q
        Write-Log INFO "Generated Ed25519 host key"
    else
        Write-Log INFO "Ed25519 host key already exists"
    fi

    # Remove weak legacy keys (RSA, ECDSA, DSA)
    for key_type in rsa ecdsa dsa; do
        if [ -f "/etc/ssh/ssh_host_${key_type}_key" ]; then
            rm -f "/etc/ssh/ssh_host_${key_type}_key" \
                  "/etc/ssh/ssh_host_${key_type}_key.pub"
            Write-Log INFO "Removed legacy $key_type host key"
        fi
    done

    chmod 600 /etc/ssh/ssh_host_*_key
    chmod 644 /etc/ssh/ssh_host_*_key.pub
    Write-Log SUCCESS "Host keys configured (Ed25519 only)"
}

Set-SshConfig() {
    Write-Log STEP "Writing hardened SSH configuration"

    # Write new configuration to a temporary file first, so we can validate it
    local tmp_config
    tmp_config="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"

    cat > "$tmp_config" << 'EOF'
# =============================================================================
# Hardened OpenSSH Server Configuration
# Ed25519-only · No password auth · Post-quantum hardened
#
# CVE mitigations:
#   CVE-2023-51767 — Ed25519 only (no RSA)
#   CVE-2025-26465 — UseDNS no
#   CVE-2025-26466 — LoginGraceTime 30, MaxStartups 20:50:100
#   CVE-2025-32728 — All forwarding explicitly disabled
#
# Key philosophy:
#   Password authentication over SSH is obsolete and insecure.
#   SSH keys are the only acceptable remote auth method.
#
#   Recommendation: store your SSH keys in Bitwarden (SSH Agent feature).
#   This gives you encrypted storage, cross-device sync, audit logs, and
#   easy revocation — without ever exposing your private key.
#
#   Use passwords only for sudo (local privilege escalation), never for
#   SSH authentication itself.
#
#   Crypto policy:
#     This script does not require or enforce Fedora/RHEL FUTURE crypto
#     policy. It independently applies strong, post-quantum-aware settings
#     that align with FUTURE in spirit — Ed25519, curve25519, AES-256,
#     SHA-2 — while adding ML-KEM (Kyber) key exchange to mitigate
#     store-now-decrypt-later attacks. No FUTURE policy activation needed.
# =============================================================================

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
Port 22
AddressFamily any

# -----------------------------------------------------------------------------
# Host Keys — Ed25519 only
# -----------------------------------------------------------------------------
HostKey /etc/ssh/ssh_host_ed25519_key

# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------
PermitRootLogin no
StrictModes yes
PermitEmptyPasswords no

# Public key authentication — the only accepted method
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile .ssh/authorized_keys

# PasswordAuthentication is disabled. SSH passwords are not of this era.
# If you're locked out and need emergency access:
#   1. Get console access to the machine
#   2. Temporarily uncomment the line below and restart sshd
#   3. Fix your keys, then re-disable password auth immediately
# PasswordAuthentication yes
PasswordAuthentication no

# Disable all other auth methods
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
HostbasedAuthentication no
GSSAPIAuthentication no

# UsePAM: disabled — we don't need PAM for key-only auth
# WARNING: on some distros this affects account/session modules.
# If you see login issues, re-enable and investigate pam config.
UsePAM no

# Restrict to specific users (recommended — add your username)
# AllowUsers youruser

# -----------------------------------------------------------------------------
# DoS / Connection Protection
# -----------------------------------------------------------------------------
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 10
MaxStartups 20:50:100
PerSourceMaxStartups 20
PerSourceNetBlockSize 32:128
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no

# -----------------------------------------------------------------------------
# Cryptographic Algorithms — Post-quantum hardened
#
# Goal: mitigate store-now-decrypt-later (SNDL) attacks by adding a
# post-quantum key exchange (ML-KEM / FIPS 203) alongside classical
# curve25519. This does not require FUTURE crypto policy to be active.
#
# Ed25519 + ML-KEM + curve25519 + AES-256 + SHA-2 only
# No RSA, no ECDSA, no SHA-1, no AES-128
# -----------------------------------------------------------------------------
KexAlgorithms mlkem768x25519-sha256,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519
PubkeyAcceptedAlgorithms ssh-ed25519,sk-ssh-ed25519@openssh.com

# No compression — faster on modern connections, avoids CRIME-style attacks
Compression no

# -----------------------------------------------------------------------------
# Forwarding — all disabled
# -----------------------------------------------------------------------------
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
GatewayPorts no
X11Forwarding no
X11UseLocalhost yes
PermitTunnel no
PermitUserEnvironment no
StreamLocalBindUnlink no
IgnoreRhosts yes

# -----------------------------------------------------------------------------
# Privacy & DNS
# -----------------------------------------------------------------------------
UseDNS no
PrintMotd no
PrintLastLog yes

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
SyslogFacility AUTH
LogLevel VERBOSE

# -----------------------------------------------------------------------------
# SFTP
# -----------------------------------------------------------------------------
EOF

    # Append sftp subsystem line
    echo "Subsystem sftp internal-sftp -f AUTHPRIV -l INFO" >> "$tmp_config"

    chmod 644 "$tmp_config"

    # Validate the new config before replacing the live one
    local validation_output
    if ! validation_output=$(sshd -t -f "$tmp_config" 2>&1); then
        Write-Log ERROR "New configuration failed validation; original config left intact"
        echo "$validation_output" >&2
        rm -f "$tmp_config"
        return 1
    fi

    # Atomically replace the live config
    mv -f "$tmp_config" "$CONFIG_FILE"

    mkdir -p /run/sshd
    chmod 755 /run/sshd

    Write-Log SUCCESS "SSH configuration written"
}

Set-Firewall() {
    Write-Log STEP "Configuring firewall"
    # Check which firewall is actually ACTIVE, not merely installed: a Debian
    # box can have firewalld installed while ufw is the one doing the work.
    if systemctl is-active --quiet firewalld 2>/dev/null && command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=ssh &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        Write-Log INFO "firewalld configured for SSH"
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow ssh &>/dev/null || true
        Write-Log INFO "ufw configured for SSH"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=ssh &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        Write-Log INFO "firewalld configured for SSH (inactive)"
    elif command -v ufw &>/dev/null; then
        ufw allow ssh &>/dev/null || true
        Write-Log INFO "ufw configured for SSH (inactive)"
    else
        Write-Log WARN "No firewall detected — ensure port 22 is accessible"
    fi
    Write-Log SUCCESS "Firewall done"
}

Test-SshConfig() {
    Write-Log STEP "Testing SSH configuration"
    if sshd -t 2>/dev/null; then
        Write-Log SUCCESS "Configuration syntax valid"
    else
        Write-Log ERROR "Configuration has syntax errors:"
        sshd -t
        return 1
    fi
}

Show-Summary() {
    local ssh_version
    ssh_version=$(ssh -V 2>&1 | awk '{print $1}' | tr -d ',')

    echo
    echo -e "${BOLD}Summary${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}✓${NC} $ssh_version installed"
    echo -e "${GREEN}✓${NC} Ed25519-only host key"
    echo -e "${GREEN}✓${NC} Password authentication disabled"
    echo -e "${GREEN}✓${NC} Post-quantum KEX (ML-KEM / mlkem768x25519)"
    echo -e "${GREEN}✓${NC} Aligned with FUTURE crypto policy (not required)"
    echo -e "${GREEN}✓${NC} All forwarding disabled"
    echo -e "${GREEN}✓${NC} CVE mitigations applied"
    systemctl is-active --quiet "$SSH_SERVICE" \
        && echo -e "${GREEN}✓${NC} sshd running" \
        || echo -e "${YELLOW}!${NC} sshd not running"
    echo
    echo -e "${BOLD}Next steps${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local ip_hint="host"
    if command -v hostname >/dev/null 2>&1; then
        ip_hint=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z "${ip_hint}" ]] && command -v ip >/dev/null 2>&1; then
        ip_hint=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    fi
    [[ -z "${ip_hint}" ]] && ip_hint="host"
    echo -e "1. Add your public key:  ${BLUE}ssh-copy-id user@host${NC}"
    echo -e "2. Test login:           ${BLUE}ssh user@${ip_hint}${NC}"
    echo -e "3. Store key in:         ${BLUE}Bitwarden SSH Agent${NC}"
    echo
    echo -e "${YELLOW}Emergency password access:${NC}"
    echo -e "Uncomment ${BLUE}PasswordAuthentication yes${NC} in $CONFIG_FILE"
    echo -e "then ${BLUE}sudo systemctl restart $SSH_SERVICE${NC} — fix keys — re-disable."
    echo
}

Install-HardenedOpenSsh() {
    if [[ -n "${SSH_CONNECTION:-}" ]] && [[ "${FORCE_SSH_INSTALL:-}" != "1" ]]; then
        Write-Log ERROR "Running in SSH session — this will modify SSH config."
        Write-Log WARN "Use tmux/screen, or: FORCE_SSH_INSTALL=1 $0 install"
        exit 1
    fi

    if [[ "${CONFIRM:-}" != "yes" ]]; then
        if [[ -t 0 ]]; then
            read -rp "Install hardened OpenSSH? This disables password auth. [y/N] " answer
            [[ "${answer,,}" != "y" ]] && { Write-Log ERROR "Cancelled"; exit 0; }
        else
            Write-Log ERROR "Non-interactive: use CONFIRM=yes $0 install"
            exit 0
        fi
    fi

    Test-Root
    Show-Header
    Backup-SshConfig
    Install-OpenSsh
    # Re-detect now that the package (and thus the systemd unit) exists
    SSH_SERVICE=$(Get-SshService)
    New-HostKeys
    Set-SshConfig
    Set-Firewall
    Test-SshConfig
    systemctl enable "$SSH_SERVICE"
    systemctl restart "$SSH_SERVICE"
    Show-Summary
    Write-Log SUCCESS "Done!"
}

Remove-OpenSsh() {
    Test-Root

    if [[ "${CONFIRM:-}" != "yes" ]]; then
        if [[ -t 0 ]]; then
            read -rp "Remove OpenSSH server? [y/N] " answer
            [[ "${answer,,}" != "y" ]] && { Write-Log ERROR "Cancelled"; exit 0; }
        else
            Write-Log ERROR "Non-interactive: use CONFIRM=yes $0 remove"
            exit 0
        fi
    fi

    systemctl is-active --quiet "$SSH_SERVICE" && systemctl stop "$SSH_SERVICE" || true
    systemctl is-enabled --quiet "$SSH_SERVICE" && systemctl disable "$SSH_SERVICE" || true
    [ -f "$ORIGINAL_CONFIG" ] && cp "$ORIGINAL_CONFIG" "$CONFIG_FILE" && Write-Log INFO "Original config restored"

    local remove_failed=0
    case $(Get-PkgMgr) in
        apt)
            apt-get remove -y openssh-server &>/dev/null || { Write-Log ERROR "apt-get remove failed"; remove_failed=1; }
            ;;
        dnf)
            dnf remove -y openssh-server &>/dev/null || { Write-Log ERROR "dnf remove failed"; remove_failed=1; }
            ;;
        pacman)
            pacman -Rns --noconfirm openssh &>/dev/null || { Write-Log ERROR "pacman remove failed"; remove_failed=1; }
            ;;
    esac

    if [ "$remove_failed" -eq 0 ]; then
        Write-Log SUCCESS "OpenSSH removed. Backup: $BACKUP_DIR"
    else
        Write-Log WARN "OpenSSH removal encountered errors. Backup: $BACKUP_DIR"
        return 1
    fi
}

Test-OpenSshInstallation() {
    local issues=0

    command -v sshd &>/dev/null \
        && Write-Log SUCCESS "sshd found: $(ssh -V 2>&1 | awk '{print $1}' | tr -d ',')" \
        || { Write-Log ERROR "sshd not found"; issues=$((issues + 1)); }

    [ -f "$CONFIG_FILE" ] && sshd -t 2>/dev/null \
        && Write-Log SUCCESS "Config syntax valid" \
        || { Write-Log ERROR "Config invalid or missing"; issues=$((issues + 1)); }

    systemctl is-active --quiet  "$SSH_SERVICE" && Write-Log SUCCESS "sshd running"  || Write-Log WARN "sshd not running"
    systemctl is-enabled --quiet "$SSH_SERVICE" && Write-Log SUCCESS "sshd enabled"  || Write-Log WARN "sshd not enabled"

    for key in /etc/ssh/ssh_host_*_key; do
        [ -f "$key" ] && Write-Log SUCCESS "Host key: $(ssh-keygen -lf "$key" 2>/dev/null)"
    done
    if [ ! -f "/etc/ssh/ssh_host_ed25519_key" ]; then
        Write-Log ERROR "Ed25519 host key not found"
        issues=$((issues + 1))
    fi

    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -q :22; then
            Write-Log SUCCESS "Listening on :22"
        else
            Write-Log WARN "Not listening on :22"
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ':22'; then
            Write-Log SUCCESS "Listening on :22"
        else
            Write-Log WARN "Not listening on :22"
        fi
    elif command -v lsof &>/dev/null; then
        if lsof -iTCP:22 -sTCP:LISTEN -nP &>/dev/null; then
            Write-Log SUCCESS "Listening on :22"
        else
            Write-Log WARN "Not listening on :22"
        fi
    else
        Write-Log WARN "Cannot verify listening port :22 (no ss/netstat/lsof available)"
    fi

    [ $issues -eq 0 ] && Write-Log SUCCESS "Verification passed" || { Write-Log ERROR "$issues issue(s) found"; return 1; }
}

Invoke-Main() {
    case "${1:-help}" in
        install)
            Show-Intent "This script will install and harden OpenSSH on this machine." \
                "Install the OpenSSH server package" \
                "On Arch-based systems this upgrades all system packages (pacman -Syu)" \
                "Replace sshd_config with a hardened one (password login disabled)" \
                "You need a working SSH key before this, or you lock yourself out" \
                "Enable and restart the SSH service"
            Install-HardenedOpenSsh ;;
        remove)
            Show-Intent "This script will remove OpenSSH from this machine." \
                "Stop and disable the SSH service" \
                "Uninstall the OpenSSH server package and restore the original config"
            Remove-OpenSsh ;;
        verify)  Test-OpenSshInstallation ;;
        *)
            echo
            echo -e "${BOLD}OpenSSH Hardened Configuration Installer${NC}"
            echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "Usage: $0 {install|remove|verify}"
            echo
            echo "  install   Install OpenSSH with hardened config (no password auth)"
            echo "  remove    Remove OpenSSH and restore original config"
            echo "  verify    Verify installation and config"
            echo
            echo "Env vars:"
            echo "  CONFIRM=yes          Skip confirmation prompt"
            echo "  FORCE_SSH_INSTALL=1  Allow running over SSH (risky)"
            echo
            ;;
    esac
}

Invoke-Main "$@"
