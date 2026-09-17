$target = Join-Path $env:LOCALAPPDATA 'NetBuilderAI'
$app = Join-Path $target 'net_builder.exe'
$sidecar = Join-Path $target 'sidecar\pt_autopilot.exe'

Get-Process net_builder, pt_autopilot -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq $app -or $_.Path -eq $sidecar } |
  Stop-Process -Force
Start-Sleep -Milliseconds 500

$installer = (Resolve-Path (Join-Path $PSScriptRoot '..\dist\NetBuilderAI-Tester-Setup.exe')).Path
$installProcess = Start-Process -FilePath $installer -Wait -PassThru
Start-Sleep -Seconds 20

$appProcess = Get-Process net_builder -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq $app } | Select-Object -First 1
$sidecarProcess = Get-Process pt_autopilot -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq $sidecar } | Select-Object -First 1
$health = $null
try { $health = Invoke-RestMethod -Uri 'http://127.0.0.1:5005/health' -TimeoutSec 3 } catch {}

[pscustomobject]@{
  InstallerExitCode = $installProcess.ExitCode
  InstalledApp = Test-Path $app
  InstalledSidecar = Test-Path $sidecar
  AppRunning = [bool]$appProcess
  SidecarRunning = [bool]$sidecarProcess
  Health = $health
} | ConvertTo-Json -Depth 5
