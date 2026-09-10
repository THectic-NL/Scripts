#!/usr/bin/env bash
#
# Redmi / Xiaomi HyperOS ADB Debloat Script (standalone)
#
# Removes pre-installed bloatware from a Xiaomi/Redmi/POCO phone over ADB,
# without root. Uses `pm uninstall -k --user 0`, which only hides the app
# for the current user and keeps the system APK + data, so everything is
# reversible with `restore` until a factory reset.
#
# Requires: `adb` (Android platform-tools) on this machine, and USB
# debugging enabled + authorized on the phone (Settings > About phone >
# tap "MIUI/HyperOS version" 7x > Developer options > USB debugging).
#
# See README.md in this directory for the full package tier explanation
# and sources.
#

set -euo pipefail

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

# ============================================================================
# Package Lists
#
# Tier 1 (safe): regular preinstalled third-party apps (games, shopping,
# social, office). These are ordinary user apps, not system components -
# removing them carries essentially no risk.
#
# Tier 2 (miui): Xiaomi/HyperOS-branded bundled apps and services (Mi
# Browser, Mi Video/Music, GetApps ecosystem extras, analytics/ads). Safe
# for most people but opt-in via --include-miui since a few overlap with
# account/cloud features some users rely on.
#
# Tier 3 (do-not-remove, documented only, never touched by this script):
# packages where sources conflict or where removal has caused real
# breakage. Printed by `info` so you know to leave them alone.
# ============================================================================

readonly TIER1_SAFE=(
    # Third-party bloat / regional partner apps
    com.facebook.appmanager com.facebook.katana com.facebook.orca
    com.facebook.services com.facebook.system
    com.amazon.appmanager com.amazon.fv com.amazon.kindle com.amazon.mp3
    com.amazon.mshop.android com.amazon.mshop.android.shopping com.amazon.venezia
    com.netflix.mediaclient com.netflix.partner.activation
    com.spotify.music com.linkedin.android com.booking com.tripadvisor.tripadvisor
    com.alibaba.aliexpresshd com.einnovation.temu com.zhiliaoapp.musically
    com.opera.browser com.opera.max.oem com.opera.preinstall
    com.microsoft.office.excel com.microsoft.office.officehubrow
    com.microsoft.office.outlook com.microsoft.office.powerpoint
    com.microsoft.office.word com.microsoft.skydrive
    cn.wps.moffice_eng cn.wps.xiaomi.abroad.lite com.infraware.polarisoffice5
    com.google.android.apps.magazines com.google.android.apps.books
    com.google.android.apps.docs com.google.android.apps.tachyon
    com.google.android.apps.youtube.music com.google.android.videos
    com.google.android.music com.google.android.printservice.recommendation
    com.mi.global.pocobbs com.mi.global.pocostore
    com.audible.application com.imdb.mobile com.flipboard.app com.flipboard.boxer.app
    com.touchtype.swiftkey com.sohu.inputmethod.sogou.xiaomi
    com.xiaomi.discover com.xiaomi.midrop com.xiaomi.ugd
    # Bundled games (names vary by region/campaign, harmless to skip if absent)
    com.block.juggle com.block.puzzle.game.hippo.mi com.crazy.juicer.xm
    com.fugo.wow com.funtomic.matchmasters com.gameduell.tarot
    com.jewelsblast.ivygames.adventure.free com.nf.snake com.oakever.tiletrip
    com.plarium.raidlegends com.soulcompany.bubbleshooter.relaxing
    com.sukhavati.gotoplaying.bubble.bubbleshooter.mint com.tripledot.solitaire
    com.vitastudio.mahjong net.wooga.junes_journey_hidden_object_mystery_game
)

readonly TIER2_MIUI=(
    com.mi.globalbrowser com.mi.globalminusscreen
    com.miui.videoplayer com.miui.player com.miui.yellowpage com.miui.compass
    com.miui.extraphoto com.miui.notes com.miui.weather2 com.miui.misightservice
    com.miui.analytics com.miui.msa.global
    com.xiaomi.payment com.xiaomi.barrage com.xiaomi.simactivate.service
    com.android.providers.partnerbookmarks
    com.tencent.soter.soterserver org.ifaa.aidl.manager com.qti.dcf
)

