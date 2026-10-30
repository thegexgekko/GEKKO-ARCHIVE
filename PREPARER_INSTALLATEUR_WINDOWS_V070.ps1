# Construire l'EXE NSIS sur Windows 11, avec le moteur 7-Zip local et le shell MSIX signe.
# Aucun telechargement de moteur ; aucun certificat installe dans Windows.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=$PSScriptRoot
$menu=Join-Path $root 'windows-context-menu-v060'
$target=Join-Path $root 'src-tauri\windows-dist'
$stage=Join-Path $root 'src-tauri\target\gekko-installer-stage-v070'
function Require([bool]$ok,[string]$message) { if (-not $ok) { throw $message } }
function SDKTools {
  $sdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  Require (Test-Path -LiteralPath $sdk) 'Windows SDK absent.'
  foreach($v in @(Get-ChildItem -LiteralPath $sdk -Directory | Sort-Object Name -Descending)) {
    $d=Join-Path $v.FullName 'x64'
    if ((Test-Path -LiteralPath (Join-Path $d 'makeappx.exe')) -and (Test-Path -LiteralPath (Join-Path $d 'signtool.exe'))) {
      return @{make=(Join-Path $d 'makeappx.exe');sign=(Join-Path $d 'signtool.exe')}
    }
  }
  throw 'MakeAppx et SignTool x64 introuvables.'
}
try {
  Require ([Environment]::OSVersion.Version.Build -ge 22000) 'Windows 11 requis.'
  Require ([Environment]::Is64BitOperatingSystem) 'Windows x64 requis.'
  foreach ($f in @('src-tauri\resources\7z.exe','src-tauri\resources\7z.dll','src-tauri\resources\LICENSE-7ZIP.txt')) {
    Require (Test-Path -LiteralPath (Join-Path $root $f) -PathType Leaf) ('Moteur partage ou licence manquant : '+$f)
  }
  $engine=Join-Path $root 'src-tauri\resources\7z.exe'
  & $engine i | Out-Null
  Require ($LASTEXITCODE -eq 0) 'Moteur 7z local invalide.'
  Require (Test-Path -LiteralPath (Join-Path $root 'src-tauri\windows\gekko-installer-hooks.nsh')) 'Hooks NSIS introuvables.'
  $cpp=Join-Path $menu 'native\GEKKOArchiveContext.cpp'
  $manifest=Join-Path $menu 'package\AppxManifest.xml'
  Require ((Test-Path -LiteralPath $cpp) -and (Test-Path -LiteralPath $manifest)) 'Sources de menu contextuel absentes.'
  $manifestText=[IO.File]::ReadAllText($manifest)
  Require ($manifestText.Contains('Version="0.7.0.4"') -and $manifestText.Contains('GEKKOArchiveContextV0704.dll')) 'Manifeste de distribution inattendu.'
  $certificateName='CN=GEKKO-Archive-Dev'
  $certificates=@(Get-ChildItem -Path 'Cert:\CurrentUser\My' | Where-Object { $_.Subject -eq $certificateName -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) })
  Require ($certificates.Count -eq 1) 'Certificat prive de developpement GEKKO absent ou ambigu. Aucune nouvelle approbation de certificat.'
  $cert=$certificates[0]
  $trusted=Get-Item -LiteralPath ('Cert:\LocalMachine\TrustedPeople\'+$cert.Thumbprint) -ErrorAction SilentlyContinue
  Require ($null -ne $trusted) 'Certificat public GEKKO non approuve. Utilise la procedure deja validee, sans nouvelle creation automatique.'
  $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  Require (Test-Path -LiteralPath $vswhere) 'Visual Studio C++ introuvable.'
  $vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  Require (-not [string]::IsNullOrWhiteSpace($vs)) 'Compilateur MSVC x64 introuvable.'
  $vcvars=Join-Path $vs.Trim() 'VC\Auxiliary\Build\vcvars64.bat'
  Require (Test-Path -LiteralPath $vcvars) 'vcvars64.bat absent.'
  $sdk=SDKTools
  New-Item -Path $stage,$target -ItemType Directory -Force | Out-Null
  $dll='GEKKOArchiveContextV0704.dll'
  $obj=Join-Path $stage 'GEKKOArchiveContextV0704.obj'
  $built=Join-Path $stage $dll
  $cmd=Join-Path $stage 'compilation-gekkocontext-v070.cmd'
  # Chaque ligne est formee integralement avant d'entrer dans le tableau.
  # Les concatenations non groupees etaient interpretees comme autant
  # d'elements distincts dans @(...), produisant des commandes invalides.
  $vcLine = 'call "{0}" >nul' -f $vcvars
  $clLine = 'cl.exe /nologo /std:c++17 /EHsc /O2 /W3 /LD /MT /utf-8 /Fo"{0}" /Fe"{1}" "{2}" ole32.lib shell32.lib shlwapi.lib user32.lib' -f $obj,$built,$cpp
  $compileLines = [string[]]@(
    '@echo off',
    $vcLine,
    'if errorlevel 1 exit /b 1',
    $clLine,
    'exit /b %ERRORLEVEL%'
  )
  Require ($compileLines.Length -eq 5) 'Generation des lignes de compilation C++ invalide.'
  [IO.File]::WriteAllLines($cmd,$compileLines,[Text.UTF8Encoding]::new($false))
  # Verifier les vraies lignes produites avant de lancer cmd.exe.
  $writtenLines = [string[]]@(Get-Content -LiteralPath $cmd -Encoding UTF8)
  Require ($writtenLines.Length -eq 5 -and $writtenLines[1] -ceq $vcLine -and $writtenLines[3] -ceq $clLine) 'Le script .cmd a ete fragmente : compilation interrompue.'
  Write-Host '[INFO] Correctif 2 actif : 5 lignes de compilation controlees.' -ForegroundColor Green
  Write-Host '[1/3] Compilation du module natif Windows 11...' -ForegroundColor Cyan
  # Executer le script de compilation par son nom simple dans son
  # propre dossier pour eviter les problemes de guillemets de cmd.exe
  # lorsque le chemin du projet comporte des espaces.
  Push-Location -LiteralPath $stage
  try {
    & $env:ComSpec /d /c 'call compilation-gekkocontext-v070.cmd'
    $compileExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  Require ($compileExitCode -eq 0 -and (Test-Path -LiteralPath $built)) 'Echec de compilation C++ : aucune installation effectuee.'
  $staging=Join-Path $stage 'msix-staging'
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force -Recurse }
  New-Item -Path $staging -ItemType Directory -Force | Out-Null
  Copy-Item -LiteralPath $manifest -Destination (Join-Path $staging 'AppxManifest.xml')
  Copy-Item -LiteralPath $built -Destination (Join-Path $staging $dll)
  Copy-Item -LiteralPath (Join-Path $menu 'assets') -Destination (Join-Path $staging 'GEKKOArchiveAssets') -Recurse -Force
  $msix=Join-Path $stage 'GEKKOArchiveShell-v0704.msix'
  Write-Host '[2/3] Preparation du package MSIX signe...' -ForegroundColor Cyan
  & $sdk['make'] pack /o /d $staging /nv /p $msix
  Require ($LASTEXITCODE -eq 0) 'MakeAppx a echoue.'
  & $sdk['sign'] sign /fd SHA256 /sha1 $cert.Thumbprint /s My $msix
  Require ($LASTEXITCODE -eq 0) 'Signature MSIX a echoue.'
  $sig=Get-AuthenticodeSignature -LiteralPath $msix
  Require ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Thumbprint -eq $cert.Thumbprint) 'Signature MSIX non verifiee.'
  Copy-Item -LiteralPath $built -Destination (Join-Path $target $dll) -Force
  Copy-Item -LiteralPath $msix -Destination (Join-Path $target 'GEKKOArchiveShell-v0704.msix') -Force
  $dstAssets=Join-Path $target 'GEKKOArchiveAssets'
  if(Test-Path -LiteralPath $dstAssets) { Remove-Item -LiteralPath $dstAssets -Recurse -Force }
  Copy-Item -LiteralPath (Join-Path $menu 'assets') -Destination $dstAssets -Recurse -Force
  $npm=Get-Command npm.cmd -ErrorAction SilentlyContinue
  Require ($null -ne $npm) 'npm.cmd non disponible.'
  Write-Host '[3/3] Fabrication de l installateur Windows/NSIS...' -ForegroundColor Cyan
  $buildStarted=Get-Date
  $releaseExe=Join-Path $root 'src-tauri\target\release\gekko-archive.exe'
  Push-Location $root
  try {
    # Le nouveau mode d'extraction en arriere-plan est dans Rust :
    # NE PAS re-utiliser le binaire release 0.7.0, qui ouvrirait encore l'UI.
    Write-Host '[INFO] Nouveau code Rust headless : recompilation release obligatoire (une seule fois).' -ForegroundColor Cyan
    & $npm.Source run tauri build -- --bundles nsis
    Require ($LASTEXITCODE -eq 0) 'Compilation Tauri/NSIS echouee.' 
  } finally { Pop-Location }
  $installers=@(Get-ChildItem -LiteralPath (Join-Path $root 'src-tauri\target\release\bundle\nsis') -Filter '*setup.exe' -File -ErrorAction SilentlyContinue)
  Require ($installers.Count -gt 0) 'Aucun installateur NSIS trouve apres compilation.'
  $latest=$installers | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  Require ($latest.LastWriteTime -ge $buildStarted.AddSeconds(-3)) 'Installateur trop ancien : la nouvelle construction n est pas confirmee.'
  Write-Host '[OK] Installateur local genere :' -ForegroundColor Green
  $installers | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Write-Host $_.FullName }
  Write-Host 'Il n a PAS ete execute. Le menu Windows sera propose, non impose.' -ForegroundColor Yellow
  exit 0
} catch {
  Write-Host ('ECHEC : '+$_.Exception.Message) -ForegroundColor Red
  Write-Host 'Aucune modification du certificat de confiance. Aucun installateur n a ete execute.' -ForegroundColor Yellow
  exit 1
}
