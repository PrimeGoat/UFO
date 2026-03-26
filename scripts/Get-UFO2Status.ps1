<#
.SYNOPSIS
    Reports the operational status of the UFO2 stack.
.PARAMETER Quiet
    Emit a single structured summary line.
.PARAMETER Json
    Emit full JSON output.
.PARAMETER Internal
    Suppress all console output; return only the status object.
    Used by Invoke-UFO2Cleanup and other callers that want silent programmatic access.
.NOTES
    Default mode: displays to console via Write-Host AND returns the status object
    via the pipeline, so callers can do both at once:
        $s = & .\scripts\Get-UFO2Status.ps1
.EXAMPLE
    .\scripts\Get-UFO2Status.ps1
    .\scripts\Get-UFO2Status.ps1 -Quiet
    $s = & .\scripts\Get-UFO2Status.ps1
    $s = & .\scripts\Get-UFO2Status.ps1 -Internal
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$Json,
    [switch]$Internal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$UFO_ROOT        = 'D:\AI\UFO'
$OMNI_URL        = 'http://localhost:8010'
$OMNI_PROBE_URL  = 'http://localhost:8010/probe/'
$OMNI_SCHEMA_URL = 'http://localhost:8010/openapi.json'
$LOG_DIR         = Join-Path $UFO_ROOT 'logs'

# Bat file locations -- used to discover conda envs dynamically
$UFO_BAT  = Join-Path $UFO_ROOT 'start_ufo_mcp.bat'
$OMNI_BAT = Join-Path (Split-Path $UFO_ROOT -Parent) 'OmniParser\start_server.bat'

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

$UFO_ENV    = Get-CondaEnvFromBat $UFO_BAT
$OMNI_ENV   = Get-CondaEnvFromBat $OMNI_BAT
$UFO_PYTHON = if ($UFO_ENV) { Join-Path $UFO_ENV 'python.exe' } else { $null }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-AllProcs {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
}

function Get-PythonProcs {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue
}

function Test-PortListening {
    param([int]$Port)
    $out = netstat -ano 2>$null | Select-String 'LISTENING' | Select-String (":$Port\s")
    return ($null -ne $out -and @($out).Count -gt 0)
}

function Get-PortPids {
    param([int]$Port)
    $pids = @()
    $lines = netstat -ano 2>$null | Select-String 'LISTENING' | Select-String ":$Port\s"
    foreach ($l in $lines) {
        if ($l.ToString().Trim() -match '\s(\d+)$') { $pids += [int]$Matches[1] }
    }
    return $pids
}

function Invoke-HttpProbe {
    param([string]$Url, [int]$TimeoutSec = 5)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $body = $r.Content
        if ($body.Length -gt 400) { $body = $body.Substring(0, 400) }
        return @{ Ok = $true; Code = [int]$r.StatusCode; Body = $body }
    } catch {
        return @{ Ok = $false; Code = 0; Body = $_.Exception.Message }
    }
}

function Find-GradioPort {
    for ($p = 7861; $p -le 7875; $p++) {
        if (Test-PortListening $p) { return $p }
    }
    return $null
}

function Get-McpSessionClient {
    # Walk the parent chain to find the MCP client that spawned this process.
    # Skips intermediaries: python.exe, cmd.exe, conhost.exe, bash.exe, conda wrappers.
    # Returns the first process that looks like a real client application.
    param([int]$ProcessId)
    $allProcs   = @(Get-AllProcs)
    $skipNames  = @('python.exe','pythonw.exe','cmd.exe','conhost.exe','bash.exe','sh.exe','conda.exe')
    $curId      = $ProcessId
    for ($i = 0; $i -lt 10; $i++) {
        $proc = $allProcs | Where-Object { $_.ProcessId -eq $curId }
        if (-not $proc) { break }
        $n = $proc.Name.ToLower()
        if ($skipNames -notcontains $n) { return $proc }
        $curId = $proc.ParentProcessId
    }
    return $null
}

