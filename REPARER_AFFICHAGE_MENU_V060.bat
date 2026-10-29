@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ==============================================
echo GEKKO ARCHIVE V0.6.0 - MENU WINDOWS 11
echo Diagnostic et copie du composant COM manquant
echo ==============================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-context-menu-v060\REPARER_AFFICHAGE_MENU_V060.ps1"
if errorlevel 1 (
  echo.
  echo [ECHEC] Le diagnostic n'a pas valide la correction. Lis l'erreur ci-dessus.
) else (
  echo.
  echo [OK] Controle effectue. Recharge l'Explorateur Windows.
)
echo.
pause
