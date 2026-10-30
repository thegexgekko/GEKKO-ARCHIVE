@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RETIRER_ASSOCIATIONS_WINDOWS_V064.ps1"
if errorlevel 1 (
 echo.
 echo [ERREUR] Consulte le message ci-dessus.
)
pause
