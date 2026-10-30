@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MISE_A_JOUR_SANS_INSTALLATEUR_V071.ps1"
if errorlevel 1 (
  echo.
  echo [ERREUR] La mise a jour a echoue. Voir le message ci-dessus.
)
pause
