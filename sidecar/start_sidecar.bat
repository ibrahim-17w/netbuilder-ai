@echo off
REM One-click PT Autopilot sidecar launcher (Windows)
cd /d "%~dp0.."
echo Installing sidecar deps (once)...
python -m pip install -r sidecar\requirements.txt
echo Starting sidecar on http://127.0.0.1:5005 ...
echo Keep this window open. Keep Packet Tracer open, maximized, focused.
python sidecar\pt_autopilot.py
pause
