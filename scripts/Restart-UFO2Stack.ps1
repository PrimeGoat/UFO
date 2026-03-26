<#
.SYNOPSIS
    Restarts the UFO2 stack: stop, optional cleanup, then start.
.DESCRIPTION
    Handles degraded and partially-running states correctly.
    Does not assume the system was healthy before restart.
.PARAMETER Force
    Pass -Force to Stop and Start (skip all prompts).
.PARAMETER CleanBefore
    Run Invoke-UFO2Cleanup.ps1 between stop and start.
.PARAMETER GradioDemo
    Start the Gradio demo after restart.
.PARAMETER HealthTimeout
    Seconds to wait for OmniParser health (default: 120).
.EXAMPLE
    .\scripts\Restart-UFO2Stack.ps1
    .\scripts\Restart-UFO2Stack.ps1 -Force
    .\scripts\Restart-UFO2Stack.ps1 -Force -CleanBefore -GradioDemo
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$CleanBefore,
    [switch]$GradioDemo,
    [int]$HealthTimeout = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot

function Write-Status {
    param([string]$Msg, [string]$Level = 'INFO')
    $clr = switch ($Level) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'FAIL'  { 'Red'    }
        default { 'Cyan'   }
    }
    $tag = switch ($Level) {
        'OK'    { '[OK]   ' }
        'WARN'  { '[WARN]  ' }
        'FAIL'  { '[FAIL]  ' }
        default { '[INFO]  ' }
    }
    Write-Host "$tag $Msg" -ForegroundColor $clr
}

Write-Host ''
Write-Host 'Restart-UFO2Stack' -ForegroundColor Cyan
Write-Host ('=' * 52)

# ── Phase 1: Stop ─────────────────────────────────────────────────────────────
Write-Host ''
Write-Status "Phase 1/3 -- Stopping stack..." INFO
& "$ScriptDir\Stop-UFO2Stack.ps1" -Force
if ($LASTEXITCODE -ne 0) {
    Write-Status "Stop phase had warnings. Continuing with restart..." WARN
}

Start-Sleep -Seconds 3

& "$ScriptDir\Get-UFO2Status.ps1"
$status = & "$ScriptDir\Get-UFO2Status.ps1" -Internal
if ($status.Components.OmniParser.State -ne 'STOPPED') {
    Write-Status "OmniParser still running after stop phase. Aborting." FAIL
    exit 1
}
Write-Status "Stop phase complete." OK

# ── Phase 2: Cleanup (optional) ───────────────────────────────────────────────
if ($CleanBefore) {
    Write-Host ''
    Write-Status "Phase 2/3 -- Running cleanup (-CleanBefore specified)..." INFO
    & "$ScriptDir\Invoke-UFO2Cleanup.ps1" -Force
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Cleanup reported issues (non-fatal), continuing..." WARN
    }
} else {
    Write-Status "Phase 2/3 -- Cleanup skipped (use -CleanBefore to enable)." INFO
}

# ── Phase 3: Start ────────────────────────────────────────────────────────────
Write-Host ''
Write-Status "Phase 3/3 -- Starting stack..." INFO

$startSplat = @{ Force = $true }
if ($GradioDemo)    { $startSplat['GradioDemo']    = $true }
if ($HealthTimeout) { $startSplat['HealthTimeout'] = $HealthTimeout }

& "$ScriptDir\Start-UFO2Stack.ps1" @startSplat

if ($LASTEXITCODE -eq 0) {
    Write-Host ''
    Write-Host 'Restart complete -- stack is operational.' -ForegroundColor Green
    exit 0
} else {
    Write-Host ''
    Write-Host 'Restart failed -- start phase did not complete successfully.' -ForegroundColor Red
    Write-Host '  Run: .\scripts\Get-UFO2Status.ps1  for current state.'
    exit 1
}
