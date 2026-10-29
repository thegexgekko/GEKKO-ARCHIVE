@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo [GEKKO ARCHIVE] Preparation et demarrage de l'application Windows...
where npm >nul 2>nul || (echo Node.js / npm introuvable. & pause & exit /b 1)
where cargo >nul 2>nul || (echo Rust / Cargo introuvable. & pause & exit /b 1)
if not exist "node_modules\" (
  echo Installation initiale des dependances de developpement...
  call npm install --no-audit --no-fund || (pause & exit /b 1)
)
call npm run tauri dev
if errorlevel 1 pause
