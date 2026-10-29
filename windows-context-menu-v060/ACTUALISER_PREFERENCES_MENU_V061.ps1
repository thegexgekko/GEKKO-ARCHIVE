# GEKKO ARCHIVE - actualisation ciblee du menu Windows 11 (MSIX 0.6.0.2).
# Aucun changement React/Rust, aucun nouveau certificat, pas de suppression du package actuel.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = (Resolve-Path -LiteralPath (Join-Path $here '..')).Path
$build = Join-Path $here 'build'
$packageName = 'GEKKOSoftware.GEKKOArchiveShell'
$expectedPublisher = 'CN=GEKKO-Archive-Dev'
function Require([bool]$ok, [string]$msg) { if (-not $ok) { throw $msg } }
function Find-SDKTools {
    $base = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    Require (Test-Path -LiteralPath $base) 'SDK Windows introuvable.'
    foreach ($version in @(Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name -Descending)) {
        $f = Join-Path $version.FullName 'x64'
        $make = Join-Path $f 'makeappx.exe'; $sign = Join-Path $f 'signtool.exe'
        if ((Test-Path -LiteralPath $make) -and (Test-Path -LiteralPath $sign)) {
            return @{Make=$make;Sign=$sign}
        }
    }
    throw 'MakeAppx et SignTool x64 introuvables.'
}
try {
    Require ([Environment]::OSVersion.Version.Build -ge 22000) 'Windows 11 requis.'
    Require ([Environment]::Is64BitOperatingSystem) 'Windows x64 requis.'
    $installed = @(Get-AppxPackage -Name $packageName -ErrorAction Stop)
    Require ($installed.Count -eq 1) 'Package GEKKO V0.6.0 absent ou ambigu. Aucun changement.'
    if ($installed[0].Version.ToString() -eq '0.6.0.2') {
        Write-Host '[OK] La version 0.6.0.2 est deja installee.' -ForegroundColor Green
        exit 0
    }
    Require ($installed[0].Version.ToString() -eq '0.6.0.1') 'Une autre version GEKKO est installee : ne pas remplacer sans verification.'
    $external = $null
    foreach ($mode in @('debug','release')) {
        $candidate = Join-Path $root ('src-tauri\target\' + $mode)
        if (Test-Path -LiteralPath (Join-Path $candidate 'gekko-archive.exe')) {
            $external = $candidate; break
        }
    }
    Require ($null -ne $external) 'Executable GEKKO introuvable.'
    $certPath = Join-Path $build 'GEKKOArchiveDev.cer'
    Require (Test-Path -LiteralPath $certPath) 'Certificat GEKKOArchiveDev.cer deja cree introuvable.'
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)
    Require ($certificate.Subject -eq $expectedPublisher -and $certificate.Issuer -eq $certificate.Subject) 'Certificat inattendu.'
    Require ($certificate.NotAfter -gt (Get-Date) -and $certificate.NotBefore -le (Get-Date)) 'Certificat non valide a cette date.'
    $thumb = $certificate.Thumbprint
    $private = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $thumb) -ErrorAction SilentlyContinue
    $trusted = Get-Item -LiteralPath ('Cert:\LocalMachine\TrustedPeople\' + $thumb) -ErrorAction SilentlyContinue
    Require ($null -ne $private -and $private.HasPrivateKey) 'Certificat prive GEKKO du compte introuvable.'
    Require ($null -ne $trusted) 'Certificat public GEKKO non approuve pour ce PC.'
    $cpp = Join-Path $here 'native\GEKKOArchiveContext.cpp'
    $manifest = Join-Path $here 'package\AppxManifest.xml'
    $assets = Join-Path $here 'assets'
    Require (Test-Path -LiteralPath $cpp) 'Source C++ manquante.'
    Require (Test-Path -LiteralPath $manifest) 'Manifeste manque.'
    Require (Test-Path -LiteralPath $assets) 'Dossier assets de l extension existante manque.'
    $manifestText = [System.IO.File]::ReadAllText($manifest)
    Require ($manifestText.Contains('Version="0.6.0.2"') -and $manifestText.Contains('GEKKOArchiveContextV0602.dll')) 'Manifeste de mise a jour incorrect.'
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    Require (Test-Path -LiteralPath $vswhere) 'Visual Studio introuvable.'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    Require (-not [string]::IsNullOrWhiteSpace($vs)) 'Outils C++ x64 manquants.'
    $vcvars = Join-Path $vs.Trim() 'VC\Auxiliary\Build\vcvars64.bat'
    Require (Test-Path -LiteralPath $vcvars) 'vcvars64.bat introuvable.'
    $sdk = Find-SDKTools
    Write-Host ''
    Write-Host 'GEKKO ARCHIVE - personnalisation des commandes Windows, package 0.6.0.2' -ForegroundColor Cyan
    Write-Host 'Pas de nouveau certificat ni de modifications React/Rust.'
    Write-Host 'Les choix du menu seront configurables depuis Parametres dans GEKKO ARCHIVE.' -ForegroundColor Cyan
    $confirm = Read-Host 'Pour actualiser l extension native, saisis ACTUALISER'
    if ($confirm -cne 'ACTUALISER') { Write-Host 'Operation annulee.'; exit 0 }
    New-Item -ItemType Directory -Path $build -Force | Out-Null
    $dll = Join-Path $build 'GEKKOArchiveContextV0602.dll'
    $obj = Join-Path $build 'GEKKOArchiveContextV0602.obj'
    $cmd = Join-Path $build 'compiler_gekkocontext_v0602.cmd'
    $cmdText = @"
@echo off
chcp 65001 >nul
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl.exe /nologo /std:c++17 /EHsc /O2 /W3 /LD /MT /utf-8 /Fo"$obj" /Fe"$dll" "$cpp" ole32.lib shell32.lib shlwapi.lib user32.lib
exit /b %ERRORLEVEL%
"@
    [System.IO.File]::WriteAllText($cmd, $cmdText + [Environment]::NewLine, ([System.Text.UTF8Encoding]::new($false)))
    Write-Host '[1/3] Compilation C++ du seul module de menu...' -ForegroundColor Cyan
    Push-Location $build
    try {
        & $env:ComSpec /d /c ('"' + $cmd + '"')
        Require ($LASTEXITCODE -eq 0) 'Compilation C++ echouee : aucune mise a jour de package.'
    } finally { Pop-Location }
    Require (Test-Path -LiteralPath $dll -PathType Leaf) 'DLL 0.6.0.2 non produite.'
    $stage = Join-Path $build 'package-v0602-staging'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -Recurse }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath $manifest -Destination (Join-Path $stage 'AppxManifest.xml') -Force
    # Package sparse : les fichiers doivent aussi etre disponibles sous ExternalLocation.
    Copy-Item -LiteralPath $dll -Destination (Join-Path $stage 'GEKKOArchiveContextV0602.dll') -Force
    Copy-Item -LiteralPath $assets -Destination (Join-Path $stage 'GEKKOArchiveAssets') -Recurse -Force
    $msix = Join-Path $build 'GEKKOArchiveShell-v0602.msix'
    Write-Host '[2/3] Creation et signature MSIX 0.6.0.2...' -ForegroundColor Cyan
    $makeAppxExe = $sdk['Make']
    & $makeAppxExe pack /o /d $stage /nv /p $msix
    Require ($LASTEXITCODE -eq 0) 'MakeAppx a echoue : package actuel inchange.'
    $signToolExe = $sdk['Sign']
    & $signToolExe sign /fd SHA256 /sha1 $thumb /s My $msix
    Require ($LASTEXITCODE -eq 0) 'Signature echouee : package actuel inchange.'
    # Nouveau nom DLL : pas de risque de remplacer une DLL en cours de chargement.
    Copy-Item -LiteralPath $dll -Destination (Join-Path $external 'GEKKOArchiveContextV0602.dll') -Force
    $copyHash = (Get-FileHash -LiteralPath (Join-Path $external 'GEKKOArchiveContextV0602.dll') -Algorithm SHA256).Hash
    Require ($copyHash -eq (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash) 'Empreinte DLL externe incorrecte.'
    Write-Host '[3/3] Actualisation du package Windows pour ce compte...' -ForegroundColor Cyan
    Add-AppxPackage -Path $msix -ExternalLocation $external -ErrorAction Stop
    $updated = @(Get-AppxPackage -Name $packageName -ErrorAction Stop)
    Require ($updated.Count -eq 1 -and $updated[0].Version.ToString() -eq '0.6.0.2') 'Windows n a pas confirme la version 0.6.0.2.'
    Write-Host '[OK] Package GEKKO 0.6.0.2 enregistre.' -ForegroundColor Green
    Write-Host 'Ferme puis rouvre le menu du clic droit ; si necessaire, redemarre Explorer.' -ForegroundColor Yellow
    Write-Host 'Les commandes actives sont gerees dans les Parametres GEKKO ARCHIVE.' -ForegroundColor Yellow
    Write-Host 'Si aucun changement, verifie que GEKKO ARCHIVE a recompile sa version Rust.' -ForegroundColor Yellow
    Write-Host 'Le desinstallateur V060 existant reste utilisable.'
    exit 0
} catch {
    Write-Host ('[ERREUR] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Aucun certificat nouveau ajoute et aucun code React/Rust modifie.' -ForegroundColor Yellow
    exit 1
}
