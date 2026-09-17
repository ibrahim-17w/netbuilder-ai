[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Payload
)

$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'NetBuilderAI'
$targetRoot = ([IO.Path]::GetFullPath($target)).TrimEnd('\') + '\'
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

    Write-InstallLog "Extraction and shortcuts completed successfully."
    Start-Process -FilePath $appPath -WorkingDirectory $target
    Write-InstallLog "Application launched successfully."
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-InstallLog "INSTALL FAILED: $message"
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            "NetBuilder AI could not be installed.`n`n$message`n`nLog: $logPath",
            'NetBuilder AI installer',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch { }
    exit 1
}
