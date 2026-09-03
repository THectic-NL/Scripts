---
title: ""
toc: false
---

<div class="hx-mt-6 hx-mb-6">
{{< hextra/hero-headline >}}
  Scripts
{{< /hextra/hero-headline >}}
</div>

<div class="hx-mb-12">
{{< hextra/hero-subtitle >}}
  Installatiescripts voor tools die THectic regelmatig gebruikt — Bash en PowerShell, makkelijk aan te passen
{{< /hextra/hero-subtitle >}}
</div>

<div class="hx-mb-10" style="margin-top: 2.5rem !important;">
{{< hextra/hero-badge link="https://github.com/Thectic-NL/Scripts" >}}
  <span>Bekijk op GitHub</span>
  {{< icon name="github" attributes="height=20" >}}
{{< /hextra/hero-badge >}}
</div>

<div class="hx-mt-6"></div>

## Gebruik

```bash
git clone --recurse-submodules https://github.com/Thectic-NL/Scripts.git
cd Scripts
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

| Map | Bestand(en) | Platform | Toelichting |
|-----------|---------|----------|-------|
| `ansible/` | `ansible_installer.sh` | Linux | Installeert Ansible via pip in een venv |
| `docker/` | `docker_installer.sh` | Linux | Officiële Docker-repositories |
| `kubernetes/` | `kubernetes_installer.sh` | Linux | kubectl + optioneel Minikube |
| `nginx/` | `nginx_installer.sh` | Linux | Custom build: OpenSSL 3.x, HTTP/2, HTTP/3, zstd, headers-more, ACME |
| `openssh/` | `openssh_installer.sh` | Linux | Hardened config, alleen Ed25519, post-quantum KEX (ML-KEM) |
| `podman/` | `podman_installer.sh` | Linux | Distributie-repositories |
| `system/` | `planned_shutdown.sh` | Linux | Geplande afsluiting/herstart plannen/annuleren/controleren |
| `terraform/` | `terraform_installer.sh` | Linux | HashiCorp-repositories |
| `TLS-tools/` | `TLS-checker.ps1` | Cross-platform | Test TLS-versies, HTTP-versies, QUIC, HSTS, compressie |
| `TLS-tools/` | `testssl.sh` (submodule) | Linux | Uitgebreide TLS/SSL-scanner van Dirk Wetter — vastgezet op een specifieke versie |
| `windows/` | `Enable-WinRM.ps1` | Windows | Configureert WinRM voor remote beheer |
| `windows/` | `Get-InstalledSoftware.ps1` | Windows | Toont geïnstalleerde software uit het register |
| `windows/` | `Optimize-WindowsVM.ps1` | Windows | Schakelt onnodige services uit voor VM's |
| `windows/` | `Install-VagrantVMware.ps1` | Windows | Installeert Vagrant + VMware Workstation |
| `windows/` | `Install-DellCommandUpdate.ps1` | Windows | Installeert Dell Command Update via winget |
| `windows/` | `Install-HPImageAssistant.ps1` | Windows | Installeert HP Image Assistant via winget |
| `windows/` | `Set-PlannedShutdown.ps1` | Windows | Geplande afsluiting/herstart plannen/annuleren/controleren |

## Ondersteunde Linux-distro's

Alle Linux-installers richten zich op dezelfde drie pakketbeheerfamilies:

| Script | apt (Debian/Ubuntu) | dnf (Fedora/RHEL) | pacman (Arch) |
|--------|:---:|:---:|:---:|
| `ansible_installer.sh` | ✅ | ✅ | ✅ |
| `docker_installer.sh` | ✅ | ✅ | ✅ ¹ |
| `kubernetes_installer.sh` | ✅ | ✅ | ✅ ² |
| `nginx_installer.sh` | ✅ | ✅ | ✅ |
| `openssh_installer.sh` | ✅ | ✅ | ✅ |
| `podman_installer.sh` | ✅ | ✅ | ✅ |
| `terraform_installer.sh` | ✅ | ✅ | ✅ ¹ |

¹ Geen vendor-repo voor Arch; installatie via de community-repositories.
² Geen pkgs.k8s.io-repo voor Arch; kubectl wordt geïnstalleerd als checksum-geverifieerde binary.

openSUSE (zypper) wordt niet ondersteund.

{{< callout type="info" >}}
Dependency-checks draaien wekelijks; scriptvalidatie (ShellCheck voor Bash, PSScriptAnalyzer voor PowerShell) draait bij elke push. Zie de [GitHub-repository](https://github.com/Thectic-NL/Scripts) voor de volledige broncode en conventies.
{{< /callout >}}
