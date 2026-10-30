# GEKKO ARCHIVE V0.7.1 - operation directe sans installer NSIS.
# Compile l'executable Tauri en mode release sans bundle, compile la DLL C++,
# signe MSIX 0.7.0.4 puis actualise uniquement l'installation Windows existante.
# Aucune modification des applications par defaut ou du certificat de confiance.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=$PSScriptRoot
$menu=Join-Path $root 'windows-context-menu-v060'
$packageName='GEKKOSoftware.GEKKOArchiveShell'
$publisher='CN=GEKKO-Archive-Dev'
$version=[version]'0.7.0.4'
$dllName='GEKKOArchiveContextV0704.dll'
$msixName='GEKKOArchiveShell-v0704.msix'
$stage=Join-Path $root 'src-tauri\target\gekko-menu-quiet-v071'
function Require([bool]$ok,[string]$reason) {if (-not $ok) {throw $reason}}
function Find-Sdk {
    $base=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    Require (Test-Path -LiteralPath $base -PathType Container) 'Windows SDK absent.'
    foreach ($item in @(Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name -Descending)) {
        $bin=Join-Path $item.FullName 'x64'
        $make=Join-Path $bin 'makeappx.exe';$sign=Join-Path $bin 'signtool.exe'
        if ((Test-Path -LiteralPath $make -PathType Leaf) -and (Test-Path -LiteralPath $sign -PathType Leaf)) {
            return @{Make=$make;Sign=$sign}
        }
    }
    throw 'MakeAppx/SignTool x64 introuvables.'
}
function Find-InstalledDir {
    $result=[System.Collections.Generic.List[string]]::new()
    foreach ($branch in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                          'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $branch)) {continue}
        foreach ($node in @(Get-ChildItem -LiteralPath $branch -ErrorAction SilentlyContinue)) {
            $info=Get-ItemProperty -LiteralPath $node.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $info) {continue}
            if ($null -eq $info.PSObject.Properties['DisplayName'] -or
                $null -eq $info.PSObject.Properties['InstallLocation']) { continue }
            $title=[string]$info.DisplayName
            $path=[string]$info.InstallLocation
            if ($title -notlike 'GEKKO ARCHIVE*' -or [string]::IsNullOrWhiteSpace($path)) {continue}
            $path=[IO.Path]::GetFullPath($path.Trim().Trim('"'))
            if ((Test-Path -LiteralPath (Join-Path $path 'gekko-archive.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $path 'windows-dist\REGISTER_MENU_V070.ps1') -PathType Leaf) -and
                -not $result.Contains($path)) { $result.Add($path) }
        }
    }
    if ($result.Count -eq 1) {return $result[0]}
    Write-Host 'Dossier installe non detecte de maniere unique.' -ForegroundColor Yellow
    foreach ($p in $result) {Write-Host (' - '+$p)}
    $manual=Read-Host 'Chemin complet du dossier GEKKO ARCHIVE installe (vide=annuler)'
    Require (-not [string]::IsNullOrWhiteSpace($manual)) 'Aucune installation selectionnee.'
    $path=[IO.Path]::GetFullPath($manual.Trim().Trim('"'))
    Require (Test-Path -LiteralPath (Join-Path $path 'gekko-archive.exe') -PathType Leaf) 'Executable installe introuvable.'
    Require (Test-Path -LiteralPath (Join-Path $path 'windows-dist\REGISTER_MENU_V070.ps1') -PathType Leaf) 'Dossier choisi non reconnu comme installation V0.7.0.'
    return $path
}
try {
    Require ([Environment]::OSVersion.Version.Build -ge 22000) 'Windows 11 requis.'
    Require ([Environment]::Is64BitOperatingSystem) 'Windows 11 x64 requis.'
    $installed=@(Get-AppxPackage -Name $packageName -ErrorAction Stop)
    Require ($installed.Count -eq 1 -and $installed[0].Publisher -eq $publisher) 'Le package du menu actif est absent ou inattendu.'
    Require ($installed[0].Version -ge [version]'0.7.0.2' -and $installed[0].Version -lt $version) 'Version du menu incompatible ou deja plus recente. Operation annulee.'
    $installDir=Find-InstalledDir
    $installedExe=Join-Path $installDir 'gekko-archive.exe'
    $installedDist=Join-Path $installDir 'windows-dist'
    Require (Test-Path -LiteralPath (Join-Path $root 'src-tauri\resources\7z.exe') -PathType Leaf) 'Moteur 7-Zip source absent.'
    Require (Test-Path -LiteralPath (Join-Path $root 'src-tauri\resources\7z.dll') -PathType Leaf) '7z.dll source absente.'
    $rust=[IO.File]::ReadAllText((Join-Path $root 'src-tauri\src\lib.rs'))
    $cpp=Join-Path $menu 'native\GEKKOArchiveContext.cpp'
    $cppText=[IO.File]::ReadAllText($cpp)
    Require ($rust.Contains('--gekko-shell-compress') -and $rust.Contains('--gekko-shell-extract')) 'Sources Rust des quatre actions silencieuses absentes.'
    Require ($cppText.Contains('StartBackgroundOperation') -and $cppText.Contains('--gekko-shell-compress')) 'Source DLL du clic droit non mise a jour.'
    $conf=Get-Content -LiteralPath (Join-Path $root 'src-tauri\tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Require ($conf.app.windows[0].width -eq 960 -and $conf.app.windows[0].height -eq 630) 'Parametres de petite fenetre absents.'
    $manifest=Join-Path $menu 'package\AppxManifest.xml'
    $manifestText=[IO.File]::ReadAllText($manifest)
    Require ($manifestText.Contains('Version="0.7.0.4"') -and $manifestText.Contains($dllName)) 'Manifeste de menu incorrect.'
    $assets=Join-Path $menu 'assets'
    Require (Test-Path -LiteralPath $assets -PathType Container) 'Images d extension du menu absentes.'
    $register=Join-Path $root 'src-tauri\windows-dist\REGISTER_MENU_V070.ps1'
    Require (Test-Path -LiteralPath $register -PathType Leaf) 'Script de desinstallation du menu absent.'
    $registerText=[IO.File]::ReadAllText($register)
    Require ($registerText.Contains('0.7.0.4') -and $registerText.Contains($dllName)) 'Script de desinstallation non mis a jour.'
    $running=@(Get-Process -Name 'gekko-archive' -ErrorAction SilentlyContinue)
    Require ($running.Count -eq 0) 'Ferme toutes les fenetres GEKKO ARCHIVE avant de continuer.'
    $certs=@(Get-ChildItem 'Cert:\CurrentUser\My' | Where-Object {
        $_.Subject -eq $publisher -and $_.HasPrivateKey -and $_.NotBefore -le (Get-Date) -and $_.NotAfter -gt (Get-Date)
    })
    $eligible=@($certs | Where-Object {
        $null -ne (Get-Item -LiteralPath ('Cert:\LocalMachine\TrustedPeople\'+$_.Thumbprint) -ErrorAction SilentlyContinue)
    })
    Require ($eligible.Count -eq 1) 'Certificat de developpement existant absent ou ambigu. Aucun certificat ne sera ajoute.'
    $cert=$eligible[0]
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    Require (Test-Path -LiteralPath $vswhere -PathType Leaf) 'Outils Visual Studio introuvables.'
    $vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    Require (-not [string]::IsNullOrWhiteSpace($vs)) 'Compilateur C++ x64 introuvable.'
    $vcvars=Join-Path $vs.Trim() 'VC\Auxiliary\Build\vcvars64.bat'
    Require (Test-Path -LiteralPath $vcvars -PathType Leaf) 'vcvars64.bat introuvable.'
    $sdk=Find-Sdk
    $npm=Get-Command npm.cmd -ErrorAction SilentlyContinue
    Require ($null -ne $npm) 'npm.cmd introuvable.'

    Write-Host 'GEKKO ARCHIVE : mise a jour directe V0.7.1, sans reconstruire/installateur NSIS.' -ForegroundColor Cyan
    Write-Host ('Menu actuellement actif : '+$installed[0].Version)
    Write-Host ('Dossier installe : '+$installDir) -ForegroundColor Yellow
    Write-Host 'Operations : compilation Tauri sans bundle, DLL C++, MSIX signe, copie dans installation existante.'
    Write-Host 'Aucun changement des applications par defaut ni du certificat de confiance.'
    $confirmation=Read-Host 'Saisis METTREAJOUR pour autoriser cette modification (autre=annuler)'
    if ($confirmation -cne 'METTREAJOUR') {Write-Host 'Annule sans modification.';exit 0}

    Write-Host '[1/4] Compilation C++ du menu...' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $dll=Join-Path $stage $dllName
    $obj=Join-Path $stage 'GEKKOArchiveContextV0704.obj'
    $cmd=Join-Path $stage 'compiler-menu-quiet-v071.cmd'
    $vcLine='call "{0}" >nul' -f $vcvars
    $clLine='cl.exe /nologo /std:c++17 /EHsc /O2 /W3 /LD /MT /utf-8 /Fo"{0}" /Fe"{1}" "{2}" ole32.lib shell32.lib shlwapi.lib user32.lib' -f $obj,$dll,$cpp
    $lines=[string[]]@('@echo off',$vcLine,'if errorlevel 1 exit /b 1',$clLine,'exit /b %ERRORLEVEL%')
    [IO.File]::WriteAllLines($cmd,$lines,[Text.UTF8Encoding]::new($false))
    $check=[string[]]@(Get-Content -LiteralPath $cmd -Encoding UTF8)
    Require ($check.Count -eq 5 -and $check[1] -ceq $vcLine -and $check[3] -ceq $clLine) 'Lignes du compilateur mal generees.'
    Push-Location -LiteralPath $stage
    try { & $env:ComSpec /d /c 'call compiler-menu-quiet-v071.cmd';$cppExit=$LASTEXITCODE }
    finally { Pop-Location }
    Require ($cppExit -eq 0 -and (Test-Path -LiteralPath $dll -PathType Leaf)) 'Compilation DLL echouee. Installation actuelle inchangee.'

    Write-Host '[2/4] Construction et signature du MSIX...' -ForegroundColor Cyan
    $msixStage=Join-Path $stage 'staging-msix'
    if (Test-Path -LiteralPath $msixStage) {Remove-Item -LiteralPath $msixStage -Recurse -Force}
    New-Item -ItemType Directory -Path $msixStage -Force | Out-Null
    Copy-Item -LiteralPath $manifest -Destination (Join-Path $msixStage 'AppxManifest.xml')
    Copy-Item -LiteralPath $dll -Destination (Join-Path $msixStage $dllName)
    Copy-Item -LiteralPath $assets -Destination (Join-Path $msixStage 'GEKKOArchiveAssets') -Recurse
    $msix=Join-Path $stage $msixName
    & $sdk.Make pack /o /d $msixStage /nv /p $msix
    Require ($LASTEXITCODE -eq 0) 'Echec MakeAppx. Installation actuelle inchangee.'
    & $sdk.Sign sign /fd SHA256 /sha1 $cert.Thumbprint /s My $msix
    Require ($LASTEXITCODE -eq 0) 'Signature du MSIX echouee. Installation actuelle inchangee.'
    $sig=Get-AuthenticodeSignature -LiteralPath $msix
    Require ($sig.Status -eq 'Valid' -and $null -ne $sig.SignerCertificate -and $sig.SignerCertificate.Thumbprint -eq $cert.Thumbprint) 'Signature MSIX invalide.'

    # Tauri 2 valide les ressources du bundle meme avec --no-bundle.
    # Produire la DLL et le MSIX AVANT d'appeler Tauri, et aligner leurs
    # noms avec les chemins declares dans tauri.conf.json.
    $sourceDist=Join-Path $root 'src-tauri\windows-dist'
    New-Item -ItemType Directory -Path $sourceDist -Force | Out-Null
    Copy-Item -LiteralPath $dll -Destination (Join-Path $sourceDist $dllName) -Force -ErrorAction Stop
    Copy-Item -LiteralPath $msix -Destination (Join-Path $sourceDist $msixName) -Force -ErrorAction Stop
    $sourceAssets=Join-Path $sourceDist 'GEKKOArchiveAssets'
    New-Item -ItemType Directory -Path $sourceAssets -Force | Out-Null
    foreach ($assetFile in @(Get-ChildItem -LiteralPath $assets -File)) {
        Copy-Item -LiteralPath $assetFile.FullName -Destination (Join-Path $sourceAssets $assetFile.Name) -Force -ErrorAction Stop
    }
    foreach ($resource in @($dllName,$msixName,'REGISTER_MENU_V070.ps1')) {
        Require (Test-Path -LiteralPath (Join-Path $sourceDist $resource) -PathType Leaf) ('Ressource de compilation absente : '+$resource)
    }
    foreach ($assetName in @('Square150x150Logo.png','Square44x44Logo.png','storelogo.png')) {
        Require (Test-Path -LiteralPath (Join-Path $sourceAssets $assetName) -PathType Leaf) ('Image de compilation absente : '+$assetName)
    }
    $sourceDllHash=(Get-FileHash -LiteralPath (Join-Path $sourceDist $dllName) -Algorithm SHA256).Hash
    Require ($sourceDllHash -eq (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash) 'DLL de compilation non identique a la DLL du menu.'
    $sourceMsixHash=(Get-FileHash -LiteralPath (Join-Path $sourceDist $msixName) -Algorithm SHA256).Hash
    Require ($sourceMsixHash -eq (Get-FileHash -LiteralPath $msix -Algorithm SHA256).Hash) 'MSIX de compilation non identique au MSIX signe.'
    Write-Host '[OK] Ressources Tauri presentes AVANT la compilation (DLL et MSIX 0.7.0.4).' -ForegroundColor Green

    Write-Host '[3/4] Compilation Tauri sans installateur NSIS...' -ForegroundColor Cyan
    $buildStarted=Get-Date
    Push-Location -LiteralPath $root
    try { & $npm.Source run tauri build -- --no-bundle; $buildExit=$LASTEXITCODE }
    finally { Pop-Location }
    Require ($buildExit -eq 0) 'Compilation Tauri echouee. Installation actuelle inchangee.'
    $newExe=Join-Path $root 'src-tauri\target\release\gekko-archive.exe'
    Require (Test-Path -LiteralPath $newExe -PathType Leaf) 'Executable recompilé introuvable.'
    $newExeFile=Get-Item -LiteralPath $newExe
    Require ($newExeFile.LastWriteTime -ge $buildStarted.AddSeconds(-5)) 'Executable trop ancien : recompilation non confirmee.'

    Write-Host '[4/4] Mise a jour des fichiers installes et du menu...' -ForegroundColor Cyan
    $backupDir=Join-Path $env:LOCALAPPDATA ('GEKKO_ARCHIVE\sauvegarde_avant_menu_quiet_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backupExe=Join-Path $backupDir 'gekko-archive.exe'
    $backupRegister=Join-Path $backupDir 'REGISTER_MENU_V070.ps1'
    Copy-Item -LiteralPath $installedExe -Destination $backupExe -Force
    $installedRegister=Join-Path $installedDist 'REGISTER_MENU_V070.ps1'
    Copy-Item -LiteralPath $installedRegister -Destination $backupRegister -Force
    $applied=$false
    $packageUpdated=$false
    try {
        Copy-Item -LiteralPath $newExe -Destination $installedExe -Force -ErrorAction Stop
        Require ((Get-FileHash -LiteralPath $newExe -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash) 'Copie du nouvel executable non verifiee.'
        Copy-Item -LiteralPath $dll -Destination (Join-Path $installDir $dllName) -Force -ErrorAction Stop
        Copy-Item -LiteralPath $dll -Destination (Join-Path $installedDist $dllName) -Force -ErrorAction Stop
        Copy-Item -LiteralPath $msix -Destination (Join-Path $installedDist $msixName) -Force -ErrorAction Stop
        Copy-Item -LiteralPath $register -Destination $installedRegister -Force -ErrorAction Stop
        $installedAssets=Join-Path $installedDist 'GEKKOArchiveAssets'
        if (-not (Test-Path -LiteralPath $installedAssets -PathType Container)) {
            Copy-Item -LiteralPath $assets -Destination $installedAssets -Recurse -Force -ErrorAction Stop
        }
        Add-AppxPackage -Path $msix -ExternalLocation $installDir -ErrorAction Stop
        $packageUpdated=$true
        $updated=@(Get-AppxPackage -Name $packageName -ErrorAction Stop)
        Require ($updated.Count -eq 1 -and $updated[0].Version -eq $version) 'Mise a jour du MSIX non confirmee.'
        $applied=$true
    } finally {
        if (-not $applied) {
            if (-not $packageUpdated) {
                # Le menu Windows reste enregistre sur son ancienne version.
                Copy-Item -LiteralPath $backupExe -Destination $installedExe -Force -ErrorAction Continue
                Copy-Item -LiteralPath $backupRegister -Destination $installedRegister -Force -ErrorAction Continue
            } else {
                Write-Host 'Attention : MSIX installe mais controle final non concluant. Ne pas restaurer l EXE sans examen du package.' -ForegroundColor Red
            }
            Write-Host ('Sauvegarde des anciens fichiers : '+$backupDir) -ForegroundColor Yellow
        }
    }
    Write-Host '[OK] GEKKO ARCHIVE actualise, sans fabriquer d installateur NSIS.' -ForegroundColor Green
    Write-Host ('MSIX du menu : '+$version) -ForegroundColor Green
    Write-Host 'Commandes : ZIP/7z et extractions sans interface ; Ouvrir conserve la fenetre.'
    Write-Host 'Ouverture normale : fenetre 960 x 630.'
    Write-Host ('Sauvegarde locale de secours : '+$backupDir)
    Write-Host 'Si Explorer conserve un ancien menu, redemarre uniquement Explorer Windows.' -ForegroundColor Yellow
    exit 0
} catch {
    Write-Host ('[ECHEC] '+$_.Exception.Message) -ForegroundColor Red
    Write-Host 'Aucun installateur NSIS n a ete construit. Aucun certificat de confiance n a ete modifie.' -ForegroundColor Yellow
    exit 1
}