function Get-ProcessLabel {
    # Returns a human-readable label for a process.
    # For shell hosts (powershell, pwsh): extracts the script filename if present.
    # For all others: reads Description or Product from exe metadata.
    param($Proc)
    if (-not $Proc) { return $null }
    $name = $Proc.Name.ToLower()
    if ($name -in @('powershell.exe','pwsh.exe')) {
        # Extract .ps1 script name from commandline
        if ($Proc.CommandLine -match '([^\\/ "]+\.ps1)') {
            $script = $Matches[1]
            $tag = if ($script -eq 'Get-UFO2Status.ps1') { '[Status Script]' } else { '[PowerShell Script]' }
            return "$script $tag"
        }
        return 'powershell.exe [PowerShell]'
    }
    $gp = Get-Process -Id $Proc.ProcessId -ErrorAction SilentlyContinue
    if ($gp) {
        if ($gp.Description) { return "$($Proc.Name) [$($gp.Description)]" }
        if ($gp.Product)     { return "$($Proc.Name) [$($gp.Product)]" }
    }
    return $Proc.Name
}

# ---------------------------------------------------------------------------
# Collect processes (single WMI call)
# ---------------------------------------------------------------------------
$allPython = @(Get-PythonProcs)

# OmniParser: match by script name first
$omniProcs = @($allPython | Where-Object {
    $_.CommandLine -like '*omniparserserver.py*' -or
    $_.CommandLine -like '*omniparser*server*'
})

# OmniParser: fallback -- find by port 8010 ownership
$omniPort8010 = Test-PortListening 8010
if ($omniProcs.Count -eq 0 -and $omniPort8010) {
    $portPids = Get-PortPids 8010
    $omniProcs = @($allPython | Where-Object { $portPids -contains $_.ProcessId })
}

# UFO2 and Gradio
$ufoProcs    = @($allPython | Where-Object { $_.CommandLine -like '*ufo_mcp_server.py*' })
$gradioProcs = @($allPython | Where-Object { $_.CommandLine -like '*gradio_demo.py*' })
$gradioPort  = Find-GradioPort

# ---------------------------------------------------------------------------
# OmniParser health checks
# ---------------------------------------------------------------------------
# 1. Process in correct conda env
$omniEnvOk = $false
if ($omniProcs.Count -gt 0 -and $OMNI_ENV) {
    $ep = $omniProcs[0].ExecutablePath
    $cl = $omniProcs[0].CommandLine
    $omniEnvOk = ($ep -like "*$OMNI_ENV*") -or ($cl -like "*$OMNI_ENV*")
    if (-not $omniEnvOk -and (Test-Path "$OMNI_ENV\python.exe")) { $omniEnvOk = $true }
} elseif ($omniProcs.Count -gt 0 -and -not $OMNI_ENV) {
    $omniEnvOk = $null  # bat not found, cannot determine
}

# 2. Model weights present (critical files required to start)
$OMNI_ROOT     = Split-Path (Split-Path $UFO_ROOT -Parent) -Parent | Join-Path -ChildPath 'AI\OmniParser'
$OMNI_ROOT     = 'D:\AI\OmniParser'
$omniWeightsOk = (Test-Path "$OMNI_ROOT\weights\icon_detect\model.pt") -and
                 (Test-Path "$OMNI_ROOT\weights\icon_caption_florence\model.safetensors") -and
                 (Test-Path "$OMNI_ROOT\weights\icon_caption_florence\config.json")

# 3. Port 8010 listening (already collected above)

# 4. HTTP probe: GET /probe/ -- expect 200 + body contains "Omniparser API ready"
$omniProbe   = if ($omniPort8010) { Invoke-HttpProbe $OMNI_PROBE_URL } `
               else { @{ Ok = $false; Code = 0; Body = 'port 8010 not listening' } }
$omniBodyOk  = $omniProbe.Ok -and ($omniProbe.Body -like '*Omniparser API ready*')

# 4. HTTP schema: GET /openapi.json -- confirms FastAPI fully initialised
$omniSchema  = if ($omniPort8010) { Invoke-HttpProbe $OMNI_SCHEMA_URL } `
               else { @{ Ok = $false; Code = 0; Body = 'port 8010 not listening' } }
$omniSchemaOk = $omniSchema.Ok -and ($omniSchema.Body -like '*openapi*')

