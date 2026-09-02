#!/usr/bin/env bash
#
# Recalculate and optionally apply SHA256 checksums for nginx installer dependencies.
#
# Usage:
#   .github/scripts/update-nginx-checksums.sh
#   .github/scripts/update-nginx-checksums.sh --apply
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

Show-Usage() {
    cat <<'EOF'
Usage: update-nginx-checksums.sh [--apply]

Options:
  --apply   Apply calculated checksums to nginx/nginx_installer.sh without prompting
  -h, --help  Show this help
EOF
}

APPLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            APPLY=true
            shift
            ;;
        -h|--help)
            Show-Usage
            exit 0
            ;;
        *)
            Write-Log ERROR "Unknown argument: $1"
            Show-Usage
            exit 1
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly BASH_INSTALLER="$REPO_ROOT/nginx/nginx_installer.sh"

cd "$REPO_ROOT"

Get-BashVar() {
    local key=$1
    sed -n "s/^${key}=\"\\([^\"]*\\)\"$/\\1/p" "$BASH_INSTALLER" | head -n1
}

Set-BashVar() {
    local key=$1
    local value=$2
    sed -i "s/^${key}=\"[^\"]*\"$/${key}=\"${value}\"/" "$BASH_INSTALLER"
}

Get-UrlHash() {
    local url=$1
    local file=$2
    curl -fsSL "$url" -o "$file"
    sha256sum "$file" | awk '{print $1}'
}

NGINX_VERSION="$(Get-BashVar NGINX_VERSION)"
PCRE2_VERSION="$(Get-BashVar PCRE2_VERSION)"
ZLIB_VERSION="$(Get-BashVar ZLIB_VERSION)"
HEADERS_MORE_VERSION="$(Get-BashVar HEADERS_MORE_VERSION)"
ZSTD_MODULE_VERSION="$(Get-BashVar ZSTD_MODULE_VERSION)"
ACME_MODULE_VERSION="$(Get-BashVar ACME_MODULE_VERSION)"

required_values=(
    "$NGINX_VERSION"
    "$PCRE2_VERSION"
    "$ZLIB_VERSION"
    "$HEADERS_MORE_VERSION"
    "$ZSTD_MODULE_VERSION"
    "$ACME_MODULE_VERSION"
)
for value in "${required_values[@]}"; do
    [[ -n "$value" ]] || { Write-Log ERROR "Failed to read one or more versions from $BASH_INSTALLER"; exit 1; }
done

Write-Log INFO "Versions to recalculate:"
echo "  NGINX:         $NGINX_VERSION"
echo "  PCRE2:         $PCRE2_VERSION"
echo "  Zlib:          $ZLIB_VERSION"
echo "  headers-more:  $HEADERS_MORE_VERSION"
echo "  zstd-module:   $ZSTD_MODULE_VERSION"
echo "  nginx-acme:    $ACME_MODULE_VERSION"
echo

TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' EXIT
cd "$TEMP_DIR"

Write-Log INFO "Downloading and hashing release tarballs..."

NGINX_SHA256="$(Get-UrlHash "https://github.com/nginx/nginx/releases/download/release-${NGINX_VERSION}/nginx-${NGINX_VERSION}.tar.gz" "nginx.tar.gz")"
Write-Log SUCCESS "NGINX_SHA256: $NGINX_SHA256"

PCRE2_SHA256="$(Get-UrlHash "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" "pcre2.tar.gz")"
Write-Log SUCCESS "PCRE2_SHA256: $PCRE2_SHA256"

ZLIB_SHA256="$(Get-UrlHash "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" "zlib.tar.gz")"
Write-Log SUCCESS "ZLIB_SHA256: $ZLIB_SHA256"

HEADERS_MORE_SHA256="$(Get-UrlHash "https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v${HEADERS_MORE_VERSION}.tar.gz" "headers-more.tar.gz")"
Write-Log SUCCESS "HEADERS_MORE_SHA256: $HEADERS_MORE_SHA256"

ZSTD_MODULE_SHA256="$(Get-UrlHash "https://github.com/tokers/zstd-nginx-module/archive/refs/tags/${ZSTD_MODULE_VERSION}.tar.gz" "zstd-module.tar.gz")"
Write-Log SUCCESS "ZSTD_MODULE_SHA256: $ZSTD_MODULE_SHA256"

ACME_MODULE_SHA256="$(Get-UrlHash "https://github.com/nginx/nginx-acme/releases/download/v${ACME_MODULE_VERSION}/nginx-acme-${ACME_MODULE_VERSION}.tar.gz" "nginx-acme.tar.gz")"
Write-Log SUCCESS "ACME_MODULE_SHA256: $ACME_MODULE_SHA256"

echo
Write-Log INFO "Calculated checksums:"
echo "  NGINX_SHA256:         $NGINX_SHA256"
echo "  PCRE2_SHA256:         $PCRE2_SHA256"
echo "  ZLIB_SHA256:          $ZLIB_SHA256"
echo "  HEADERS_MORE_SHA256:  $HEADERS_MORE_SHA256"
echo "  ZSTD_MODULE_SHA256:   $ZSTD_MODULE_SHA256"
echo "  ACME_MODULE_SHA256:   $ACME_MODULE_SHA256"
echo

if [[ "$APPLY" != true ]]; then
    read -rp "Apply these checksums to installer files? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        Write-Log INFO "No changes made"
        exit 0
    fi
fi

cd "$REPO_ROOT"

Set-BashVar NGINX_SHA256 "$NGINX_SHA256"
Set-BashVar PCRE2_SHA256 "$PCRE2_SHA256"
Set-BashVar ZLIB_SHA256 "$ZLIB_SHA256"
Set-BashVar HEADERS_MORE_SHA256 "$HEADERS_MORE_SHA256"
Set-BashVar ZSTD_MODULE_SHA256 "$ZSTD_MODULE_SHA256"
Set-BashVar ACME_MODULE_SHA256 "$ACME_MODULE_SHA256"

Write-Log SUCCESS "Updated checksums in:"
echo "  - nginx/nginx_installer.sh"
