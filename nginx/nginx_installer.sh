#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# NGINX Installer Script for Linux (Bash)
# ============================================================================
#
# Description:
#   Builds and installs NGINX with OpenSSL, HTTP/3, zstd compression,
#   and ACME support on Linux.
#
# Usage:
#   ./nginx_installer.sh install [options]   - Build and install NGINX
#   ./nginx_installer.sh remove              - Uninstall NGINX
#
# Options:
#   --skip-acme            Do not build/install the ACME module
#   --skip-zstd            Do not build/install the zstd module
#   --skip-headers-more    Do not build/install the headers-more module
#   --skip-modules=a,b,c   Comma-separated list of: acme, zstd, headers-more
#
#   A module that fails to download or build is skipped automatically
#   (with a warning) instead of aborting the whole install.
#
# ============================================================================

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

# ============================================================================
# Version Configuration
# ============================================================================

# NGINX
NGINX_VERSION="1.31.5"
NGINX_SHA256="e951607d534836624bd36b6b45a71dbfb055237deae3738da6bbf3270dada279"

# PCRE2
PCRE2_VERSION="10.48"
PCRE2_SHA256="ebcc25aadf2a51fa1fefa9b8bc9e7a79b3dae86870a0f1152a22e42befd46888"

# Zlib
ZLIB_VERSION="1.3.2"
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"

# Headers-More Module
HEADERS_MORE_VERSION="0.39"
HEADERS_MORE_SHA256="dde68d3fa2a9fc7f52e436d2edc53c6d703dcd911283965d889102d3a877c778"

# Zstd Module
ZSTD_MODULE_VERSION="0.1.1"
ZSTD_MODULE_SHA256="707d534f8ca4263ff043066db15eac284632aea875f9fe98c96cea9529e15f41"

# ACME Module
ACME_MODULE_VERSION="0.4.1"
ACME_MODULE_SHA256="b4f99f971bd0bebc89b2037f3afeaa3281004fe434de558df87d69cab2be1f22"

# ============================================================================
# Optional Module Configuration
# ============================================================================
# zstd, headers-more and ACME are optional dynamic modules. Any of them can
# be disabled up front with a --skip-* flag, and any of them is disabled
# automatically (with a warning) if its download or build fails, instead of
# aborting the whole install. Env vars let CI/automation set the same thing.

SKIP_ACME="${NGINX_SKIP_ACME:-false}"
SKIP_ZSTD="${NGINX_SKIP_ZSTD:-false}"
SKIP_HEADERS_MORE="${NGINX_SKIP_HEADERS_MORE:-false}"

# Set once the ACME module has actually been built; used to decide whether
# to install/require it later, since it can be skipped mid-build on failure.
ACME_MODULE_BUILT=false

# ============================================================================
# Configuration
# ============================================================================

BUILD_DIR="/var/tmp/nginx-build-$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/lib/nginx-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/nginx-installer-$(date +%Y%m%d-%H%M%S).log"

# install paths (matching what dnf/rpm would use)
NGINX_PREFIX="/usr/share/nginx"
case "$(uname -m)" in
    x86_64|aarch64) NGINX_LIBDIR="/usr/lib64" ;;
    *)              NGINX_LIBDIR="/usr/lib" ;;
esac
NGINX_MODULES_PATH="${NGINX_LIBDIR}/nginx/modules"

# Download URLs
NGINX_URL="https://github.com/nginx/nginx/releases/download/release-${NGINX_VERSION}/nginx-${NGINX_VERSION}.tar.gz"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
HEADERS_MORE_URL="https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v${HEADERS_MORE_VERSION}.tar.gz"
ZSTD_MODULE_URL="https://github.com/tokers/zstd-nginx-module/archive/refs/tags/${ZSTD_MODULE_VERSION}.tar.gz"
ACME_MODULE_URL="https://github.com/nginx/nginx-acme/releases/download/v${ACME_MODULE_VERSION}/nginx-acme-${ACME_MODULE_VERSION}.tar.gz"

# Initialize logging
mkdir -p "$(dirname "$LOG_FILE")" "$BUILD_DIR"

# ============================================================================
# Helper Functions
# ============================================================================

