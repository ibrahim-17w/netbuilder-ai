[CmdletBinding()]
param(
    [string]$InstallerPath = '',
    # Leave the installed app running after the check (the default). Use this
    # in a throwaway VM; the script never uninstalls, so a tester can inspect it.
    [switch]$StopAfter
)

$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'NetBuilderAI'
$app = Join-Path $target 'net_builder.exe'
$sidecar = Join-Path $target 'sidecar\pt_autopilot.exe'
$installInfoPath = Join-Path $target 'config\install.json'
$manifestPath = Join-Path $target 'bundle-manifest.json'
$uninstaller = Join-Path $target 'uninstall.ps1'
if (-not $InstallerPath) {
    $InstallerPath = Join-Path $PSScriptRoot '..\dist\NetBuilderAI-Tester-Setup.exe'
}
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path

Get-Process net_builder, pt_autopilot -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $app -or $_.Path -eq $sidecar } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Host "Running the actual installer wrapper: $installer"
# Start-Process -Wait follows the whole process tree, and this wrapper launches
# the app, which stays open. Wait for the installer process itself instead.
$installProcess = Start-Process -FilePath $installer -PassThru
$installerDeadline = [DateTime]::UtcNow.AddMinutes(3)
while (-not $installProcess.HasExited -and
    [DateTime]::UtcNow -lt $installerDeadline) {
    Start-Sleep -Milliseconds 500
}
if (-not $installProcess.HasExited) {
    throw 'The installer wrapper did not exit within three minutes.'
}
if ($installProcess.ExitCode -ne 0) {
    throw "The installer wrapper exited with $($installProcess.ExitCode)."
}

# IExpress launches the PowerShell installer asynchronously through a VBS
# shim, so the wrapper can exit before install.json is written.
$deadline = [DateTime]::UtcNow.AddMinutes(2)
while (-not (Test-Path -LiteralPath $installInfoPath) -and
    [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
}
if (-not (Test-Path -LiteralPath $installInfoPath)) {
    throw 'The installer did not write config\install.json within two minutes.'
}

$installInfo = Get-Content -LiteralPath $installInfoPath -Raw | ConvertFrom-Json
if ([int]$installInfo.schemaVersion -lt 2) {
    throw 'The installed metadata is not schema 2.'
}
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).
    Hash.ToLowerInvariant()
if ("$($installInfo.bundleManifestSha256)".ToLowerInvariant() -ne
    $manifestHash) {
    throw 'The installed metadata does not match the bundle manifest.'
}

# Let the installer's own app launch settle before the verifier closes it and
# starts the packaged app itself.
Start-Sleep -Seconds 3
Write-Host 'Checking files, hash manifest, auto-start engine and uninstall entry...'
$verifyJson = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'verify_installed.ps1') -InstallRoot $target
if ($LASTEXITCODE -ne 0) {
    throw "verify_installed.ps1 exited with $LASTEXITCODE."
}
$verified = ($verifyJson -join "`n") | ConvertFrom-Json
if (-not $verified.AppRunning) { throw 'The installed app did not start.' }
if (-not $verified.SidecarAutoStarted) {
    throw 'The installed app did not start its bundled engine.'
}
if (-not $verified.UninstallerPresent) {
    throw 'The uninstaller is missing from the installed folder.'
}
if (-not $verified.RegistryPresent) {
    throw 'The per-user uninstall entry is missing.'
}
if ("$($verified.Health.version)" -ne "$($installInfo.sidecarVersion)") {
    throw 'The engine version does not match install.json.'
}

if ($StopAfter) {
    Get-Process net_builder, pt_autopilot -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $app -or $_.Path -eq $sidecar } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    InstallerExitCode = $installProcess.ExitCode
    InstallRoot = $target
    SchemaVersion = $installInfo.schemaVersion
    AppVersion = $installInfo.appVersion
    EngineVersion = $installInfo.sidecarVersion
    SourceRevision = $installInfo.sourceRevision
    BundleManifestSha256 = $manifestHash
    InstalledApp = Test-Path -LiteralPath $app
    InstalledSidecar = Test-Path -LiteralPath $sidecar
    AppRunning = [bool](Get-Process net_builder -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $app })
    SidecarRunning = [bool](Get-Process pt_autopilot -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $sidecar })
    Health = $verified.Health
} | ConvertTo-Json -Depth 5
