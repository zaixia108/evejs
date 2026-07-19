@echo off
setlocal
cd /d "%~dp0"
title EveJS Client Launcher

where uv >nul 2>&1
if errorlevel 1 (
  echo [ERROR] uv not found. Install uv or run: dist\EveJSClientLauncher.exe
  pause
  exit /b 1
)

uv run python main.py
set EXIT_CODE=%errorlevel%
if not "%EXIT_CODE%"=="0" (
  echo.
  echo Launcher exited with code %EXIT_CODE%.
  pause
)
exit /b %EXIT_CODE%
