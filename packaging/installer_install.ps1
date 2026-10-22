[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Payload,

    # Defaults to the per-user location. The override exists for the isolated
    # clean-install test; the shipped installer always uses LocalAppData and
    # never asks for administrator rights.
    [string]$InstallRoot = '',
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [switch]$NoRegistry,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Get-SafeInstallRoot([string]$Path) {
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $root = ([IO.Path]::GetPathRoot($full)).TrimEnd('\')
    # A test override must never turn an install or a -Purge uninstall into a
    # drive-root or UNC-share delete. The production path is always deeper.
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root -or
        $full.Length -lt 3) {
        throw "Refusing unsafe install root: $Path"
    }
    return $full
}

$target = if ($InstallRoot.Trim()) {
    Get-SafeInstallRoot $InstallRoot
} else {
    Get-SafeInstallRoot (Join-Path $env:LOCALAPPDATA 'NetBuilderAI')
}
$targetRoot = "$target\"
$appPath = Join-Path $target 'net_builder.exe'
$logPath = Join-Path $env:TEMP 'NetBuilderAI-installer.log'

function Write-InstallLog([string]$Message) {
    Add-Content -LiteralPath $logPath -Value ("{0:u} {1}" -f (Get-Date), $Message)
}

function Get-TargetProcesses {
    $matches = @()
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        $processPath = $null
        try { $processPath = $process.Path } catch { }
        if ($processPath -and $processPath.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $matches += $process
        }
    }
    return $matches
}

