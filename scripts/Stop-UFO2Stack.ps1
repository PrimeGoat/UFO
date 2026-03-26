<#
.SYNOPSIS
    Stops the UFO2 stack gracefully, force-killing if needed.
.PARAMETER Force
    Skip interactive prompts; proceed immediately.
.PARAMETER IncludeGradio
    Also stop Gradio demo if running (default: true).
.PARAMETER GracePeriod
    Seconds to wait for graceful exit before force-killing (default: 10).
.EXAMPLE
    .\scripts\Stop-UFO2Stack.ps1
    .\scripts\Stop-UFO2Stack.ps1 -Force
    .\scripts\Stop-UFO2Stack.ps1 -Force -GracePeriod 5
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [bool]$IncludeGradio = $true,
    [int]$GracePeriod    = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$UFO_ROOT  = 'D:\AI\UFO'

function Get-CondaEnvFromBat {
    param([string]$BatPath)
    if (-not (Test-Path $BatPath)) { return $null }
    foreach ($line in (Get-Content $BatPath -ErrorAction SilentlyContinue)) {
        if ($line -match 'conda\s+activate\s+"?([^"]+)"?\s*$') {
            $p = $Matches[1].Trim()
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

$OMNI_ENV = Get-CondaEnvFromBat (Join-Path (Split-Path $UFO_ROOT -Parent) 'OmniParser\start_server.bat')

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

function Get-PythonProcs {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue
}

function Stop-ComponentProcess {
    param([string]$Name, [string]$CmdlineMatch, [int]$Grace)

    $procs = @(Get-PythonProcs | Where-Object { $_.CommandLine -like "*$CmdlineMatch*" })
    if ($procs.Count -eq 0) {
        Write-Status "$Name : not running, nothing to stop." INFO
        return $true
    }

    foreach ($p in $procs) {
        $pidNum = $p.ProcessId
        Write-Status "$Name : sending stop signal to PID $pidNum..." INFO
        $psProc = Get-Process -Id $pidNum -ErrorAction SilentlyContinue
        if ($psProc) {
            $psProc.CloseMainWindow() | Out-Null
        }
    }

    # Wait for graceful exit
    $deadline = (Get-Date).AddSeconds($Grace)
    while ((Get-Date) -lt $deadline) {
        $still = @(Get-PythonProcs | Where-Object { $_.CommandLine -like "*$CmdlineMatch*" })
        if ($still.Count -eq 0) {
            Write-Status "$Name : stopped gracefully." OK
            return $true
        }
        Start-Sleep -Seconds 1
    }

    # Force kill
    $still = @(Get-PythonProcs | Where-Object { $_.CommandLine -like "*$CmdlineMatch*" })
    if ($still.Count -gt 0) {
        Write-Status "$Name : grace period expired, force-killing..." WARN
        foreach ($p in $still) {
            $pidNum = $p.ProcessId
            taskkill /PID $pidNum /F 2>$null | Out-Null
            Write-Status "$Name : force-killed PID $pidNum" WARN
        }
        Start-Sleep -Seconds 2
        $remaining = @(Get-PythonProcs | Where-Object { $_.CommandLine -like "*$CmdlineMatch*" })
        if ($remaining.Count -gt 0) {
            $leftPids = ($remaining | ForEach-Object { $_.ProcessId }) -join ','
            Write-Status "$Name : could not kill PID(s): $leftPids" FAIL
            return $false
        }
    }

    Write-Status "$Name : stopped (force)." OK
    return $true
}

function Test-PortListening {
    param([int]$Port)
    $out = netstat -ano 2>$null | Select-String 'LISTENING' | Select-String (":$Port\s")
    return ($null -ne $out -and @($out).Count -gt 0)
}

# ── Check current state ───────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Stop-UFO2Stack' -ForegroundColor Cyan
Write-Host ('=' * 52)
& "$ScriptDir\Get-UFO2Status.ps1"
$status = & "$ScriptDir\Get-UFO2Status.ps1" -Internal

if ($status.Overall -eq 'STOPPED') {
    Write-Status "Stack is already STOPPED -- nothing to do." OK
    exit 0
}

# ── Stop in reverse order ─────────────────────────────────────────────────────

if ($IncludeGradio -and $status.Components.GradioDemo.State -ne 'STOPPED') {
    Write-Host ''
    Write-Status "Stopping Gradio demo..." INFO
    Stop-ComponentProcess -Name 'GradioDemo' -CmdlineMatch 'gradio_demo.py' -Grace $GracePeriod | Out-Null
}

Write-Host ''
Write-Status "Stopping OmniParser server..." INFO
# Kill by commandline match first, then fall back to killing by port ownership
Stop-ComponentProcess -Name 'OmniParser' -CmdlineMatch 'omniparserserver.py' -Grace $GracePeriod | Out-Null

# Also kill any omniparser conda env python processes (handles workers/forks)
$omniEnvProcs = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $OMNI_ENV -and $_.CommandLine -like "*$OMNI_ENV*" })
if ($omniEnvProcs.Count -gt 0) {
    Write-Status "OmniParser : killing $($omniEnvProcs.Count) omniparser env process(es) (incl. workers)..." WARN
    foreach ($p in $omniEnvProcs) {
        taskkill /PID $p.ProcessId /F 2>$null | Out-Null
    }
    Start-Sleep -Seconds 2
}

# ── Verify shutdown ───────────────────────────────────────────────────────────
Write-Host ''
Write-Status "Verifying shutdown..." INFO
Start-Sleep -Seconds 2

$allPython    = @(Get-PythonProcs)
$omniLeft     = @($allPython | Where-Object { $_.CommandLine -like '*omniparserserver.py*' })
$gradioLeft   = @($allPython | Where-Object { $_.CommandLine -like '*gradio_demo.py*' })
$port8010Left = Test-PortListening 8010

if ($omniLeft.Count -eq 0)  { Write-Status "OmniParser process : gone" OK }
else                         { Write-Status "OmniParser process : still running! PIDs: $(($omniLeft | ForEach-Object { $_.ProcessId }) -join ',')" FAIL }

if (-not $port8010Left)     { Write-Status "Port 8010          : released" OK }
else                         { Write-Status "Port 8010          : still occupied!" WARN }

# ── Scan for residual artifacts ───────────────────────────────────────────────
Write-Host ''
Write-Status "Scanning for residual artifacts..." INFO
$artifacts = @()
$artifacts += @(Get-ChildItem $UFO_ROOT -Recurse -Filter '*.lock' -ErrorAction SilentlyContinue)
$artifacts += @(Get-ChildItem $UFO_ROOT -Recurse -Include '*.part','*.incomplete' -ErrorAction SilentlyContinue)
$artifacts += @(Get-ChildItem $UFO_ROOT -Recurse -Include '*.tmp','*.temp' -ErrorAction SilentlyContinue)

if ($artifacts.Count -gt 0) {
    Write-Status "$($artifacts.Count) residual artifact(s) found. Recommend:" WARN
    Write-Host "    .\scripts\Invoke-UFO2Cleanup.ps1" -ForegroundColor Yellow
} else {
    Write-Status "No residual artifacts detected." OK
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
$failed = ($omniLeft.Count -gt 0)
if (-not $failed) {
    Write-Host 'SUCCESS -- UFO2 stack stopped.' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'WARNING -- Some processes may still be running.' -ForegroundColor Yellow
    Write-Host '  Run: .\scripts\Get-UFO2Status.ps1  for current state.'
    exit 1
}
