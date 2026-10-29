@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
echo ==============================================
echo  GEKKO ARCHIVE - TEST PONT WINDOWS V0.5.0
 echo ==============================================
echo.
echo Ce test envoie une commande a la fenetre GEKKO ARCHIVE deja ouverte.
echo Aucun programme supplementaire n'est lance.
echo.
if not exist "src\App.jsx" (
 echo [ERREUR] Script non installe dans le dossier racine du projet.
 pause
 exit /b 7
)
findstr /C:"get_shell_launch" "src\App.jsx" >nul || (
 echo [ERREUR] Frontend V0.5.0 non installe : commande get_shell_launch absente.
 pause
 exit /b 8
)
findstr /C:"get_shell_launch" "src-tauri\src\lib.rs" >nul || (
 echo [ERREUR] Backend V0.5.0 non installe : commande get_shell_launch absente.
 pause
 exit /b 9
)
if "%~1"=="" (
 echo Glisse une archive ou un fichier sur ce fichier .bat.
 pause
 exit /b 2
)
if not exist "%~1" (
 echo [ERREUR] Fichier ou dossier source introuvable : "%~1"
 pause
 exit /b 3
)
set "source=%~f1"
echo Source : "%source%"
echo.
echo 1 = Ouvrir une archive
echo 2 = Compresser en ZIP
echo 3 = Compresser en 7z
echo 4 = Extraire ici
echo 5 = Extraire vers un dossier
set "action="
set /p "choice=Choix (1-5) : "
if "%choice%"=="1" set "action=open"
if "%choice%"=="2" set "action=zip"
if "%choice%"=="3" set "action=7z"
if "%choice%"=="4" set "action=extractHere"
if "%choice%"=="5" set "action=extractFolder"
if not defined action (
 echo Choix invalide.
 pause
 exit /b 4
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ENVOYER_PONT_WINDOWS_V050.ps1" -Action "%action%" -Source "%source%"
if errorlevel 1 (
 echo [ERREUR] Commande non transmise. Verifie le message ci-dessus.
 pause
 exit /b 5
)
echo.
echo Commande lue par GEKKO ARCHIVE. Regarde sa fenetre.
echo Ce test n'affirme pas que la commande a ete executee : verifie l'application.
pause
