@echo off
setlocal

set "PAYLOAD=%~dp0payload.zip"

if not exist "%PAYLOAD%" (
  echo NetBuilder AI payload is missing.
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer_install.ps1" -Payload "%PAYLOAD%" %*
exit /b %errorlevel%
