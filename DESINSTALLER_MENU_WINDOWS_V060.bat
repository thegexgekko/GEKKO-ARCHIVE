@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ==================================================
echo  GEKKO ARCHIVE - RETRAIT DU MENU CONTEXTUEL
 echo ==================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-context-menu-v060\DESINSTALLER_MENU_WINDOWS_V060.ps1"
if errorlevel 1 (
 echo.
 echo [ERREUR] Le retrait n'a pas pu etre confirme.
 pause
 exit /b 1
)
echo.
pause
