# Scripts

Installer scripts for tools and software I use regularly. Tailored to my preferences, but easy to adapt.

## Usage

```bash
git clone --recurse-submodules https://github.com/Stensel8/scripts.git
cd scripts
```

Bash:
```bash
./<tool>_installer.sh
```

PowerShell:
```powershell
pwsh ./<tool>_installer.ps1
```

## Scripts

| Directory | File(s) | Platform | Notes |
|-----------|---------|----------|-------|
| `ansible/` | `ansible_installer.sh` | Linux | Installs Ansible via pip in a venv |
| `docker/` | `docker_installer.sh` | Linux | Official Docker repositories |
| `kubernetes/` | `kubernetes_installer.sh` | Linux | kubectl + optional Minikube |
| `nginx/` | `nginx_installer.sh` | Linux | Custom build: OpenSSL 3.x, HTTP/2, HTTP/3, zstd, headers-more, ACME |
| `openssh/` | `openssh_installer.sh` | Linux | Hardened config, Ed25519-only, post-quantum KEX (ML-KEM) |
| `podman/` | `podman_installer.sh` | Linux | Distribution repositories |
| `system/` | `planned_shutdown.sh` | Linux | Schedule/cancel/check a planned shutdown or reboot |
| `terraform/` | `terraform_installer.sh` | Linux | HashiCorp repositories |
| `TLS-tools/` | `TLS-checker.ps1` | Cross-platform | Tests TLS versions, HTTP versions, QUIC, HSTS, compression |
| `TLS-tools/` | `testssl.sh` (submodule) | Linux | Comprehensive TLS/SSL scanner by Dirk Wetter — pinned at a specific version |
| `windows/` | `Enable-WinRM.ps1` | Windows | Configures WinRM for remote management |
| `windows/` | `Get-InstalledSoftware.ps1` | Windows | Lists installed software from registry |
| `windows/` | `Optimize-WindowsVM.ps1` | Windows | Disables unnecessary services for VMs |
| `windows/` | `Install-VagrantVMware.ps1` | Windows | Installs Vagrant + VMware Workstation |
| `windows/` | `Install-DellCommandUpdate.ps1` | Windows | Installs Dell Command Update via winget |
| `windows/` | `Install-HPImageAssistant.ps1` | Windows | Installs HP Image Assistant via winget |
| `windows/` | `Set-PlannedShutdown.ps1` | Windows | Schedule/cancel/check a planned shutdown or reboot |

## Linux distro support

All Linux installers target the same three package-manager families:

| Script | apt (Debian/Ubuntu) | dnf (Fedora/RHEL) | pacman (Arch) |
|--------|:---:|:---:|:---:|
| `ansible_installer.sh` | ✅ | ✅ | ✅ |
| `docker_installer.sh` | ✅ | ✅ | ✅ ¹ |
| `kubernetes_installer.sh` | ✅ | ✅ | ✅ ² |
| `nginx_installer.sh` | ✅ | ✅ | ✅ |
| `openssh_installer.sh` | ✅ | ✅ | ✅ |
| `podman_installer.sh` | ✅ | ✅ | ✅ |
| `terraform_installer.sh` | ✅ | ✅ | ✅ ¹ |

¹ No vendor repo exists for Arch; installed from the community repos.
² No pkgs.k8s.io repo exists for Arch; kubectl is installed as a checksum-verified binary.

openSUSE (zypper) is not supported.

## Conventions

- All bash scripts are standalone single-file downloads. They share the same
  set of helper functions (`Write-Log`, `Stop-Script`, `Get-PkgMgr`, ...),
  copied into each script — keep them aligned when changing one.
- Function names follow the PowerShell Verb-Noun convention everywhere — also
  in bash (`Write-Log`, `Get-PkgMgr`, `Install-Podman`). Hyphenated function
  names are bash-only syntax, so scripts must keep the bash shebang.
- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`.

## Automation

Dependency checks run weekly via GitHub Actions. When updates are detected, a PR is created automatically.

Script validation runs on every push: ShellCheck for Bash, PSScriptAnalyzer for PowerShell.

## Notes

- `testssl.sh` is included as a Git submodule. Run `git submodule update --init` if it's missing after cloning.
- NGINX updates require manual checksum verification: `.github/scripts/update-nginx-checksums.sh`
- Some scripts were partially written with GitHub Copilot assistance.