Test-Hash() {
    local file=$1
    local expected=$2
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || Stop-Script "Checksum failed: $file"
}

Get-File() {
    local url=$1
    local file=$2
    local sha=$3

    if [[ -f "$file" ]]; then
        Test-Hash "$file" "$sha"
        return 0
    fi

    Write-Log INFO "Downloading $(basename "$file")..."
    curl -fsSL "$url" -o "$file" || Stop-Script "Download failed: $url"
    Test-Hash "$file" "$sha"
}

# Like Get-File, but for optional modules: returns 1 instead of aborting the
# script when the download fails or the checksum doesn't match.
Get-OptionalFile() {
    local url=$1
    local file=$2
    local sha=$3
    local label=$4
    local actual

    if [[ -f "$file" ]]; then
        actual=$(sha256sum "$file" | awk '{print $1}')
        if [[ "$actual" == "$sha" ]]; then
            return 0
        fi
        Write-Log WARN "Checksum mismatch for existing $label archive, re-downloading"
        rm -f "$file"
    fi

    Write-Log INFO "Downloading $label..."
    if ! curl -fsSL "$url" -o "$file"; then
        Write-Log WARN "Download failed for $label module: $url"
        return 1
    fi

    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual" != "$sha" ]]; then
        Write-Log WARN "Checksum verification failed for $label module, skipping it"
        rm -f "$file"
        return 1
    fi
    return 0
}

# Downloads rustup-init, verifies its published SHA256, then installs the
# Rust toolchain. Replaces the old unverified `curl | sh` pattern.
# Returns 1 instead of aborting the script on failure, so callers can skip
# whichever module needed it (currently: ACME).
Install-Rustup() {
    Write-Log INFO "Installing Rust toolchain via rustup-init"
    local rustup_arch
    rustup_arch="$(uname -m)-unknown-linux-gnu"
    local rustup_url="https://static.rust-lang.org/rustup/dist/${rustup_arch}/rustup-init"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! curl -fsSL "$rustup_url" -o "$tmp_dir/rustup-init"; then
        Write-Log WARN "Failed to download rustup-init"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! curl -fsSL "${rustup_url}.sha256" -o "$tmp_dir/rustup-init.sha256"; then
        Write-Log WARN "Failed to download rustup-init checksum"
        rm -rf "$tmp_dir"
        return 1
    fi

    local expected actual
    expected=$(cut -d' ' -f1 "$tmp_dir/rustup-init.sha256")
    actual=$(sha256sum "$tmp_dir/rustup-init" | awk '{print $1}')
    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        Write-Log WARN "rustup-init checksum verification failed"
        rm -rf "$tmp_dir"
        return 1
    fi

    chmod +x "$tmp_dir/rustup-init"
    if ! "$tmp_dir/rustup-init" -y >/dev/null 2>&1; then
        Write-Log WARN "rustup installation failed"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
    return 0
}

# ============================================================================
# System Dependencies
# ============================================================================

Install-Dependencies() {
    Test-Root
    command -v curl >/dev/null 2>&1 || Stop-Script "curl required"

    Write-Log INFO "Installing build dependencies"

    local mgr
    mgr=$(Get-PkgMgr)

    case $mgr in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y build-essential libpcre2-dev zlib1g-dev libzstd-dev libssl-dev curl gcc make cargo pkg-config clang gawk cmake >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y -q gcc gcc-c++ make pcre2-devel zlib-devel libzstd-devel openssl-devel curl perl cargo pkgconf-pkg-config clang gawk cmake >/dev/null 2>&1
            ;;
        pacman)
            if ! pacman -Sy --noconfirm --needed base-devel pcre2 zstd openssl curl clang gawk cmake pkgconf >/dev/null 2>&1; then
                Write-Log WARN "pacman install failed, will try rustup for cargo. Note: zlib is not required (zlib-ng-compat provides it)."
            fi
            ;;
        *)
            Stop-Script "Unsupported package manager. Only apt, dnf and pacman are supported."
            ;;
    esac
    
    # Verify cargo availability (only needed to build the ACME module)
    if [[ $SKIP_ACME != true ]] && ! command -v cargo >/dev/null 2>&1; then
        Write-Log WARN "Cargo not found. Installing rustup..."
        if ! Install-Rustup; then
            Write-Log WARN "Rust toolchain unavailable, disabling ACME module for this run"
            SKIP_ACME=true
        fi
    fi

    Write-Log INFO "Dependencies installed"
}

