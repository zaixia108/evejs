@echo off
setlocal EnableDelayedExpansion
title EveJS PlayerConnect
for %%I in ("%~dp0.") do set "BUNDLE_ROOT=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BUNDLE_ROOT%\Connect.ps1"
set "EXIT_CODE=!errorlevel!"
if not "!EXIT_CODE!"=="0" (
  echo.
  echo   Connect failed with code !EXIT_CODE!.
  pause
)
exit /b !EXIT_CODE!
