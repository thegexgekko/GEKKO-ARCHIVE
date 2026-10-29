@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo =============================================
echo  GEKKO ARCHIVE - MENU WIN11 GETSTATE V0.6.0.1
echo =============================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-context-menu-v060\ACTUALISER_VISIBILITE_MENU_V060.ps1"
if errorlevel 1 echo [ECHEC] Lis l'erreur ci-dessus.
pause