try {
    if (-not (Test-Path -LiteralPath $Payload -PathType Leaf)) {
        throw "The application payload was not found: $Payload"
    }

    Write-InstallLog "Starting installation from $Payload"

    # Stop only processes running from this application's install directory.
    # This avoids killing unrelated applications with similar process names.
    $running = @(Get-TargetProcesses)
    foreach ($process in $running) {
        Write-InstallLog "Stopping PID $($process.Id): $($process.Path)"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $remaining = @(Get-TargetProcesses)
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        $paths = ($remaining | ForEach-Object { $_.Path }) -join ', '
        throw "NetBuilder AI is still running and its files are locked: $paths"
    }

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Expand-Archive -LiteralPath $Payload -DestinationPath $target -Force

    if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        throw "Extraction finished but net_builder.exe was not found."
    }

    # The bundle manifest is the version handshake. Refuse to install a
    # payload whose executable or engine does not match the hashes recorded
    # when the package was assembled; that is the difference between a broken
    # download and a mystery bug reported weeks later.
    $manifestPath = Join-Path $target 'bundle-manifest.json'
    $manifest = $null
    $bundleManifestSha = ''
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw |
                ConvertFrom-Json
        } catch {
            throw "bundle-manifest.json is unreadable: $($_.Exception.Message)"
        }
        $bundleManifestSha = (Get-FileHash -LiteralPath $manifestPath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestAppVersion = "$($manifest.appVersion)".Trim()
        $exeVersion = (Get-Item -LiteralPath $appPath).VersionInfo.ProductVersion
        if ($manifestAppVersion -and $exeVersion -and
            -not $exeVersion.StartsWith($manifestAppVersion,
                [StringComparison]::Ordinal)) {
            throw ("The payload manifest names app $manifestAppVersion, but " +
                "net_builder.exe reports $exeVersion.")
        }
        if ($manifest.files) {
            foreach ($entry in $manifest.files.PSObject.Properties) {
                $relative = $entry.Name.Replace('/', '\')
                $candidate = Join-Path $target $relative
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    throw "The payload is incomplete: $relative is missing."
                }
                $actual = (Get-FileHash -LiteralPath $candidate `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
                $expected = "$($entry.Value.sha256)".ToLowerInvariant()
                if ($actual -ne $expected) {
                    throw "The payload is corrupt: $relative has the wrong SHA256."
                }
            }
        }
        Write-InstallLog ("Bundle manifest matched: app $manifestAppVersion, " +
            "engine $($manifest.sidecarVersion).")
    } else {
        Write-InstallLog 'No bundle-manifest.json; this is an older payload.'
    }

    # Everything the app writes lives beside the install, so a recipient never
    # has to pick a folder or edit a path. Creating them here is what makes the
    # app work on first run without any manual setting.
    $dataRoot = Join-Path $target 'data'
    $folders = [ordered]@{
        config = Join-Path $target 'config'
        output = Join-Path $target 'output'
        logs   = Join-Path $target 'logs'
        cache  = Join-Path $target 'cache'
        data   = $dataRoot
    }
    foreach ($folder in $folders.Values) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    # The uninstaller travels in the payload. Copy its command wrapper here
    # so the Start Menu and the HKCU uninstall entry have one stable target.
    $uninstaller = Join-Path $target 'uninstall.ps1'
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        throw 'The payload is incomplete: uninstall.ps1 is missing.'
    }
    $uninstallCmd = Join-Path $target 'uninstall.cmd'
    $uninstallCmdText = "@echo off`r`n" +
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ' +
        '-File "%~dp0uninstall.ps1" %*' + "`r`n"
    [IO.File]::WriteAllText($uninstallCmd, $uninstallCmdText,
        [Text.Encoding]::ASCII)

    # The app reads this on start and adopts these paths as its defaults.
    # Written fresh on every install, so a moved or renamed install can never
    # leave the app pointing at a folder that is gone.
    $installedAppVersion = (Get-Item -LiteralPath $appPath).VersionInfo.ProductVersion
    $installInfo = [ordered]@{
        schemaVersion        = 2
        installedAt          = (Get-Date).ToString('o')
        installRoot          = $target
        appVersion           = $installedAppVersion
        sidecarVersion       = if ($manifest) { "$($manifest.sidecarVersion)" } else { '' }
        sourceRevision       = if ($manifest) { "$($manifest.sourceRevision)" } else { '' }
        bundleManifestSha256 = $bundleManifestSha
        outputDir            = $folders.output
        logsDir              = $folders.logs
        cacheDir             = $folders.cache
        dataDir              = $folders.data
        engineBase           = 'http://127.0.0.1:5005'
    }
    $installInfo |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $folders.config 'install.json') `
            -Encoding UTF8
    Write-InstallLog ("Created config, output, logs, cache and data folders " +
        "under $target.")

    if (-not $NoShortcuts) {
        $shell = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath('Desktop')
        $start = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        New-Item -ItemType Directory -Force -Path $start | Out-Null
        foreach ($folder in @($desktop, $start)) {
            $shortcut = Join-Path $folder 'NetBuilder AI.lnk'
            $link = $shell.CreateShortcut($shortcut)
            $link.TargetPath = $appPath
            $link.WorkingDirectory = $target
            $link.Description = 'NetBuilder AI - local network lab builder'
            $link.Save()
        }
        $uninstallShortcut = Join-Path $start 'Uninstall NetBuilder AI.lnk'
        $uninstallLink = $shell.CreateShortcut($uninstallShortcut)
        $uninstallLink.TargetPath = Join-Path $env:SystemRoot `
            'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uninstallLink.Arguments = (
            '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' +
            $uninstaller + '"')
        $uninstallLink.WorkingDirectory = $target
        $uninstallLink.Description = 'Remove NetBuilder AI'
        $uninstallLink.Save()
    }

    if (-not $NoRegistry) {
        $registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NetBuilderAI'
        New-Item -Path $registry -Force | Out-Null
        $sizeKb = [int](((Get-ChildItem -LiteralPath $target -Recurse -File |
            Measure-Object -Property Length -Sum).Sum) / 1KB)
        $displayVersion = if ($installedAppVersion) {
            $installedAppVersion
        } elseif ($manifest) {
            "$($manifest.appVersion)"
        } else {
            'unknown'
        }
        Set-ItemProperty -Path $registry -Name DisplayName `
            -Value 'NetBuilder AI'
        Set-ItemProperty -Path $registry -Name DisplayVersion `
            -Value $displayVersion
        Set-ItemProperty -Path $registry -Name Publisher `
            -Value 'NetBuilder AI'
        Set-ItemProperty -Path $registry -Name InstallLocation `
            -Value $target
        Set-ItemProperty -Path $registry -Name DisplayIcon `
            -Value "$appPath,0"
        Set-ItemProperty -Path $registry -Name UninstallString `
            -Value "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$uninstaller`""
        Set-ItemProperty -Path $registry -Name QuietUninstallString `
            -Value "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$uninstaller`" -Quiet"
        Set-ItemProperty -Path $registry -Name EstimatedSize -Value $sizeKb
        Set-ItemProperty -Path $registry -Name NoModify -Value 1
        Set-ItemProperty -Path $registry -Name NoRepair -Value 1
    }

    Write-InstallLog "Extraction, shortcuts and uninstall entry completed."
    if (-not $NoLaunch) {
        Start-Process -FilePath $appPath -WorkingDirectory $target
        Write-InstallLog "Application launched successfully."
    } else {
        Write-InstallLog 'Application launch skipped by request.'
    }
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-InstallLog "INSTALL FAILED: $message"
    if (-not $Quiet) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show(
                "NetBuilder AI could not be installed.`n`n$message`n`nLog: $logPath",
                'NetBuilder AI installer',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        } catch { }
    }
    exit 1
}
