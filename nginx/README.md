# NGINX Installer

Builds NGINX from source with hardened defaults: TLS 1.3 only, post-quantum key exchange (X25519MLKEM768), HTTP/2, HTTP/3 (QUIC), zstd compression, headers-more, and ACME module.

Requires the system OpenSSL to be 3.5 or newer (Debian 13, Ubuntu 26.04, current Fedora and Arch). On older systems the installer stops before changing anything.

```bash
sudo ./nginx_installer.sh install
sudo ./nginx_installer.sh remove
```

## Optional modules

zstd, headers-more and ACME are optional dynamic modules. Skip any of them
up front, or let the installer skip them automatically (with a warning)
when a download or build fails, instead of aborting the whole install:

```bash
sudo ./nginx_installer.sh install --skip-acme
sudo ./nginx_installer.sh install --skip-modules=acme,zstd,headers-more
```

| Flag | Skips |
|------|-------|
| `--skip-acme` | ACME module |
| `--skip-zstd` | zstd compression module |
| `--skip-headers-more` | headers-more module |
| `--skip-modules=a,b,c` | Any combination of `acme`, `zstd`, `headers-more` |

## Adding sites

A fresh install ships ready-to-copy reverse-proxy examples. They end in
`.example`, so nginx ignores them until you copy one:

| File | For |
|------|-----|
| `conf.d/homeassistant.conf.example` | Home Assistant |
| `conf.d/jellyfin.conf.example` | Jellyfin |
| `conf.d/arr.conf.example` | Sonarr, Radarr, Lidarr, Readarr, Prowlarr, Bazarr |
| `conf.d/seerr.conf.example` | Seerr / Jellyseerr / Overseerr |
| `conf.d/qbittorrent.conf.example` | qBittorrent Web UI |
| `conf.d/cockpit.conf.example` | Cockpit |
| `stream.d/minecraft.conf.example` | Plain TCP passthrough (Minecraft) |

Each file lists the settings the app itself needs (trusted proxies, allowed
origins, ...). Shared proxy settings live in `snippets/proxy.conf`.

```bash
cd /etc/nginx/conf.d
sudo cp homeassistant.conf.example home.example.com.conf   # then edit the name and upstream
sudo certbot certonly --webroot -w /var/www/acme -d home.example.com \
     --deploy-hook "systemctl reload nginx"
sudo nginx -t && sudo systemctl reload nginx
```

Port 80 answers ACME HTTP-01 challenges from `/var/www/acme` for every name
and redirects everything else to HTTPS. The bare IP address and names without
their own site get the self-signed `localhost` certificate, never a real one.

## Installed paths

| Path | Purpose |
|------|---------|
| `/usr/sbin/nginx` | Binary |
| `/etc/nginx/nginx.conf` | Main config |
| `/etc/nginx/ssl/` | TLS certificates |
| `/etc/nginx/conf.d/` | One file per site (`*.conf`), plus the `*.conf.example` files |
| `/etc/nginx/stream.d/` | TCP/UDP passthrough (`*.conf`) |
| `/etc/nginx/snippets/proxy.conf` | Shared reverse-proxy settings |
| `/var/www/acme/` | ACME HTTP-01 challenge webroot |
| `/etc/nginx/modules` | Symlink → `/usr/lib64/nginx/modules` |
| `/usr/lib64/nginx/modules/` | Dynamic modules |
| `/usr/share/nginx/html/` | Default web root |
| `/var/log/nginx/` | Logs |
| `/var/cache/nginx/` | ACME state and cache |
| `/var/lib/nginx/` | Temp files |
| `/etc/systemd/system/nginx.service` | Systemd service |

## Service management

```bash
sudo systemctl {start|stop|reload|restart|status} nginx
```

## Manual removal

```bash
sudo systemctl stop nginx && sudo systemctl disable nginx
sudo rm -f /etc/systemd/system/nginx.service /etc/modules-load.d/nginx-ktls.conf
sudo systemctl daemon-reload
sudo rm -rf /usr/sbin/nginx /etc/nginx /usr/lib64/nginx /usr/share/nginx \
            /var/log/nginx /var/cache/nginx /var/lib/nginx /var/www/acme
sudo userdel nginx
```

Build directories are created in `/tmp/` and cleaned up automatically on exit.
