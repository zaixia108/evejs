@echo off
setlocal
cd /d "%~dp0"
title EveJS Server Launcher

where uv >nul 2>&1
if errorlevel 1 (
  echo [ERROR] uv not found on PATH.
  pause
  exit /b 1
)

uv run python server_main.py
set EXIT_CODE=%errorlevel%
if not "%EXIT_CODE%"=="0" (
  echo.
  echo Launcher exited with code %EXIT_CODE%.
  pause
)
exit /b %EXIT_CODE%
