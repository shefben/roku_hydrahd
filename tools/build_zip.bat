@echo off
rem ---------------------------------------------------------------------
rem build_zip.bat - Build HydraHD.zip.
rem
rem The channel auto-discovers the resolver on the LAN at runtime, so
rem no IP needs to be baked in. Pass an IP only if you want a fallback
rem for networks that block UDP broadcast (AP isolation, VLANs, etc.).
rem
rem Usage:
rem   build_zip.bat                    no IP baked in (recommended)
rem   build_zip.bat auto               auto-detect LAN IP, port 8787
rem   build_zip.bat 192.168.1.50       explicit IP, port 8787
rem   build_zip.bat 192.168.1.50 9000  explicit IP and port
rem
rem Output: HydraHD.zip in the channel root.
rem ---------------------------------------------------------------------

setlocal

set "CHANNEL_DIR=%~dp0.."
for %%I in ("%CHANNEL_DIR%") do set "CHANNEL_DIR=%%~fI"

if not exist "%CHANNEL_DIR%\manifest" (
    echo [build_zip] manifest not found at %CHANNEL_DIR%\manifest
    exit /b 1
)

set "LAN_IP=%~1"
set "LAN_PORT=%~2"
if "%LAN_PORT%"=="" set "LAN_PORT=8787"

if /I "%LAN_IP%"=="auto" (
    set "LAN_IP="
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0detect_lan_ip.ps1"`) do set "LAN_IP=%%i"
    if "%LAN_IP%"=="" (
        echo [build_zip] Could not auto-detect a LAN IP.
        echo Pass it explicitly, e.g. build_zip.bat 192.168.1.50
        exit /b 1
    )
)

if "%LAN_IP%"=="" (
    set "RESOLVER_URL="
    echo [build_zip] Channel dir : %CHANNEL_DIR%
    echo [build_zip] Resolver URL: ^<none^> ^(channel will auto-discover on LAN^)
) else (
    set "RESOLVER_URL=http://%LAN_IP%:%LAN_PORT%"
    echo [build_zip] Channel dir : %CHANNEL_DIR%
    echo [build_zip] Resolver URL: %RESOLVER_URL% ^(fallback if discovery fails^)
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_zip.ps1"
endlocal & exit /b %ERRORLEVEL%
