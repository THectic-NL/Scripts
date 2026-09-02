<#
.SYNOPSIS
    NGINX Installer Script for Linux (PowerShell)

.DESCRIPTION
    Builds and installs NGINX with OpenSSL, HTTP/3, zstd compression,
    and ACME support on Linux.

.PARAMETER Command
    install - Build and install NGINX
    remove  - Uninstall NGINX

.EXAMPLE
    ./nginx_installer.ps1 -Command install
#>

#!/usr/bin/env pwsh
#Requires -Version 7.1

param(
    [ValidateSet('install','remove')]
    [string]$Command = 'install'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Linux only check
if (-not $IsLinux) {
    Write-Host 'ERROR: This script is for Linux only.' -ForegroundColor Red
    exit 1
}

# ============================================================================
# Version Configuration
# ============================================================================

# NGINX
$Script:NGINX_VERSION = '1.31.5'
$Script:NGINX_SHA256  = 'e6f20b644a17a643f059ae6467a1971fe2811587d025e071068753a1f1e3b3c3'

# PCRE2
$Script:PCRE2_VERSION = '10.48'
$Script:PCRE2_SHA256  = 'ebcc25aadf2a51fa1fefa9b8bc9e7a79b3dae86870a0f1152a22e42befd46888'

# Zlib
$Script:ZLIB_VERSION = '1.3.2'
$Script:ZLIB_SHA256  = 'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'

# Headers-More Module
$Script:HEADERS_MORE_VERSION = '0.39'
$Script:HEADERS_MORE_SHA256  = 'dde68d3fa2a9fc7f52e436d2edc53c6d703dcd911283965d889102d3a877c778'

# Zstd Module
$Script:ZSTD_MODULE_VERSION = '0.1.1'
$Script:ZSTD_MODULE_SHA256  = '707d534f8ca4263ff043066db15eac284632aea875f9fe98c96cea9529e15f41'

# ACME Module
$Script:ACME_MODULE_VERSION = '0.4.1'
$Script:ACME_MODULE_SHA256  = 'b4f99f971bd0bebc89b2037f3afeaa3281004fe434de558df87d69cab2be1f22'

# ============================================================================
# Static Configuration
# ============================================================================

$Script:BUILD_DIR  = "/var/tmp/nginx-build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$Script:BACKUP_DIR = "/var/lib/nginx-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$Script:LOG_FILE   = "/var/log/nginx-installer-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# FHS-compliant install paths (matching what dnf/rpm would use)
$Script:NGINX_PREFIX = '/usr/share/nginx'
$Script:NGINX_LIBDIR = if ((& uname -m) -in @('x86_64', 'aarch64')) { '/usr/lib64' } else { '/usr/lib' }
$Script:NGINX_MODULES_PATH = "$Script:NGINX_LIBDIR/nginx/modules"

# Download URLs
$Script:NGINX_URL        = "https://github.com/nginx/nginx/releases/download/release-$($Script:NGINX_VERSION)/nginx-$($Script:NGINX_VERSION).tar.gz"
$Script:PCRE2_URL        = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$($Script:PCRE2_VERSION)/pcre2-$($Script:PCRE2_VERSION).tar.gz"
$Script:ZLIB_URL         = "https://github.com/madler/zlib/releases/download/v$($Script:ZLIB_VERSION)/zlib-$($Script:ZLIB_VERSION).tar.gz"
$Script:HEADERS_MORE_URL = "https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v$($Script:HEADERS_MORE_VERSION).tar.gz"
$Script:ZSTD_MODULE_URL  = "https://github.com/tokers/zstd-nginx-module/archive/refs/tags/$($Script:ZSTD_MODULE_VERSION).tar.gz"
$Script:ACME_MODULE_URL  = "https://github.com/nginx/nginx-acme/releases/download/v$($Script:ACME_MODULE_VERSION)/nginx-acme-$($Script:ACME_MODULE_VERSION).tar.gz"

# Ensure directories exist
$null = New-Item -ItemType Directory -Path $Script:BUILD_DIR -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Path (Split-Path $Script:LOG_FILE -Parent) -Force -ErrorAction SilentlyContinue

# Start transcript logging (equivalent to Bash exec > >(tee -a ...))
if (-not (Test-Path $Script:LOG_FILE)) {
    Start-Transcript -Path $Script:LOG_FILE -Append | Out-Null
}

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    $logMessage = "[$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $Script:LOG_FILE -Value $logMessage -ErrorAction SilentlyContinue
}

