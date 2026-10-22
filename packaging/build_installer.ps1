[CmdletBinding()]
param(
    [switch]$SkipFlutterBuild,

    # Optional Authenticode signing. Prefer passing the password through
    # NETBUILDER_SIGN_PASSWORD so it does not appear in the process list or a
    # shell history; the parameter exists for a local one-off.
    [string]$SignCertificatePath = '',
    [string]$SignCertificatePassword = '',
    [string]$SignCertificateThumbprint = '',
    [string]$TimestampUrl = 'http://timestamp.digicert.com',

    # A pilot installer must not silently ship unsigned. Local builds warn;
    # the release job passes this switch and fails instead.
    [switch]$RequireSignature
)

$ErrorActionPreference = 'Stop'
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$OutputRoot = Join-Path $AppRoot 'dist'
$WorkRoot = Join-Path $AppRoot 'build\tester-installer'
$StageRoot = Join-Path $WorkRoot 'payload'
$PyDistRoot = Join-Path $WorkRoot 'pyinstaller-dist'
$PyWorkRoot = Join-Path $WorkRoot 'pyinstaller-work'
$ExpressRoot = Join-Path $WorkRoot 'iexpress'
$ReleaseRoot = Join-Path $AppRoot 'build\windows\x64\runner\Release'
$InstallerPath = Join-Path $OutputRoot 'NetBuilderAI-Tester-Setup.exe'
$PortablePath = Join-Path $OutputRoot 'NetBuilderAI-Tester-Portable.zip'
$ReleaseManifestPath = Join-Path $OutputRoot 'release-manifest.json'
$ChecksumsPath = Join-Path $OutputRoot 'SHA256SUMS.txt'
$BundleManifestName = 'bundle-manifest.json'
$PyInstaller = (Get-Command python -ErrorAction Stop).Source

if (-not $SignCertificatePassword) {
    $SignCertificatePassword = $env:NETBUILDER_SIGN_PASSWORD
}
$SigningRequested = -not [string]::IsNullOrWhiteSpace($SignCertificatePath) -or
    -not [string]::IsNullOrWhiteSpace($SignCertificateThumbprint)

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Find-SignTool {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $roots = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $roots += Join-Path $base 'Windows Kits\10\bin' }
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -LiteralPath $root -Filter signtool.exe `
            -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Invoke-SignFile([string]$Path) {
    if (-not $SigningRequested) { return }
    if (-not $script:SignTool) {
        throw 'A signing certificate was supplied but signtool.exe was not found. Install the Windows SDK signing tools.'
    }
    $arguments = @('sign', '/fd', 'SHA256',
        '/tr', $TimestampUrl, '/td', 'SHA256')
    if ($SignCertificateThumbprint) {
        $arguments += @('/sha1', $SignCertificateThumbprint)
    } else {
        $arguments += @('/f', (Resolve-Path -LiteralPath $SignCertificatePath).Path)
        if ($SignCertificatePassword) {
            $arguments += @('/p', $SignCertificatePassword)
        }
    }
    $arguments += (Resolve-Path -LiteralPath $Path).Path
    & $script:SignTool @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed while signing $Path."
    }
    & $script:SignTool verify /pa /v $Path | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "signtool could not verify the signature on $Path."
    }
}

$script:SignTool = $null
if ($SigningRequested) {
    $script:SignTool = Find-SignTool
    if (-not $script:SignTool) {
        throw 'A signing certificate was supplied but signtool.exe was not found.'
    }
    Write-Host "Code signing: $script:SignTool"
} elseif ($RequireSignature) {
    throw 'RequireSignature was set, but no signing certificate path or thumbprint was supplied.'
} else {
    Write-Warning 'No code-signing certificate supplied. This build is unsigned; SmartScreen will warn pilot users.'
}

# Flutter stamps the Windows resource and the Android manifest from pubspec.
# The installer is just a wrapper around that release, so a disagreement here
# would ship a binary labelled with a version nobody can reproduce. Refuse it
# before spending time on PyInstaller and IExpress.
$PubspecText = Get-Content (Join-Path $AppRoot 'pubspec.yaml') -Raw
if ($PubspecText -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$') {
    throw 'pubspec.yaml is missing a semantic version line (x.y.z+build).'
}
$AppVersion = $Matches[1]
$ChangelogText = Get-Content (Join-Path $AppRoot 'lib\widgets\whats_new.dart') -Raw
$ChangelogMatch = [regex]::Match(
    $ChangelogText, "version:\s*'([^']+)'")
if (-not $ChangelogMatch.Success -or
    $ChangelogMatch.Groups[1].Value -ne $AppVersion) {
    throw "Changelog version does not match pubspec $AppVersion."
}

function Assert-WorkspacePath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside the app workspace: $resolved"
    }
}

function Reset-GeneratedDirectory([string]$Path) {
    Assert-WorkspacePath $Path
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
Reset-GeneratedDirectory $WorkRoot
New-Item -ItemType Directory -Path $StageRoot, $PyDistRoot, $PyWorkRoot,
    $ExpressRoot -Force | Out-Null

if (-not $SkipFlutterBuild) {
    Push-Location $AppRoot
    try {
        # A native tool writing a warning to stderr must not fail the build:
        # under ErrorActionPreference=Stop PowerShell turns that into a
        # terminating error. The exit code is the real signal, and it is
        # checked below.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & flutter build windows --release --no-pub
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows release build failed.' }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'net_builder.exe'))) {
    throw "Flutter release output not found: $ReleaseRoot"
}

$BuiltExe = Get-Item -LiteralPath (Join-Path $ReleaseRoot 'net_builder.exe')
$BuiltVersion = $BuiltExe.VersionInfo.ProductVersion
if ([string]::IsNullOrWhiteSpace($BuiltVersion) -or
    -not $BuiltVersion.StartsWith($AppVersion, [StringComparison]::Ordinal)) {
    throw "Built executable version '$BuiltVersion' does not match pubspec $AppVersion."
}
Write-Host "App version: $AppVersion (installer payload $BuiltVersion)"

$SidecarSource = Get-Content (Join-Path $AppRoot 'sidecar\pt_autopilot.py') -Raw
if ($SidecarSource -notmatch '(?m)^VERSION\s*=\s*"([^"]+)"') {
    throw 'sidecar/pt_autopilot.py is missing its VERSION line.'
}
$SidecarVersion = $Matches[1]

$SourceRevision = 'unknown'
$SourceDirty = $true
try {
    $revision = (& git -C $AppRoot rev-parse HEAD 2>$null)
    if ($revision) { $SourceRevision = $revision.Trim() }
    $porcelain = (& git -C $AppRoot status --porcelain 2>$null) -join "`n"
    $SourceDirty = -not [string]::IsNullOrWhiteSpace($porcelain)
} catch {
    # A source archive without .git still produces a usable tester package;
    # the manifest says the revision is unknown rather than inventing one.
}
Write-Host "Sidecar version: $SidecarVersion"
Write-Host "Source revision: $SourceRevision (dirty: $SourceDirty)"

