@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ======================================
echo  GEKKO ARCHIVE - MOTEUR 7-ZIP
 echo ======================================
echo Installation locale des fichiers 7-Zip sans modifier Windows.
echo Source : 7-Zip Extra 26.05, officiel, gratuit.
echo Une connexion Internet est requise pour cette preparation unique.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALLER_MOTEUR_7ZIP.ps1"
if errorlevel 1 (
  echo.
  echo La preparation du moteur a echoue. Consulte le message ci-dessus.
  pause
  exit /b 1
)
echo.
echo Preparation terminee. Tu peux relancer GEKKO ARCHIVE.
pause
