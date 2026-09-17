@echo off
REM Emergency stop for PT Autopilot sidecar
curl -X POST http://127.0.0.1:5005/stop
echo.
pause
