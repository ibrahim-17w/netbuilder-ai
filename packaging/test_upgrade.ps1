[CmdletBinding()]
param(
    # Both default to the payload produced by build_installer.ps1. To exercise
    # a real old-to-new upgrade, pass the old payload explicitly.
    [string]$OldPayload = '',
    [string]$NewPayload = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workPayload = Join-Path $AppRoot 'build\tester-installer\iexpress\payload.zip'
if (-not $OldPayload) { $OldPayload = $workPayload }
if (-not $NewPayload) { $NewPayload = $workPayload }
foreach ($payload in @($OldPayload, $NewPayload)) {
    if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
        throw "Payload not found: $payload. Run packaging\build_installer.ps1 first."
    }
}

$installScript = Join-Path $PSScriptRoot 'installer_install.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify_installed.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("NetBuilderAI-upgrade-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
$payloadDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("NetBuilderAI-payloads-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $tempRoot, $payloadDir -Force | Out-Null
$oldCopy = Join-Path $payloadDir 'old.zip'
$newCopy = Join-Path $payloadDir 'new.zip'
Copy-Item -LiteralPath $OldPayload -Destination $oldCopy -Force
Copy-Item -LiteralPath $NewPayload -Destination $newCopy -Force

function Install-Payload([string]$Path) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $installScript -Payload $Path -InstallRoot $tempRoot `
        -NoLaunch -NoShortcuts -NoRegistry -Quiet
    if ($LASTEXITCODE -ne 0) {
        throw "installer_install.ps1 exited with $LASTEXITCODE."
    }
}

function Stop-TestInstallProcesses {
    Get-Process net_builder, pt_autopilot -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Path -and $_.Path.StartsWith("$tempRoot\",
                [StringComparison]::OrdinalIgnoreCase)
        } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

$failed = $false
try {
    $listeners = @(Get-NetTCPConnection -LocalPort 5005 -State Listen `
        -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        throw 'Port 5005 is already in use. Close NetBuilder AI first.'
    }

    Write-Host 'Installing the old payload and creating synthetic user data...'
    Install-Payload $oldCopy
    $fixtures = [ordered]@{
        'data\history\fixture.json' = '{"version":1,"name":"keep-me"}'
        'data\memory.json' = '{"learned":["vlan 20"]}'
        'output\fixture.pkt' = 'not-a-real-pkt-but-must-survive'
        'logs\fixture.log' = 'old log line'
        'config\user-settings.json' = '{"theme":"dark"}'
    }
    foreach ($relative in $fixtures.Keys) {
        $full = Join-Path $tempRoot $relative
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $fixtures[$relative] -Encoding UTF8
    }
    $before = @{}
    foreach ($relative in $fixtures.Keys) {
        $before[$relative] = (Get-FileHash -LiteralPath (Join-Path $tempRoot `
            $relative) -Algorithm SHA256).Hash
    }

    Write-Host 'Installing the new payload over it...'
    Install-Payload $newCopy
    foreach ($relative in $fixtures.Keys) {
        $full = Join-Path $tempRoot $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Upgrade removed user data: $relative"
        }
        $after = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if ($after -ne $before[$relative]) {
            throw "Upgrade changed user data: $relative"
        }
    }

    $installInfo = Get-Content -LiteralPath (Join-Path $tempRoot `
        'config\install.json') -Raw | ConvertFrom-Json
    if ([int]$installInfo.schemaVersion -lt 2) {
        throw 'The upgraded install.json is not schema 2.'
    }
    if (-not "$($installInfo.appVersion)".Trim()) {
        throw 'The upgraded install.json has no appVersion.'
    }

    Write-Host 'Verifying the upgraded app and engine...'
    $verifyJson = & powershell.exe -NoLogo -NoProfile `
        -ExecutionPolicy Bypass -File $verifyScript -InstallRoot $tempRoot `
        -StopAfter
    if ($LASTEXITCODE -ne 0) {
        throw "verify_installed.ps1 exited with $LASTEXITCODE."
    }
    $verified = ($verifyJson -join "`n") | ConvertFrom-Json
    if (-not $verified.AppRunning -or -not $verified.SidecarAutoStarted) {
        throw 'The upgraded app or engine did not start.'
    }
    if (-not $verified.Health.ok) {
        throw 'The upgraded engine is not healthy.'
    }
    if ("$($verified.Health.version)" -ne "$($installInfo.sidecarVersion)") {
        throw 'The upgraded engine version does not match install.json.'
    }

    Write-Host 'Upgrade test passed; user fixtures survived.'
} catch {
    $failed = $true
    Stop-TestInstallProcesses
    Write-Error $_
    Write-Host "Leftover install folder: $tempRoot"
    throw
} finally {
    if (-not $failed -and (Test-Path -LiteralPath $tempRoot)) {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $tempRoot 'uninstall.ps1') -Purge -Quiet
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ((Test-Path -LiteralPath $tempRoot) -and
            [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
    }
    if (Test-Path -LiteralPath $payloadDir) {
        Remove-Item -LiteralPath $payloadDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
