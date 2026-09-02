# NGINX Installer

Builds NGINX from source with hardened defaults: OpenSSL 3.x, HTTP/2, HTTP/3 (QUIC), zstd compression, headers-more, and ACME module.

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

## Installed paths

| Path | Purpose |
|------|---------|
| `/usr/sbin/nginx` | Binary |
| `/etc/nginx/nginx.conf` | Main config |
| `/etc/nginx/ssl/` | TLS certificates |
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
sudo rm -f /etc/systemd/system/nginx.service
sudo systemctl daemon-reload
sudo rm -rf /usr/sbin/nginx /etc/nginx /usr/lib64/nginx /usr/share/nginx \
            /var/log/nginx /var/cache/nginx /var/lib/nginx
sudo userdel nginx
```

Build directories are created in `/tmp/` and cleaned up automatically on exit.