# Documented only - `info` prints these, `remove` never touches them even
# with --include-miui. Sources disagree on some (see README), so the safe
# default is: leave alone.
readonly TIER3_DO_NOT_REMOVE_DOC=(
    "com.miui.daemon|core system daemon; removal has been reported to break Xiaomi Cloud SMS verification"
    "com.android.stk|SIM Toolkit; some banking/carrier apps depend on it"
    "com.android.incallui|the phone call UI itself"
    "com.android.contacts|the default Contacts app/provider UI"
    "com.miui.miservice|conflicting reports: one source lists it as safe MI-service cleanup, another says it's required for Bluetooth - not worth the risk"
    "com.xiaomi.joyose|game-performance daemon; low impact idle, but leave it if you play games"
    "com.qti.qcc|Qualcomm service some games (e.g. Monopoly GO) require"
    "com.miui.miwallpaper|needed for lock screen wallpaper rendering"
    "com.xiaomi.xmsf|Xiaomi Mi Service Framework; needed for OTA system updates"
)

# ============================================================================
# ADB Helpers
# ============================================================================

Test-Adb() {
    command -v adb >/dev/null 2>&1 || Stop-Script "adb not found. Install Android platform-tools first."
}

# Usage: Test-DeviceConnected  (exits with guidance if 0 or >1 devices, or unauthorized)
Test-DeviceConnected() {
    local lines
    lines=$(adb devices | tail -n +2 | sed '/^$/d')

    local count
    count=$(echo "$lines" | grep -c . || true)

    if [[ $count -eq 0 ]]; then
        Stop-Script "No device found. Enable USB debugging (Settings > Additional settings > Developer options) and plug in the phone."
    fi

    if echo "$lines" | grep -q unauthorized; then
        Stop-Script "Device listed as 'unauthorized'. Accept the 'Allow USB debugging?' prompt on the phone screen."
    fi

    if [[ $count -gt 1 ]]; then
        Stop-Script "Multiple devices/emulators connected. Disconnect the others first."
    fi

    echo "$lines" | grep -q device$ || Stop-Script "Device is not ready (state: $lines). Check the USB connection."
}

# Usage: packages=$(Get-InstalledPackages) - full "com.example.app" list, one per line
Get-InstalledPackages() {
    adb shell pm list packages | tr -d '\r' | sed 's/^package://'
}

# Usage: Test-PackageInstalled "$installed_list" "com.example.app"
Test-PackageInstalled() {
    local installed=$1 pkg=$2
    grep -qx "$pkg" <<< "$installed"
}

# Usage: Remove-Package "com.example.app"
Remove-Package() {
    local pkg=$1
    if adb shell pm uninstall -k --user 0 "$pkg" 2>&1 | grep -q Success; then
        Write-Log SUCCESS "Removed: $pkg"
        return 0
    else
        Write-Log WARN "Failed to remove: $pkg (may be protected on this ROM)"
        return 1
    fi
}

# Usage: Restore-Package "com.example.app"
Restore-Package() {
    local pkg=$1
    if adb shell pm install-existing --user 0 "$pkg" 2>&1 | grep -q Installed; then
        Write-Log SUCCESS "Restored: $pkg"
    else
        Write-Log ERROR "Failed to restore: $pkg (it may have been a Tier 1 app removed via the Play Store path, or is gone after a factory reset)"
    fi
}

# ============================================================================
# Commands
# ============================================================================

Show-Usage() {
    cat <<'EOF'
Usage: redmi_debloat.sh <command> [options]

Commands:
  list                    Show which known bloat packages are installed on the connected device
  remove                  Uninstall (for current user) matched packages; writes a restore file
  restore <package>       Reinstall one package for the current user
  restore-all <file>      Reinstall every package listed in a file produced by `remove`
  info                    Print all known packages per tier with explanation (no device needed)

Options (remove):
  --include-miui          Also remove Tier 2 (Xiaomi/HyperOS bundled apps), not just Tier 1
  --dry-run               Show what would be removed without doing it
  -y, --yes               Skip the confirmation prompt

Examples:
  ./redmi_debloat.sh info
  ./redmi_debloat.sh list
  ./redmi_debloat.sh remove --dry-run
  ./redmi_debloat.sh remove --include-miui
  ./redmi_debloat.sh restore com.miui.notes
  ./redmi_debloat.sh restore-all removed-packages-20260906-120000.txt

See README.md for background on the package tiers and sources.
EOF
}

Get-MatchedPackages() {
    local installed=$1 include_miui=$2
    local pkg
    for pkg in "${TIER1_SAFE[@]}"; do
        Test-PackageInstalled "$installed" "$pkg" && echo "$pkg"
    done
    if [[ $include_miui == true ]]; then
        for pkg in "${TIER2_MIUI[@]}"; do
            Test-PackageInstalled "$installed" "$pkg" && echo "$pkg"
        done
    fi
    return 0
}

