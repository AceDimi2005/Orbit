@echo off
cd /d "%~dp0"
title Orbit PC Companion Agent v2.0
echo Installing / verifying Python dependencies...
python -m pip install -r requirements.txt
echo Starting Orbit Agent...
python orbit_agent.py
pause