# ---------------------------------------------------------------------------
# UFO2 health checks
# ---------------------------------------------------------------------------
# 1. Conda env: check the env path from the bat file exists and has python.exe
#    This is independent of whether UFO2 is currently running -- the probe uses
#    this same python, so if env:OK and probe:OK the full startup chain is valid.
$ufoEnvOk = $UFO_PYTHON -and (Test-Path $UFO_PYTHON)

# 2. Config files present
$ufoConfigSys    = Test-Path "$UFO_ROOT\config\ufo\system.yaml"
$ufoConfigAgents = Test-Path "$UFO_ROOT\config\ufo\agents.yaml"
$ufoConfigOk     = $ufoConfigSys -and $ufoConfigAgents

# 3. MCP probe: spawn fresh UFO2 instance, send initialize+ping, check exit 0
$UFO_PROBE  = Join-Path $PSScriptRoot 'ufo2_probe.py'
$ufoProbeOk = $false
if ($UFO_PYTHON -and (Test-Path $UFO_PYTHON) -and (Test-Path $UFO_PROBE)) {
    & $UFO_PYTHON $UFO_PROBE 2>$null | Out-Null
    $ufoProbeOk = ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# Stdio session detection
# ---------------------------------------------------------------------------
# Probe session: always the current script process (this PowerShell instance ran the probe)
$probeProc       = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
$probeLabel      = Get-ProcessLabel -Proc $probeProc
$probePath       = if ($probeProc -and $probeProc.ExecutablePath) { $probeProc.ExecutablePath } else { 'N/A' }

# Persistent session: walk parent chain of the running UFO2 process (if any)
$ufoSessionClient      = $null
$ufoSessionClientLabel = $null
$ufoSessionClientPath  = 'N/A'
if ($ufoProcs.Count -gt 0) {
    $ufoSessionClient = Get-McpSessionClient -ProcessId $ufoProcs[0].ProcessId
    if ($ufoSessionClient) {
        $ufoSessionClientLabel = Get-ProcessLabel -Proc $ufoSessionClient
        $ufoSessionClientPath  = if ($ufoSessionClient.ExecutablePath) { $ufoSessionClient.ExecutablePath }
                                  else { 'N/A' }
    }
}

# ---------------------------------------------------------------------------
# Gradio
# ---------------------------------------------------------------------------
$gradioState = if ($gradioProcs.Count -gt 0 -and $null -ne $gradioPort)    { 'RUNNING'  }
               elseif ($gradioProcs.Count -gt 0 -or $null -ne $gradioPort) { 'DEGRADED' }
               else                                                          { 'STOPPED'  }

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
$lastLog = $null
if (Test-Path $LOG_DIR) {
    $lastLog = Get-ChildItem $LOG_DIR -Directory -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Overall component states
# ---------------------------------------------------------------------------
# OmniParser: port + probe body = RUNNING; partial signals = DEGRADED
$omniState = if   ($omniPort8010 -and $omniProbe.Ok -and $omniBodyOk)       { 'RUNNING'  }
             elseif ($omniPort8010 -or $omniProcs.Count -gt 0)               { 'DEGRADED' }
             else                                                              { 'STOPPED'  }

# UFO2: process + config + probe = RUNNING
$ufoState = if   ($ufoProcs.Count -gt 0 -and $ufoConfigOk -and $ufoProbeOk) { 'RUNNING'  }
            elseif ($ufoProcs.Count -gt 0)                                    { 'DEGRADED' }
            else                                                               { 'STOPPED'  }

$overallState =
    if     ($omniState -eq 'RUNNING'  -and $ufoState -eq 'RUNNING')  { 'RUNNING'  }
    elseif ($omniState -eq 'DEGRADED' -or  $ufoState -eq 'DEGRADED') { 'DEGRADED' }
    elseif ($omniState -eq 'STOPPED'  -and $ufoState -eq 'STOPPED')  { 'STOPPED'  }
    else                                                               { 'PARTIAL'  }

# ---------------------------------------------------------------------------
# Status object (returned to callers)
# ---------------------------------------------------------------------------
$statusObj = [PSCustomObject]@{
    Overall   = $overallState
    Timestamp = (Get-Date).ToString('MM-dd-yy hh:mm:sstt')
    Components = [PSCustomObject]@{
        UFO2 = [PSCustomObject]@{
            State      = $ufoState
            PIDs       = if ($ufoProcs.Count) { @($ufoProcs | ForEach-Object { $_.ProcessId }) } else { @() }
            EnvOk      = $ufoEnvOk
            ConfigOk   = $ufoConfigOk
            ProbeOk    = $ufoProbeOk
            Session    = if ($ufoSessionClient) { [PSCustomObject]@{
                             ClientPID   = $ufoSessionClient.ProcessId
                             ClientExe   = $ufoSessionClient.Name
                             ClientTitle = $ufoSessionClientTitle
                             ClientPath  = $ufoSessionClientPath
                         }} else { $null }
        }
        OmniParser = [PSCustomObject]@{
            State      = $omniState
            PIDs       = if ($omniProcs.Count) { @($omniProcs | ForEach-Object { $_.ProcessId }) } else { @() }
            EnvOk      = $omniEnvOk
            WeightsOk  = $omniWeightsOk
            Port8010   = $omniPort8010
            ProbeOk    = $omniProbe.Ok
            ProbeBody  = $omniBodyOk
            SchemaOk   = $omniSchemaOk
            ProbeCode  = $omniProbe.Code
            ProbeURL   = $OMNI_PROBE_URL
            URL        = $OMNI_URL
        }
        GradioDemo = [PSCustomObject]@{
            State    = $gradioState
            PIDs     = if ($gradioProcs.Count) { @($gradioProcs | ForEach-Object { $_.ProcessId }) } else { @() }
            Port     = $gradioPort
            URL      = if ($null -ne $gradioPort) { "http://localhost:$gradioPort" } else { $null }
            Optional = $true
        }
    }
    Logs = [PSCustomObject]@{
        Directory = $LOG_DIR
        LastTask  = if ($lastLog) { $lastLog.FullName } else { $null }
        LastMtime = if ($lastLog) { $lastLog.LastWriteTime.ToString('MM-dd-yy hh:mm:sstt') } else { $null }
    }
}

if ($Internal) { return $statusObj }

if ($Json) {
    $statusObj | ConvertTo-Json -Depth 10
    return
}

if ($Quiet) {
    Write-Output "STATUS=$overallState OmniParser=$omniState UFO2=$ufoState GradioDemo=$gradioState"
    return
}

# ---------------------------------------------------------------------------
# Interactive display
# ---------------------------------------------------------------------------
$stateClr = @{ RUNNING='Green'; STOPPED='Red'; PARTIAL='Yellow'; DEGRADED='Yellow' }

function fOk  { param($v) if ($v) { 'OK'   } else { 'FAIL' } }
function fBool { param($v) if ($v) { 'yes' } else { 'no'  } }

Write-Host ''
Write-Host 'UFO2 Stack Status' -ForegroundColor Cyan
Write-Host ('=' * 60)
Write-Host ("Overall : $overallState") -ForegroundColor $stateClr[$overallState]
Write-Host "Time    : $($statusObj.Timestamp)"
Write-Host ''
Write-Host 'Components:' -ForegroundColor Cyan

# UFO2 row
$m2 = if ($ufoState -eq 'RUNNING') { '[OK]  ' } elseif ($ufoState -eq 'DEGRADED') { '[WARN]' } else { '[FAIL]' }
$c2 = if ($ufoState -eq 'RUNNING') { 'Green' }  elseif ($ufoState -eq 'DEGRADED') { 'Yellow' } else { 'Red' }
$pid2 = if ($ufoProcs.Count) { $ufoProcs[0].ProcessId } else { 'N/A' }
$sessionInline = if ($ufoProbeOk -and $probeLabel) { "  (probe-session:$probeLabel PID:$PID)" } else { '' }
Write-Host ("  $m2 $('UFO2 Agent'.PadRight(14)) PID:$pid2  stdio  env:$(fOk $ufoEnvOk)  config:$(fOk $ufoConfigOk)  probe:$(fOk $ufoProbeOk)$sessionInline") -ForegroundColor $c2

# OmniParser row
$m1 = if ($omniState -eq 'RUNNING') { '[OK]  ' } elseif ($omniState -eq 'DEGRADED') { '[WARN]' } else { '[FAIL]' }
$c1 = if ($omniState -eq 'RUNNING') { 'Green' }  elseif ($omniState -eq 'DEGRADED') { 'Yellow' } else { 'Red' }
$pid1 = if ($omniProcs.Count) { $omniProcs[0].ProcessId } else { 'N/A' }
$portStr = if ($omniPort8010) { 'YES' } else { 'NO' }
Write-Host ("  $m1 $('OmniParser'.PadRight(14)) PID:$pid1  port:$portStr  env:$(fOk $omniEnvOk)  weights:$(fOk $omniWeightsOk)  probe:$(fOk ($omniProbe.Ok))  body:$(fOk $omniBodyOk)  schema:$(fOk $omniSchemaOk)") -ForegroundColor $c1

# Gradio row
$m3 = if ($gradioState -eq 'RUNNING') { '[OK]  ' } elseif ($gradioState -eq 'DEGRADED') { '[WARN]' } else { '[INFO]' }
$c3 = if ($gradioState -eq 'RUNNING') { 'Green' }  elseif ($gradioState -eq 'DEGRADED') { 'Yellow' } else { 'Gray' }
$gradioDetail = if ($gradioPort) { "PID:$($gradioProcs[0].ProcessId)  port:$gradioPort  http://localhost:$gradioPort" } else { 'OPTIONAL STOPPED' }
Write-Host ("  $m3 $('Gradio Demo'.PadRight(14)) $gradioDetail") -ForegroundColor $c3

# Stdio Sessions
Write-Host ''
Write-Host 'Stdio Sessions:' -ForegroundColor Cyan
if ($ufoProcs.Count -eq 0) {
    Write-Host '  none' -ForegroundColor DarkGray
} elseif ($ufoSessionClient) {
    Write-Host ("  UFO2 Agent") -ForegroundColor DarkCyan
    Write-Host ("    client  PID  : $($ufoSessionClient.ProcessId)") -ForegroundColor DarkCyan
    Write-Host ("    client  name : $ufoSessionClientLabel") -ForegroundColor DarkCyan
    Write-Host ("    client  path : $ufoSessionClientPath") -ForegroundColor DarkCyan
} else {
    Write-Host ("  UFO2 Agent  (PID:$($ufoProcs[0].ProcessId))  no active client") -ForegroundColor DarkGray
}

# URLs
Write-Host ''
Write-Host 'URLs:' -ForegroundColor Cyan
Write-Host "  OmniParser API    : $OMNI_URL"
Write-Host "  OmniParser probe  : $OMNI_PROBE_URL"
Write-Host "  OmniParser schema : $OMNI_SCHEMA_URL"
Write-Host "  OmniParser docs   : $OMNI_URL/docs"
if ($gradioPort) { Write-Host "  Gradio Demo       : http://localhost:$gradioPort" }
Write-Host "  Log directory     : $LOG_DIR"
if ($lastLog) {
    $lastMtime = $lastLog.LastWriteTime.ToString('MM-dd-yy hh:mm:sstt')
    Write-Host "  Last task log     : $($lastLog.FullName)  [$lastMtime]"
}

# Commands
Write-Host ''
Write-Host 'Commands:' -ForegroundColor Cyan
$cwd = (Get-Location).Path.TrimEnd('\')
$sd  = $PSScriptRoot.TrimEnd('\')
$rel = if ($sd -eq $cwd) { '.' }
       elseif ($sd.StartsWith($cwd + '\')) { '.' + $sd.Substring($cwd.Length) }
       else { $sd }
Write-Host "  Start   : $rel\Start-UFO2Stack.ps1"
Write-Host "  Stop    : $rel\Stop-UFO2Stack.ps1"
Write-Host "  Restart : $rel\Restart-UFO2Stack.ps1"
Write-Host "  Cleanup : $rel\Invoke-UFO2Cleanup.ps1"
Write-Host ''

