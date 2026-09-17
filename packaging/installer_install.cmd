@echo off
setlocal

set "TARGET=%LOCALAPPDATA%\NetBuilderAI"
set "PAYLOAD=%~dp0payload.zip"

if not exist "%PAYLOAD%" (
  echo NetBuilder AI payload is missing.
  exit /b 1
)

set "NETBUILDER_PAYLOAD=%PAYLOAD%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$target = Join-Path $env:LOCALAPPDATA 'NetBuilderAI'; New-Item -ItemType Directory -Force -Path $target | Out-Null; Expand-Archive -LiteralPath $env:NETBUILDER_PAYLOAD -DestinationPath $target -Force; $shell = New-Object -ComObject WScript.Shell; $desktop = [Environment]::GetFolderPath('Desktop'); $start = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'; New-Item -ItemType Directory -Force -Path $start | Out-Null; foreach ($folder in @($desktop, $start)) { $shortcut = Join-Path $folder 'NetBuilder AI.lnk'; $link = $shell.CreateShortcut($shortcut); $link.TargetPath = (Join-Path $target 'net_builder.exe'); $link.WorkingDirectory = $target; $link.Description = 'NetBuilder AI - local network lab builder'; $link.Save() }; Start-Process -FilePath (Join-Path $target 'net_builder.exe') -WorkingDirectory $target"

if errorlevel 1 (
  echo Installation failed while extracting the application.
  exit /b 1
)

if not exist "%TARGET%\net_builder.exe" (
  echo Installation finished but net_builder.exe was not found.
  exit /b 1
)

exit /b 0
