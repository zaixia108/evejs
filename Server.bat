@echo off
setlocal EnableDelayedExpansion
title EveJS - Server (Quick Deploy)

rem ============================================================
rem  Server.bat  -  one-click multiplayer host deploy + start
rem  Style matches StartServer.bat / StartMultiplayerHost.bat
rem ============================================================

for %%I in ("%~dp0.") do set "EVEJS_REPO_ROOT=%%~fI"

echo.
echo   ============================================================
echo     EveJS - Server  ^(quick deploy + start^)
echo   ============================================================
echo.
echo   This will:
echo     1. Configure multiplayer bind/advertise addresses
echo     2. Export friend connect bundle
echo     3. Open firewall ports ^(if elevated^)
echo     4. Ensure database + npm deps
echo     5. Start the game server
echo.

where node >nul 2>&1
if errorlevel 1 (
  echo   [ERROR] Node.js is not installed or not on PATH.
  echo       Download LTS from https://nodejs.org
  pause
  exit /b 1
)

if not exist "%EVEJS_REPO_ROOT%\server\index.js" (
  echo   [ERROR] Server not found:
  echo       %EVEJS_REPO_ROOT%\server\index.js
  pause
  exit /b 1
)

rem --- optional host override: Server.bat 192.168.1.10 ---
set "HOST_ADDRESS=%~1"
if "%HOST_ADDRESS%"=="" set "HOST_ADDRESS=auto"

echo   Advertise host: %HOST_ADDRESS%
echo   Configuring multiplayer host...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%EVEJS_REPO_ROOT%\tools\PlayerConnect\ConfigureMultiplayerHost.ps1" -HostAddress "%HOST_ADDRESS%" -OpenFirewall
if errorlevel 1 (
  echo.
  echo   [ERROR] Multiplayer host configuration failed.
  pause
  exit /b 1
)

rem --- database + dependencies (same path as StartServer.bat) ---
set "EVEJS_LOCAL_DATABASE_ROOT=%EVEJS_REPO_ROOT%\_local\gameStore"
set "EVEJS_GAMESTORE_DATA_DIR=%EVEJS_LOCAL_DATABASE_ROOT%\data"
call :MigrateLegacyData
call :EnsureLocalDatabase
if errorlevel 1 exit /b 1
call :EnsureServerDependencies
if errorlevel 1 exit /b 1

set "EVEJS_PROXY_LOCAL_INTERCEPT=1"
if not exist "%EVEJS_REPO_ROOT%\server\logs\node-reports" mkdir "%EVEJS_REPO_ROOT%\server\logs\node-reports" >nul 2>&1

echo.
echo   ============================================================
echo     Server is starting. Friends connect with Client.bat
echo     Bundle folder:
echo       %EVEJS_REPO_ROOT%\_local\player-connect-bundle
echo.
echo     Ports: 26000  26001  26002  5222
echo     Press Ctrl+C to stop.
echo   ============================================================
echo.

pushd "%EVEJS_REPO_ROOT%\server"
call npm start
set "EVEJS_EXIT=!errorlevel!"
popd

if not "!EVEJS_EXIT!"=="0" (
  echo.
  echo   Server exited with code !EVEJS_EXIT!.
  pause
)
exit /b !EVEJS_EXIT!

:EnsureServerDependencies
if exist "%EVEJS_REPO_ROOT%\server\node_modules\express\package.json" exit /b 0

echo   Server dependencies are not installed.
echo   Running npm ci in the server directory...
echo.

pushd "%EVEJS_REPO_ROOT%\server"
call npm ci
set "EVEJS_NPM_EXIT=!errorlevel!"
popd

if not "!EVEJS_NPM_EXIT!"=="0" (
  echo.
  echo   [ERROR] npm ci failed with code !EVEJS_NPM_EXIT!.
  pause
  exit /b !EVEJS_NPM_EXIT!
)

echo.
echo   Dependencies installed successfully.
echo.
exit /b 0

:EnsureLocalDatabase
if exist "%EVEJS_LOCAL_DATABASE_ROOT%\manifest.json" exit /b 0

if not exist "%EVEJS_REPO_ROOT%\tools\DatabaseCreator\CreateDatabase.bat" (
  echo   [ERROR] Local database has not been generated and DatabaseCreator is missing.
  echo       Expected: %EVEJS_REPO_ROOT%\tools\DatabaseCreator\CreateDatabase.bat
  pause
  exit /b 1
)

echo   Local database not found.
echo   Running tools\DatabaseCreator\CreateDatabase.bat...
echo.

call "%EVEJS_REPO_ROOT%\tools\DatabaseCreator\CreateDatabase.bat"
set "EVEJS_DB_EXIT=!errorlevel!"
if not "!EVEJS_DB_EXIT!"=="0" (
  echo.
  echo   [ERROR] Database generation failed with code !EVEJS_DB_EXIT!.
  pause
  exit /b !EVEJS_DB_EXIT!
)

echo.
echo   Local database ready: %EVEJS_GAMESTORE_DATA_DIR%
echo.
exit /b 0

:MigrateLegacyData
if exist "%EVEJS_REPO_ROOT%\server\src\gameStore\migrateLegacyNewDatabase.js" (
  node "%EVEJS_REPO_ROOT%\server\src\gameStore\migrateLegacyNewDatabase.js"
)
exit /b 0
