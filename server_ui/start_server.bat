@echo off
setlocal
title WhatsReply Local Server
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Python is not installed or is not in PATH.
  pause
  exit /b 1
)

echo Starting WhatsReply history server on port 8765...
start "WhatsReply Server" /d "%~dp0" cmd /k python server.py
timeout /t 2 /nobreak >nul

echo Checking server connection...
curl.exe -s http://127.0.0.1:8765/api/health
echo.
echo Dashboard: http://127.0.0.1:8765
echo Use your PC Tailscale IP in the Android app.
start "" http://127.0.0.1:8765
echo.
echo Server window is running separately. Close that window to stop the server.
pause