Update-SystemPackages() {
    Test-Root

    Write-Log INFO "Updating system packages"

    local mgr
    mgr=$(Get-PkgMgr)

    case $mgr in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || Write-Log WARN "apt-get update failed"
            apt-get upgrade -y -q || Stop-Script "apt-get upgrade failed"
            ;;
        dnf)
            if ! dnf upgrade -y -q >/dev/null 2>&1; then
                Stop-Script "dnf upgrade failed"
            fi
            ;;
        pacman)
            pacman -Syu --noconfirm >/dev/null 2>&1 || Write-Log WARN "pacman upgrade failed"
            ;;
        *)
            Write-Log WARN "Unable to detect package manager"
            ;;
    esac

    Write-Log INFO "System packages updated"
}

# ============================================================================
# Download Sources
# ============================================================================

Get-Sources() {
    cd "$BUILD_DIR" || Stop-Script "Cannot cd to BUILD_DIR: $BUILD_DIR"
    
    Write-Log INFO "Downloading sources"
    
    Get-File "$NGINX_URL" "nginx.tgz" "$NGINX_SHA256"
    Get-File "$PCRE2_URL" "pcre2.tgz" "$PCRE2_SHA256"
    Get-File "$ZLIB_URL" "zlib.tgz" "$ZLIB_SHA256"

    if [[ $SKIP_HEADERS_MORE != true ]] && ! Get-OptionalFile "$HEADERS_MORE_URL" "headers.tgz" "$HEADERS_MORE_SHA256" "headers-more"; then
        Write-Log WARN "Disabling headers-more module for this run"
        SKIP_HEADERS_MORE=true
    fi
    if [[ $SKIP_ZSTD != true ]] && ! Get-OptionalFile "$ZSTD_MODULE_URL" "zstd.tgz" "$ZSTD_MODULE_SHA256" "zstd"; then
        Write-Log WARN "Disabling zstd module for this run"
        SKIP_ZSTD=true
    fi
    if [[ $SKIP_ACME != true ]] && ! Get-OptionalFile "$ACME_MODULE_URL" "acme.tgz" "$ACME_MODULE_SHA256" "acme"; then
        Write-Log WARN "Disabling ACME module for this run"
        SKIP_ACME=true
    fi

    Write-Log INFO "Extracting archives"

    # Clean previous extractions
    rm -rf nginx openssl pcre2 zlib headers-more zstd-module nginx-acme 2>/dev/null || true

    tar xzf nginx.tgz && mv "nginx-${NGINX_VERSION}" nginx
    tar xzf pcre2.tgz && mv "pcre2-${PCRE2_VERSION}" pcre2
    tar xzf zlib.tgz && mv "zlib-${ZLIB_VERSION}" zlib
    [[ $SKIP_HEADERS_MORE == true ]] || { tar xzf headers.tgz && mv "headers-more-nginx-module-${HEADERS_MORE_VERSION}" headers-more; }
    [[ $SKIP_ZSTD == true ]] || { tar xzf zstd.tgz && mv "zstd-nginx-module-${ZSTD_MODULE_VERSION}" zstd-module; }
    [[ $SKIP_ACME == true ]] || { tar xzf acme.tgz && mv "nginx-acme-${ACME_MODULE_VERSION}" nginx-acme; }

    Write-Log INFO "Sources ready"
}

# ============================================================================
# Build Functions
# ============================================================================

