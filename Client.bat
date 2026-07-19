@echo off
setlocal EnableDelayedExpansion
title EveJS - Client (Quick Connect)

rem ============================================================
rem  Client.bat  -  one-click connect to multiplayer host
rem  Works from:
rem    - repo root  (uses _local\player-connect-bundle)
rem    - the exported player-connect-bundle folder itself
rem ============================================================

for %%I in ("%~dp0.") do set "LAUNCHER_ROOT=%%~fI"

echo.
echo   ============================================================
echo     EveJS - Client  ^(quick connect^)
echo   ============================================================
echo.

rem Resolve Connect.ps1 + server.json locations.
set "CONNECT_PS1="
set "BUNDLE_ROOT="

if exist "%LAUNCHER_ROOT%\server.json" if exist "%LAUNCHER_ROOT%\Connect.ps1" (
  set "BUNDLE_ROOT=%LAUNCHER_ROOT%"
  set "CONNECT_PS1=%LAUNCHER_ROOT%\Connect.ps1"
  goto BundleReady
)

if exist "%LAUNCHER_ROOT%\_local\player-connect-bundle\server.json" if exist "%LAUNCHER_ROOT%\_local\player-connect-bundle\Connect.ps1" (
  set "BUNDLE_ROOT=%LAUNCHER_ROOT%\_local\player-connect-bundle"
  set "CONNECT_PS1=%LAUNCHER_ROOT%\_local\player-connect-bundle\Connect.ps1"
  goto BundleReady
)

if exist "%LAUNCHER_ROOT%\tools\PlayerConnect\Connect.ps1" (
  set "BUNDLE_ROOT=%LAUNCHER_ROOT%\_local\player-connect-bundle"
  set "CONNECT_PS1=%LAUNCHER_ROOT%\tools\PlayerConnect\Connect.ps1"
  if not exist "%BUNDLE_ROOT%\server.json" (
    echo   [ERROR] No player-connect-bundle found.
    echo.
    echo   On the host PC, run Server.bat first, then copy this folder
    echo   to the client machine:
    echo     _local\player-connect-bundle
    echo.
    echo   Or place Client.bat next to server.json inside that folder.
    pause
    exit /b 1
  )
  goto BundleReady
)

echo   [ERROR] Connect.ps1 / server.json not found next to this script.
echo       Expected either:
echo         %LAUNCHER_ROOT%\server.json + Connect.ps1
echo         or %LAUNCHER_ROOT%\_local\player-connect-bundle\
pause
exit /b 1

:BundleReady
echo   Bundle:  %BUNDLE_ROOT%
if exist "%BUNDLE_ROOT%\server.json" (
  for /f "usebackq delims=" %%H in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "try { (Get-Content -LiteralPath '%BUNDLE_ROOT%\server.json' -Raw | ConvertFrom-Json).host } catch { '' }"`) do set "SERVER_HOST=%%H"
  if defined SERVER_HOST echo   Server:  !SERVER_HOST!
)
echo.

rem Optional: Client.bat "D:\Games\EVE\tq"  to skip the folder picker
set "CLIENT_PATH_ARG="
if not "%~1"=="" set "CLIENT_PATH_ARG=-ClientPath `"%~1`""

powershell -NoProfile -ExecutionPolicy Bypass -File "%CONNECT_PS1%" %CLIENT_PATH_ARG%
set "EXIT_CODE=!errorlevel!"

if not "!EXIT_CODE!"=="0" (
  echo.
  echo   Client launcher failed with code !EXIT_CODE!.
  echo   Checklist:
  echo     - Host is running Server.bat
  echo     - server.json host IP is reachable from this PC
  echo     - Full EVE build 3396210 client copy ^(with ResFiles^)
  echo     - Firewall allows 26000 / 26001 / 26002 / 5222
  pause
)

exit /b !EXIT_CODE!
