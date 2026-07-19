@echo off
setlocal
cd /d "%~dp0"
title Build EveJS Client Launcher

where uv >nul 2>&1
if errorlevel 1 (
  echo [ERROR] uv not found on PATH.
  pause
  exit /b 1
)

echo.
echo   Building EveJSClientLauncher.exe with PyInstaller...
echo.

uv run pyinstaller --noconfirm --clean ^
  --name EveJSClientLauncher ^
  --windowed ^
  --onefile ^
  --collect-all customtkinter ^
  main.py

if errorlevel 1 (
  echo.
  echo   Build failed.
  pause
  exit /b 1
)

echo.
echo   Done:
echo     dist\EveJSClientLauncher.exe
echo.
echo   Copy next to a player-connect-bundle folder that contains server.json,
echo   or fill host/token in the UI on first run.
echo.
pause
exit /b 0
