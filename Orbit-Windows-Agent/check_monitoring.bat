@echo off
cd /d "%~dp0"
title Orbit monitoring source check
if not exist ".venv\Scripts\python.exe" (
    echo Run start_agent.bat first to install the Orbit dependencies.
    pause
    exit /b 1
)
".venv\Scripts\python.exe" check_monitoring.py
pause
