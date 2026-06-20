@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"

:: ===== Check for existing instance (keep-alive guard) =====
tasklist /fi "WINDOWTITLE eq RAMMap Memory Monitor*" /fo csv /nh 2>nul | find /i "cmd.exe" >nul
if !errorlevel! equ 0 exit /b 0

title RAMMap Memory Monitor - Background Service

:: ===== Configuration =====
set THRESHOLD=80
set INTERVAL=30
set RAMMAP=rammap64.exe
set LOGFILE=memory_cleaner.log

:: ===== Auto-elevate to admin =====
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: ===== Check RAMMap exists =====
if not exist "%RAMMAP%" (
    echo [ERROR] %RAMMAP% not found in current directory.
    pause
    exit /b 1
)

echo ==============================================
echo   RAMMap Memory Monitor - Background Service
echo ==============================================
echo   Threshold:     %THRESHOLD%%
echo   Check every:  %INTERVAL% seconds
echo   RAMMap:       %RAMMAP%
echo   Log file:     %LOGFILE%
echo ==============================================

:: Write startup log entry
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty TotalVisibleMemorySize"`) do set total_mem=%%a
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty FreePhysicalMemory"`) do set free_mem=%%a
set /a used_mem = total_mem - free_mem
set /a used_pct = used_mem * 100 / total_mem

for /f "tokens=1-2 delims=." %%a in ("!TIME!") do set time_clean=%%a
set timestamp=!DATE! !time_clean!

echo [!timestamp!] Service started. Initial memory: !used_pct!%% (!total_mem! KB total)
echo [!timestamp!] Service started. Initial memory: !used_pct!%% (!total_mem! KB total) > "%~dp0!LOGFILE!"

:main_loop

for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty TotalVisibleMemorySize"`) do set total_mem=%%a
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty FreePhysicalMemory"`) do set free_mem=%%a
set /a used_mem = total_mem - free_mem
set /a used_pct = used_mem * 100 / total_mem

for /f "tokens=1-2 delims=." %%a in ("!TIME!") do set time_clean=%%a
set timestamp=!DATE! !time_clean!

echo [!timestamp!] Memory: !used_pct!%% (!used_mem! KB used / !total_mem! KB total)

if !used_pct! geq %THRESHOLD% (
    echo [!timestamp!] WARNING: Memory exceeds %THRESHOLD%%% threshold! Cleaning...

    start /min "" "!RAMMAP!" -Ew >nul 2>&1
    timeout /t 3 /nobreak >nul
    taskkill /f /im RAMMap64.exe >nul 2>&1

    start /min "" "!RAMMAP!" -Es >nul 2>&1
    timeout /t 3 /nobreak >nul
    taskkill /f /im RAMMap64.exe >nul 2>&1

    start /min "" "!RAMMAP!" -Em >nul 2>&1
    timeout /t 3 /nobreak >nul
    taskkill /f /im RAMMap64.exe >nul 2>&1

    for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty FreePhysicalMemory"`) do set new_free=%%a
    set /a new_used = total_mem - new_free
    set /a new_pct = new_used * 100 / total_mem
    set /a freed_kb = new_free - free_mem
    set /a freed_mb = freed_kb / 1024

    echo [!timestamp!] CLEANUP: After cleanup: !new_pct!%% used (freed ~!freed_mb! MB)
    if !freed_mb! gtr 0 (
        echo [!timestamp!] CLEANUP: After cleanup: !new_pct!%% used (freed ~!freed_mb! MB) > "%~dp0!LOGFILE!"
    )

) else (
    echo [!timestamp!] OK: Memory below threshold.
)

timeout /t %INTERVAL% /nobreak >nul
goto main_loop
