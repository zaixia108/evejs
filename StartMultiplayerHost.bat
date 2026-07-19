@echo off
setlocal EnableDelayedExpansion
title EveJS - Multiplayer Host

for %%I in ("%~dp0.") do set "EVEJS_REPO_ROOT=%%~fI"

echo.
echo   ============================================================
echo     EveJS Multiplayer Host
echo   ============================================================
echo.
echo   This will:
echo     - bind game/proxy/image/chat listeners to 0.0.0.0
echo     - advertise your LAN/public host IP to clients
echo     - turn on auto-create accounts, turn off password skip
echo     - export a one-click PlayerConnect bundle for friends
echo     - optionally open Windows Firewall ports
echo     - start the server
echo.

set "HOST_ADDRESS=auto"
set /p "HOST_ADDRESS=  Host IP/hostname to advertise [auto detect LAN]: "
if "%HOST_ADDRESS%"=="" set "HOST_ADDRESS=auto"

set "OPEN_FW=Y"
set /p "OPEN_FW=  Open Windows Firewall ports now? [Y/n]: "
if /I "%OPEN_FW%"=="" set "OPEN_FW=Y"

set "PS_ARGS=-HostAddress `"%HOST_ADDRESS%`""
if /I "%OPEN_FW%"=="Y" set "PS_ARGS=%PS_ARGS% -OpenFirewall"
if /I "%OPEN_FW%"=="YES" set "PS_ARGS=%PS_ARGS% -OpenFirewall"

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%EVEJS_REPO_ROOT%\tools\PlayerConnect\ConfigureMultiplayerHost.ps1" %PS_ARGS%
if errorlevel 1 (
  echo.
  echo   [ERROR] Multiplayer host configuration failed.
  pause
  exit /b 1
)

echo.
echo   Starting server...
echo   Friends should use the folder:
echo     %EVEJS_REPO_ROOT%\_local\player-connect-bundle
echo.
echo   Press Ctrl+C in the server window to stop.
echo.

rem Reuse the normal server launcher path: database migrate + deps + npm start.
call "%EVEJS_REPO_ROOT%\StartServer.bat"
exit /b %errorlevel%
