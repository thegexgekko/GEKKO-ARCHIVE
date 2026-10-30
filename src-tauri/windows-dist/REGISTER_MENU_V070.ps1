# GEKKO ARCHIVE - integration moderne Windows 11 pour un installateur NSIS per-user.
# N'importe AUCUN certificat, ne supprime AUCUNE preference utilisateur.
param(
    [ValidateSet('install','remove')][string]$Action = 'install',
    [Parameter(Mandatory = $true)][string]$InstallDir
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$packageName='GEKKOSoftware.GEKKOArchiveShell'
$expectedVersion=[version]'0.7.0.4'
$expectedPublisher='CN=GEKKO-Archive-Dev'
$assets=@('Square150x150Logo.png','Square44x44Logo.png','storelogo.png')
$logFolder=Join-Path $env:LOCALAPPDATA 'GEKKO_ARCHIVE'
New-Item -Path $logFolder -ItemType Directory -Force | Out-Null
$log=Join-Path $logFolder 'installation_menu_v070.log'
function Log([string]$s) { Add-Content -LiteralPath $log -Encoding UTF8 -Value ('[{0}] {1}' -f (Get-Date -Format 's'),$s) }
function Require([bool]$ok,[string]$message) { if (-not $ok) { throw $message } }
try {
    Require ([Environment]::OSVersion.Version.Build -ge 22000) 'Windows 11 requis.'
    Require ([Environment]::Is64BitOperatingSystem) 'Windows x64 requis.'
    $root=[IO.Path]::GetFullPath($InstallDir.TrimEnd('\'))
    $dist=Join-Path $root 'windows-dist'
    $msix=Join-Path $dist 'GEKKOArchiveShell-v0704.msix'
    $dllName='GEKKOArchiveContextV0704.dll'
    $installed=@(Get-AppxPackage -Name $packageName -ErrorAction Stop)
    if ($Action -eq 'install') {
        Require (Test-Path -LiteralPath (Join-Path $root 'gekko-archive.exe') -PathType Leaf) 'Executable GEKKO absent.'
        Require (Test-Path -LiteralPath $msix -PathType Leaf) 'MSIX de menu manquant dans l installateur.'
        Require (Test-Path -LiteralPath (Join-Path $dist $dllName) -PathType Leaf) 'DLL GEKKO manquante.'
        $sig=Get-AuthenticodeSignature -LiteralPath $msix
        Require ($sig.Status -eq 'Valid' -and $null -ne $sig.SignerCertificate) 'La signature MSIX n est pas approuvee. Le certificat de developpement doit deja etre approuve sur ce PC.'
        Require ($sig.SignerCertificate.Subject -eq $expectedPublisher) 'Editeur MSIX inattendu.'
        if ($installed.Count -gt 0) {
            Require ($installed.Count -eq 1 -and $installed[0].Publisher -eq $expectedPublisher) 'Un autre package GEKKO inattendu est enregistre.'
            Require ($installed[0].Version -le $expectedVersion) 'Version du menu existante plus recente ; aucune modification.'
        }
        foreach ($name in $assets) {
            $origin=Join-Path (Join-Path $dist 'GEKKOArchiveAssets') $name
            Require (Test-Path -LiteralPath $origin -PathType Leaf) ('Image absente : '+$name)
        }
        $dstDll=Join-Path $root $dllName
        $dstAssets=Join-Path $root 'GEKKOArchiveAssets'
        New-Item -Path $dstAssets -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $dist $dllName) -Destination $dstDll -Force
        foreach ($name in $assets) {
            $origin=Join-Path (Join-Path $dist 'GEKKOArchiveAssets') $name
            Require (Test-Path -LiteralPath $origin -PathType Leaf) ('Image absente : '+$name)
            Copy-Item -LiteralPath $origin -Destination (Join-Path $dstAssets $name) -Force
        }
        # Ne jamais desinscrire l'ancien menu avant d'avoir valide le nouveau package.
        # Une version differente s'actualise par Add-AppxPackage directement.
        # Ne pas accepter silencieusement un package du meme numero
        # qui serait deja rattache au dossier de developpement.
        # Add-AppxPackage peut actualiser l'emplacement externe ; l'operation
        # reste une mise a jour et ne desinstalle pas la version fonctionnelle avant.
        Add-AppxPackage -Path $msix -ExternalLocation $root -ErrorAction Stop
        $current=@(Get-AppxPackage -Name $packageName -ErrorAction Stop)
        Require ($current.Count -eq 1 -and $current[0].Version -eq $expectedVersion) 'Enregistrement MSIX 0.7.0.4 non confirme.'
        Log 'Menu GEKKO 0.7.0.4 enregistre pour cet utilisateur.'
    } else {
        # Si une version du menu existe et differe, ne surtout pas
        # effacer ses fichiers sous une extension COM encore enregistree.
        if ($installed.Count -gt 0) {
            Require ($installed.Count -eq 1 -and $installed[0].Publisher -eq $expectedPublisher) 'Package de menu inconnu : desinstallation du menu interrompue.'
            if ($installed[0].Version -eq $expectedVersion) {
                Remove-AppxPackage -Package $installed[0].PackageFullName -ErrorAction Stop
                Log 'Menu GEKKO 0.7.0.4 desinstalle.'
            } elseif ($installed[0].Version -lt $expectedVersion) {
                # L utilisateur a refuse le menu pendant l installation :
                # son ancien menu de developpement doit rester intact.
                Log 'Ancien menu de developpement conserve pendant la desinstallation.'
            } else {
                throw 'Une version plus recente du menu est presente : desinstallation interrompue pour eviter une extension COM orpheline.'
            }
        } else { Log 'Aucun package GEKKO a retirer.' }
        # Suppression des fichiers supplementaires copies par le hook, pas des preferences.
        Remove-Item -LiteralPath (Join-Path $root $dllName) -Force -ErrorAction SilentlyContinue
        $dstAssets=Join-Path $root 'GEKKOArchiveAssets'
        foreach ($name in $assets) { Remove-Item -LiteralPath (Join-Path $dstAssets $name) -Force -ErrorAction SilentlyContinue }
        if ((Test-Path -LiteralPath $dstAssets) -and @(Get-ChildItem -LiteralPath $dstAssets -Force).Count -eq 0) {
            Remove-Item -LiteralPath $dstAssets -Force -ErrorAction SilentlyContinue
        }
    }
    exit 0
} catch {
    Log ('ERREUR : '+ $_.Exception.Message)
    Write-Error $_.Exception.Message
    exit 1
}