# Sign the binaries before they are copied into the payload, so the portable
# ZIP and the installed copy carry the same signature as the release folder.
Invoke-SignFile (Join-Path $ReleaseRoot 'net_builder.exe')

Write-Host 'Building the bundled sidecar executable...'
Push-Location $AppRoot
try {
    # Same reason as the Flutter call: PyInstaller prints deprecation notes on
    # stderr, and those are not build failures.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $PyInstaller -m pip install --disable-pip-version-check --quiet pyinstaller
        if ($LASTEXITCODE -ne 0) { throw 'Could not install PyInstaller.' }
        & $PyInstaller -m PyInstaller --noconfirm --clean --onedir --noconsole `
            --name pt_autopilot --distpath $PyDistRoot --workpath $PyWorkRoot `
            --specpath $WorkRoot (Join-Path $AppRoot 'sidecar\pt_autopilot.py')
        if ($LASTEXITCODE -ne 0) { throw 'PyInstaller sidecar build failed.' }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
} finally {
    Pop-Location
}

$BuiltSidecar = Join-Path $PyDistRoot 'pt_autopilot'
if (-not (Test-Path -LiteralPath (Join-Path $BuiltSidecar 'pt_autopilot.exe'))) {
    throw "Bundled sidecar executable not found: $BuiltSidecar"
}
Invoke-SignFile (Join-Path $BuiltSidecar 'pt_autopilot.exe')

# The .pkt generator is useless without its template library, and the frozen
# sidecar looks for it inside its own _internal folder. Shipping it here is
# what makes 'build a .pkt' work on a machine that has never seen one; the
# sample saves are what let the app rebuild the library if it is ever missing.
$BuiltInternal = Join-Path $BuiltSidecar '_internal'
New-Item -ItemType Directory -Path $BuiltInternal -Force | Out-Null
foreach ($Name in @('pkt_templates', 'pkt_seed')) {
    $Source = Join-Path $AppRoot "sidecar\$Name"
    if (Test-Path -LiteralPath $Source) {
        Copy-Item -Path $Source -Destination $BuiltInternal -Recurse -Force
        Write-Host "Bundled sidecar\$Name"
    } else {
        Write-Warning "sidecar\$Name is missing; the installed app may not be able to build a .pkt."
    }
}

