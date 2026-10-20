# Start the packaged Windows app and prove it stays alive.
#
# This is deliberately not a UI test: GitHub-hosted Windows runners do not
# guarantee an interactive desktop, and MainWindowHandle is unreliable there.
# Starting the real executable still catches the failures a unit test cannot:
# a missing DLL, a bad resource path, or a startup exception that closes the
# process before the first frame.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,
    [int]$WarmupSeconds = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolved = Resolve-Path -LiteralPath $ExePath -ErrorAction Stop
Write-Host "Starting $resolved"
$process = Start-Process -FilePath $resolved -PassThru
try {
    Start-Sleep -Seconds $WarmupSeconds
    $process.Refresh()
    if ($process.HasExited) {
        throw ("The packaged app exited during startup with code {0}." -f $process.ExitCode)
    }
    Write-Host ("Smoke test passed: process {0} is still running after {1}s." -f `
        $process.Id, $WarmupSeconds)
} finally {
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit(5000) | Out-Null
    }
}
