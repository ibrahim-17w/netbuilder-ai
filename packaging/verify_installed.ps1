[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [switch]$StopAfter
)

$ErrorActionPreference = 'Stop'
$target = if ($InstallRoot.Trim()) {
    [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
} else {
    Join-Path $env:LOCALAPPDATA 'NetBuilderAI'
}
$app = Join-Path $target 'net_builder.exe'
$sidecar = Join-Path $target 'sidecar\pt_autopilot.exe'
$manifestPath = Join-Path $target 'bundle-manifest.json'
$installInfoPath = Join-Path $target 'config\install.json'
$uninstaller = Join-Path $target 'uninstall.ps1'

foreach ($required in @($app, $sidecar, $manifestPath, $installInfoPath,
        $uninstaller)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Installed package is missing $required"
    }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$installInfo = Get-Content -LiteralPath $installInfoPath -Raw | ConvertFrom-Json
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).
    Hash.ToLowerInvariant()
if ("$($installInfo.bundleManifestSha256)".Trim() -and
    $manifestHash -ne "$($installInfo.bundleManifestSha256)".ToLowerInvariant()) {
    throw 'install.json does not match bundle-manifest.json.'
}
$installedVersion = (Get-Item -LiteralPath $app).VersionInfo.ProductVersion
if ("$($manifest.appVersion)".Trim() -and $installedVersion -and
    -not $installedVersion.StartsWith("$($manifest.appVersion)",
        [StringComparison]::Ordinal)) {
    throw ("The manifest names app $($manifest.appVersion), but " +
        "net_builder.exe reports $installedVersion.")
}
$hashChecks = @()
foreach ($entry in $manifest.files.PSObject.Properties) {
    $relative = $entry.Name.Replace('/', '\')
    $candidate = Join-Path $target $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Installed manifest file is missing: $relative"
    }
    $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).
        Hash.ToLowerInvariant()
    $matches = $actual -eq "$($entry.Value.sha256)".ToLowerInvariant()
    $hashChecks += [pscustomobject]@{
        file = $relative
        matches = $matches
    }
    if (-not $matches) { throw "Installed file hash does not match: $relative" }
}

# A verifier has to observe the app's own startup path. An app that was
# already running may not restart an engine this script just stopped, so close
# both processes that belong to THIS install before starting it fresh.
Get-Process net_builder, pt_autopilot -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $app -or $_.Path -eq $sidecar } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$appProcess = Start-Process -FilePath $app -WorkingDirectory $target -PassThru
$sidecarProcess = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    $sidecarProcess = Get-Process pt_autopilot -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $sidecar } |
        Select-Object -First 1
    if ($sidecarProcess) { break }
}
if (-not $sidecarProcess) {
    throw 'The app did not start the bundled engine from this install.'
}

# The process can exist before Flask starts listening, especially on a busy
# upgrade. Wait for the health endpoint, and only accept a listener owned by
# the sidecar this install just started.
$health = $null
for ($i = 0; $i -lt 40; $i++) {
    try {
        $listener = @(Get-NetTCPConnection -LocalPort 5005 -State Listen `
            -ErrorAction SilentlyContinue)
        if ($listener.Count -eq 0) {
            Start-Sleep -Milliseconds 500
            continue
        }
        $owners = @($listener |
            Select-Object -ExpandProperty OwningProcess -Unique)
        if ($owners -notcontains $sidecarProcess.Id) {
            Start-Sleep -Milliseconds 500
            continue
        }
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:5005/health' `
            -TimeoutSec 3
        if ($health.ok) { break }
    } catch {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $health) { throw 'The installed engine did not answer /health.' }
if (-not $health.ok) { throw 'The installed engine reported an unhealthy state.' }

$registry = Get-ItemProperty -Path `
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NetBuilderAI' `
    -ErrorAction SilentlyContinue
$result = [pscustomobject]@{
    InstallRoot = $target
    AppPath = $app
    AppRunning = [bool](Get-Process -Id $appProcess.Id -ErrorAction SilentlyContinue)
    SidecarPath = $sidecar
    SidecarAutoStarted = [bool]$sidecarProcess
    SidecarPid = if ($sidecarProcess) { $sidecarProcess.Id } else { $null }
    ManifestAppVersion = $manifest.appVersion
    ManifestSidecarVersion = $manifest.sidecarVersion
    InstalledAppVersion = $installedVersion
    BundleManifestSha256 = $manifestHash
    InstallInfoAppVersion = $installInfo.appVersion
    InstallInfoSidecarVersion = $installInfo.sidecarVersion
    ManifestHashes = @($hashChecks)
    UninstallerPresent = Test-Path -LiteralPath $uninstaller
    RegistryPresent = [bool]$registry
    RegistryVersion = if ($registry) { $registry.DisplayVersion } else { $null }
    Health = $health
}
if ($health) {
    if ("$($health.version)" -ne "$($manifest.sidecarVersion)") {
        throw ("The installed engine reports $($health.version), but the " +
            "manifest says $($manifest.sidecarVersion).")
    }
}

$result | ConvertTo-Json -Depth 6

if ($StopAfter) {
    Get-Process net_builder, pt_autopilot -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $app -or $_.Path -eq $sidecar } |
        Stop-Process -Force
}
