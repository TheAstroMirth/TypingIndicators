@echo off
rem TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
rem Installer scripts: Copyright (c) 2026 TheAstroMirth.
rem Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
rem Double-click to run the TypingIndicators installer. No administrator rights needed.
setlocal
set "TI_SCRIPT=%~dp0install.ps1"
set "TI_EXIT=1"

if not exist "%TI_SCRIPT%" goto :missing_script
where powershell.exe >nul 2>nul
if errorlevel 1 goto :missing_powershell

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TI_SCRIPT%" %*
set "TI_EXIT=%ERRORLEVEL%"
if "%TI_EXIT%"=="0" goto :end
echo.
echo The installer stopped with exit code %TI_EXIT%. Read the messages above.
echo If PowerShell printed an error about scripts being disabled or blocked,
echo your PC or organisation restricts PowerShell scripts. Ask your administrator,
echo or follow the manual steps in README.md instead.
goto :end

:missing_script
echo Cannot find install.ps1 next to this file:
echo   "%TI_SCRIPT%"
echo Unzip the whole project first and keep its folders together.
goto :end

:missing_powershell
echo Windows PowerShell (powershell.exe) was not found on this PC.
echo It is included in Windows 10 and 11. Make sure it has not been removed
echo or blocked, then run this file again.
goto :end

:end
echo.
pause
exit /b %TI_EXIT%
