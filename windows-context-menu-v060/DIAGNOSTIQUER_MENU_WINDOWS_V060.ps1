# GEKKO ARCHIVE V0.6.0 - Diagnostic du menu Windows 11, lecture seule.
# Aucune installation, recompilation, elevation ou modification du registre.
$ErrorActionPreference = 'Stop'
$packageName = 'GEKKOSoftware.GEKKOArchiveShell'
$clsid = '348348C7-F21A-4D5F-8E16-35C9F55212D4'
$dllName = 'GEKKOArchiveContextV060.dll'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$report = Join-Path $here 'DIAGNOSTIC_MENU_WINDOWS_V060_RESULTAT.txt'
$messages = New-Object 'System.Collections.Generic.List[string]'
$issues = New-Object 'System.Collections.Generic.List[string]'
function Say([string]$value) {
    $messages.Add($value)
    Write-Host $value
}
function Check([bool]$ok, [string]$yes, [string]$no) {
    if ($ok) { Say ('[OK] ' + $yes) }
    else { Say ('[ANOMALIE] ' + $no); $issues.Add($no) }
}
Say 'GEKKO ARCHIVE - DIAGNOSTIC MENU WINDOWS 11 - V0.6.0'
Say 'Lecture seule : aucun changement systeme, aucun administrateur necessaire.'
Say ('Date locale : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ('Windows : ' + [Environment]::OSVersion.Version.ToString())
Say ''
try {
    $pkgs = @(Get-AppxPackage -Name $packageName -ErrorAction Stop)
    if ($pkgs.Count -eq 0) {
        Check $false '' 'Package GEKKO absent pour le compte actuellement connecte.'
    } elseif ($pkgs.Count -gt 1) {
        Check $false '' 'Plusieurs packages GEKKO correspondent au meme nom.'
    } else {
        $p = $pkgs[0]
        Check $true 'Package GEKKO installe pour ce compte.' ''
        Say ('  Nom : ' + $p.Name)
        Say ('  Version : ' + $p.Version)
        Say ('  Etat : ' + $p.Status)
        Say ('  Famille : ' + $p.PackageFamilyName)
        Say ('  Repertoire MSIX : ' + $p.InstallLocation)
        Check (($p.Status.ToString() -eq 'Ok')) 'Package signale comme operationnel par Windows.' 'Le package n a pas le statut Ok.'
        $xml = $null
        try { $xml = Get-AppxPackageManifest -Package $p.PackageFullName -ErrorAction Stop }
        catch { Check $false '' ('Manifest installe inaccessible : ' + $_.Exception.Message) }
        if ($xml) {
            $classes = @($xml.SelectNodes("//*[local-name()='Extension' and @Category='windows.comServer']//*[local-name()='Class']"))
            $verbs = @($xml.SelectNodes("//*[local-name()='Extension' and @Category='windows.fileExplorerContextMenus']//*[local-name()='Verb']"))
            Say ('  Classes COM : ' + $classes.Count)
            Say ('  Verbes de menu : ' + $verbs.Count)
            Check ($classes.Count -eq 5 -and $verbs.Count -ge 5) 'Declarations COM et menu retrouvees dans le manifest installe.' 'Declarations COM/menu absentes ou incompletes dans le manifest installe.'
            $comIds = @($classes | ForEach-Object { [string]$_.GetAttribute('Id') })
            $verbIds = @($verbs | ForEach-Object { [string]$_.GetAttribute('Clsid') })
            Check ($comIds -contains $clsid -and $verbIds -contains $clsid) 'CLSID principal identique dans les deux declarations.' 'CLSID principal absent ou incoherent entre COM et menu.'
            $unmatched = @($verbIds | Where-Object { $comIds -notcontains $_ })
            Check ($unmatched.Count -eq 0) 'Chaque commande du menu possede une classe COM.' 'Certaines commandes ne correspondent a aucune classe COM.'
            $app = @($xml.SelectNodes("//*[local-name()='Application']")) | Select-Object -First 1
            if ($app) { Say ('  Executable declare : ' + $app.GetAttribute('Executable')) }
            $externalContent = @($xml.SelectNodes("//*[local-name()='AllowExternalContent']"))
            Check ($externalContent.Count -ge 1) 'Manifeste declare AllowExternalContent pour le package sparse.' 'AllowExternalContent absent du manifeste installe.'
            $dllClasses = @($classes | Where-Object { [string]$_.GetAttribute('Path') -ne $dllName })
            Check ($dllClasses.Count -eq 0) 'Toutes les classes COM pointent sur la DLL attendue.' 'Chemin de DLL inattendu pour une ou plusieurs classes COM.'
        }
        if ($p.InstallLocation) {
            $packagedDll = Join-Path $p.InstallLocation $dllName
            Say ('  DLL dans le repertoire MSIX : ' + $(if (Test-Path -LiteralPath $packagedDll -PathType Leaf -ErrorAction SilentlyContinue) {'PRESENTE'} else {'NON VISIBLE / ACCES REFUSE'}))
        }
    }
} catch {
    Check $false '' ('Lecture du package echouee : ' + $_.Exception.Message)
}
Say ''
Say 'EMPLACEMENT DES BINAIRES'
$extDirs = @((Join-Path $root 'src-tauri\target\debug'),(Join-Path $root 'src-tauri\target\release'))
$exeFound = $false
$dllFound = $false
foreach ($dir in $extDirs) {
    $exe = Join-Path $dir 'gekko-archive.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        $exeFound = $true
        Say ('  Executable GEKKO : ' + $exe)
        $dll = Join-Path $dir $dllName
        if (Test-Path -LiteralPath $dll -PathType Leaf) {
            $dllFound = $true
            Say ('  DLL de menu : ' + $dll)
            Say ('  Taille DLL : ' + (Get-Item -LiteralPath $dll).Length + ' octets')
        } else { Say ('  DLL absente a cote de cet executable : ' + $dll) }
    }
}
Check $exeFound 'Executable GEKKO trouve.' 'Executable GEKKO introuvable sous src-tauri/target.'
Check $dllFound 'DLL de menu trouvee a cote d au moins un executable GEKKO.' 'DLL absente des dossiers habituels de l application.'
$buildDll = Join-Path $here ('build\' + $dllName)
if (Test-Path -LiteralPath $buildDll -PathType Leaf) {
    $buildHash = (Get-FileHash -LiteralPath $buildDll -Algorithm SHA256).Hash
    Say '  DLL compilee par l installateur : PRESENTE'
    foreach ($dir in $extDirs) {
        $dll = Join-Path $dir $dllName
        if (Test-Path -LiteralPath $dll -PathType Leaf) {
            Check ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -eq $buildHash) 'DLL externe identique a la derniere DLL compilee.' 'DLL externe differente de la derniere DLL compilee.'
        }
    }
} else { Say '  DLL compilee dans le dossier build : NON TROUVEE' }
Say ''
Say 'JOURNAL WINDOWS RECENT (INFORMATIF)'
$logs = @('Microsoft-Windows-AppModel-Runtime/Admin','Microsoft-Windows-AppXDeploymentServer/Operational')
$hits = 0
foreach($log in $logs) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{LogName=$log; StartTime=(Get-Date).AddDays(-2)} -MaxEvents 100 -ErrorAction Stop |
          Where-Object { $_.Message -match 'GEKKOArchive|GEKKOSoftware|348348C7|GEKKO-Archive-Dev' } |
          Select-Object -First 4)
        foreach ($ev in $events) {
            $hits++
            $oneLine = (($ev.Message -replace '\s+', ' ').Trim())
            if ($oneLine.Length -gt 280) { $oneLine = $oneLine.Substring(0,280) + '...' }
            Say ('  [' + $log + ' #' + $ev.Id + '] ' + $oneLine)
        }
    } catch { Say ('  Journal inaccessible/sans evenement : ' + $log) }
}
if ($hits -eq 0) { Say '  Aucun evenement GEKKO pertinent trouve dans les journaux consultes.' }
Say ''
Say 'BILAN'
if ($issues.Count -gt 0) {
    Say ('  ' + $issues.Count + ' anomalie(s) detectee(s).')
    foreach ($issue in $issues) { Say ('  - ' + $issue) }
} else {
    Say '  Enregistrement de base coherent. Si le menu est absent, le chargement COM ou GetState est a examiner.'
    Say '  ATTENTION : ce bilan ne prouve pas que la DLL a ete activee par l Explorateur.'
}
try {
    [System.IO.File]::WriteAllLines($report, $messages.ToArray(), [System.Text.UTF8Encoding]::new($true))
    Write-Host ''
    Write-Host ('RAPPORT ENREGISTRE : ' + $report) -ForegroundColor Green
} catch { Write-Host ('Impossible de sauvegarder le rapport : ' + $_.Exception.Message) -ForegroundColor Yellow }
Write-Host 'Aucun composant Windows ou GEKKO n a ete modifie.' -ForegroundColor Cyan