# Keep the unpacked Windows release self-contained too.  Previously only the
# installer payload received the freshly built sidecar, so launching
# build\windows\x64\runner\Release\net_builder.exe directly could still
# start an older sidecar and appear unchanged.
$ReleaseSidecar = Join-Path $ReleaseRoot 'sidecar'
New-Item -ItemType Directory -Path $ReleaseSidecar -Force | Out-Null
Copy-Item -Path (Join-Path $BuiltSidecar '*') -Destination $ReleaseSidecar -Recurse -Force
Copy-Item -LiteralPath (Join-Path $AppRoot 'sidecar\stop_sidecar.bat') `
    -Destination $ReleaseSidecar -Force

Copy-Item -Path (Join-Path $ReleaseRoot '*') -Destination $StageRoot -Recurse -Force
$StageSidecar = Join-Path $StageRoot 'sidecar'
New-Item -ItemType Directory -Path $StageSidecar -Force | Out-Null
Copy-Item -Path (Join-Path $BuiltSidecar '*') -Destination $StageSidecar -Recurse -Force
Copy-Item -LiteralPath (Join-Path $AppRoot 'sidecar\stop_sidecar.bat') `
    -Destination $StageSidecar -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README-TESTER.txt') `
    -Destination (Join-Path $StageRoot 'README-TESTER.txt') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README-PORTABLE.txt') `
    -Destination (Join-Path $StageRoot 'README-PORTABLE.txt') -Force
# The uninstaller is part of the payload, not the IExpress wrapper, so it is
# present in both the installed copy and the portable ZIP.
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer_uninstall.ps1') `
    -Destination (Join-Path $StageRoot 'uninstall.ps1') -Force

$TesseractSource = 'C:\Program Files\Tesseract-OCR'
$TesseractTarget = Join-Path $StageRoot 'tesseract'
if (Test-Path -LiteralPath (Join-Path $TesseractSource 'tesseract.exe')) {
    New-Item -ItemType Directory -Path $TesseractTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $TesseractSource '*') -Destination $TesseractTarget `
        -Recurse -Force
} else {
    Write-Warning 'Tesseract was not found; OCR will require a tester-installed copy.'
}

# The bundle manifest is the handshake a support engineer can check without
# trusting the installer UI: app version, engine version, source revision and
# the hashes of every shipped executable/template plus the app's own AOT code
# (data/app.so) and core runtime DLLs. It is written after all signing and
# assembly, so a later edit cannot leave a stale hash behind.
$ManifestFiles = [ordered]@{}
foreach ($Relative in @(
        'net_builder.exe',
        'data\app.so',
        'data\icudtl.dat',
        'flutter_windows.dll',
        'sqlite3.dll',
        'dartjni.dll',
        'flutter_secure_storage_windows_plugin.dll',
        'native_assets.json',
        'sidecar\pt_autopilot.exe',
        'sidecar\_internal\pkt_templates\manifest.json',
        'tesseract\tesseract.exe',
        'README-TESTER.txt',
        'README-PORTABLE.txt',
        'uninstall.ps1')) {
    $Full = Join-Path $StageRoot $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { continue }
    $ManifestFiles[$Relative.Replace('\', '/')] = [ordered]@{
        sha256 = Get-Sha256 $Full
        bytes  = (Get-Item -LiteralPath $Full).Length
    }
}
$BundleManifest = [ordered]@{
    schemaVersion   = 1
    app             = 'NetBuilder AI'
    appVersion      = $AppVersion
    sidecarVersion  = $SidecarVersion
    sourceRevision  = $SourceRevision
    sourceDirty     = $SourceDirty
    builtAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
    signed          = [bool]$SigningRequested
    files           = $ManifestFiles
}
$BundleManifestPath = Join-Path $StageRoot $BundleManifestName
$BundleManifest |
    ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $BundleManifestPath -Encoding UTF8
Write-Host "Bundle manifest: $BundleManifestPath"

$PayloadZip = Join-Path $ExpressRoot 'payload.zip'
Compress-Archive -Path (Join-Path $StageRoot '*') -DestinationPath $PayloadZip -Force

# A portable ZIP is the no-admin fallback when SmartScreen or a managed
# machine blocks the installer. It is the same staged payload, so the
# manifest, uninstaller and README travel with it.
if (Test-Path -LiteralPath $PortablePath) {
    Remove-Item -LiteralPath $PortablePath -Force
}
Compress-Archive -Path (Join-Path $StageRoot '*') -DestinationPath $PortablePath -Force
Write-Host "Portable ZIP: $PortablePath"
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer_install.vbs') `
    -Destination (Join-Path $ExpressRoot 'installer_install.vbs') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer_install.ps1') `
    -Destination (Join-Path $ExpressRoot 'installer_install.ps1') -Force

