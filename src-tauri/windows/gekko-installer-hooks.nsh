; GEKKO ARCHIVE V0.7.0 - installation par utilisateur, sans elevation.
; Tauri conserve la gestion de l'application et des associations de fichiers.
!macro NSIS_HOOK_POSTINSTALL
  MessageBox MB_YESNO|MB_ICONQUESTION "Activer le menu contextuel moderne GEKKO ARCHIVE dans Windows 11 ?$\r$\nCette option utilise uniquement le certificat de developpement GEKKO deja approuve sur ce PC. Aucun certificat n'est installe automatiquement." IDNO gekko_shell_postinstall_end
  ${If} ${FileExists} "$INSTDIR\windows-dist\REGISTER_MENU_V070.ps1"
    nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\windows-dist\REGISTER_MENU_V070.ps1" -Action install -InstallDir "$INSTDIR"'
    Pop $0
    Pop $1
    ${If} "$0" != "0"
      DetailPrint "GEKKO : menu contextuel non active (code $0)."
      MessageBox MB_OK|MB_ICONEXCLAMATION "GEKKO ARCHIVE est installe, mais le menu contextuel n'a pas pu etre active.$\r$\nVerifie le certificat GEKKO et consulte le journal dans %LOCALAPPDATA%\GEKKO_ARCHIVE."
    ${EndIf}
  ${Else}
    MessageBox MB_OK|MB_ICONEXCLAMATION "Script de menu contextuel absent. Application installee sans extension."
  ${EndIf}
  gekko_shell_postinstall_end:
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  ; Desinscrire AVANT que NSIS ne retire le code COM de l'extension.
  ${If} ${FileExists} "$INSTDIR\windows-dist\REGISTER_MENU_V070.ps1"
    nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\windows-dist\REGISTER_MENU_V070.ps1" -Action remove -InstallDir "$INSTDIR"'
    Pop $0
    Pop $1
    ${If} "$0" != "0"
      MessageBox MB_OK|MB_ICONSTOP "Le menu Windows 11 n'a pas pu etre desinstalle correctement.$\r$\nDesinstallation GEKKO interrompue afin de ne pas laisser un module COM orphelin."
      Abort
    ${EndIf}
  ${EndIf}
!macroend
