[CmdletBinding()]
param(
    [switch]$SkipFlutterBuild
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
$PyInstaller = (Get-Command python -ErrorAction Stop).Source

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

$TesseractSource = 'C:\Program Files\Tesseract-OCR'
$TesseractTarget = Join-Path $StageRoot 'tesseract'
if (Test-Path -LiteralPath (Join-Path $TesseractSource 'tesseract.exe')) {
    New-Item -ItemType Directory -Path $TesseractTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $TesseractSource '*') -Destination $TesseractTarget `
        -Recurse -Force
} else {
    Write-Warning 'Tesseract was not found; OCR will require a tester-installed copy.'
}

$PayloadZip = Join-Path $ExpressRoot 'payload.zip'
Compress-Archive -Path (Join-Path $StageRoot '*') -DestinationPath $PayloadZip -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer_install.vbs') `
    -Destination (Join-Path $ExpressRoot 'installer_install.vbs') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer_install.ps1') `
    -Destination (Join-Path $ExpressRoot 'installer_install.ps1') -Force

$SedPath = Join-Path $ExpressRoot 'installer.sed'
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
FinishMessage=NetBuilder AI was installed. The app will now open.
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

$zip = Get-Item -LiteralPath $PayloadZip
$installer = Get-Item -LiteralPath $InstallerPath
Write-Host "Payload:   $([math]::Round($zip.Length / 1MB, 1)) MB"
Write-Host "Installer: $($installer.FullName)"
Write-Host "Size:      $([math]::Round($installer.Length / 1MB, 1)) MB"