function Stop-Script {
    param([string]$Message)
    Write-Log 'ERROR' $Message
    exit 1
}

function Test-Hash {
    param(
        [string]$File,
        [string]$Expected
    )
    $actual = (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Expected.ToLower()) {
        Stop-Script "Checksum failed: $File"
    }
}

function Get-File {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Hash
    )
    $fullPath = Join-Path $Script:BUILD_DIR $OutFile

    if (Test-Path $fullPath) {
        Test-Hash -File $fullPath -Expected $Hash
        return
    }

    Write-Log 'INFO' "Downloading $(Split-Path -Leaf $OutFile)..."
    try {
        Push-Location $Script:BUILD_DIR
        & curl -fsSL $Url -o $OutFile
        if ($LASTEXITCODE -ne 0) { throw 'Download failed' }
        Pop-Location
    } catch {
        Pop-Location -ErrorAction SilentlyContinue
        Stop-Script "Download failed: $Url"
    }
    Test-Hash -File $fullPath -Expected $Hash
}

function Get-PkgMgr {
    if (Get-Command apt-get -ErrorAction SilentlyContinue) {
        return 'apt'
    } elseif (Get-Command dnf -ErrorAction SilentlyContinue) {
        return 'dnf'
    } elseif (Get-Command pacman -ErrorAction SilentlyContinue) {
        return 'pacman'
    } else {
        return 'unknown'
    }
}

# ============================================================================
# System Dependencies
# ============================================================================

function Install-Dependencies {
    try {
        $uid = & id -u 2>$null
        if ($uid -ne '0') { Stop-Script 'Run as root' }
    } catch {
        Stop-Script 'Cannot determine user ID; run as root'
    }

    if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
        Stop-Script 'curl required'
    }

    Write-Log 'INFO' 'Installing build dependencies'

    $mgr = Get-PkgMgr
    switch ($mgr) {
        'apt' {
            $env:DEBIAN_FRONTEND = 'noninteractive'
            & apt-get update -qq 2>&1 | Out-Null
            & apt-get install -y build-essential libpcre2-dev zlib1g-dev libzstd-dev libssl-dev curl gcc make cargo pkg-config clang gawk cmake 2>&1 | Out-Null
        }
        'dnf' {
            & dnf install -y -q gcc gcc-c++ make pcre2-devel zlib-devel libzstd-devel openssl-devel curl perl cargo pkgconf-pkg-config clang gawk cmake 2>&1 | Out-Null
        }
        'pacman' {
            $null = & pacman -Sy --noconfirm --needed base-devel pcre2 zstd openssl curl clang gawk cmake pkgconf 2>&1
            $pacmanExit = $LASTEXITCODE
            if ($pacmanExit -ne 0) {
                Write-Log WARN "pacman install failed, will try rustup for cargo. Note: zlib is not required (zlib-ng-compat provides it)."
            }
        }
        default {
            Stop-Script 'Unsupported package manager. Only apt, dnf and pacman are supported.'
        }
    }

    # Verify cargo availability
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Log 'WARN' 'Cargo not found. Installing rustup...'
        bash -lc "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" | Out-Null
    }

    Write-Log 'INFO' 'Dependencies installed'
}

