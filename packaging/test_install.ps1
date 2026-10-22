[CmdletBinding()]
param(
    # Defaults to the payload produced by build_installer.ps1. A clean VM can
    # point this at a copied payload.zip without needing the source tree.
    [string]$Payload = '',
    [switch]$KeepInstalled
)

$ErrorActionPreference = 'Stop'
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Payload) {
    $Payload = Join-Path $AppRoot 'build\tester-installer\iexpress\payload.zip'
}
if (-not (Test-Path -LiteralPath $Payload -PathType Leaf)) {
    throw "Payload not found: $Payload. Run packaging\build_installer.ps1 first."
}

$installScript = Join-Path $PSScriptRoot 'installer_install.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify_installed.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("NetBuilderAI-clean-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$payloadCopy = Join-Path $tempRoot 'payload.zip'
Copy-Item -LiteralPath $Payload -Destination $payloadCopy -Force

function Stop-TestInstallProcesses {
    Get-Process net_builder, pt_autopilot -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Path -and $_.Path.StartsWith("$tempRoot\",
                [StringComparison]::OrdinalIgnoreCase)
        } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# verify_installed starts the app and its engine; a leftover listener would
# make that check pass against the wrong process.
$listeners = @(Get-NetTCPConnection -LocalPort 5005 -State Listen `
    -ErrorAction SilentlyContinue)
if ($listeners.Count -gt 0) {
    throw 'Port 5005 is already in use. Close NetBuilder AI before running the clean-install test.'
}

$failed = $false
try {
    Write-Host "Installing into $tempRoot (per-user, no shortcuts, no registry)..."
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $installScript -Payload $payloadCopy -InstallRoot $tempRoot `
        -NoLaunch -NoShortcuts -NoRegistry -Quiet
    if ($LASTEXITCODE -ne 0) {
        throw "installer_install.ps1 exited with $LASTEXITCODE."
    }

    $installInfoPath = Join-Path $tempRoot 'config\install.json'
    if (-not (Test-Path -LiteralPath $installInfoPath)) {
        throw 'install.json was not written.'
    }
    $installInfo = Get-Content -LiteralPath $installInfoPath -Raw |
        ConvertFrom-Json
    if ([int]$installInfo.schemaVersion -lt 2) {
        throw 'install.json is not the versioned schema (expected 2).'
    }
    foreach ($field in @('appVersion', 'sidecarVersion',
            'bundleManifestSha256')) {
        if (-not "$($installInfo.$field)".Trim()) {
            throw "install.json is missing $field."
        }
    }
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $tempRoot `
        'bundle-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifestHash -ne "$($installInfo.bundleManifestSha256)".ToLowerInvariant()) {
        throw 'install.json does not match bundle-manifest.json.'
    }

    Write-Host 'Verifying the installed files, engine and auto-start...'
    $verifyJson = & powershell.exe -NoLogo -NoProfile `
        -ExecutionPolicy Bypass -File $verifyScript -InstallRoot $tempRoot `
        -StopAfter
    if ($LASTEXITCODE -ne 0) {
        throw "verify_installed.ps1 exited with $LASTEXITCODE."
    }
    $verified = ($verifyJson -join "`n") | ConvertFrom-Json
    if (-not $verified.AppRunning) { throw 'The installed app did not start.' }
    if (-not $verified.SidecarAutoStarted) {
        throw 'The installed app did not start the bundled engine.'
    }
    if (-not $verified.Health.ok) { throw 'The installed engine is not healthy.' }
    if ("$($verified.Health.version)" -ne "$($installInfo.sidecarVersion)") {
        throw 'The engine version does not match install.json.'
    }
    if (-not $verified.UninstallerPresent) {
        throw 'The installed uninstaller is missing.'
    }

    # A default uninstall must keep the user's work while removing the app.
    # Write fixtures the way the app would, then check both halves.
    Write-Host 'Uninstalling without -Purge to check user data is kept...'
    $fixtures = @(
        'data\projects\kept.txt',
        'output\kept.pkt',
        'logs\kept.log',
        'config\kept-settings.json')
    foreach ($relative in $fixtures) {
        $path = Join-Path $tempRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force |
            Out-Null
        Set-Content -LiteralPath $path -Value 'fixture' -Encoding ASCII
    }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $tempRoot 'uninstall.ps1') -Quiet
    if ($LASTEXITCODE -ne 0) {
        throw "uninstall.ps1 exited with $LASTEXITCODE."
    }
    foreach ($binary in @('net_builder.exe', 'sidecar\pt_autopilot.exe')) {
        if (Test-Path -LiteralPath (Join-Path $tempRoot $binary)) {
            throw "The default uninstall left $binary in place."
        }
    }
    foreach ($relative in $fixtures) {
        if (-not (Test-Path -LiteralPath (Join-Path $tempRoot $relative))) {
            throw "The default uninstall removed $relative."
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'UNINSTALLED.txt'))) {
        throw 'The default uninstall did not write UNINSTALLED.txt.'
    }

    Write-Host 'Uninstalling with -Purge...'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $tempRoot 'uninstall.ps1') -Purge -Quiet
    if ($LASTEXITCODE -ne 0) {
        throw "uninstall.ps1 exited with $LASTEXITCODE."
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ((Test-Path -LiteralPath $tempRoot) -and
        [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path -LiteralPath $tempRoot) {
        throw 'The uninstaller did not remove the install folder.'
    }

    Write-Host 'Clean-install and uninstall tests passed.'
} catch {
    $failed = $true
    Stop-TestInstallProcesses
    Write-Error $_
    Write-Host "Leftover install folder: $tempRoot"
    throw
} finally {
    if (-not $failed -and -not $KeepInstalled -and
        (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
