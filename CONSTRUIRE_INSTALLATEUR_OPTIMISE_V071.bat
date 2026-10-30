@echo off
setlocal
cd /d "%~dp0"
echo GEKKO ARCHIVE - reconstruction de l installateur V0.7.1 avec optimisation du demarrage
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CONSTRUIRE_INSTALLATEUR_OPTIMISE_V071.ps1"
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" echo [ECHEC] Installation existante inchangee.
pause
exit /b %CODE%
