@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
title GEKKO ARCHIVE - Recompilation du pont Windows V0.5.0
echo =============================================
echo    GEKKO ARCHIVE - Pont Windows V0.5.0
echo =============================================
echo.
if not exist "LANCER_GEKKO_ARCHIVE.bat" (
  echo [ERREUR] Place le correctif A LA RACINE du projet.
  pause
  exit /b 1
)
if not exist "src-tauri\src\lib.rs" (
  echo [ERREUR] Backend Rust introuvable.
  pause
  exit /b 1
)
findstr /C:"fn shell_queued_launch()" "src-tauri\src\lib.rs" >nul
if errorlevel 1 (
  echo [ERREUR] Le bon fichier Rust V0.5.0 n est pas installe.
  echo Redecompresse le correctif complet dans ton projet.
  pause
  exit /b 2
)
findstr /C:"receiveWindowsCommand" "src\App.jsx" >nul
if errorlevel 1 (
  echo [ERREUR] Le frontend du pont Windows est absent.
  pause
  exit /b 3
)
tasklist /FI "IMAGENAME eq gekko-archive.exe" /NH 2>nul | find /I "gekko-archive.exe" >nul
if not errorlevel 1 (
  echo [ERREUR] GEKKO ARCHIVE tourne encore.
  echo Ferme l application ET sa console, puis relance ce script.
  pause
  exit /b 4
)
where cargo >nul 2>nul
if errorlevel 1 (
  echo [ERREUR] Cargo est introuvable dans le PATH.
  pause
  exit /b 5
)
where npm >nul 2>nul
if errorlevel 1 (
  echo [ERREUR] NPM est introuvable dans le PATH.
  pause
  exit /b 6
)
echo Backend et frontend V0.5.0 confirms.
echo Recompilation ciblée du programme GEKKO ARCHIVE.
echo Les dependances Rust, node_modules et les modeles ne seront pas effaces.
echo.
pushd "src-tauri"
call cargo clean -p gekko-archive
set "clean_result=%errorlevel%"
popd
if not "%clean_result%"=="0" (
  echo [ERREUR] Nettoyage cible du paquet Rust impossible.
  echo Aucune reconstruction generale n a ete effectuee.
  pause
  exit /b 7
)
echo.
echo Lancement de GEKKO ARCHIVE et compilation du backend actualise...
call "LANCER_GEKKO_ARCHIVE.bat"
if errorlevel 1 (
  echo [ERREUR] GEKKO ARCHIVE n a pas pu demarrer correctement.
  pause
  exit /b 8
)
