@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
title EVE Layout Manager
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%EveLayoutManager.ps1"
if errorlevel 1 pause
endlocal
