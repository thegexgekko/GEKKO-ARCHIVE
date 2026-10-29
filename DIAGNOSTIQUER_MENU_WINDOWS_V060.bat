@echo off
setlocal
cd /d "%~dp0"
echo ====================================================
echo  GEKKO ARCHIVE - DIAGNOSTIC DU MENU WINDOWS 11
 echo ====================================================
echo Aucun changement du systeme, aucun droit admin requis.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-context-menu-v060\DIAGNOSTIQUER_MENU_WINDOWS_V060.ps1"
echo.
if errorlevel 1 echo [ERREUR] Le diagnostic a rencontre une erreur inattendue.
echo Le rapport est enregistre dans windows-context-menu-v060.
pause
endlocal
