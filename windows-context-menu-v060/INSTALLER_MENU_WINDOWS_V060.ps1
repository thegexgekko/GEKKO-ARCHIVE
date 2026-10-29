# GEKKO ARCHIVE — test per-user du menu moderne Windows 11.
# Prérequis : Visual Studio C++ x64, Windows SDK (MakeAppx + SignTool),
#            GEKKO ARCHIVE V0.5.0 déjà compilé/lancé au moins une fois.
# Aucune modification du code React/Rust. Ne touche pas à l'Explorateur avant accord.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PackageName = 'GEKKOSoftware.GEKKOArchiveShell'
$CertSubject = 'CN=GEKKO-Archive-Dev'
$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here '..')).Path
$build = Join-Path $here 'build'
$source = Join-Path $here 'bootstrap-v0600\GEKKOArchiveContext.cpp'
$manifest = Join-Path $here 'bootstrap-v0600\AppxManifest.xml'
$assets = Join-Path $here 'assets'

function Require([bool] $ok, [string] $message) { if (-not $ok) { throw $message } }
function Get-SDKTools {
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    Require (Test-Path -LiteralPath $kits) 'Windows SDK introuvable (Windows Kits\10\bin). Installer le SDK via Visual Studio.'
    $versions = @(Get-ChildItem -LiteralPath $kits -Directory | Sort-Object Name -Descending)
    foreach ($v in $versions) {
        $folder = Join-Path $v.FullName 'x64'
        $a = Join-Path $folder 'makeappx.exe'
        $b = Join-Path $folder 'signtool.exe'
        if ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b)) { return @{ MakeAppx=$a; SignTool=$b } }
    }
    throw 'MakeAppx.exe et SignTool.exe x64 introuvables. Ajouter les outils de packaging du Windows SDK.'
}
try {
    Require (([Environment]::OSVersion.Version.Build -ge 22000)) 'Windows 11 requis.'
    Require ([Environment]::Is64BitOperatingSystem) 'Windows 11 x64 requis.'
    Require (Test-Path -LiteralPath (Join-Path $root 'src-tauri\src\lib.rs')) 'Installe le correctif a la racine du projet GEKKO ARCHIVE.'
    $core = Get-Content -LiteralPath (Join-Path $root 'src-tauri\src\lib.rs') -Raw
    Require ($core.Contains('shell_queued_launch') -and $core.Contains('get_shell_launch')) 'Le backend du pont V0.5.0 n''est pas présent dans le projet.'
    $existing = @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)
    Require ($existing.Count -eq 0) 'Un menu GEKKO ARCHIVE est déjà installé. Utilise d''abord DESINSTALLER_MENU_WINDOWS_V060.bat.'
    $externals = @((Join-Path $root 'src-tauri\target\debug'), (Join-Path $root 'src-tauri\target\release'))
    $external = $null
    foreach ($dir in $externals) {
        if (Test-Path -LiteralPath (Join-Path $dir 'gekko-archive.exe')) { $external=$dir; break }
    }
    Require ($null -ne $external) 'gekko-archive.exe introuvable. Lance une fois LANCER_GEKKO_ARCHIVE.bat et attends la compilation.'
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    Require (Test-Path -LiteralPath $vswhere) 'Visual Studio / vswhere introuvable.'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    Require (-not [string]::IsNullOrWhiteSpace($vs)) 'Outils de développement C++ x64 manquants dans Visual Studio.'
    $vcvars = Join-Path $vs.Trim() 'VC\Auxiliary\Build\vcvars64.bat'
    Require (Test-Path -LiteralPath $vcvars) 'vcvars64.bat introuvable dans Visual Studio.'
    $sdk = Get-SDKTools
    New-Item -ItemType Directory -Path $build -Force | Out-Null
    Write-Host '[1/5] Compilation de l''extension native C++ x64...' -ForegroundColor Cyan
    $dll = Join-Path $build 'GEKKOArchiveContextV060.dll'
    $obj = Join-Path $build 'GEKKOArchiveContext.obj'
    $cmdFile = Join-Path $build 'compiler_gekkocontext.cmd'
    # Utiliser un here-string PowerShell : les caracteres CMD >nul,
    # les guillemets et les virgules restent du texte, pas de la syntaxe PS.
    $cmdText = @"