Build-Nginx() {
    # Clean compiler temp files (not the build dir itself — managed by EXIT trap)
    rm -rf /tmp/cc* /tmp/tmp.* 2>/dev/null || true

    # Check disk space in /var/tmp
    local tmp_space
    tmp_space=$(df /var/tmp | tail -1 | awk '{print $4}')
    if [[ $tmp_space -lt 1048576 ]]; then
        Write-Log WARN "Low disk space in /var/tmp, using build directory"
        export TMPDIR="$BUILD_DIR"
    fi

    # Ensure cc symlink exists
    if ! command -v cc >/dev/null 2>&1; then
        ln -sf /usr/bin/gcc /usr/local/bin/cc 2>/dev/null || true
        export PATH="/usr/local/bin:$PATH"
    fi

    # Build NGINX
    Write-Log INFO "Building Nginx ${NGINX_VERSION}"
    cd "$BUILD_DIR/nginx" || Stop-Script "Nginx source missing"
    
    export TMPDIR="$BUILD_DIR"
    export CC=gcc

    if [[ $SKIP_ZSTD != true ]]; then
        # Verify libzstd availability
        if command -v ldconfig >/dev/null 2>&1; then
            if ! ldconfig -p 2>/dev/null | grep -q "libzstd.so"; then
                Write-Log WARN "Shared libzstd not found. Install libzstd-dev/devel; disabling zstd module for this run"
                SKIP_ZSTD=true
            fi
        elif [[ ! -f /usr/lib/libzstd.so && ! -f /usr/lib/libzstd.so.1 &&
                ! -f /usr/lib64/libzstd.so && ! -f /usr/lib64/libzstd.so.1 &&
                ! -f /usr/local/lib/libzstd.so ]]; then
            Write-Log WARN "Shared libzstd not found. Install libzstd-dev/devel; disabling zstd module for this run"
            SKIP_ZSTD=true
        fi
    fi
    [[ $SKIP_ZSTD == true ]] || export LDFLAGS="-lzstd"

    local configure_args=(
        --with-compat
        --prefix="${NGINX_PREFIX}"
        --sbin-path=/usr/sbin/nginx
        --conf-path=/etc/nginx/nginx.conf
        --http-log-path=/var/log/nginx/access.log
        --error-log-path=/var/log/nginx/error.log
        --pid-path=/run/nginx.pid
        --lock-path=/run/lock/nginx.lock
        --http-client-body-temp-path=/var/lib/nginx/tmp/client_body
        --http-proxy-temp-path=/var/lib/nginx/tmp/proxy
        --http-fastcgi-temp-path=/var/lib/nginx/tmp/fastcgi
        --http-uwsgi-temp-path=/var/lib/nginx/tmp/uwsgi
        --http-scgi-temp-path=/var/lib/nginx/tmp/scgi
        --with-pcre="$BUILD_DIR/pcre2"
        --with-zlib="$BUILD_DIR/zlib"
        --with-pcre-jit
        --with-http_ssl_module
        --with-http_v2_module
        --with-http_v3_module
        --with-http_gzip_static_module
        --with-http_stub_status_module
        --with-http_realip_module
        --with-http_sub_module
        --with-http_secure_link_module
        --with-stream
        --with-stream_ssl_module
        --with-stream_ssl_preread_module
        --with-stream_realip_module
        --with-file-aio
        --with-threads
        --modules-path="${NGINX_MODULES_PATH}"
    )
    [[ $SKIP_HEADERS_MORE == true ]] || configure_args+=(--add-dynamic-module="$BUILD_DIR/headers-more")
    [[ $SKIP_ZSTD == true ]] || configure_args+=(--add-dynamic-module="$BUILD_DIR/zstd-module")

    local output
    if ! output=$(./configure "${configure_args[@]}" 2>&1); then
        printf '%s\n' "$output" >> "$LOG_FILE"
        Write-Log ERROR "Configure output: $(echo "$output" | tail -20)"
        Stop-Script "Configure failed"
    fi

    # Patch Makefile for shared libzstd
    if [[ $SKIP_ZSTD != true && -f "objs/Makefile" ]]; then
        Write-Log INFO "Patching nginx Makefile for shared libzstd"
        sed -i 's/-l:libzstd\.a/-lzstd/g' "objs/Makefile"
    fi

    if ! output=$(make -j"$(nproc)" 2>&1); then
        printf '%s\n' "$output" >> "$LOG_FILE"
        Write-Log ERROR "Make output: $(echo "$output" | tail -20)"
        Stop-Script "Build failed"
    fi

    # Build ACME Module (optional — skipped automatically on failure)
    if [[ $SKIP_ACME == true ]]; then
        Write-Log INFO "Skipping ACME module"
    elif Build-AcmeModule; then
        ACME_MODULE_BUILT=true
    else
        Write-Log WARN "Continuing without the ACME module"
        SKIP_ACME=true
    fi

    Write-Log INFO "Build complete"
}

