@echo off
setlocal
title Orbit PC Companion - Installer
cd /d "%~dp0"

echo ============================================================
echo   Orbit PC Companion 5.0.0 - Windows Installer
echo ============================================================
echo.

where py >nul 2>nul
if %errorlevel%==0 (
    set "PYTHON_BOOTSTRAP=py -3"
) else (
    where python >nul 2>nul
    if %errorlevel%==0 (
        set "PYTHON_BOOTSTRAP=python"
    ) else (
        echo Python 3.11+ was not found on this PC.
        where winget >nul 2>nul
        if %errorlevel%==0 (
            echo Installing Python 3.12 via Windows Package Manager ^(winget^)...
            winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
            set "PYTHON_BOOTSTRAP=py -3"
        ) else (
            echo Please install Python 3.11 or newer from https://www.python.org/downloads/
            echo Make sure to check "Add python.exe to PATH", then run install_orbit.bat again.
            pause
            exit /b 1
        )
    )
)

if not exist ".venv\Scripts\python.exe" (
    echo [1/5] Creating private Python environment...
    %PYTHON_BOOTSTRAP% -m venv .venv
    if errorlevel 1 (
        echo Could not create the Python virtual environment.
        pause
        exit /b 1
    )
)

echo [2/5] Installing Orbit PC Companion dependencies...
".venv\Scripts\python.exe" -m pip install --disable-pip-version-check --upgrade pip >nul
".venv\Scripts\python.exe" -m pip install --disable-pip-version-check -q -r requirements.txt
if errorlevel 1 (
    echo Failed to install dependencies from requirements.txt.
    pause
    exit /b 1
)

echo [3/5] Building native OrbitCompanion.exe launcher with Orbit icon...
set "CSC_EXE=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC_EXE%" set "CSC_EXE=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if exist "%CSC_EXE%" (
    if exist "OrbitCompanion.cs" (
        "%CSC_EXE%" /nologo /target:winexe /win32icon:orbit.ico /r:System.Windows.Forms.dll /out:OrbitCompanion.exe OrbitCompanion.cs >nul 2>nul
    )
)

echo [4/5] Creating Desktop and Start Menu shortcuts with Orbit icon...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$workDir = (Get-Location).Path; " ^
    "$exePath = Join-Path $workDir 'OrbitCompanion.exe'; " ^
    "$pythonw = Join-Path $workDir '.venv\Scripts\pythonw.exe'; " ^
    "$script  = Join-Path $workDir 'orbit_agent.py'; " ^
    "$icon    = Join-Path $workDir 'orbit.ico'; " ^
    "$wsh     = New-Object -ComObject WScript.Shell; " ^
    "$desktop = [Environment]::GetFolderPath('Desktop'); " ^
    "$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Orbit PC Companion.lnk'; " ^
    "$deskLink  = Join-Path $desktop 'Orbit PC Companion.lnk'; " ^
    "foreach ($lnkPath in @($deskLink, $startMenu)) { " ^
    "  $sc = $wsh.CreateShortcut($lnkPath); " ^
    "  if (Test-Path $exePath) { " ^
    "    $sc.TargetPath = $exePath; " ^
    "    $sc.Arguments = '--tray'; " ^
    "  } else { " ^
    "    $sc.TargetPath = $pythonw; " ^
    "    $sc.Arguments = ('\"' + $script + '\" --tray'); " ^
    "  } " ^
    "  $sc.WorkingDirectory = $workDir; " ^
    "  if (Test-Path $icon) { $sc.IconLocation = ($icon + ',0'); } " ^
    "  $sc.Description = 'Orbit PC Companion - System Tray Agent'; " ^
    "  $sc.Save(); " ^
    "}"

echo [5/5] Enabling Run at Windows Startup and launching in System Tray...
".venv\Scripts\python.exe" "%~dp0orbit_agent.py" --enable-startup
if exist "%~dp0OrbitCompanion.exe" (
    start "" "%~dp0OrbitCompanion.exe" --tray
) else (
    start "" ".venv\Scripts\pythonw.exe" "%~dp0orbit_agent.py" --tray
)

echo.
echo ============================================================
echo   Installation complete!
echo   - Native launcher: OrbitCompanion.exe
echo   - Desktop ^& Start Menu shortcuts: "Orbit PC Companion"
echo   - Orbit is now running in your Windows System Tray
echo     ^(bottom-right hidden icons bar^).
echo   - Right-click the tray icon anytime to:
echo       * Check for updates on GitHub
echo       * Toggle "Run at Windows startup"
echo       * View connection details or Stop Orbit Companion
echo ============================================================
echo.
timeout /t 4 >nul
exit /b 0
