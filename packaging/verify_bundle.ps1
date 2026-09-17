[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleRoot
)

$ErrorActionPreference = 'Stop'
$sidecarExe = Join-Path $BundleRoot 'sidecar\pt_autopilot.exe'
$tesseractExe = Join-Path $BundleRoot 'tesseract\tesseract.exe'
if (-not (Test-Path -LiteralPath $sidecarExe)) {
    throw "Missing bundled sidecar: $sidecarExe"
}

$previousTesseract = $env:TESSERACT_CMD
if (Test-Path -LiteralPath $tesseractExe) {
    $env:TESSERACT_CMD = $tesseractExe
}
$existing = @(Get-NetTCPConnection -LocalPort 5005 -State Listen `
    -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
    $owners = ($existing | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
    throw "Port 5005 is already owned by process $owners; refusing to validate a stale sidecar."
}
$process = $null
$process = Start-Process -FilePath $sidecarExe `
    -WorkingDirectory (Split-Path $sidecarExe) -WindowStyle Hidden -PassThru
try {
    $health = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) {
            throw "Bundled sidecar exited before /health became available (code $($process.ExitCode))."
        }
        try {
            $listener = @(Get-NetTCPConnection -LocalPort 5005 -State Listen `
                -ErrorAction SilentlyContinue)
            if ($listener.Count -eq 0) { continue }
            if (($listener | Select-Object -ExpandProperty OwningProcess -Unique) -ne $process.Id) {
                throw 'Port 5005 was claimed by a different process while validating the bundle.'
            }
            $health = Invoke-RestMethod 'http://127.0.0.1:5005/health' -TimeoutSec 2
            break
        } catch {}
    }
    if ($null -eq $health) {
        throw 'Bundled sidecar did not answer /health.'
    }
    [pscustomobject]@{
        Pid = $process.Id
        Version = $health.version
        Rpa = $health.rpa
        Ocr = $health.ocr
        Healthy = $health.ok
    } | ConvertTo-Json -Compress
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
    if ($null -eq $previousTesseract) {
        Remove-Item Env:TESSERACT_CMD -ErrorAction SilentlyContinue
    } else {
        $env:TESSERACT_CMD = $previousTesseract
    }
}