# Builds the ACME dynamic module. Returns 1 on any failure instead of
# aborting the script, so the caller can skip the module and carry on.
Build-AcmeModule() {
    Write-Log INFO "Building ACME module ${ACME_MODULE_VERSION}"
    cd "$BUILD_DIR/nginx-acme" || { Write-Log WARN "ACME source missing"; return 1; }

    export NGINX_BUILD_DIR="$BUILD_DIR/nginx/objs"
    export NGX_ACME_STATE_PREFIX="/var/cache/nginx"

    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi

    # Verify Rust toolchain
    if ! command -v rustc >/dev/null 2>&1; then
        Write-Log WARN "rustc not found, installing rustup"
        Install-Rustup || { Write-Log WARN "Rust toolchain unavailable"; return 1; }
    fi

    local cargo_output
    if ! cargo_output=$(cargo build --release 2>&1); then
        printf '%s\n' "$cargo_output" >> "$LOG_FILE"
        Write-Log WARN "ACME build failed: $(echo "$cargo_output" | tail -20)"
        return 1
    fi

    mkdir -p "$BUILD_DIR/nginx-acme/objs"
    local acme_so="target/release/libnginx_acme.so"
    if [[ ! -f "$acme_so" ]]; then
        Write-Log WARN "ACME module not built: $acme_so missing (cargo build may have failed)"
        return 1
    fi
    if ! cp "$acme_so" "$BUILD_DIR/nginx-acme/objs/ngx_http_acme_module.so"; then
        Write-Log WARN "Failed to stage ACME module: cp failed (check disk space or permissions)"
        return 1
    fi

    Write-Log INFO "ACME module built successfully"
    return 0
}

# ============================================================================
# Configuration Functions
# ============================================================================

