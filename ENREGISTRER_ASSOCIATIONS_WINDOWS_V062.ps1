# GEKKO ARCHIVE - enregistrement facultatif pour Windows 11 (compte actuel).
# N'ecrit JAMAIS dans UserChoice et ne remplace aucun programme par defaut.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$exe = $null
foreach ($mode in @('release','debug')) {
    $candidate = Join-Path $root ("src-tauri\target\$mode\gekko-archive.exe")
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $exe = (Resolve-Path -LiteralPath $candidate).Path; break }
}
if (-not $exe) {
    Write-Host '[ERREUR] Executable GEKKO ARCHIVE introuvable.' -ForegroundColor Red
    Write-Host 'Lance LANCER_GEKKO_ARCHIVE.bat pour compiler l application, puis reessaie.'
    exit 1
}
$progId = 'GEKKOArchive.Archive'
$reg = [Microsoft.Win32.Registry]::CurrentUser
$base='Software\Classes'
$capPath='Software\GEKKO SOFTWARE\GEKKO ARCHIVE\Capabilities'
$types=@('.zip','.7z','.rar','.tar')
Write-Host 'GEKKO ARCHIVE - Associations optionnelles' -ForegroundColor Cyan
Write-Host ('Executable : ' + $exe)
Write-Host 'Formats proposes : ZIP, 7z, RAR, TAR.'
if ($exe -match '\\target\\debug\\') {
    Write-Host '[IMPORTANT] Executable de developpement detecte.' -ForegroundColor Yellow
    Write-Host 'Le double-clic fonctionne quand GEKKO ARCHIVE et son serveur Tauri/Vite sont deja lances.' -ForegroundColor Yellow
    Write-Host 'Pour un demarrage autonome apres fermeture, il faudra une version Windows compilee pour distribution.' -ForegroundColor Yellow
}
Write-Host 'WinRAR et les applications deja choisies resteront par defaut tant que tu ne les changes pas.'
$accept=Read-Host 'Pour enregistrer GEKKO ARCHIVE comme application compatible, ecris ENREGISTRER'
if($accept -cne 'ENREGISTRER'){Write-Host 'Aucun changement.';exit 0}
try {
    $p=$reg.CreateSubKey("$base\$progId")
    $p.SetValue('', 'Archives prises en charge par GEKKO ARCHIVE')
    $p.Close()
    $k=$reg.CreateSubKey("$base\$progId\DefaultIcon")
    $k.SetValue('', ('"'+$exe+'",0'))
    $k.Close()
    $k=$reg.CreateSubKey("$base\$progId\shell\open\command")
    $k.SetValue('', ('"'+$exe+'" "%1"'))
    $k.Close()
    $cap=$reg.CreateSubKey($capPath)
    $cap.SetValue('ApplicationName','GEKKO ARCHIVE')
    $cap.SetValue('ApplicationDescription','Gestionnaire d archives local ZIP, 7z, RAR et TAR.')
    $cap.Close()
    $assoc=$reg.CreateSubKey("$capPath\FileAssociations")
    foreach($ext in $types){$assoc.SetValue($ext,$progId)}
    $assoc.Close()
    $apps=$reg.CreateSubKey('Software\RegisteredApplications')
    $apps.SetValue('GEKKO ARCHIVE',$capPath)
    $apps.Close()
    foreach($ext in $types){
        $openwith=$reg.CreateSubKey("$base\$ext\OpenWithProgids")
        $openwith.SetValue($progId,[byte[]]@(),[Microsoft.Win32.RegistryValueKind]::None)
        $openwith.Close()
    }
    Write-Host '[OK] GEKKO ARCHIVE enregistre comme application compatible.' -ForegroundColor Green
    Write-Host 'Dans Windows : Parametres > Applications > Applications par defaut.'
    Write-Host 'Choisis GEKKO ARCHIVE pour chaque extension souhaitee.'
    Write-Host 'Aucune association par defaut n a ete forcee.' -ForegroundColor Yellow
    $choice=Read-Host 'Ouvrir maintenant les parametres Applications par defaut ? (O/N)'
    if($choice -ieq 'O'){Start-Process 'ms-settings:defaultapps'}
    exit 0
} catch {
    Write-Host ('[ERREUR] '+$_.Exception.Message) -ForegroundColor Red
    exit 1
}