function Update-SystemPackages {
    try {
        $uid = & id -u 2>$null
        if ($uid -ne '0') { Stop-Script 'Run as root' }
    } catch {
        Stop-Script 'Cannot determine user ID; run as root'
    }

    Write-Log 'INFO' 'Updating system packages'

    $mgr = Get-PkgMgr
    switch ($mgr) {
        'apt' {
            $env:DEBIAN_FRONTEND = 'noninteractive'
            & apt-get update -qq 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Log 'WARN' 'apt-get update failed' }
            & apt-get upgrade -y -q 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Stop-Script 'apt-get upgrade failed' }
        }
        'dnf' {
            $dnfOutput = & dnf upgrade -y -q 2>&1 | Select-String -Pattern '(Complete|Error|Failed)'
            if ($LASTEXITCODE -ne 0) { Stop-Script 'dnf upgrade failed' }
            if ($dnfOutput) { $dnfOutput | Out-Host }
        }
        'pacman' {
            & pacman -Syu --noconfirm 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Log 'WARN' 'pacman upgrade failed' }
        }
        default {
            Write-Log 'WARN' 'Unable to detect package manager'
        }
    }

    Write-Log 'INFO' 'System packages updated'
}

# ============================================================================
# Download Sources
# ============================================================================

function Get-Sources {
    Push-Location $Script:BUILD_DIR
    Write-Log 'INFO' 'Downloading sources'

    Get-File $Script:NGINX_URL        'nginx.tgz'   $Script:NGINX_SHA256
    Get-File $Script:PCRE2_URL        'pcre2.tgz'   $Script:PCRE2_SHA256
    Get-File $Script:ZLIB_URL         'zlib.tgz'    $Script:ZLIB_SHA256
    Get-File $Script:HEADERS_MORE_URL 'headers.tgz' $Script:HEADERS_MORE_SHA256
    Get-File $Script:ZSTD_MODULE_URL  'zstd.tgz'    $Script:ZSTD_MODULE_SHA256
    Get-File $Script:ACME_MODULE_URL  'acme.tgz'    $Script:ACME_MODULE_SHA256

    Write-Log 'INFO' 'Extracting archives'

    # Clean previous extractions
    Remove-Item nginx, openssl, pcre2, zlib, headers-more, zstd-module, nginx-acme -Recurse -Force -ErrorAction SilentlyContinue

    & tar xzf nginx.tgz
    Move-Item "nginx-$Script:NGINX_VERSION" nginx -Force

    & tar xzf pcre2.tgz
    Move-Item "pcre2-$Script:PCRE2_VERSION" pcre2 -Force

    & tar xzf zlib.tgz
    Move-Item "zlib-$Script:ZLIB_VERSION" zlib -Force

    & tar xzf headers.tgz
    Move-Item "headers-more-nginx-module-$Script:HEADERS_MORE_VERSION" headers-more -Force

    & tar xzf zstd.tgz
    Move-Item "zstd-nginx-module-$Script:ZSTD_MODULE_VERSION" zstd-module -Force

    & tar xzf acme.tgz
    Move-Item "nginx-acme-$Script:ACME_MODULE_VERSION" nginx-acme -Force

    Pop-Location
    Write-Log 'INFO' 'Sources ready'
}

# ============================================================================
# Build Functions
# ============================================================================

