[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleRoot,
    [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
$sidecarExe = Join-Path $BundleRoot 'sidecar\pt_autopilot.exe'
$tesseractExe = Join-Path $BundleRoot 'tesseract\tesseract.exe'
if (-not (Test-Path -LiteralPath $sidecarExe)) {
    throw "Missing bundled sidecar: $sidecarExe"
}

$manifest = $null
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $BundleRoot 'bundle-manifest.json'
}
if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.files) {
        throw '$ManifestPath has no files section.'
    }
    foreach ($entry in $manifest.files.PSObject.Properties) {
        $relative = $entry.Name.Replace('/', '\')
        $candidate = Join-Path $BundleRoot $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Manifest file is missing: $relative"
        }
        $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256)
        if ($actual.Hash.ToLowerInvariant() -ne
            "$($entry.Value.sha256)".ToLowerInvariant()) {
            throw "Manifest hash does not match: $relative"
        }
    }
} else {
    Write-Warning "No bundle manifest at $ManifestPath; hash and version checks were skipped."
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

    if ($manifest) {
        if ($manifest.signed) {
            foreach ($relative in @('net_builder.exe',
                    'sidecar\pt_autopilot.exe')) {
                $signature = Get-AuthenticodeSignature (Join-Path `
                    $BundleRoot $relative)
                if ($signature.Status -ne 'Valid') {
                    throw "Signature is not valid for $relative`: $($signature.Status)."
                }
            }
        }
        if ("$($health.version)" -ne "$($manifest.sidecarVersion)") {
            throw ("Engine version $($health.version) does not match the " +
                "manifest's $($manifest.sidecarVersion).")
        }
        $reportedFile = "$($health.engine.file)"
        if ($reportedFile) {
            $expectedFile = [IO.Path]::GetFullPath($sidecarExe)
            if ([IO.Path]::GetFullPath($reportedFile) -ne $expectedFile) {
                throw ("The process serving /health is $reportedFile, not the " +
                    "bundled $expectedFile.")
            }
        }
    }

    [pscustomobject]@{
        Pid = $process.Id
        Version = $health.version
        ManifestVersion = if ($manifest) { $manifest.sidecarVersion } else { $null }
        ManifestAppVersion = if ($manifest) { $manifest.appVersion } else { $null }
        ManifestSourceRevision = if ($manifest) { $manifest.sourceRevision } else { $null }
        EngineFile = $health.engine.file
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
