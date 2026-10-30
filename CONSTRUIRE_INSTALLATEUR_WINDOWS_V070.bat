@echo off
setlocal
cd /d "%~dp0"
echo GEKKO ARCHIVE - fabrication de l'installateur Windows 11 V0.7.0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PREPARER_INSTALLATEUR_WINDOWS_V070.ps1"
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" echo Echec de construction : code %CODE%.
pause
exit /b %CODE%
