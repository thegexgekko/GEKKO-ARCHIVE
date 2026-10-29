@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ======================================================
echo GEKKO ARCHIVE - REPARER CONFIANCE MSIX SANS RECOMPILER
echo ======================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-context-menu-v060\FINALISER_MENU_WINDOWS_V060.ps1"
if errorlevel 1 (
 echo.
 echo [ECHEC] Consulte l'erreur affichee ci-dessus.
 pause
 exit /b 1
)
echo.
pause