function Build-Nginx {
    # Clean compiler temp files (not the build dir itself — managed by finally block)
    Get-ChildItem /tmp -Filter 'cc*'   -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem /tmp -Filter 'tmp.*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Check disk space in /var/tmp
    $tmpSpace = (& df /var/tmp | Select-Object -Skip 1 | ForEach-Object {
        $_.Split([char[]]@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries)[3]
    })
    if ($tmpSpace -and [int]$tmpSpace -lt 1048576) {
        Write-Log 'WARN' 'Low disk space in /var/tmp, using build directory'
        $env:TMPDIR = $Script:BUILD_DIR
    }

    # Ensure cc symlink exists
    if (-not (Get-Command cc -ErrorAction SilentlyContinue)) {
        $gccPath = Get-Command gcc -ErrorAction SilentlyContinue
        if ($gccPath -and (Test-Path '/usr/local/bin')) {
            New-Item -ItemType SymbolicLink -Path '/usr/local/bin/cc' -Target $gccPath.Source -Force -ErrorAction SilentlyContinue | Out-Null
            $env:PATH = "/usr/local/bin:$($env:PATH)"
        }
    }

    # Build NGINX
    Write-Log 'INFO' "Building Nginx $Script:NGINX_VERSION"
    $nginxSrc = Join-Path $Script:BUILD_DIR 'nginx'
    if (-not (Test-Path $nginxSrc)) { Stop-Script 'Nginx source missing' }
    Push-Location $nginxSrc

    # Verify libzstd availability
    $ldconfigAvail = bash -c 'command -v ldconfig >/dev/null 2>&1 && echo yes || echo no'
    if ($ldconfigAvail.Trim() -eq 'yes') {
        $ldconfigResult = bash -c 'ldconfig -p 2>/dev/null | grep -q "libzstd.so" && echo found || echo missing'
        if ($ldconfigResult.Trim() -eq 'missing') {
            Stop-Script 'Shared libzstd not found. Install libzstd-dev/devel'
        }
    } else {
        $zstdPaths = @('/usr/lib/libzstd.so', '/usr/lib/libzstd.so.1', '/usr/lib64/libzstd.so', '/usr/lib64/libzstd.so.1', '/usr/local/lib/libzstd.so')
        $found = $zstdPaths | Where-Object { Test-Path $_ }
        if (-not $found) {
            Stop-Script 'Shared libzstd not found. Install libzstd-dev/devel'
        }
    }

    $pcre2Path   = Join-Path $Script:BUILD_DIR 'pcre2'
    $zlibPath    = Join-Path $Script:BUILD_DIR 'zlib'
    $headersPath = Join-Path $Script:BUILD_DIR 'headers-more'
    $zstdPath    = Join-Path $Script:BUILD_DIR 'zstd-module'

    $configCmd = @"
export TMPDIR='$Script:BUILD_DIR'
export CC=gcc
export LDFLAGS='-lzstd'
./configure \
  --with-compat \
  --prefix=$Script:NGINX_PREFIX \
  --sbin-path=/usr/sbin/nginx \
  --conf-path=/etc/nginx/nginx.conf \
  --http-log-path=/var/log/nginx/access.log \
  --error-log-path=/var/log/nginx/error.log \
  --pid-path=/run/nginx.pid \
  --lock-path=/run/lock/nginx.lock \
  --http-client-body-temp-path=/var/lib/nginx/tmp/client_body \
  --http-proxy-temp-path=/var/lib/nginx/tmp/proxy \
  --http-fastcgi-temp-path=/var/lib/nginx/tmp/fastcgi \
  --http-uwsgi-temp-path=/var/lib/nginx/tmp/uwsgi \
  --http-scgi-temp-path=/var/lib/nginx/tmp/scgi \
  --with-pcre=$pcre2Path \
  --with-zlib=$zlibPath \
  --with-pcre-jit \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-http_gzip_static_module \
  --with-http_stub_status_module \
  --with-http_realip_module \
  --with-http_sub_module \
  --with-http_secure_link_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-stream_realip_module \
  --with-file-aio \
  --with-threads \
  --modules-path=$Script:NGINX_MODULES_PATH \
  --add-dynamic-module=$headersPath \
  --add-dynamic-module=$zstdPath
"@

    $configOutput = bash -c "$configCmd 2>&1"
    if ($LASTEXITCODE -ne 0) {
        $lastLines = ($configOutput -split "`n" | Select-Object -Last 20) -join "`n"
        Write-Log 'ERROR' "Configure output: $lastLines"
        Stop-Script 'Nginx configure failed'
    }

    # Patch Makefile for shared libzstd
    if (Test-Path 'objs/Makefile') {
        Write-Log 'INFO' 'Patching nginx Makefile for shared libzstd'
        bash -c "sed -i 's/-l:libzstd\.a/-lzstd/g' objs/Makefile" | Out-Null
    }

    $nproc = (bash -c 'nproc').Trim()
    $makeOutput = bash -c "export TMPDIR='$Script:BUILD_DIR' && make -j$nproc 2>&1"
    if ($LASTEXITCODE -ne 0) {
        $lastLines = ($makeOutput -split "`n" | Select-Object -Last 20) -join "`n"
        Write-Log 'ERROR' "Make output: $lastLines"
        Stop-Script 'Nginx build failed'
    }

    # Build ACME Module
    Write-Log 'INFO' "Building ACME module $Script:ACME_MODULE_VERSION"
    $acmeSrc = Join-Path $Script:BUILD_DIR 'nginx-acme'
    if (-not (Test-Path $acmeSrc)) { Stop-Script 'ACME source missing' }
    Push-Location $acmeSrc

    $env:NGINX_BUILD_DIR       = Join-Path $Script:BUILD_DIR 'nginx/objs'
    $env:NGX_ACME_STATE_PREFIX = '/var/cache/nginx'

    $sourceCargo = 'if [ -f "$HOME/.cargo/env" ]; then source "$HOME/.cargo/env"; fi'

    # Verify Rust toolchain
    $rustcVer = bash -lc "$sourceCargo && rustc --version 2>/dev/null"
    if (-not $rustcVer) {
        Write-Log 'WARN' 'rustc not found, installing rustup...'
        bash -lc "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" | Out-Null
    }

    $acmeOutput = bash -lc "$sourceCargo && cargo build --release 2>&1"
    if ($LASTEXITCODE -ne 0) {
        $lastLines = ($acmeOutput -split "`n" | Select-Object -Last 20) -join "`n"
        Write-Log 'ERROR' "ACME build failed: $lastLines"
        Stop-Script 'ACME module build failed'
    }

    New-Item -ItemType Directory -Path "$Script:BUILD_DIR/nginx-acme/objs" -Force | Out-Null
    $acmeSo = 'target/release/libnginx_acme.so'
    if (-not (Test-Path $acmeSo)) {
        Stop-Script "ACME module not built: $acmeSo missing (cargo build may have failed)"
    }
    try {
        Copy-Item $acmeSo -Destination "$Script:BUILD_DIR/nginx-acme/objs/ngx_http_acme_module.so" -Force -ErrorAction Stop
    } catch {
        Stop-Script "Failed to stage ACME module: $($_.Exception.Message)"
    }

    Pop-Location # nginx-acme
    Pop-Location # nginx
    Write-Log 'INFO' 'ACME module built successfully'
    Write-Log 'INFO' 'Build complete'
}

