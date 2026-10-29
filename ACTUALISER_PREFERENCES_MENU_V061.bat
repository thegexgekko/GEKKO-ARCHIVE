@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo ==============================================
echo GEKKO ARCHIVE V0.6.1 - PREFERENCES CLIC DROIT
echo ==============================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-context-menu-v060\ACTUALISER_PREFERENCES_MENU_V061.ps1"
if errorlevel 1 (
  echo.
  echo [ECHEC] Lis le message ci-dessus. L'ancien menu reste installe.
) else (
  echo.
  echo [OK] Mise a jour terminee, lance GEKKO ARCHIVE.
)
echo.
pause
endlocal