$SedPath = Join-Path $ExpressRoot 'installer.sed'
# Keep FinishMessage empty. A non-empty IExpress finish message opens a dialog
# after the app launches, so the wrapper process stays alive and a scripted
# install looks hung.
$Sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=$InstallerPath
FriendlyName=NetBuilder AI Tester
AppLaunched=wscript.exe //B //NoLogo installer_install.vbs
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
FILE0=payload.zip
FILE1=installer_install.vbs
FILE2=installer_install.ps1
[SourceFiles]
SourceFiles0=$ExpressRoot
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
"@
Set-Content -LiteralPath $SedPath -Value $Sed -Encoding ASCII

# Do not mistake an older artifact for the result of this build.
if (Test-Path -LiteralPath $InstallerPath) {
    Remove-Item -LiteralPath $InstallerPath -Force
}

$iexpress = Start-Process -FilePath 'iexpress.exe' `
    -ArgumentList @('/N', $SedPath) -Wait -PassThru
if ($iexpress.ExitCode -ne 0) { throw 'IExpress installer build failed.' }

# IExpress launches CAB compression asynchronously on some Windows builds.
# Wait for the final self-extracting executable instead of treating the
# temporary DDF/CAB files as completion.
$deadline = [DateTime]::UtcNow.AddMinutes(10)
while (-not (Test-Path -LiteralPath $InstallerPath) -and
       [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 2
}
if (-not (Test-Path -LiteralPath $InstallerPath)) {
    throw "Installer was not created: $InstallerPath"
}

# Sign the wrapper after IExpress has finished writing it. Signing before the
# final write would be discarded by CAB compression on some Windows builds.
Invoke-SignFile $InstallerPath

$BundleManifestCopy = Join-Path $OutputRoot $BundleManifestName
Copy-Item -LiteralPath $BundleManifestPath -Destination $BundleManifestCopy -Force
$BundleManifestSha = Get-Sha256 $BundleManifestCopy
$Artifacts = @(
    [ordered]@{
        name = 'NetBuilderAI-Tester-Setup.exe'
        path = $InstallerPath
        sha256 = Get-Sha256 $InstallerPath
        bytes = (Get-Item -LiteralPath $InstallerPath).Length
    },
    [ordered]@{
        name = 'NetBuilderAI-Tester-Portable.zip'
        path = $PortablePath
        sha256 = Get-Sha256 $PortablePath
        bytes = (Get-Item -LiteralPath $PortablePath).Length
    }
)
$ReleaseManifest = [ordered]@{
    schemaVersion = 1
    app = 'NetBuilder AI'
    appVersion = $AppVersion
    sidecarVersion = $SidecarVersion
    sourceRevision = $SourceRevision
    sourceDirty = $SourceDirty
    builtAtUtc = $BundleManifest.builtAtUtc
    signed = [bool]$SigningRequested
    bundleManifestSha256 = $BundleManifestSha
    artifacts = @($Artifacts | ForEach-Object {
            [ordered]@{
                name = $_.name
                sha256 = $_.sha256
                bytes = $_.bytes
            }
        })
}
$ReleaseManifest |
    ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $ReleaseManifestPath -Encoding UTF8

$Checksums = @(
    "$($Artifacts[0].sha256)  NetBuilderAI-Tester-Setup.exe",
    "$($Artifacts[1].sha256)  NetBuilderAI-Tester-Portable.zip",
    "$BundleManifestSha  $BundleManifestName",
    "$(Get-Sha256 $ReleaseManifestPath)  release-manifest.json"
)
$Checksums | Set-Content -LiteralPath $ChecksumsPath -Encoding ASCII

$zip = Get-Item -LiteralPath $PayloadZip
$installer = Get-Item -LiteralPath $InstallerPath
Write-Host "Payload:   $([math]::Round($zip.Length / 1MB, 1)) MB"
Write-Host "Installer: $($installer.FullName)"
Write-Host "Size:      $([math]::Round($installer.Length / 1MB, 1)) MB"
Write-Host "Portable:  $PortablePath"
Write-Host "Manifest:  $ReleaseManifestPath"
Write-Host "Checksums: $ChecksumsPath"