# ============================================================================
# Configuration Functions
# ============================================================================

function Install-HtmlFiles {
    Write-Log 'INFO' 'Installing HTML files'
    $htmlDir = '/usr/share/nginx/html'
    New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null

    $indexContent = @'
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
'@

    $styleContent = @'
body {
    width: 35em;
    margin: 0 auto;
    font-family: Tahoma, Verdana, Arial, sans-serif;
}
'@

    $indexContent | Out-File (Join-Path $htmlDir 'index.html') -Encoding utf8 -Force
    $styleContent | Out-File (Join-Path $htmlDir 'style.css') -Encoding utf8 -Force
    bash -c "chmod 0644 $htmlDir/*.html $htmlDir/*.css 2>/dev/null || true" | Out-Null
}

function New-NginxSelfSignedCertificate {
    Write-Log 'INFO' 'Generating self-signed TLS certificate'
    $sslDir = '/etc/nginx/ssl'
    New-Item -ItemType Directory -Path $sslDir -Force | Out-Null

    if ((Test-Path "$sslDir/nginx.key") -and (Test-Path "$sslDir/nginx.crt")) {
        Write-Log 'INFO' 'Existing SSL certificate preserved'
        return
    }

    $opensslBin = (Get-Command openssl -ErrorAction SilentlyContinue)?.Source
    if (-not $opensslBin) { Stop-Script 'openssl not found' }

    $keyPath = "$sslDir/nginx.key"
    $crtPath = "$sslDir/nginx.crt"

    $cmd = "OPENSSL_CONF=/dev/null '$opensslBin' req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -days 365 -nodes -keyout '$keyPath' -out '$crtPath' -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' 2>&1"
    $output = bash -c $cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'ERROR' "OpenSSL output: $output"
        Stop-Script 'Certificate generation failed'
    }

    bash -c "chmod 600 '$keyPath' && chmod 644 '$crtPath'" | Out-Null
}

