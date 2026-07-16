@echo off
setlocal EnableDelayedExpansion
:: ============================================================
::  uninstall-java.bat
::  Complete removal of Java from Windows 10 / Windows 11
::  Author: lorenzocaputodev
:: ============================================================

:: --------------------------------------------------------------
:: 1) Elevate to administrator privileges
::
:: The ELEVATED marker prevents any further self-elevation
:: attempt: if this instance was already relaunched with
:: elevated privileges, it jumps straight to execution,
:: guaranteeing the relaunch can happen at most once
:: (no loop, under any circumstance).
:: --------------------------------------------------------------
if "%~1"=="ELEVATED" goto :main

net session >nul 2>&1
if %errorlevel% EQU 0 goto :main

echo Requesting administrator privileges...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'ELEVATED' -Verb RunAs" >nul 2>&1
exit /B


:main
pushd "%cd%"
cd /D "%~dp0"

cls
echo ============================================================
echo         COMPLETE JAVA REMOVAL - Windows 10 / Windows 11
echo ============================================================
echo.
echo WARNING: this script removes ALL installed Java versions
echo (Oracle, OpenJDK, Temurin, Zulu, AdoptOpenJDK), cleans the
echo registry, the JAVA_HOME variable, and Java-related entries
echo in PATH.
echo.
set /p "CONFIRM=Do you want to continue? (Y/N): "
if /I not "%CONFIRM%"=="Y" (
    echo Operation cancelled by the user.
    pause
    exit /B
)

set "LOGFILE=%~dp0uninstall-java-log.txt"
echo Log started on %date% at %time% > "%LOGFILE%"

:: --------------------------------------------------------------
:: 2) Close any running Java processes
:: --------------------------------------------------------------
echo [1/5] Closing active Java processes...
taskkill /F /IM java.exe   >nul 2>&1
taskkill /F /IM javaw.exe  >nul 2>&1
taskkill /F /IM javaws.exe >nul 2>&1

:: --------------------------------------------------------------
:: 3) Uninstall via winget
:: --------------------------------------------------------------
echo [2/5] Uninstalling via winget...
where winget >nul 2>&1
if %errorlevel% EQU 0 (
    winget uninstall --name "Java" --accept-source-agreements --disable-interactivity >> "%LOGFILE%" 2>&1
    winget uninstall --name "OpenJDK" --accept-source-agreements --disable-interactivity >> "%LOGFILE%" 2>&1
    winget uninstall --name "Eclipse Temurin" --accept-source-agreements --disable-interactivity >> "%LOGFILE%" 2>&1
    winget uninstall --name "Zulu" --accept-source-agreements --disable-interactivity >> "%LOGFILE%" 2>&1
) else (
    echo winget is not available on this system, skipping this step. >> "%LOGFILE%"
)

:: --------------------------------------------------------------
:: 4) Advanced uninstall (Get-Package, registry, PATH cleanup)
::    via the external PowerShell module uninstall-java.ps1
:: --------------------------------------------------------------
echo [3/5] Advanced uninstall via PowerShell...
if exist "%~dp0uninstall-java.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-java.ps1" >> "%LOGFILE%" 2>&1
) else (
    echo WARNING: uninstall-java.ps1 not found in the script folder. >> "%LOGFILE%"
    echo WARNING: uninstall-java.ps1 not found, some steps were skipped.
)

:: --------------------------------------------------------------
:: 5) Remove leftover folders
:: --------------------------------------------------------------
echo [4/5] Removing leftover folders from disk...
rmdir /s /q "%ProgramFiles%\Java" 2>nul
if not "%ProgramFiles(x86)%"=="" rmdir /s /q "%ProgramFiles(x86)%\Java" 2>nul
rmdir /s /q "%ProgramFiles%\Eclipse Adoptium" 2>nul
rmdir /s /q "%ProgramFiles%\Zulu" 2>nul
rmdir /s /q "%ProgramFiles%\AdoptOpenJDK" 2>nul
rmdir /s /q "%ProgramData%\Oracle" 2>nul
rmdir /s /q "%AppData%\Oracle\Java" 2>nul
rmdir /s /q "%LocalAppData%\Oracle\Java" 2>nul

:: --------------------------------------------------------------
:: 6) Clean registry and JAVA_HOME variable
:: --------------------------------------------------------------
echo [5/5] Cleaning up the registry and JAVA_HOME...
reg delete "HKLM\SOFTWARE\JavaSoft" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\WOW6432Node\JavaSoft" /f >nul 2>&1
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v JAVA_HOME /f >nul 2>&1
reg delete "HKCU\Environment" /v JAVA_HOME /f >nul 2>&1

echo.
echo ============================================================
echo  Done! Log saved to:
echo  %LOGFILE%
echo  It is recommended to restart your PC to apply the changes.
echo ============================================================
echo.
popd
pause
endlocal
