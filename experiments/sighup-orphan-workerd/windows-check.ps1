<#
.SYNOPSIS
    Windows check for the SIGHUP orphan-workerd bug. Mostly manual, on purpose.

.DESCRIPTION
    On Windows, SIGHUP only exists as Node's mapping of CTRL_CLOSE_EVENT — the
    event raised when a console window is actually closed. There is no way to
    send it programmatically: GenerateConsoleCtrlEvent accepts only
    CTRL_C_EVENT and CTRL_BREAK_EVENT (which Node maps to SIGINT and SIGBREAK),
    and process.kill() can't deliver SIGHUP either. So the window has to be
    closed by hand, and this script only handles the setup and the counting.

    Run it twice — once per variant — and close the window it opens each time.

.PARAMETER Variant
    baseline = miniflare as published (expected to leak).
    patched  = with the SIGHUP handler (expected to be clean).

.EXAMPLE
    .\windows-check.ps1 -Variant baseline
    .\windows-check.ps1 -Variant patched
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('baseline', 'patched')]
    [string]$Variant,

    [string]$WranglerVersion = '4.107.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Join-Path $env:TEMP 'sighup-windows-check'
$ResultsTsv = Join-Path $ScriptDir 'results-windows.tsv'

function Get-OurWorkerd {
    Get-CimInstance Win32_Process -Filter "Name='workerd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($ProjectDir) } |
        Select-Object ProcessId, ParentProcessId
}

function Test-Alive {
    param([int]$ProcessId)
    $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

Write-Host ''
Write-Host "SIGHUP orphan workerd — Windows check [$Variant]" -ForegroundColor Cyan
Write-Host ([System.Environment]::OSVersion.VersionString) -ForegroundColor DarkGray
Write-Host ''

# --- setup -----------------------------------------------------------------
Write-Host 'Setting up the throwaway project...' -ForegroundColor DarkGray
& node (Join-Path $ScriptDir 'setup-project.mjs') $Variant $ProjectDir $WranglerVersion
if ($LASTEXITCODE -ne 0) { throw "setup-project.mjs failed ($LASTEXITCODE)" }

# Anything left over from a previous run would be counted as a survivor.
Get-OurWorkerd | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# --- start the dev server in its own console -------------------------------
Write-Host ''
Write-Host 'Opening a console window running `wrangler dev`...' -ForegroundColor DarkGray

$wrangler = Join-Path $ProjectDir 'node_modules\.bin\wrangler.cmd'
$proc = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList '/c', "title SIGHUP test - CLOSE THIS WINDOW && `"$wrangler`" dev --port 0" `
    -WorkingDirectory $ProjectDir `
    -PassThru

$workerd = @()
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    $workerd = @(Get-OurWorkerd)
    if ($workerd.Count -ge 2) { break }
}
Start-Sleep -Seconds 3
$workerd = @(Get-OurWorkerd)

if ($workerd.Count -eq 0) {
    Write-Host ''
    Write-Host 'workerd never started — nothing to measure.' -ForegroundColor Yellow
    Write-Host 'Check the console window for the error, then close it.' -ForegroundColor Yellow
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

$before = $workerd.ProcessId
Write-Host ''
Write-Host "  workerd running: $($before -join ', ')" -ForegroundColor Green
Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
Write-Host '   Now CLOSE the console window titled "SIGHUP test"' -ForegroundColor Yellow
Write-Host '   with its X button or Alt+F4.' -ForegroundColor Yellow
Write-Host '' -ForegroundColor Yellow
Write-Host '   Do NOT press Ctrl+C — that is SIGINT, a path that already works.' -ForegroundColor Yellow
Write-Host '   Closing the window is what raises SIGHUP.' -ForegroundColor Yellow
Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
Write-Host ''
Read-Host 'Press Enter once the window is closed'

# Windows force-terminates roughly 10s after the close event; give it room.
Write-Host 'Waiting 12s for shutdown to finish...' -ForegroundColor DarkGray
Start-Sleep -Seconds 12

$survivors = @($before | Where-Object { Test-Alive -ProcessId $_ })
$verdict = if ($survivors.Count -gt 0) { 'ORPHANED' } else { 'CLEAN' }
$colour = if ($verdict -eq 'ORPHANED') { 'Red' } else { 'Green' }

Write-Host ''
Write-Host "Result [$Variant]: $verdict" -ForegroundColor $colour
if ($survivors.Count -gt 0) {
    Get-OurWorkerd | Where-Object { $survivors -contains $_.ProcessId } | ForEach-Object {
        $parentAlive = Test-Alive -ProcessId $_.ParentProcessId
        Write-Host ("  pid {0} survived (parent {1} {2})" -f `
            $_.ProcessId, $_.ParentProcessId, $(if ($parentAlive) { 'still alive' } else { 'gone' }))
    }
}

if (-not (Test-Path $ResultsTsv)) {
    "variant`tworkerd_before`tworkerd_after`tverdict`tos" | Set-Content -Path $ResultsTsv -Encoding utf8
}
"$Variant`t$($before.Count)`t$($survivors.Count)`t$verdict`t$([System.Environment]::OSVersion.VersionString)" |
    Add-Content -Path $ResultsTsv -Encoding utf8

Get-OurWorkerd | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Appended to $ResultsTsv" -ForegroundColor DarkGray
Write-Host 'Run the other variant too, then share that file.' -ForegroundColor DarkGray
Write-Host ''
