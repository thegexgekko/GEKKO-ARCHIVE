@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ===================================================
echo  GEKKO ARCHIVE V0.6.0 - MENU MODERNE WINDOWS 11
 echo ===================================================
echo Integration experimentale pour ce compte Windows.
echo Rien ne sera enregistre sans validation explicite.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-context-menu-v060\INSTALLER_MENU_WINDOWS_V060.ps1"
if errorlevel 1 (
 echo.
 echo [ECHEC] Installation non terminee. Lis l'erreur ci-dessus.
 pause
 exit /b 1
)
echo.
pause
