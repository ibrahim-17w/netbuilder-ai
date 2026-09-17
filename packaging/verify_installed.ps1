$target = Join-Path $env:LOCALAPPDATA 'NetBuilderAI'
$app = Join-Path $target 'net_builder.exe'
$sidecar = Join-Path $target 'sidecar\pt_autopilot.exe'

$existing = Get-Process pt_autopilot -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $sidecar }
if ($existing) {
  Stop-Process -Id $existing.Id -Force
  Start-Sleep -Milliseconds 500
}

$appProcess = Start-Process -FilePath $app -WorkingDirectory $target -PassThru
$sidecarProcess = $null
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  $sidecarProcess = Get-Process pt_autopilot -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $sidecar }
  if ($sidecarProcess) { break }
}

$health = $null
try { $health = Invoke-RestMethod -Uri 'http://127.0.0.1:5005/health' -TimeoutSec 3 } catch {}

[pscustomobject]@{
  AppPath = $app
  AppRunning = [bool](Get-Process -Id $appProcess.Id -ErrorAction SilentlyContinue)
  SidecarPath = $sidecar
  SidecarAutoStarted = [bool]$sidecarProcess
  SidecarPid = if ($sidecarProcess) { $sidecarProcess.Id } else { $null }
  Health = $health
} | ConvertTo-Json -Depth 5
