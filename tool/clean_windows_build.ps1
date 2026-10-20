# Clean a Windows Flutter build when an old NetBuilder or test process still
# holds sqlite3.dll. Run from the repository root:
#
#   powershell -ExecutionPolicy Bypass -File tool/clean_windows_build.ps1 -Force
#
# The retries matter: antivirus and Explorer previews release a DLL a moment
# after the process exits, and a single Remove-Item turns that into a build
# failure that looks like a compiler problem.

[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$processNames = @('net_builder', 'netbuilder', 'flutter_tester')
$stale = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $processNames -contains $_.ProcessName.ToLowerInvariant() }
)

if ($stale.Count -gt 0) {
    Write-Host 'Stale NetBuilder/test processes are holding the build:'
    $stale | ForEach-Object { Write-Host ("  {0} (PID {1})" -f $_.ProcessName, $_.Id) }
    if (-not $Force) {
        throw 'Close those processes, or rerun with -Force to stop them.'
    }
    $stale | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

function Remove-WithRetry {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 6) {
                throw (("Could not remove '{0}' after 6 attempts. Close NetBuilder, " +
                    "any file preview, and pause antivirus scanning, then retry. " +
                    "Last error: {1}") -f $Path, $_.Exception.Message)
            }
            Write-Host ("Waiting for '{0}' to be released (attempt {1}/6)..." -f $Path, $attempt)
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
}

Remove-WithRetry 'build\windows'
Remove-WithRetry '.dart_tool\flutter_build'
Write-Host 'Windows build directories are clean.'