Show-InstalledMatches() {
    Test-Adb
    Test-DeviceConnected
    Write-Log INFO "Reading installed packages from device..."
    local installed
    installed=$(Get-InstalledPackages)

    Write-Log STEP "Tier 1 (safe, third-party bloat) found on device:"
    Get-MatchedPackages "$installed" false | sed 's/^/  - /'

    Write-Log STEP "Tier 2 (Xiaomi/HyperOS bundled apps, opt-in) found on device:"
    local pkg
    for pkg in "${TIER2_MIUI[@]}"; do
        Test-PackageInstalled "$installed" "$pkg" && echo "  - $pkg"
    done
    return 0
}

Show-Info() {
    Write-Log STEP "Tier 1 - safe to remove (third-party bloat, ${#TIER1_SAFE[@]} packages):"
    printf '  %s\n' "${TIER1_SAFE[@]}"
    echo
    Write-Log STEP "Tier 2 - opt-in via --include-miui (Xiaomi/HyperOS bundled apps, ${#TIER2_MIUI[@]} packages):"
    printf '  %s\n' "${TIER2_MIUI[@]}"
    echo
    Write-Log STEP "Tier 3 - do NOT remove (documented only):"
    local entry
    for entry in "${TIER3_DO_NOT_REMOVE_DOC[@]}"; do
        printf '  %-32s %s\n' "${entry%%|*}" "${entry#*|}"
    done
}

Remove-MatchedPackages() {
    local include_miui=$1 dry_run=$2 assume_yes=$3

    Test-Adb
    Test-DeviceConnected
    Write-Log INFO "Reading installed packages from device..."
    local installed
    installed=$(Get-InstalledPackages)

    local matches
    matches=$(Get-MatchedPackages "$installed" "$include_miui")

    if [[ -z "$matches" ]]; then
        Write-Log INFO "No known bloat packages found installed. Nothing to do."
        return 0
    fi

    Write-Log STEP "The following packages will be removed for the current user:"
    echo "$matches" | sed 's/^/  - /'

    if [[ $dry_run == true ]]; then
        Write-Log INFO "Dry run, no changes made."
        return 0
    fi

    if [[ $assume_yes != true ]]; then
        read -r -p "Proceed? [y/N]: " response
        [[ "$response" =~ ^[Yy]$ ]] || Stop-Script "Aborted"
    fi

    local restore_file
    restore_file="removed-packages-$(date +%Y%m%d-%H%M%S).txt"
    : > "$restore_file"

    local pkg failed=0
    while IFS= read -r pkg; do
        if Remove-Package "$pkg"; then
            echo "$pkg" >> "$restore_file"
        else
            failed=$((failed + 1))
        fi
    done <<< "$matches"

    Write-Log SUCCESS "Done. Restore list saved to: $restore_file"
    [[ $failed -eq 0 ]] || Write-Log WARN "$failed package(s) could not be removed, see warnings above."
}

Restore-One() {
    local pkg=${1:-}
    [[ -n "$pkg" ]] || Stop-Script "Usage: restore <package>"
    Test-Adb
    Test-DeviceConnected
    Restore-Package "$pkg"
}

Restore-FromFile() {
    local file=${1:-}
    [[ -n "$file" ]] || Stop-Script "Usage: restore-all <file>"
    [[ -f "$file" ]] || Stop-Script "File not found: $file"
    Test-Adb
    Test-DeviceConnected

    local pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        Restore-Package "$pkg"
    done < "$file"
}

# ============================================================================
# Main Entry Point
# ============================================================================

case "${1:-}" in
    list)
        Show-InstalledMatches
        ;;
    info)
        Show-Info
        ;;
    remove)
        shift
        include_miui=false dry_run=false assume_yes=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --include-miui) include_miui=true; shift ;;
                --dry-run)      dry_run=true; shift ;;
                -y|--yes)       assume_yes=true; shift ;;
                *) Stop-Script "Unknown option for 'remove': $1" ;;
            esac
        done
        Remove-MatchedPackages "$include_miui" "$dry_run" "$assume_yes"
        ;;
    restore)
        Restore-One "${2:-}"
        ;;
    restore-all)
        Restore-FromFile "${2:-}"
        ;;
    -h|--help|"")
        Show-Usage
        ;;
    *)
        Write-Log ERROR "Unknown command: $1"
        Show-Usage
        exit 1
        ;;
esac