Install-HtmlFiles() {
    Write-Log INFO "Installing HTML files"
    mkdir -p /usr/share/nginx/html

    cat > /usr/share/nginx/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Welcome to nginx!</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>
</body>
</html>
EOF

    cat > /usr/share/nginx/html/style.css <<'EOF'
body {
    width: 35em;
    margin: 0 auto;
    font-family: Tahoma, Verdana, Arial, sans-serif;
}
EOF

    chmod 0644 /usr/share/nginx/html/*.html /usr/share/nginx/html/*.css 2>/dev/null || true
}

New-SelfSignedCertificate() {
    Write-Log INFO "Generating self-signed TLS certificate"
    mkdir -p /etc/nginx/ssl

    if [[ -f /etc/nginx/ssl/nginx.key && -f /etc/nginx/ssl/nginx.crt ]]; then
        Write-Log INFO "Existing SSL certificate preserved"
        return 0
    fi

    local ssl_bin
    ssl_bin=$(command -v openssl || true)
    [[ -n "$ssl_bin" ]] || Stop-Script "openssl not found"

    local output
    if ! output=$(OPENSSL_CONF=/dev/null "$ssl_bin" req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:secp384r1 \
        -days 365 -nodes \
        -keyout /etc/nginx/ssl/nginx.key \
        -out /etc/nginx/ssl/nginx.crt \
        -subj '/CN=localhost' \
        -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' 2>&1); then
        Write-Log ERROR "OpenSSL output: $output"
        Stop-Script "Certificate generation failed"
    fi
    
    chmod 600 /etc/nginx/ssl/nginx.key
    chmod 644 /etc/nginx/ssl/nginx.crt
}

New-NginxConfig() {
    Write-Log INFO "Creating nginx configuration"

    : > /etc/nginx/nginx.conf

    if [[ $SKIP_ZSTD != true ]]; then
        cat >> /etc/nginx/nginx.conf <<'EOF'
load_module /etc/nginx/modules/ngx_http_zstd_filter_module.so;
load_module /etc/nginx/modules/ngx_http_zstd_static_module.so;
EOF
    fi
    if [[ $SKIP_HEADERS_MORE != true ]]; then
        cat >> /etc/nginx/nginx.conf <<'EOF'
load_module /etc/nginx/modules/ngx_http_headers_more_filter_module.so;
EOF
    fi
    if [[ $ACME_MODULE_BUILT == true ]]; then
        cat >> /etc/nginx/nginx.conf <<'EOF'
load_module /etc/nginx/modules/ngx_http_acme_module.so;
EOF
    fi

    cat >> /etc/nginx/nginx.conf <<'EOF'

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    server_tokens off;
EOF

    if [[ $SKIP_HEADERS_MORE != true ]]; then
        cat >> /etc/nginx/nginx.conf <<'EOF'
    more_set_headers 'Server: nginx';
EOF
    fi

    cat >> /etc/nginx/nginx.conf <<'EOF'

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    types_hash_max_size 4096;
    types_hash_bucket_size 128;

    # Gzip compression
    gzip  on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;
EOF

    if [[ $SKIP_ZSTD != true ]]; then
        cat >> /etc/nginx/nginx.conf <<'EOF'

    # Zstd compression
    zstd on;
    zstd_comp_level 6;
    zstd_min_length 1024;
    zstd_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;
EOF
    fi

    cat >> /etc/nginx/nginx.conf <<'EOF'

    # SSL/TLS configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    # TLS 1.2 ciphers — ECDSA-only (matches the ECDSA certificate generated below).
    # TLS 1.3 ciphers are built-in and always secure; no need to list them.
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256;
    ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1:secp384r1;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_buffer_size 4k;

    # QUIC configuration
    quic_retry on;
    # 0-RTT disabled: no replay attack protection configured at application layer
    ssl_early_data off;

    server {
        listen 80;
        listen [::]:80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        listen [::]:443 ssl;
        listen 443 quic reuseport;
        listen [::]:443 quic reuseport;

        http2 on;
        http3 on;

        server_name localhost;

        ssl_certificate /etc/nginx/ssl/nginx.crt;
        ssl_certificate_key /etc/nginx/ssl/nginx.key;

        add_header Alt-Svc 'h3=":443"; ma=86400' always;
        add_header X-Protocol $server_protocol always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none';" always;
        add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;
        add_header Cross-Origin-Opener-Policy "same-origin" always;

        location / {
            root   /usr/share/nginx/html;
            index  index.html index.htm;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }
}
EOF
}

# ============================================================================
# Install/Remove Functions
# ============================================================================

Install-Nginx() {
    Write-Log INFO "Installing Nginx"

    local had_existing_nginx=false
    [[ -d /etc/nginx ]] && had_existing_nginx=true
    local had_existing_html=false
    [[ -f /usr/share/nginx/html/index.html ]] && had_existing_html=true

    # Backup existing configuration
    if [[ -d /etc/nginx ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a /etc/nginx "$BACKUP_DIR/" || true
    fi
    
    # Install binaries
    cd "$BUILD_DIR/nginx" || Stop-Script "Cannot cd to $BUILD_DIR/nginx"
    local output
    if ! output=$(make install 2>&1); then
        printf '%s\n' "$output" >> "$LOG_FILE"
        Write-Log ERROR "Install output: $(echo "$output" | tail -10)"
        Stop-Script "Nginx install failed"
    fi
    
    # Verify nginx binary exists
    [[ -x /usr/sbin/nginx ]] || Stop-Script "NGINX binary not found after install"
    
    # Create directories
    mkdir -p /etc/nginx/{conf.d,sites-available,sites-enabled}
    mkdir -p "${NGINX_MODULES_PATH}"
    mkdir -p /var/log/nginx /var/cache/nginx "${NGINX_PREFIX}/html"
    mkdir -p /var/lib/nginx/tmp/{client_body,proxy,fastcgi,uwsgi,scgi}

    # Symlink /etc/nginx/modules -> real modules dir (matches Fedora/RHEL convention)
    if [[ ! -L /etc/nginx/modules ]]; then
        ln -sf "${NGINX_MODULES_PATH}" /etc/nginx/modules
    fi

    # Install dynamic modules
    local nginx_module_files=()
    local module_file
    while IFS= read -r module_file; do
        nginx_module_files+=("$module_file")
    done < <(compgen -G 'objs/*.so' || true)

    if [[ ${#nginx_module_files[@]} -eq 0 ]]; then
        if [[ $SKIP_ZSTD == true && $SKIP_HEADERS_MORE == true ]]; then
            Write-Log INFO "No optional dynamic modules to install (zstd and headers-more both skipped)"
        else
            Stop-Script "No NGINX dynamic modules found in $BUILD_DIR/nginx/objs"
        fi
    else
        cp "${nginx_module_files[@]}" "${NGINX_MODULES_PATH}/" || Stop-Script "Failed to copy NGINX modules"
    fi

    if [[ $ACME_MODULE_BUILT == true ]]; then
        local acme_module="$BUILD_DIR/nginx-acme/objs/ngx_http_acme_module.so"
        if [[ -f "$acme_module" ]]; then
            cp "$acme_module" "${NGINX_MODULES_PATH}/" || Stop-Script "Failed to copy ACME module"
        else
            Write-Log WARN "ACME module artifact missing, skipping"
            ACME_MODULE_BUILT=false
        fi
    fi

    local required_modules=()
    [[ $SKIP_ZSTD == true ]] || required_modules+=(ngx_http_zstd_filter_module.so ngx_http_zstd_static_module.so)
    [[ $SKIP_HEADERS_MORE == true ]] || required_modules+=(ngx_http_headers_more_filter_module.so)
    [[ $ACME_MODULE_BUILT == true ]] && required_modules+=(ngx_http_acme_module.so)
    local module
    for module in "${required_modules[@]}"; do
        [[ -f "${NGINX_MODULES_PATH}/${module}" ]] || Stop-Script "Required module missing after install: ${module}"
    done

    # Install configuration files
    if [[ $had_existing_html == false ]]; then
        Install-HtmlFiles
    else
        Write-Log INFO "Existing HTML files preserved"
    fi
    New-SelfSignedCertificate
    if [[ $had_existing_nginx == false ]]; then
        New-NginxConfig
    else
        Write-Log INFO "Existing nginx.conf preserved"
    fi

    # Create nginx user
    if ! id nginx >/dev/null 2>&1; then
        useradd -r -s /sbin/nologin nginx || true
    fi

    chown -R nginx:nginx /var/log/nginx /var/cache/nginx /var/lib/nginx
    chown root:root /etc/nginx/ssl
    chmod 600 /etc/nginx/ssl/nginx.key
    chmod 644 /etc/nginx/ssl/nginx.crt
    chmod 755 /etc/nginx/conf.d "${NGINX_MODULES_PATH}"
    
    # Create systemd service
    cat > /etc/systemd/system/nginx.service <<'EOF'
[Unit]
Description=Nginx HTTP Server
After=network.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable nginx >/dev/null 2>&1
    if ! /usr/sbin/nginx -t; then
        Stop-Script "nginx configuration test failed — check the error above"
    fi
    systemctl start nginx || Stop-Script "Failed to start nginx service"
    
    local openssl_ver
    openssl_ver=$(openssl version 2>/dev/null | awk '{print $1" "$2}' || echo "OpenSSL unknown")
    Write-Log INFO "Nginx ${NGINX_VERSION} with ${openssl_ver} (system) installed"
    Write-Log INFO "Access: https://localhost"
    Write-Log INFO "Manage nginx with: systemctl {start|stop|reload|restart|status} nginx"
    /usr/sbin/nginx -V 2>&1 | head -n1 || true
    
    Test-NginxInstallation || Write-Log WARN "Post-install checks detected issues"
}

Test-NginxInstallation() {
    Write-Log INFO "Running post-install checks"
    
    [[ -f /etc/nginx/ssl/nginx.crt && -f /etc/nginx/ssl/nginx.key ]] || {
        Write-Log ERROR "SSL certificates missing"
        return 1
    }
    
    if [[ ! -f /etc/nginx/modules/ngx_http_acme_module.so ]]; then
        if [[ $ACME_MODULE_BUILT == true ]]; then
            Write-Log WARN "ACME module not found"
        else
            Write-Log INFO "ACME module skipped"
        fi
    else
        Write-Log INFO "ACME module present"
    fi
    
    if ! /usr/sbin/nginx -t >/dev/null 2>&1; then
        Write-Log ERROR "nginx -t failed"
        return 1
    fi
    
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        Write-Log WARN "Nginx service not active"
    fi
    
    if systemctl is-active --quiet nginx 2>/dev/null; then
        Write-Log INFO "Nginx service is active"
    fi

    curl -k https://localhost -I >/dev/null 2>&1 || Write-Log WARN "curl to https://localhost failed"

    return 0
}

Remove-Nginx() {
    Write-Log INFO "Removing Nginx"

    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    rm -f /etc/systemd/system/nginx.service
    systemctl daemon-reload 2>/dev/null || true

    rm -rf \
        /usr/sbin/nginx \
        /etc/nginx \
        /var/log/nginx \
        /var/cache/nginx \
        /var/lib/nginx \
        "${NGINX_PREFIX}" \
        "${NGINX_LIBDIR}/nginx"
    userdel nginx 2>/dev/null || true

    Write-Log INFO "Nginx removed"
}

Test-RunningWebServers() {
    local ports_in_use=()
    local has_lsof=0 has_ss=0
    command -v lsof >/dev/null 2>&1 && has_lsof=1
    command -v ss   >/dev/null 2>&1 && has_ss=1

    if [[ $has_lsof -eq 0 && $has_ss -eq 0 ]]; then
        Write-Log WARN "Neither lsof nor ss available; skipping port conflict check"
        return 0
    fi

    for port in 80 443; do
        local pid
        if [[ $has_lsof -eq 1 ]]; then
            pid=$(lsof -ti :"$port" 2>/dev/null | head -n1 || true)
        else
            pid=$(ss -tlnp 2>/dev/null \
                | awk -v p="${port}" '
                    $0 ~ ":"p"[[:space:]]" {
                        if (match($0, /pid=[0-9]+/)) { print substr($0, RSTART+4, RLENGTH-4); exit }
                    }' \
                || true)
        fi
        if [[ -n "$pid" ]]; then
            local proc
            proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            ports_in_use+=("$port ($proc)")
            Write-Log WARN "Port $port in use by: $proc"
        fi
    done

    if [[ ${#ports_in_use[@]} -gt 0 ]]; then
        read -r -p "Stop conflicting services? [y/N]: " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            systemctl stop apache2 2>/dev/null || true
            systemctl stop httpd 2>/dev/null || true
            systemctl stop nginx 2>/dev/null || true
            Write-Log INFO "Services stopped"
        else
            Stop-Script "Cannot proceed with ports in use: ${ports_in_use[*]}"
        fi
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

Show-Usage() {
    cat <<'EOF'
Usage: nginx_installer.sh {install|remove} [options]

Options:
  --skip-acme            Do not build/install the ACME module
  --skip-zstd            Do not build/install the zstd module
  --skip-headers-more    Do not build/install the headers-more module
  --skip-modules=a,b,c   Comma-separated list of: acme, zstd, headers-more
  -h, --help             Show this help

A module that fails to download or build is skipped automatically (with a
warning) instead of aborting the whole install.
EOF
}

COMMAND="install"
if [[ $# -gt 0 && "$1" != -* ]]; then
    COMMAND="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-acme)
            SKIP_ACME=true
            ;;
        --skip-zstd)
            SKIP_ZSTD=true
            ;;
        --skip-headers-more)
            SKIP_HEADERS_MORE=true
            ;;
        --skip-modules=*)
            IFS=',' read -ra _skip_list <<< "${1#*=}"
            for _module in "${_skip_list[@]}"; do
                case "$_module" in
                    acme)          SKIP_ACME=true ;;
                    zstd)          SKIP_ZSTD=true ;;
                    headers-more)  SKIP_HEADERS_MORE=true ;;
                    *) Stop-Script "Unknown module: $_module (expected acme, zstd, headers-more)" ;;
                esac
            done
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
    shift
done

trap 'rm -rf "$BUILD_DIR"' EXIT

case "$COMMAND" in
    install)
        Update-SystemPackages
        Test-RunningWebServers
        Install-Dependencies
        Get-Sources
        Build-Nginx
        Install-Nginx
        echo
        echo "Installation log: $LOG_FILE"
        ;;
    remove)
        Remove-Nginx
        echo
        echo "Removal log: $LOG_FILE"
        ;;
    *)
        Show-Usage
        exit 1
        ;;
esac
