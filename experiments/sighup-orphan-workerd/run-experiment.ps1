<#
.SYNOPSIS
    Does closing a console window leave orphaned workerd processes on Windows?

.DESCRIPTION
    Starts `wrangler dev` in its own console, closes that console the way a user would,
    and reports whether the workerd child processes survive.

    Run it twice: once with -Variant baseline (stock miniflare) and once with
    -Variant patched (SIGHUP handler injected into the installed miniflare bundle).
    Results are appended to results-windows.tsv.

    Read-only with respect to your machine: it creates its own temp project under
    $env:TEMP and only ever kills processes it started itself.

.PARAMETER Variant
    baseline = miniflare as published. patched = with the SIGHUP handler.

.PARAMETER Trials
    How many times to repeat. 3 is plenty; the macOS signal was 5/5 vs 0/5.

.PARAMETER WranglerVersion
    Pin wrangler so results are comparable to the macOS run.

.EXAMPLE
    .\run-experiment.ps1 -Variant baseline -Trials 3
    .\run-experiment.ps1 -Variant patched  -Trials 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('baseline', 'patched')]
    [string]$Variant,

    [int]$Trials = 3,

    [string]$WranglerVersion = '4.107.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Join-Path $env:TEMP 'wrangler-sighup-test'
$ResultsTsv = Join-Path $ScriptDir 'results-windows.tsv'

# --- Win32 interop: send a real console-close event -------------------------
# Windows has no `kill -HUP`. Node maps CTRL_CLOSE_EVENT (console window closed)
# onto SIGHUP, so that is what we generate. AttachConsole lets us target the
# child's console; FreeConsole detaches ours first because a process can only be
# attached to one console at a time.
if (-not ('WinConsole' -as [type])) {
    Add-Type -Namespace '' -Name 'WinConsole' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

[DllImport("kernel32.dll")]
public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
'@
}

$CTRL_C_EVENT     = 0
$CTRL_BREAK_EVENT = 1

function Write-Step { param([string]$Message) Write-Host "  $Message" -ForegroundColor DarkGray }

