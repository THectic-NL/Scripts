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

## Automatisering

Dependency-checks draaien wekelijks via GitHub Actions. Bij gevonden updates wordt automatisch een PR aangemaakt.

Scriptvalidatie draait bij elke push: ShellCheck voor Bash, PSScriptAnalyzer voor PowerShell.

## Opmerkingen

- `testssl.sh` zit als Git-submodule in de repo. Draai `git submodule update --init` als die na het klonen ontbreekt.
- NGINX-updates vereisen handmatige checksum-verificatie: `.github/scripts/update-nginx-checksums.sh`
- Sommige scripts zijn deels geschreven met hulp van GitHub Copilot.