function New-NginxConfig {
    Write-Log 'INFO' 'Creating nginx configuration'
    $conf = @'
load_module /etc/nginx/modules/ngx_http_zstd_filter_module.so;
load_module /etc/nginx/modules/ngx_http_zstd_static_module.so;
load_module /etc/nginx/modules/ngx_http_headers_more_filter_module.so;
load_module /etc/nginx/modules/ngx_http_acme_module.so;

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
    more_set_headers 'Server: nginx';

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

    # Zstd compression
    zstd on;
    zstd_comp_level 6;
    zstd_min_length 1024;
    zstd_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;

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
'@
    $conf | Out-File '/etc/nginx/nginx.conf' -Encoding utf8 -Force
}

# ============================================================================
# Install/Remove Functions
# ============================================================================

function Install-Nginx {
    Write-Log 'INFO' 'Installing Nginx'

    $hadExistingNginx = Test-Path '/etc/nginx'
    $hadExistingHtml  = Test-Path '/usr/share/nginx/html/index.html'

    # Backup existing configuration
    if (Test-Path '/etc/nginx') {
        New-Item -ItemType Directory -Path $Script:BACKUP_DIR -Force | Out-Null
        Copy-Item '/etc/nginx' "$Script:BACKUP_DIR/" -Recurse -Force
    }

    # Install binaries
    Push-Location (Join-Path $Script:BUILD_DIR 'nginx')
    $installOut = bash -c 'make install 2>&1'
    if ($LASTEXITCODE -ne 0) {
        $lastLines = ($installOut -split "`n" | Select-Object -Last 10) -join "`n"
        Write-Log 'ERROR' "Install output: $lastLines"
        Stop-Script 'Nginx install failed'
    }
    Pop-Location

    # Create directories
    $dirs = @(
        '/etc/nginx/conf.d',
        '/etc/nginx/sites-available',
        '/etc/nginx/sites-enabled',
        $Script:NGINX_MODULES_PATH,
        '/var/log/nginx',
        '/var/cache/nginx',
        "$Script:NGINX_PREFIX/html",
        '/var/lib/nginx/tmp/client_body',
        '/var/lib/nginx/tmp/proxy',
        '/var/lib/nginx/tmp/fastcgi',
        '/var/lib/nginx/tmp/uwsgi',
        '/var/lib/nginx/tmp/scgi'
    )
    foreach ($d in $dirs) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    # Symlink /etc/nginx/modules -> real modules dir (matches Fedora/RHEL convention)
    $modulesLink = '/etc/nginx/modules'
    $existingItem = Get-Item $modulesLink -Force -ErrorAction SilentlyContinue
    if (-not $existingItem -or $existingItem.LinkType -ne 'SymbolicLink') {
        Remove-Item $modulesLink -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType SymbolicLink -Path $modulesLink -Target $Script:NGINX_MODULES_PATH -Force | Out-Null
    }

    # Install dynamic modules
    $nginxModules = Get-ChildItem -Path "$Script:BUILD_DIR/nginx/objs" -Filter '*.so' -File -ErrorAction SilentlyContinue
    if (-not $nginxModules) {
        Stop-Script "No NGINX dynamic modules found in $Script:BUILD_DIR/nginx/objs"
    }
    try {
        Copy-Item -Path $nginxModules.FullName -Destination $Script:NGINX_MODULES_PATH -Force -ErrorAction Stop
    } catch {
        Stop-Script "Failed to copy NGINX modules: $($_.Exception.Message)"
    }

    $acmeModule = "$Script:BUILD_DIR/nginx-acme/objs/ngx_http_acme_module.so"
    if (-not (Test-Path $acmeModule)) {
        Stop-Script "ACME module not found: $acmeModule"
    }
    try {
        Copy-Item -Path $acmeModule -Destination $Script:NGINX_MODULES_PATH -Force -ErrorAction Stop
    } catch {
        Stop-Script "Failed to copy ACME module: $($_.Exception.Message)"
    }

    $requiredModules = @(
        'ngx_http_zstd_filter_module.so',
        'ngx_http_zstd_static_module.so',
        'ngx_http_headers_more_filter_module.so',
        'ngx_http_acme_module.so'
    )
    foreach ($module in $requiredModules) {
        if (-not (Test-Path (Join-Path $Script:NGINX_MODULES_PATH $module))) {
            Stop-Script "Required module missing after install: $module"
        }
    }

    # Install configuration files
    if (-not $hadExistingHtml) {
        Install-HtmlFiles
    } else {
        Write-Log 'INFO' 'Existing HTML files preserved'
    }
    New-NginxSelfSignedCertificate
    if (-not $hadExistingNginx) {
        New-NginxConfig
    } else {
        Write-Log 'INFO' 'Existing nginx.conf preserved'
    }

    # Create nginx user
    bash -c 'id nginx 2>/dev/null || useradd -r -s /sbin/nologin nginx' | Out-Null

    bash -c "chown -R nginx:nginx /var/log/nginx /var/cache/nginx /var/lib/nginx" | Out-Null
    bash -c "chown root:root /etc/nginx/ssl" | Out-Null
    bash -c "chmod 600 /etc/nginx/ssl/nginx.key" | Out-Null
    bash -c "chmod 644 /etc/nginx/ssl/nginx.crt" | Out-Null
    bash -c "chmod 755 /etc/nginx/conf.d '$Script:NGINX_MODULES_PATH'" | Out-Null

    # Create systemd service
    $svc = @'
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
'@
    $svc | Out-File '/etc/systemd/system/nginx.service' -Encoding utf8 -Force

    bash -c 'systemctl daemon-reload' | Out-Null
    bash -c 'systemctl enable nginx' 2>&1 | Out-Null
    bash -c '/usr/sbin/nginx -t && systemctl start nginx' | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Script 'Failed to start nginx' }

    $opensslVer = (bash -c 'openssl version 2>/dev/null').Trim()
    if (-not $opensslVer) { $opensslVer = 'OpenSSL unknown' }
    Write-Log 'INFO' "Nginx $Script:NGINX_VERSION with $opensslVer (system) installed"
    Write-Log 'INFO' 'Access: https://localhost'
    Write-Log 'INFO' 'Manage nginx with: systemctl {start|stop|reload|restart|status} nginx'
    bash -c '/usr/sbin/nginx -V 2>&1 | head -n1'

    $testResult = Test-NginxInstallation
    if (-not $testResult) {
        Write-Log 'WARN' 'Post-install checks detected issues'
    }
}

