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
  Installer scripts for tools THectic uses regularly — Bash and PowerShell, easy to adapt
{{< /hextra/hero-subtitle >}}
</div>

<div class="hx-mb-10" style="margin-top: 2.5rem !important;">
{{< hextra/hero-badge link="https://github.com/Thectic-NL/Scripts" >}}
  <span>View on GitHub</span>
  {{< icon name="github" attributes="height=20" >}}
{{< /hextra/hero-badge >}}
</div>

<div class="hx-mt-6"></div>

## Usage

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

## Automation

Dependency checks run weekly via GitHub Actions. When updates are detected, a PR is created automatically.

Script validation runs on every push: ShellCheck for Bash, PSScriptAnalyzer for PowerShell.

## Notes

- `testssl.sh` is included as a Git submodule. Run `git submodule update --init` if it's missing after cloning.
- NGINX updates require manual checksum verification: `.github/scripts/update-nginx-checksums.sh`
- Some scripts were partially written with GitHub Copilot assistance.
