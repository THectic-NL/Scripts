<#
.SYNOPSIS
    Schedules, cancels, or reports a planned shutdown/reboot.
.DESCRIPTION
    Thin wrapper around shutdown.exe: schedules a power-off or restart after
    a delay or at a specific time, with an optional broadcast message, and
    can cancel a pending one or report whether one is active.

    shutdown.exe has no built-in query verb, so this script keeps a small
    state file (ProgramData\PlannedShutdown\state.json) to answer 'status'
    without side effects. Only shutdowns scheduled through this script are
    reflected in 'status'.
.PARAMETER Command
    schedule - Schedule a shutdown or reboot
    cancel   - Cancel a previously scheduled shutdown/reboot
    status   - Show whether a shutdown/reboot is currently pending
.PARAMETER At
    Shut down at a specific time today (24h clock, e.g. "23:30").
.PARAMETER Delay
    Shut down after a delay in minutes (e.g. 30).
.PARAMETER Reboot
    Reboot instead of powering off.
.PARAMETER Message
    Message shown to logged-in users before shutdown.
.PARAMETER Force
    Force running applications to close without warning.
.PARAMETER Yes
    Skip the confirmation prompt.
.EXAMPLE
    ./Set-PlannedShutdown.ps1 -Command schedule -Delay 30 -Message "Maintenance starting soon"
.EXAMPLE
    ./Set-PlannedShutdown.ps1 -Command schedule -At 23:30 -Reboot
.EXAMPLE
    ./Set-PlannedShutdown.ps1 -Command cancel
.EXAMPLE
    ./Set-PlannedShutdown.ps1 -Command status
.NOTES
    Run as Administrator (the script self-elevates if needed).
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('schedule', 'cancel', 'status')]
    [string]$Command = 'status',

    [string]$At,
    [int]$Delay,
    [switch]$Reboot,
    [string]$Message,
    [switch]$Force,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-elevate when not running as Administrator
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting the script with administrator rights..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Command', $Command)
    if ($At) { $argList += @('-At', $At) }
    if ($Delay) { $argList += @('-Delay', $Delay) }
    if ($Reboot) { $argList += '-Reboot' }
    if ($Message) { $argList += @('-Message', "`"$Message`"") }
    if ($Force) { $argList += '-Force' }
    if ($Yes) { $argList += '-Yes' }
    Start-Process -FilePath "PowerShell" -ArgumentList ($argList -join ' ') -Verb RunAs
    Exit
}
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$StateDir = Join-Path $env:ProgramData 'PlannedShutdown'
$StateFile = Join-Path $StateDir 'state.json'

function Convert-AtTimeToTarget {
    param([string]$Time)

    if ($Time -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {
        throw "Invalid -At value: $Time (expected HH:MM, 24h clock)"
    }

    $target = Get-Date -Hour ([int]$Time.Split(':')[0]) -Minute ([int]$Time.Split(':')[1]) -Second 0
    if ($target -le (Get-Date)) {
        $target = $target.AddDays(1)
    }
    return $target
}

function Save-ShutdownState {
    param([datetime]$Target, [string]$Action)

    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    [pscustomobject]@{
        TargetTime = $Target.ToString('o')
        Action     = $Action
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Clear-ShutdownState {
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
}

switch ($Command) {
    'schedule' {
        if (-not $At -and -not $Delay) {
            throw "Specify -At HH:MM or -Delay <minutes>"
        }
        if ($At -and $Delay) {
            throw "Use either -At or -Delay, not both"
        }

        $target = if ($At) { Convert-AtTimeToTarget -Time $At } else { (Get-Date).AddMinutes($Delay) }
        $seconds = [int]([TimeSpan]($target - (Get-Date))).TotalSeconds
        $action = if ($Reboot) { "reboot" } else { "power off" }

        if (-not $Yes) {
            $response = Read-Host "Schedule a $action for $($target.ToString('yyyy-MM-dd HH:mm'))? [y/N]"
            if ($response -notmatch '^[Yy]$') {
                Write-Host "Aborted" -ForegroundColor Yellow
                Exit 1
            }
        }

        $shutdownArgs = @(if ($Reboot) { '/r' } else { '/s' })
        $shutdownArgs += @('/t', $seconds)
        if ($Force) { $shutdownArgs += '/f' }
        if ($Message) { $shutdownArgs += @('/c', $Message) }

        & shutdown.exe @shutdownArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to schedule shutdown (shutdown.exe exit code $LASTEXITCODE)"
        }
        Save-ShutdownState -Target $target -Action $action
        Write-Host "Scheduled $action for $($target.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    }

    'cancel' {
        & shutdown.exe /a
        $cancelled = ($LASTEXITCODE -eq 0)
        Clear-ShutdownState
        if ($cancelled) {
            Write-Host "Scheduled shutdown/reboot cancelled" -ForegroundColor Green
        } else {
            Write-Host "No shutdown/reboot was pending" -ForegroundColor Yellow
        }
    }

    'status' {
        if (-not (Test-Path $StateFile)) {
            Write-Host "No shutdown/reboot is currently scheduled" -ForegroundColor Cyan
        } else {
            $state = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
            $target = [datetime]$state.TargetTime

            if ($target -le (Get-Date)) {
                Write-Host "No shutdown/reboot is currently scheduled" -ForegroundColor Cyan
                Clear-ShutdownState
            } else {
                Write-Host "A $($state.Action) is scheduled for: $($target.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Cyan
            }
        }
    }
}