function Test-NginxInstallation {
    Write-Log 'INFO' 'Running post-install checks'
    $ok = $true

    if (-not (Test-Path '/etc/nginx/ssl/nginx.crt') -or -not (Test-Path '/etc/nginx/ssl/nginx.key')) {
        Write-Log 'ERROR' 'SSL certificates missing'
        $ok = $false
    }

    if (-not (Test-Path "$Script:NGINX_MODULES_PATH/ngx_http_acme_module.so")) {
        Write-Log 'WARN' 'ACME module not found'
    } else {
        Write-Log 'INFO' 'ACME module present'
    }

    $nginxTest = bash -c '/usr/sbin/nginx -t 2>&1'
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'ERROR' "nginx -t failed: $nginxTest"
        $ok = $false
    }

    bash -c 'systemctl is-active --quiet nginx' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'WARN' 'Nginx service not active'
    } else {
        Write-Log 'INFO' 'Nginx service is active'
    }

    bash -c 'curl -k https://localhost -I >/dev/null 2>&1 || true' | Out-Null

    return $ok
}

function Remove-Nginx {
    Write-Log 'INFO' 'Removing Nginx'

    bash -c 'systemctl stop nginx 2>/dev/null || true' | Out-Null
    bash -c 'systemctl disable nginx 2>/dev/null || true' | Out-Null
    Remove-Item '/etc/systemd/system/nginx.service' -Force -ErrorAction SilentlyContinue
    bash -c 'systemctl daemon-reload 2>/dev/null || true' | Out-Null

    $toRemove = @(
        '/usr/sbin/nginx',
        '/etc/nginx',
        '/var/log/nginx',
        '/var/cache/nginx',
        '/var/lib/nginx',
        $Script:NGINX_PREFIX,
        "$Script:NGINX_LIBDIR/nginx"
    )
    foreach ($path in $toRemove) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    bash -c 'userdel nginx 2>/dev/null || true' | Out-Null
    Write-Log 'INFO' 'Nginx removed'
}