@echo off
chcp 65001 >nul
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl.exe /nologo /std:c++17 /EHsc /O2 /W3 /LD /MT /utf-8 /Fo"$obj" /Fe"$dll" "$source" ole32.lib shell32.lib shlwapi.lib user32.lib
exit /b %ERRORLEVEL%
"@
    [System.IO.File]::WriteAllText($cmdFile, $cmdText + [Environment]::NewLine, ([System.Text.UTF8Encoding]::new($false)))
    Push-Location $build
    try { & $env:ComSpec /d /c ('"' + $cmdFile + '"'); Require ($LASTEXITCODE -eq 0) 'Compilation C++ échouée, consulter les erreurs ci-dessus.' }
    finally { Pop-Location }
    Require (Test-Path -LiteralPath $dll) 'La DLL n''a pas été produite.'

    Write-Host '[2/5] Préparation du package d''identité Windows...' -ForegroundColor Cyan
    $assetTarget = Join-Path $external 'GEKKOArchiveAssets'
    New-Item -ItemType Directory -Path $assetTarget -Force | Out-Null
    foreach($filename in @('Square150x150Logo.png','Square44x44Logo.png','storelogo.png')) {
        Copy-Item -LiteralPath (Join-Path $assets $filename) -Destination (Join-Path $assetTarget $filename) -Force
    }
    $packageDir = Join-Path $build 'package-staging'
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    Copy-Item -LiteralPath $manifest -Destination (Join-Path $packageDir 'AppxManifest.xml') -Force
    Copy-Item -LiteralPath $dll -Destination (Join-Path $packageDir 'GEKKOArchiveContextV060.dll') -Force
    Copy-Item -LiteralPath $assets -Destination (Join-Path $packageDir 'GEKKOArchiveAssets') -Recurse -Force
    $msix = Join-Path $build 'GEKKOArchiveShell-v060.msix'
    $makeappx = $sdk['MakeAppx']
    & $makeappx pack /o /d $packageDir /nv /p $msix
    Require ($LASTEXITCODE -eq 0) 'MakeAppx a rejeté le manifeste. Aucun package installé.'

    Write-Host '[3/5] Signature du package de test...' -ForegroundColor Cyan
    $cert = @(Get-ChildItem -Path 'Cert:\CurrentUser\My' | Where-Object {
        $_.Subject -eq $CertSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(10)
    } | Sort-Object NotAfter -Descending | Select-Object -First 1)
    if ($cert.Count -eq 0) {
        $identityCert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject -CertStoreLocation 'Cert:\CurrentUser\My' -KeyUsage DigitalSignature -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(1)
    } else { $identityCert = $cert[0] }
    $signtool = $sdk['SignTool']
    & $signtool sign /fd SHA256 /sha1 $identityCert.Thumbprint /s My $msix
    Require ($LASTEXITCODE -eq 0) 'Échec de signature du package. Aucun menu installé.'

    Write-Host ''
    Write-Host 'ATTENTION : Windows exige un certificat reconnu pour ce package MSIX.' -ForegroundColor Yellow
    Write-Host 'Le test ajoutera un certificat de développement GEKKO au magasin' -ForegroundColor Yellow
    Write-Host 'TrustedPeople de TON compte uniquement (pas au magasin système).' -ForegroundColor Yellow
    Write-Host 'La commande de désinstallation peut ensuite le retirer.' -ForegroundColor Yellow
    Write-Host ('Chemin de l''application : ' + $external)
    Write-Host 'Aucune modification des commandes du moteur ZIP/7z.'
    $decision = Read-Host 'Pour autoriser l''installation locale, écris exactement INSTALLER'
    if ($decision -cne 'INSTALLER') { Write-Host 'Installation annulée. Aucun menu enregistré.'; exit 0 }
    Write-Host '[4/5] Approbation du certificat pour ton compte...' -ForegroundColor Cyan
    $cer = Join-Path $build 'GEKKOArchiveDev.cer'
    Export-Certificate -Cert $identityCert -FilePath $cer -Force | Out-Null
    $trusted = @(Get-ChildItem -Path 'Cert:\CurrentUser\TrustedPeople' | Where-Object Thumbprint -eq $identityCert.Thumbprint)
    if ($trusted.Count -eq 0) { Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\CurrentUser\TrustedPeople' | Out-Null }

    Write-Host '[5/5] Installation du sous-menu Windows 11...' -ForegroundColor Cyan
    Add-AppxPackage -Path $msix -ExternalLocation $external -ErrorAction Stop
    $added = @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)
    Require ($added.Count -gt 0) 'La commande d''installation est revenue sans package GEKKO enregistré.'
    Write-Host 'Installation enregistrée pour ce compte.' -ForegroundColor Green
    Write-Host 'Garde GEKKO ARCHIVE OUVERT, puis clic droit sur un ZIP ou un 7z.' -ForegroundColor Green
    Write-Host 'Si le menu n''apparaît pas immédiatement, rouvre l''Explorateur Windows ou reconnecte-toi.'
    Write-Host 'Pour annuler le test : DESINSTALLER_MENU_WINDOWS_V060.bat'
    exit 0
} catch {
    Write-Host ('[ERREUR] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Aucun fichier React ou Rust n''a été modifié.'
    exit 1
}
