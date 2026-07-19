@echo off
setlocal
cd /d "%~dp0"
title Build EveJS Server Launcher

where uv >nul 2>&1
if errorlevel 1 (
  echo [ERROR] uv not found on PATH.
  pause
  exit /b 1
)

echo.
echo   Building EveJSServerLauncher.exe ...
echo.

uv run pyinstaller --noconfirm --clean ^
  --name EveJSServerLauncher ^
  --windowed ^
  --onefile ^
  --collect-all customtkinter ^
  server_main.py

if errorlevel 1 (
  echo Build failed.
  pause
  exit /b 1
)

echo.
echo   Done: dist\EveJSServerLauncher.exe
echo   Place the exe in the EveJS repo root (needs server\ and tools\).
echo.
pause
exit /b 0
