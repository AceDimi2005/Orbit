@echo off
cd /d "%~dp0"
title Orbit PC Companion Agent
where python >nul 2>nul
if errorlevel 1 (
    echo Install Python 3.11 or newer from python.org and enable Add Python to PATH.
    pause
    exit /b 1
)
if not exist ".venv\Scripts\python.exe" python -m venv .venv
if errorlevel 1 goto failed
echo Installing / verifying Orbit dependencies in a private environment...
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto failed
echo Starting Orbit Agent...
".venv\Scripts\python.exe" orbit_agent.py
pause
exit /b
:failed
echo Setup failed. Check the error above and your Internet connection.
pause
exit /b 1