function Initialize-Project {
    if (Test-Path $ProjectDir) {
        Remove-Item $ProjectDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path (Join-Path $ProjectDir 'src') -Force | Out-Null

    # Deliberately framework-free: the macOS runs reproduced this with both
    # Hono and Next.js, so the app layer is not the variable.
    Set-Content -Path (Join-Path $ProjectDir 'src\index.js') -Encoding utf8 -Value @'
export default { fetch() { return new Response("ok"); } };
'@

    Set-Content -Path (Join-Path $ProjectDir 'wrangler.json') -Encoding utf8 -Value @'
{ "name": "sighup-test", "main": "src/index.js", "compatibility_date": "2026-01-01" }
'@

    Set-Content -Path (Join-Path $ProjectDir 'package.json') -Encoding utf8 -Value @'
{ "name": "wrangler-sighup-test", "private": true, "version": "0.0.0" }
'@

    Write-Step "Installing wrangler@$WranglerVersion (this takes a moment)..."
    Push-Location $ProjectDir
    try {
        & npm install "wrangler@$WranglerVersion" --no-audit --no-fund 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $miniflareEntry = Join-Path $ProjectDir 'node_modules\miniflare\dist\src\index.js'
    if (-not (Test-Path $miniflareEntry)) {
        throw "miniflare bundle not found at $miniflareEntry"
    }
    Copy-Item $miniflareEntry "$miniflareEntry.bak" -Force
    return $miniflareEntry
}

function Set-MiniflareVariant {
    param([string]$EntryPath, [string]$Which)

    # Always start from the pristine copy so patched/baseline runs cannot drift.
    Copy-Item "$EntryPath.bak" $EntryPath -Force
    if ($Which -eq 'baseline') {
        Write-Step 'miniflare: stock (no SIGHUP handler)'
        return
    }

    $source = Get-Content $EntryPath -Raw

    # The bundle keeps exit-hook's shape, so anchor on the SIGINT/SIGTERM pair.
    $addAnchor = @"
  process.on("SIGINT", onSignalInt);
  process.on("SIGTERM", onSignalTerm);
"@
    if ($source -notlike "*$addAnchor*") {
        throw 'Could not find the exit-hook listener registration in the miniflare bundle. The bundle layout may have changed for this wrangler version.'
    }

    $addReplacement = @"
  process.on("SIGINT", onSignalInt);
  process.on("SIGTERM", onSignalTerm);
  process.on("SIGHUP", onSignalHup);
"@
    $source = $source.Replace($addAnchor, $addReplacement)

    $removeAnchor = @"
  process.removeListener("SIGTERM", onSignalTerm);
  process.removeListener("message", onMessage);
"@
    $removeReplacement = @"
  process.removeListener("SIGTERM", onSignalTerm);
  process.removeListener("SIGHUP", onSignalHup);
  process.removeListener("message", onMessage);
"@
    $source = $source.Replace($removeAnchor, $removeReplacement)

    # Mirror onSignalTerm exactly, only the exit code differs (128 + SIGHUP).
    $hupFunction = @"

function onSignalHup() {
  runCallbacks();
  process.exit(128 + 1);
}
__name(onSignalHup, "onSignalHup");
"@
    $termPattern = 'function onSignalTerm\(\)\s*\{[^}]*\}'
    $termMatch = [regex]::Match($source, $termPattern)
    if (-not $termMatch.Success) { throw 'Could not find onSignalTerm in the miniflare bundle.' }
    $source = $source.Insert($termMatch.Index + $termMatch.Length, $hupFunction)

    Set-Content -Path $EntryPath -Value $source -Encoding utf8 -NoNewline
    $count = ([regex]::Matches((Get-Content $EntryPath -Raw), 'onSignalHup')).Count
    if ($count -lt 3) { throw "SIGHUP patch did not apply cleanly (found $count references, expected >= 3)." }
    Write-Step "miniflare: patched (onSignalHup present, $count references)"
}

function Get-WorkerdProcesses {
    # Scope strictly to this experiment's copy of workerd.
    $needle = ($ProjectDir -replace '\\', '\\') + '\\node_modules'
    Get-CimInstance Win32_Process -Filter "Name='workerd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$ProjectDir*" } |
        Select-Object ProcessId, ParentProcessId, ExecutablePath
}

function Stop-LeftoverProcesses {
    Get-WorkerdProcesses | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*wrangler-sighup-test*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

function Send-ConsoleCloseEvent {
    param([int]$ProcessId)

    # Detach from our own console, attach to the child's, then raise the event.
    # CTRL_BREAK is delivered to the target group reliably; CTRL_C is the fallback.
    [void][WinConsole]::FreeConsole()
    $attached = [WinConsole]::AttachConsole([uint32]$ProcessId)
    if (-not $attached) {
        return $false
    }
    # Ignore the event in our own process so we do not take ourselves down.
    [void][WinConsole]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
    $sent = [WinConsole]::GenerateConsoleCtrlEvent([uint32]$CTRL_BREAK_EVENT, [uint32]$ProcessId)
    if (-not $sent) {
        $sent = [WinConsole]::GenerateConsoleCtrlEvent([uint32]$CTRL_C_EVENT, [uint32]$ProcessId)
    }
    [void][WinConsole]::FreeConsole()
    [void][WinConsole]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
    return $sent
}

function Invoke-Trial {
    param([string]$Which, [int]$Run)

    Stop-LeftoverProcesses

    $logPath = Join-Path $ProjectDir "dev-$Which-$Run.log"
    $wrangler = Join-Path $ProjectDir 'node_modules\.bin\wrangler.cmd'

    # A new console window is what makes the close event meaningful.
    $proc = Start-Process -FilePath $wrangler `
        -ArgumentList 'dev', '--port', '0' `
        -WorkingDirectory $ProjectDir `
        -RedirectStandardOutput $logPath `
        -RedirectStandardError "$logPath.err" `
        -PassThru

    # Wait for workerd children (wrangler normally starts two).
    $workerd = @()
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1
        $workerd = @(Get-WorkerdProcesses)
        if ($workerd.Count -ge 2) { break }
    }
    Start-Sleep -Seconds 3
    $workerd = @(Get-WorkerdProcesses)

    if ($workerd.Count -eq 0) {
        Write-Host "    trial ${Run}: workerd never started - check $logPath" -ForegroundColor Yellow
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Stop-LeftoverProcesses
        return [pscustomobject]@{
            Variant = $Which; Run = $Run; Before = 0; After = 'NA'
            Survivors = 'NA'; Verdict = 'STARTUP_FAIL'
        }
    }

    $beforePids = $workerd.ProcessId
    Write-Step "trial ${Run}: wrangler pid=$($proc.Id), workerd=$($beforePids -join ', ')"

    $sent = Send-ConsoleCloseEvent -ProcessId $proc.Id
    if (-not $sent) {
        # Fall back to closing the window, which also produces CTRL_CLOSE_EVENT.
        Write-Step "trial ${Run}: ctrl event failed, falling back to CloseMainWindow"
        [void]$proc.CloseMainWindow()
    }

    Start-Sleep -Seconds 10   # Windows force-kills ~10s after console close

    $survivors = @(Get-WorkerdProcesses | Where-Object { $beforePids -contains $_.ProcessId })
    $verdict = if ($survivors.Count -gt 0) { 'ORPHANED' } else { 'CLEAN' }

    $survivorText = if ($survivors.Count -gt 0) {
        ($survivors | ForEach-Object { "$($_.ProcessId)(ppid $($_.ParentProcessId))" }) -join ' '
    } else { 'none' }

    $colour = if ($verdict -eq 'ORPHANED') { 'Red' } else { 'Green' }
    Write-Host "    trial ${Run}: $verdict - survivors: $survivorText" -ForegroundColor $colour

    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Stop-LeftoverProcesses

    return [pscustomobject]@{
        Variant = $Which; Run = $Run; Before = $beforePids.Count
        After = $survivors.Count; Survivors = $survivorText; Verdict = $verdict
    }
}

# --- main -------------------------------------------------------------------

Write-Host ''
Write-Host "SIGHUP orphan workerd - Windows check ($Variant, $Trials trials)" -ForegroundColor Cyan
Write-Host ("OS: " + [System.Environment]::OSVersion.VersionString + " | PowerShell " + $PSVersionTable.PSVersion) -ForegroundColor DarkGray
Write-Host ''

$entry = Initialize-Project
Set-MiniflareVariant -EntryPath $entry -Which $Variant
Write-Host ''

$results = @()
for ($run = 1; $run -le $Trials; $run++) {
    $results += Invoke-Trial -Which $Variant -Run $run
}

if (-not (Test-Path $ResultsTsv)) {
    "variant`trun`tworkerd_before`tworkerd_after`tsurvivors`tverdict`tos" |
        Set-Content -Path $ResultsTsv -Encoding utf8
}
$osLabel = [System.Environment]::OSVersion.VersionString
foreach ($r in $results) {
    "$($r.Variant)`t$($r.Run)`t$($r.Before)`t$($r.After)`t$($r.Survivors)`t$($r.Verdict)`t$osLabel" |
        Add-Content -Path $ResultsTsv -Encoding utf8
}

$orphaned = @($results | Where-Object { $_.Verdict -eq 'ORPHANED' }).Count
$clean    = @($results | Where-Object { $_.Verdict -eq 'CLEAN' }).Count
$failed   = @($results | Where-Object { $_.Verdict -eq 'STARTUP_FAIL' }).Count

Write-Host ''
Write-Host "Summary [$Variant]: $orphaned orphaned / $clean clean / $failed startup failures (of $Trials)" -ForegroundColor Cyan
Write-Host "Appended to $ResultsTsv" -ForegroundColor DarkGray
Write-Host ''
if ($failed -gt 0) {
    Write-Host 'Some trials never started workerd; the numbers above are not conclusive.' -ForegroundColor Yellow
    Write-Host "Check the dev-*.log files in $ProjectDir" -ForegroundColor Yellow
}
Write-Host 'Run the other variant too, then share results-windows.tsv.' -ForegroundColor DarkGray
Write-Host ''