function Test-RunningWebServers {
    $portsInUse = [System.Collections.Generic.List[string]]::new()

    $portTool = (bash -c '(command -v lsof >/dev/null 2>&1 && echo lsof) || (command -v ss >/dev/null 2>&1 && echo ss) || echo none').Trim()
    if ($portTool -eq 'none') {
        Write-Log 'WARN' 'Neither lsof nor ss available; skipping port conflict check'
        return
    }

    foreach ($port in @(80, 443)) {
        $detectPid = @'
tool=$1; port=$2
if [ "$tool" = "lsof" ]; then
    lsof -ti ":$port" 2>/dev/null | head -n1
else
    ss -tlnp 2>/dev/null | awk -v p="$port" '
        $0 ~ ":"p"[[:space:]]" {
            if (match($0, /pid=[0-9]+/)) { print substr($0, RSTART+4, RLENGTH-4); exit }
        }'
fi
'@
        $procId = (bash -c $detectPid 'detect-port' $portTool $port 2>$null)?.Trim()
        if ($procId) {
            $proc = (bash -c "ps -p $procId -o comm= 2>/dev/null || echo unknown").Trim()
            $portsInUse.Add("$port ($proc)")
            Write-Log 'WARN' "Port $port in use by: $proc"
        }
    }

    if ($portsInUse.Count -gt 0) {
        $response = Read-Host 'Stop conflicting services? [y/N]'
        if ($response -match '^[Yy]') {
            bash -c 'systemctl stop apache2 2>/dev/null || true' | Out-Null
            bash -c 'systemctl stop httpd 2>/dev/null || true' | Out-Null
            bash -c 'systemctl stop nginx 2>/dev/null || true' | Out-Null
            Write-Log 'INFO' 'Services stopped'
        } else {
            Stop-Script "Cannot proceed with ports in use: $($portsInUse -join ', ')"
        }
    }
}

# ============================================================================
# Main Entry Point
# ============================================================================

try {
    switch ($Command) {
        'install' {
            Update-SystemPackages
            Test-RunningWebServers
            Install-Dependencies
            Get-Sources
            Build-Nginx
            Install-Nginx
            Write-Host "`nInstallation log: $Script:LOG_FILE"
        }
        'remove' {
            Remove-Nginx
            Write-Host "`nRemoval log: $Script:LOG_FILE"
        }
    }
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
    Remove-Item $Script:BUILD_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
