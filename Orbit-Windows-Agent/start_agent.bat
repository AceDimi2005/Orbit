@echo off
setlocal
title Orbit PC Companion 4.3.1
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    call "%~dp0install_orbit.bat"
    exit /b %errorlevel%
)

if not exist "OrbitCompanion.exe" (
    if exist "OrbitCompanion.cs" (
        if exist "%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" (
            "%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /win32icon:orbit.ico /r:System.Windows.Forms.dll /out:OrbitCompanion.exe OrbitCompanion.cs >nul 2>nul
        )
    )
)

if /I "%~1"=="--console" (
    ".venv\Scripts\python.exe" "%~dp0orbit_agent.py" --console
    pause
    exit /b 0
)

if exist ".venv\Scripts\pythonw.exe" (
    start "" ".venv\Scripts\pythonw.exe" "%~dp0orbit_agent.py" --tray
    exit /b 0
)

".venv\Scripts\python.exe" "%~dp0orbit_agent.py" --tray
