@echo off
setlocal
title Orbit PC Companion - Build Standalone Executable (.exe)
cd /d "%~dp0"

echo ============================================================
echo   Orbit PC Companion - Standalone .EXE Builder
echo ============================================================
echo.

if not exist ".venv\Scripts\python.exe" (
    where py >nul 2>nul
    if %errorlevel%==0 (
        py -3 -m venv .venv
    ) else (
        python -m venv .venv
    )
)

echo [1/3] Installing requirements and PyInstaller...
".venv\Scripts\python.exe" -m pip install --disable-pip-version-check -q -r requirements.txt pyinstaller
if errorlevel 1 (
    echo Failed to install PyInstaller or requirements.
    pause
    exit /b 1
)

echo [2/3] Building OrbitCompanion.exe with embedded orbit.ico...
".venv\Scripts\pyinstaller.exe" --noconfirm --clean --onefile --noconsole ^
    --name "OrbitCompanion" ^
    --icon "orbit.ico" ^
    --add-data "orbit.ico;." ^
    --hidden-import "uvicorn.logging" ^
    --hidden-import "uvicorn.loops.auto" ^
    --hidden-import "uvicorn.protocols.http.auto" ^
    --hidden-import "uvicorn.protocols.websockets.auto" ^
    --hidden-import "uvicorn.lifespan.on" ^
    --hidden-import "orbit_capabilities" ^
    --hidden-import "orbit_desktop" ^
    --hidden-import "orbit_energy" ^
    --hidden-import "orbit_summary" ^
    --hidden-import "orbit_events" ^
    --hidden-import "orbit_icons" ^
    --hidden-import "orbit_input" ^
    --hidden-import "orbit_links" ^
    --hidden-import "orbit_notify" ^
    --hidden-import "orbit_settings" ^
    --hidden-import "orbit_files" ^
    --hidden-import "orbit_hardware" ^
    --hidden-import "orbit_history" ^
    --hidden-import "orbit_pairing" ^
    --hidden-import "orbit_processes" ^
    --hidden-import "orbit_tls" ^
    --hidden-import "orbit_tray" ^
    --hidden-import "orbit_updater" ^
    orbit_agent.py

if errorlevel 1 (
    echo PyInstaller build failed.
    pause
    exit /b 1
)

echo [3/3] Copying OrbitCompanion.exe to current folder...
copy /y "dist\OrbitCompanion.exe" "OrbitCompanion.exe" >nul

echo.
echo ============================================================
echo   Success! Standalone executable created:
echo     %~dp0OrbitCompanion.exe
echo   Double-click OrbitCompanion.exe to run Orbit directly in
echo   the Windows System Tray with no console window.
echo ============================================================
pause
