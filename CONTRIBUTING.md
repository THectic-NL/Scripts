# Contributing to Scripts Repository

Thank you for your interest in contributing to this repository! This guide will help you understand how to maintain and update the installer scripts.

## Automated Dependency Management

This repository uses Renovate plus a few GitHub Actions workflows to keep dependencies up-to-date:

### 1. Renovate (`renovate.json`)
Automatically monitors and creates PRs for:
- GitHub Actions updates
- The `TLS-tools/testssl.sh` git submodule
- Hardcoded versions in installer scripts (NGINX and its modules, Ansible, kubectl, minikube, Vagrant) via custom regex managers

**Important:** the custom regex managers match exact variable formats such as
`NGINX_VERSION="1.31.1"` (bash) and `$Script:NGINX_VERSION = '1.31.1'`
(PowerShell). Do not reformat these lines or rename these variables/files, or
Renovate will silently stop updating them.

### 2. NGINX Checksum Updater (`.github/workflows/update-nginx-checksums.yml`)
Runs automatically on `renovate/*` PR branches: when Renovate bumps an NGINX
dependency, this workflow recalculates the SHA256 checksums via
`.github/scripts/update-nginx-checksums.sh` and commits them to the PR.

### 3. Script Validator (`.github/workflows/validate-scripts.yml`)
Runs on all PRs and commits to validate:
- Bash script syntax and quality (ShellCheck)
- PowerShell script syntax and quality (PSScriptAnalyzer)
- Potential security issues

**Action required:** Fix any validation errors before merging.

## Script Structure Guidelines

### Shared helpers (bash)

Every bash script is standalone but carries the same helper functions
(colors, `Write-Log`, `Stop-Script`, `Test-Root`, `Get-PkgMgr`, `Get-OsId`,
`Invoke-Cmd`). When you improve a helper, apply the same change in the other
scripts so they stay aligned.

### Naming convention

Function names follow the PowerShell Verb-Noun convention **everywhere**,
including bash: `Write-Log`, `Get-PkgMgr`, `Install-Podman`, `Remove-Nginx`.
Hyphenated function names are bash-only syntax, so scripts must keep the
`#!/usr/bin/env bash` shebang.

### Distro support (Linux)

All Linux installers support apt (Debian/Ubuntu), dnf (Fedora/RHEL) and
pacman (Arch). New installers should cover all three; use the shared
`Get-PkgMgr` helper and add a clear `Stop-Script` for unsupported systems.

### Version Configuration

Always keep version numbers at the top of scripts in clearly marked sections:

```bash
# ============================================================================
# Version Configuration
# ============================================================================

NGINX_VERSION="1.31.1"
NGINX_SHA256="9fcaaeb8f22544b09a19a761f3412c4112215422401634bebdd1296a403cc4bc"
```

### Error Handling

Every script starts with:

```bash
#!/usr/bin/env bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures
```

### Logging

Use the shared helper functions instead of raw `echo`:

```bash
Write-Log INFO "Installing build dependencies"
Write-Log WARN "Cargo not found. Installing rustup..."
Stop-Script "Unsupported package manager."
Invoke-Cmd apt-get install -y podman   # logs + aborts on failure
```

Set `LOG_FILE` (after the helper functions) to also append plain-text logs
to a file.

## Updating Installer Scripts

### General Process

Renovate normally handles version bumps. For manual updates:

1. **Update version numbers**: Edit the relevant `*_VERSION` variables in the script (keep the exact line format)
2. **Update checksums**: For NGINX, run `.github/scripts/update-nginx-checksums.sh`
3. **Test**: Run the script on a clean system to verify it works
4. **Commit**: Push changes and ensure CI passes

### Example: Updating NGINX manually

```bash
# 1. Edit nginx/nginx_installer.sh
# Update this line:
NGINX_VERSION="1.31.1"

# 2. Recalculate the checksum
.github/scripts/update-nginx-checksums.sh --apply

# 3. Test the script
sudo ./nginx/nginx_installer.sh install

# 4. Verify installation
nginx -v
nginx -V  # Check modules

# 5. Commit changes
git add nginx/
git commit -m "deps: update NGINX to 1.31.1"
git push
```

### Adding Renovate coverage for a new script

Add a custom regex manager to `renovate.json`:

```json
{
  "customType": "regex",
  "datasourceTemplate": "github-releases",
  "depNameTemplate": "owner/repo",
  "matchStrings": ["NEWTOOL_VERSION=\"(?<currentValue>[^\"]+)\""],
  "managerFilePatterns": ["/^newtool/newtool_installer\\.sh$/"]
}
```

Validate with `npx --yes --package renovate -- renovate-config-validator renovate.json`.

## Testing Guidelines

### Before Committing
1. **Syntax check**: Ensure scripts pass syntax validation
   ```bash
   bash -n script_name.sh
   shellcheck -S warning script_name.sh
   ```

2. **Test installation**: Run on a clean system (VM/container recommended)
   ```bash
   docker run -it --rm ubuntu:latest
   # Or
   docker run -it --rm fedora:latest
   # Or
   docker run -it --rm archlinux:latest
   ```

3. **Verify functionality**: After installation, test that the software works
   ```bash
   # Example for nginx
   nginx -v
   nginx -t
   systemctl status nginx
   ```

### After Committing
- Check that GitHub Actions workflows pass
- Review any warnings from ShellCheck or PSScriptAnalyzer
- Ensure no security scan warnings

## Common Tasks

### Adding a New Installer Script

1. Create the script in an appropriate directory
2. Follow existing naming convention: `<tool>_installer.sh`
3. Copy the shared helper functions from an existing installer
4. Support apt, dnf and pacman
5. Include a version configuration section at the top (if versions are pinned)
6. Test thoroughly on clean systems
7. Update README.md (script table + distro matrix)
8. Add a Renovate custom manager for any pinned versions

## Security Considerations

1. **Never commit credentials**: Use environment variables or prompt for sensitive data
2. **Verify checksums**: Always verify SHA256 checksums for downloaded files
3. **Use HTTPS**: Only download from HTTPS URLs
4. **Validate inputs**: Check user inputs before using them
5. **Run as root carefully**: Only request root when necessary

## Getting Help

- **Issues**: Create an issue if you encounter problems
- **Discussions**: Use GitHub Discussions for questions
- **Automated Checks**: Let the CI/CD workflows guide you

## Code of Conduct

- Be respectful and constructive
- Test your changes thoroughly
- Document significant changes
- Follow existing code style and conventions
