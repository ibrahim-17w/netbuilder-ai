[CmdletBinding()]
param(
    # Remove saved projects, logs, caches and settings as well as the app.
    [switch]$Purge,
    [switch]$Quiet,
    [string]$InstallRoot = ''
)

$ErrorActionPreference = 'Stop'

function Get-SafeInstallRoot([string]$Path) {
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $root = ([IO.Path]::GetPathRoot($full)).TrimEnd('\')
    # -Purge hands this path to a detached delete. A typo or a test override
    # must not be able to turn that into "delete the drive".
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root -or
        $full.Length -lt 3) {
        throw "Refusing unsafe uninstall root: $Path"
    }
    return $full
}

$target = if ($InstallRoot.Trim()) {
    Get-SafeInstallRoot $InstallRoot
} else {
    Get-SafeInstallRoot $PSScriptRoot
}
$logPath = Join-Path $env:TEMP 'NetBuilderAI-uninstall.log'

function Write-UninstallLog([string]$Message) {
    Add-Content -LiteralPath $logPath -Value ("{0:u} {1}" -f (Get-Date), $Message)
}

function Get-TargetProcesses {
    $matches = @()
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        $processPath = $null
        try { $processPath = $process.Path } catch { }
        if ($processPath -and
            $processPath.StartsWith("$target\", [StringComparison]::OrdinalIgnoreCase)) {
            $matches += $process
        }
    }
    return $matches
}

try {
    Write-UninstallLog "Starting uninstall from $target (Purge=$Purge)"
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "The NetBuilder AI folder was not found: $target"
    }

    # Stop only processes running from this install, never an unrelated app
    # with the same executable name.
    foreach ($process in @(Get-TargetProcesses)) {
        Write-UninstallLog "Stopping PID $($process.Id): $($process.Path)"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500

    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $start = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    foreach ($shortcut in @(
            (Join-Path $desktop 'NetBuilder AI.lnk'),
            (Join-Path $start 'NetBuilder AI.lnk'),
            (Join-Path $start 'Uninstall NetBuilder AI.lnk'))) {
        if (Test-Path -LiteralPath $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force
            Write-UninstallLog "Removed shortcut $shortcut"
        }
    }

    $registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NetBuilderAI'
    if (Test-Path -LiteralPath $registry) {
        Remove-Item -LiteralPath $registry -Recurse -Force
        Write-UninstallLog 'Removed the per-user uninstall entry.'
    }

    if ($Purge) {
        # A running script cannot delete the folder that contains it. Hand the
        # final removal to a detached process after this one exits.
        $escaped = $target.Replace("'", "''")
        $cleanup = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$escaped' -Recurse -Force -ErrorAction SilentlyContinue"
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($cleanup))
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
            -ArgumentList @('-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden',
                '-EncodedCommand', $encoded) | Out-Null
        Write-UninstallLog 'Scheduled removal of the install folder.'
    } else {
        # Keep the user's work. Remove the binaries and bundled runtime but
        # leave data, output, logs and config in place with a note.
        $keep = @('data', 'output', 'logs', 'config', 'uninstall.ps1',
            'uninstall.cmd')
        foreach ($item in (Get-ChildItem -LiteralPath $target -Force)) {
            if ($keep -contains $item.Name) { continue }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
        @"
NetBuilder AI was uninstalled.
Your saved projects, logs and settings were kept in this folder:
$target

Delete the folder when you no longer need them.
"@ | Set-Content -LiteralPath (Join-Path $target 'UNINSTALLED.txt') `
            -Encoding UTF8
        Write-UninstallLog 'Removed app files and kept user data.'
    }

    if (-not $Quiet) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show(
                'NetBuilder AI was uninstalled.',
                'NetBuilder AI',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
        } catch { }
    }
    exit 0
} catch {
    Write-UninstallLog "UNINSTALL FAILED: $($_.Exception.Message)"
    if (-not $Quiet) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show(
                "NetBuilder AI could not be uninstalled.`n`n$($_.Exception.Message)`n`nLog: $logPath",
                'NetBuilder AI uninstaller',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        } catch { }
    }
    exit 1
}
