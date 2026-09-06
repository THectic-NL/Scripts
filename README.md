# Scripts

Installer scripts for tools and software used regularly. Tailored to THectic's preferences, but easy to adapt.

Also browsable as a site: [scripts.thectic.nl](https://scripts.thectic.nl) (`src/`).

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
