# GEKKO ARCHIVE - retrait des seules inscriptions faites pour les associations.
# Ne modifie pas les choix UserChoice de Windows ni les inscriptions d'autres logiciels.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$reg=[Microsoft.Win32.Registry]::CurrentUser
$prog='GEKKOArchive.Archive'
$cap='Software\GEKKO SOFTWARE\GEKKO ARCHIVE\Capabilities'
Write-Host 'Retirer les inscriptions facultatives GEKKO ARCHIVE du compte Windows ?' -ForegroundColor Yellow
$answer=Read-Host 'Ecris RETIRER pour confirmer'
if($answer -cne 'RETIRER'){Write-Host 'Aucun changement.';exit 0}
try {
    foreach($ext in @('.zip','.7z','.rar','.tar')){
        $openwith=$reg.OpenSubKey('Software\Classes\'+$ext+'\OpenWithProgids',$true)
        if($openwith){
            if($openwith.GetValueNames() -contains $prog){$openwith.DeleteValue($prog,$false)}
            $openwith.Close()
        }
    }
    $apps=$reg.OpenSubKey('Software\RegisteredApplications',$true)
    if($apps){
        if($apps.GetValue('GEKKO ARCHIVE') -eq $cap){$apps.DeleteValue('GEKKO ARCHIVE',$false)}
        $apps.Close()
    }
    $reg.DeleteSubKeyTree('Software\Classes\'+$prog,$false)
    $reg.DeleteSubKeyTree('Software\GEKKO SOFTWARE\GEKKO ARCHIVE\Capabilities',$false)
    Write-Host '[OK] Inscriptions GEKKO ARCHIVE retirees.' -ForegroundColor Green
    Write-Host 'Les choix par defaut de Windows ne sont pas modifies par ce script.'
} catch {Write-Host ('[ERREUR] '+$_.Exception.Message) -ForegroundColor Red;exit 1}
