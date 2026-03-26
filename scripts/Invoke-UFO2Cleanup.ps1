<#
.SYNOPSIS
    Moves runtime artifact files to a timestamped archive. Never deletes.
.DESCRIPTION
    Finds Python bytecode, temp files, crash dumps, stale caches, and other
    generated artifacts. Moves them to D:\AI\UFO-artifacts\<timestamp>\
    preserving relative directory structure. Runtime-aware: skips locked files.
.PARAMETER Force
    Skip interactive prompts; proceed automatically.
.PARAMETER DryRun
    Report what would be moved without touching anything.
.PARAMETER IncludeLogs
    Also move .\logs\ contents (default: false).
.EXAMPLE
    .\scripts\Invoke-UFO2Cleanup.ps1 -DryRun
    .\scripts\Invoke-UFO2Cleanup.ps1 -Force
    .\scripts\Invoke-UFO2Cleanup.ps1 -Force -IncludeLogs
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun,
    [switch]$IncludeLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir    = $PSScriptRoot
$UFO_ROOT     = 'D:\AI\UFO'
$ARTIFACT_DIR = 'D:\AI\UFO-artifacts'

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

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Test-FileLocked {
    param([string]$Path)
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Invoke-UFO2Cleanup' -ForegroundColor Cyan
Write-Host ('=' * 52)
if ($DryRun) {
    Write-Host '=== DRY RUN -- no files will be modified ===' -ForegroundColor Yellow
}

# ── Get runtime state ─────────────────────────────────────────────────────────
$status = & "$ScriptDir\Get-UFO2Status.ps1" -Internal
Write-Status "State: $($status.Overall)  UFO2:$($status.Components.UFO2.State)  OmniParser:$($status.Components.OmniParser.State)" INFO

# ── Compute destination ───────────────────────────────────────────────────────
$ts   = (Get-Date).ToString('MM-dd-yy hh-mm-sstt')
$dest = Join-Path $ARTIFACT_DIR $ts
Write-Status "Archive destination: $dest" INFO

# ── Build artifact list ───────────────────────────────────────────────────────
Write-Status "Scanning for artifacts in $UFO_ROOT ..." INFO

$targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$skipped = [System.Collections.Generic.List[hashtable]]::new()

$allFiles = Get-ChildItem $UFO_ROOT -Recurse -File -ErrorAction SilentlyContinue

foreach ($file in $allFiles) {
    $rel     = $file.FullName.Substring($UFO_ROOT.Length).TrimStart('\')
    $include = $false
    $reason  = ''

    # Python bytecode
    if ($file.Extension -in @('.pyc', '.pyo', '.pyd')) {
        $include = $true; $reason = 'python bytecode'
    }

    # __pycache__
    if ($rel -match '(^|\\)__pycache__\\') {
        $include = $true; $reason = '__pycache__'
    }

    # Temp/scratch
    if ($file.Extension -in @('.tmp', '.temp') -or $file.Name -like '~*') {
        $include = $true; $reason = 'temp file'
    }

    # Crash/dump
    if ($file.Extension -in @('.dmp', '.mdmp', '.stackdump') -or $file.Name -eq 'core') {
        $include = $true; $reason = 'crash/dump'
    }

    # Partial downloads
    if ($file.Extension -in @('.part', '.incomplete')) {
        $include = $true; $reason = 'partial download'
    }

    # Stale FAISS/vectorstore (not in vectordb/)
    if (($file.Extension -eq '.faiss' -or $file.Extension -eq '.index') -and
        $rel -notmatch '^vectordb\\') {
        $include = $true; $reason = 'stale index'
    }

    # .cache
    if ($rel -match '(^|\\)\.cache\\') {
        $include = $true; $reason = '.cache'
    }

    # Orphaned lock files
    if ($file.Extension -eq '.lock' -and -not (Test-FileLocked $file.FullName)) {
        $include = $true; $reason = 'orphaned lock'
    }

    # Logs (optional)
    if ($IncludeLogs -and $rel -match '^logs\\') {
        $include = $true; $reason = 'log file (-IncludeLogs)'
    }

    if (-not $include) { continue }

    # Runtime-aware: skip locked files if stack is running
    if ($status.Overall -in @('RUNNING', 'PARTIAL', 'DEGRADED')) {
        if (Test-FileLocked $file.FullName) {
            $skipped.Add(@{ File = $file.FullName; Reason = 'locked by running process' })
            continue
        }
    }

    $targets.Add($file)
}

Write-Status "Found $($targets.Count) artifact file(s) to move." INFO
if ($skipped.Count -gt 0) {
    Write-Status "$($skipped.Count) file(s) skipped (locked by running processes)." WARN
}

if ($targets.Count -eq 0) {
    Write-Status "No artifact files found -- nothing to do." OK
    if ($DryRun) {
        Write-Host ''
        Write-Host '=== DRY RUN -- no files were modified ===' -ForegroundColor Yellow
    }
    exit 0
}

# ── Move / report files ───────────────────────────────────────────────────────
$movedCount = 0
$movedBytes = 0L
$errorCount = 0

foreach ($file in $targets) {
    $rel      = $file.FullName.Substring($UFO_ROOT.Length).TrimStart('\')
    $destPath = Join-Path $dest $rel

    Write-Host "  $($file.FullName)" -ForegroundColor DarkGray -NoNewline
    Write-Host " -> $destPath"

    if (-not $DryRun) {
        try {
            $destParent = Split-Path $destPath -Parent
            if (-not (Test-Path $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }
            Move-Item -Path $file.FullName -Destination $destPath -Force
            $movedCount++
            $movedBytes += $file.Length
        } catch {
            Write-Status "Failed to move $($file.FullName): $($_.Exception.Message)" FAIL
            $skipped.Add(@{ File = $file.FullName; Reason = $_.Exception.Message })
            $errorCount++
        }
    } else {
        $movedCount++
        $movedBytes += $file.Length
    }
}

# ── Skipped report ────────────────────────────────────────────────────────────
if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Status "Skipped files:" WARN
    foreach ($s in $skipped) {
        Write-Host "  SKIPPED: $($s.File)  ($($s.Reason))" -ForegroundColor DarkYellow
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('-' * 52)
if ($DryRun) {
    Write-Host '=== DRY RUN -- no files were modified ===' -ForegroundColor Yellow
    Write-Host "  Would move : $movedCount file(s)  ($(Format-FileSize $movedBytes))"
    Write-Host "  Destination: $dest"
} else {
    Write-Status "Moved      : $movedCount file(s)  ($(Format-FileSize $movedBytes))" OK
    Write-Status "Destination: $dest" OK
    if ($errorCount -gt 0) {
        Write-Status "Errors     : $errorCount file(s) could not be moved." FAIL
    }
}

Write-Host ''
$postStatus = & "$ScriptDir\Get-UFO2Status.ps1" -Internal
Write-Status "Post-cleanup state: $($postStatus.Overall)  UFO2:$($postStatus.Components.UFO2.State)  OmniParser:$($postStatus.Components.OmniParser.State)" $(if ($postStatus.Overall -eq 'RUNNING') { 'OK' } else { 'INFO' })

exit $(if ($errorCount -gt 0) { 1 } else { 0 })
