@echo off
setlocal
:: ============================================================
::  uninstall-java.bat
::  Complete removal of Java from Windows 10 / Windows 11
::  Author: lorenzocaputodev
::
::  This launcher only handles administrator elevation and the
::  user confirmation: the actual removal is performed by
::  uninstall-java.ps1, which also writes the log and a backup.
:: ============================================================

:: --------------------------------------------------------------
:: 1) Elevate to administrator privileges
::
:: The ELEVATED marker prevents any further self-elevation
:: attempt: if this instance was already relaunched with
:: elevated privileges, it jumps straight to execution,
:: guaranteeing the relaunch can happen at most once
:: (no loop, under any circumstance).
::
:: fltmc only succeeds when elevated and, unlike "net session",
:: does not depend on the Server service. The script path is
:: passed through an environment variable so that quotes or
:: apostrophes in the folder name cannot break the command.
:: --------------------------------------------------------------
if "%~1"=="ELEVATED" goto :main

fltmc >nul 2>&1
if %errorlevel% EQU 0 goto :main

echo Requesting administrator privileges...
set "JU_SELF=%~f0"
powershell -NoProfile -Command "try { Start-Process -FilePath $env:JU_SELF -ArgumentList 'ELEVATED' -Verb RunAs -ErrorAction Stop } catch { exit 1 }" >nul 2>&1
if errorlevel 1 goto :elevation_failed
exit /B

:elevation_failed
echo.
echo ERROR: administrator privileges are required, but the request
echo was denied or could not be shown. Nothing has been changed.
echo.
pause
exit /B 1


:main
set "PS1=%~dp0uninstall-java.ps1"
if not exist "%PS1%" goto :missing_ps1

:: --------------------------------------------------------------
:: 2) Warning and confirmation
:: --------------------------------------------------------------
cls
echo ============================================================
echo         COMPLETE JAVA REMOVAL - Windows 10 / Windows 11
echo ============================================================
echo.
echo WARNING: this script removes ALL installed Java versions
echo (Oracle, OpenJDK, Temurin, Zulu, Corretto, Liberica), their
echo leftover folders, registry keys, the JAVA_HOME variable and
echo Java entries in PATH.
echo.
echo  - Every running Java process (java.exe, javaw.exe, ...) is
echo    terminated forcefully: save your work first.
echo  - A backup of the environment variables and of the Java
echo    registry keys is saved next to this script.
echo.
echo    [Y] Uninstall Java
echo    [D] Dry run: show what would be done, change nothing
echo    [N] Cancel
echo.
choice /C YDN /N /M "Your choice: "
if errorlevel 3 goto :cancelled

set "PSARGS="
if errorlevel 2 set "PSARGS=-DryRun"

:: --------------------------------------------------------------
:: 3) Run the removal engine (it writes the log by itself)
:: --------------------------------------------------------------
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %PSARGS%
set "RC=%errorlevel%"

echo.
echo ============================================================
if "%RC%"=="0" goto :finished_ok
if "%RC%"=="1" goto :finished_warnings
goto :finished_error

:finished_ok
if defined PSARGS goto :finished_dryrun
echo  Done! Java has been removed.
echo  Restarting your PC is recommended to apply all the changes.
echo ============================================================
goto :end

:finished_dryrun
echo  Dry run completed: nothing was changed.
echo  Run this script again and choose [Y] to perform the removal.
echo ============================================================
goto :end

:finished_warnings
echo  Completed WITH WARNINGS.
echo  Check the messages above and the log file.
echo ============================================================
goto :end

:finished_error
echo  The removal did not run (exit code %RC%).
echo  Check the messages above.
echo ============================================================
goto :end

:cancelled
echo.
echo Operation cancelled by the user.
set "RC=0"
goto :end

:missing_ps1
echo ERROR: uninstall-java.ps1 not found next to this script.
echo Both files must be in the same folder. Nothing has been changed.
set "RC=1"
goto :end

:end
echo.
pause
exit /B %RC%
