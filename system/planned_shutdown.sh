#!/usr/bin/env bash
#
# Planned Shutdown Script (standalone)
#
# Schedules or cancels a system shutdown/reboot via the systemd `shutdown`
# command, and reports whether one is currently pending.
# Run as root.
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

# Usage: Test-Root  (exits unless running as root)
Test-Root() {
    [[ $EUID -eq 0 ]] || Stop-Script "Run as root (sudo)."
}

# ============================================================================
# Usage
# ============================================================================

Show-Usage() {
    cat <<'EOF'
Usage: planned_shutdown.sh <command> [options]

Commands:
  schedule    Schedule a shutdown or reboot
  cancel      Cancel a previously scheduled shutdown/reboot
  status      Show whether a shutdown/reboot is currently pending

Options (schedule):
  --at HH:MM       Shut down at a specific time (24h clock, today or tomorrow)
  --delay N[smh]   Shut down after a delay, e.g. 45, 45m, 2h, 90s (default unit: minutes)
  --reboot         Reboot instead of powering off
  --message TEXT   Broadcast message shown to logged-in users
  -y, --yes        Skip the confirmation prompt

Exactly one of --at or --delay is required for "schedule".

Examples:
  sudo ./planned_shutdown.sh schedule --delay 30m --message "Maintenance starting soon"
  sudo ./planned_shutdown.sh schedule --at 23:30 --reboot
  sudo ./planned_shutdown.sh cancel
  sudo ./planned_shutdown.sh status
EOF
}

# ============================================================================
# Helpers
# ============================================================================

# Usage: minutes=$(Convert-DelayToMinutes "30m")  ->  rounds up to whole minutes
Convert-DelayToMinutes() {
    local delay=$1
    [[ $delay =~ ^([0-9]+)([smh]?)$ ]] || Stop-Script "Invalid --delay value: $delay (expected e.g. 45, 45m, 2h, 90s)"
    local amount=${BASH_REMATCH[1]}
    local unit=${BASH_REMATCH[2]:-m}
    case $unit in
        s) echo $(( (amount + 59) / 60 )) ;;
        m) echo "$amount" ;;
        h) echo $(( amount * 60 )) ;;
    esac
}

Test-ShutdownAvailable() {
    command -v shutdown >/dev/null 2>&1 || Stop-Script "shutdown command not found"
}

# ============================================================================
# Commands
# ============================================================================

Set-PlannedShutdown() {
    local at="" delay="" reboot=false message="" assume_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --at)
                at=${2:-}; [[ -n "$at" ]] || Stop-Script "--at requires a value"; shift 2 ;;
            --delay)
                delay=${2:-}; [[ -n "$delay" ]] || Stop-Script "--delay requires a value"; shift 2 ;;
            --reboot)
                reboot=true; shift ;;
            --message)
                message=${2:-}; [[ -n "$message" ]] || Stop-Script "--message requires a value"; shift 2 ;;
            -y|--yes)
                assume_yes=true; shift ;;
            *)
                Stop-Script "Unknown option for 'schedule': $1" ;;
        esac
    done

    [[ -n "$at" || -n "$delay" ]] || Stop-Script "Specify --at HH:MM or --delay N[smh]"
    [[ -z "$at" || -z "$delay" ]] || Stop-Script "Use either --at or --delay, not both"

    local when
    if [[ -n "$at" ]]; then
        [[ $at =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || Stop-Script "Invalid --at value: $at (expected HH:MM, 24h clock)"
        when="$at"
    else
        when="+$(Convert-DelayToMinutes "$delay")"
    fi

    local action="power off"
    [[ $reboot == true ]] && action="reboot"

    if [[ $assume_yes != true ]]; then
        read -r -p "Schedule a $action for $when? [y/N]: " response
        [[ "$response" =~ ^[Yy]$ ]] || Stop-Script "Aborted"
    fi

    local shutdown_args=()
    [[ $reboot == true ]] && shutdown_args+=(-r) || shutdown_args+=(-h)
    shutdown_args+=("$when")
    [[ -n "$message" ]] && shutdown_args+=("$message")

    shutdown "${shutdown_args[@]}" || Stop-Script "Failed to schedule shutdown"
    Write-Log SUCCESS "Scheduled $action for $when"
}

Stop-PlannedShutdown() {
    if shutdown -c 2>/dev/null; then
        Write-Log SUCCESS "Scheduled shutdown/reboot cancelled"
    else
        Write-Log WARN "No shutdown/reboot was pending"
    fi
}

Get-PlannedShutdown() {
    local scheduled_file="/run/systemd/shutdown/scheduled"

    if [[ ! -f "$scheduled_file" ]]; then
        Write-Log INFO "No shutdown/reboot is currently scheduled"
        return 0
    fi

    local usec mode
    usec=$(sed -n 's/^USEC=//p' "$scheduled_file")
    mode=$(sed -n 's/^MODE=//p' "$scheduled_file")

    if [[ -n "$usec" ]]; then
        local when
        when=$(date -d "@$(( usec / 1000000 ))" 2>/dev/null || echo "unknown time")
        Write-Log INFO "A ${mode:-shutdown} is scheduled for: $when"
    else
        Write-Log INFO "A shutdown/reboot appears to be scheduled, but details could not be read"
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

Test-Root
Test-ShutdownAvailable

case "${1:-}" in
    schedule)
        shift
        Set-PlannedShutdown "$@"
        ;;
    cancel)
        Stop-PlannedShutdown
        ;;
    status)
        Get-PlannedShutdown
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
