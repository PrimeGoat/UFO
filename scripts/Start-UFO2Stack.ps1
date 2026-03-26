<#
.SYNOPSIS
    Starts the UFO2 stack (OmniParser server + optional Gradio demo).
.PARAMETER Force
    Skip all interactive prompts. Auto-stop/cleanup if environment is dirty.
.PARAMETER SkipCleanup
    If environment is dirty: stop but skip cleanup step.
.PARAMETER GradioDemo
    Also start the optional Gradio demo after main stack is up.
.PARAMETER HealthTimeout
    Seconds to wait for OmniParser health checks to pass (default: 120).
.EXAMPLE
    .\scripts\Start-UFO2Stack.ps1
    .\scripts\Start-UFO2Stack.ps1 -Force
    .\scripts\Start-UFO2Stack.ps1 -Force -GradioDemo -HealthTimeout 180
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipCleanup,
    [switch]$GradioDemo,
    [int]$HealthTimeout = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$UFO_ROOT  = 'D:\AI\UFO'
$OMNI_ROOT = 'D:\AI\OmniParser'
$PROBE_URL = 'http://localhost:8010/probe/'

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

function Test-PortListening {
    param([int]$Port)
    $out = netstat -ano 2>$null | Select-String 'LISTENING' | Select-String (":$Port\s")
    return ($null -ne $out -and @($out).Count -gt 0)
}

function Wait-OmniParserHealthy {
    param([int]$TimeoutSec)
    Write-Status "Polling OmniParser health ($PROBE_URL) -- max ${TimeoutSec}s..." INFO
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt  = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $r = Invoke-WebRequest -Uri $PROBE_URL -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
            if ($r.StatusCode -eq 200) {
                Write-Status "OmniParser healthy after ~$attempt attempt(s)" OK
                return $true
            }
        } catch { }
        Write-Host "  [...] attempt $attempt -- not ready, retrying in 3s..."
        Start-Sleep -Seconds 3
    }
    Write-Status "OmniParser did not become healthy within ${TimeoutSec}s" FAIL
    return $false
}

# ── Check current state ───────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Start-UFO2Stack' -ForegroundColor Cyan
Write-Host ('=' * 52)
& "$ScriptDir\Get-UFO2Status.ps1"
$status = & "$ScriptDir\Get-UFO2Status.ps1" -Internal

# ── Handle non-STOPPED states ─────────────────────────────────────────────────
if ($status.Overall -eq 'RUNNING') {
    Write-Status "Stack is already RUNNING -- nothing to do." OK
    exit 0
}

if ($status.Overall -in @('PARTIAL', 'DEGRADED')) {
    if ($status.Components.OmniParser.State -ne 'STOPPED') {
        Write-Status "Stack is in $($status.Overall) state -- stopping OmniParser before starting." WARN
        & "$ScriptDir\Stop-UFO2Stack.ps1" -Force
        if ($LASTEXITCODE -ne 0) {
            Write-Status "Stop failed -- aborting Start." FAIL
            exit 1
        }
        if (-not $SkipCleanup) {
            Write-Status "Invoking Invoke-UFO2Cleanup.ps1 -Force..." INFO
            & "$ScriptDir\Invoke-UFO2Cleanup.ps1" -Force
        } else {
            Write-Status "-SkipCleanup: skipping cleanup." INFO
        }
        Start-Sleep -Seconds 2
        $status = & "$ScriptDir\Get-UFO2Status.ps1" -Internal
        if ($status.Components.OmniParser.State -ne 'STOPPED') {
            Write-Status "OmniParser still running after stop attempt. Aborting." FAIL
            exit 1
        }
    } else {
        Write-Status "OmniParser already stopped -- proceeding to start." INFO
    }
}

# ── Start OmniParser server ───────────────────────────────────────────────────
Write-Host ''
Write-Status "Starting OmniParser server..." INFO
$omniProc = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList '/c', "$OMNI_ROOT\start_server.bat" `
    -WorkingDirectory $OMNI_ROOT `
    -PassThru `
    -WindowStyle Normal

if ($null -eq $omniProc) {
    Write-Status "Failed to launch OmniParser server process." FAIL
    exit 1
}

Write-Status "OmniParser launched (cmd PID: $($omniProc.Id))" INFO
Write-Status "Waiting for OmniParser to become healthy (GPU model load takes time)..." INFO

$healthy = Wait-OmniParserHealthy -TimeoutSec $HealthTimeout
if (-not $healthy) {
    Write-Status "OmniParser failed to start. Check $OMNI_ROOT for errors." FAIL
    exit 1
}

# ── Start Gradio demo (optional) ──────────────────────────────────────────────
if ($GradioDemo) {
    Write-Host ''
    Write-Status "Starting Gradio demo (optional)..." INFO
    $gradioProc = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList '/c', "$OMNI_ROOT\start_demo.bat" `
        -WorkingDirectory $OMNI_ROOT `
        -PassThru `
        -WindowStyle Normal

    if ($null -ne $gradioProc) {
        Write-Status "Gradio demo launched (cmd PID: $($gradioProc.Id)) -- port auto-selected from 7861+" INFO
    } else {
        Write-Status "Failed to launch Gradio demo (non-fatal)." WARN
    }
}

# ── Post-startup verification ─────────────────────────────────────────────────
Write-Host ''
Write-Status "Running post-startup verification..." INFO
Start-Sleep -Seconds 3
& "$ScriptDir\Get-UFO2Status.ps1"
$finalStatus = & "$ScriptDir\Get-UFO2Status.ps1" -Internal

$omniOk = ($finalStatus.Components.OmniParser.State -eq 'RUNNING')

Write-Host ''
if ($omniOk) {
    Write-Host 'SUCCESS -- OmniParser is operational.' -ForegroundColor Green
    Write-Host "  OmniParser : http://localhost:8010"
    Write-Host "  Probe      : http://localhost:8010/probe/"
    if ($finalStatus.Components.GradioDemo.Port) {
        Write-Host "  Gradio     : http://localhost:$($finalStatus.Components.GradioDemo.Port)"
    }
    exit 0
} else {
    Write-Host 'FAILURE -- OmniParser did not start successfully.' -ForegroundColor Red
    Write-Host '  Run: .\scripts\Get-UFO2Status.ps1  for detail.'
    Write-Host '  Run: .\scripts\Stop-UFO2Stack.ps1 -Force  to clean up.'
    exit 1
}
