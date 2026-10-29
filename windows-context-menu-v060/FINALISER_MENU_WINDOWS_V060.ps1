# GEKKO ARCHIVE V0.6.0 - finaliser l'installation sans recompiler.
# Cette operation utilise le certificat de test deja produit.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here '..')).Path
$build = Join-Path $here 'build'
$cer = Join-Path $build 'GEKKOArchiveDev.cer'
$msix = Join-Path $build 'GEKKOArchiveShell-v060.msix'
$admin = Join-Path $here 'GERER_CERTIFICAT_ADMIN_V060.ps1'
$name = 'GEKKOSoftware.GEKKOArchiveShell'
try {
    if (-not (Test-Path -LiteralPath $cer)) { throw 'Certificat GEKKOArchiveDev.cer introuvable. Termine d abord la preparation du package V0.6.0.' }
    if (-not (Test-Path -LiteralPath $msix)) { throw 'Package MSIX introuvable. Termine d abord la preparation V0.6.0.' }
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cer)
    if ($certificate.Subject -ne 'CN=GEKKO-Archive-Dev' -or $certificate.Issuer -ne $certificate.Subject) {
        throw 'Certificat inattendu : le script refuse de lui accorder une confiance systeme.'
    }
    if ($certificate.NotAfter -le (Get-Date) -or $certificate.NotBefore -gt (Get-Date)) {
        throw 'Certificat GEKKO expire ou non encore valide.'
    }
    $thumbprint = $certificate.Thumbprint
    $localCert = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $thumbprint) -ErrorAction SilentlyContinue
    if ($null -eq $localCert -or -not $localCert.HasPrivateKey) {
        throw 'Le certificat ne correspond pas a celui cree par la preparation GEKKO sur ce compte.'
    }
    $existing = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        Write-Host 'Le package GEKKO ARCHIVE est deja installe pour ce compte.' -ForegroundColor Green
        exit 0
    }
    $external = $null
    foreach ($mode in @('debug','release')) {
        $folder = Join-Path $root ('src-tauri\target\' + $mode)
        if (Test-Path -LiteralPath (Join-Path $folder 'gekko-archive.exe')) { $external = $folder; break }
    }
    if ($null -eq $external) { throw 'Executable GEKKO introuvable : relance d abord GEKKO ARCHIVE normalement.' }
    Write-Host ''
    Write-Host 'GEKKO ARCHIVE - correction de la confiance MSIX 0x800B0109' -ForegroundColor Cyan
    Write-Host 'Le package est deja compile et signe : aucune compilation necessaire.'
    Write-Host ('Empreinte du certificat : ' + $thumbprint)
    Write-Host ('Certificat : ' + $certificate.Subject)
    Write-Host ''
    Write-Host 'ATTENTION : le certificat public de developpement sera approuve' -ForegroundColor Yellow
    Write-Host 'pour TOUS les comptes du PC (LocalMachine\\TrustedPeople).' -ForegroundColor Yellow
    Write-Host 'Windows pourra accepter des packages MSIX signes avec ce certificat.' -ForegroundColor Yellow
    Write-Host 'Ce certificat ne sera PAS ajoute aux autorites racines.' -ForegroundColor Yellow
    Write-Host 'Une elevation Windows (UAC) sera demandee pour cette etape.' -ForegroundColor Yellow
    Write-Host 'Le package GEKKO sera ensuite installe pour TON compte seulement.' -ForegroundColor Yellow
    Write-Host 'Le script de desinstallation fourni peut retirer cette confiance.' -ForegroundColor Yellow
    $decision = Read-Host 'Ecris AUTORISER pour approuver ce certificat sur le PC (sinon Entree)'
    if ($decision -cne 'AUTORISER') { Write-Host 'Operation annulee. Aucune modification supplementaire.'; exit 0 }
    $machineCert = Get-Item -LiteralPath ('Cert:\LocalMachine\TrustedPeople\' + $thumbprint) -ErrorAction SilentlyContinue
    if ($null -eq $machineCert) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $admin + '" -Operation Installer -CertPath "' + $cer + '" -Thumbprint ' + $thumbprint
        Write-Host 'Demande elevation UAC pour importer la cle publique uniquement...' -ForegroundColor Cyan
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw 'Import du certificat non confirme. Verifie la demande UAC.' }
    } else {
        Write-Host 'Le certificat exact est deja approuve sur le PC.' -ForegroundColor Green
    }
    $installedCert = Get-Item -LiteralPath ('Cert:\LocalMachine\TrustedPeople\' + $thumbprint) -ErrorAction SilentlyContinue
    if ($null -eq $installedCert) { throw 'Certificat absent du magasin ordinateur apres l operation.' }
    Write-Host 'Certificat GEKKO approuve. Installation de l identite pour le compte courant...' -ForegroundColor Cyan
    Add-AppxPackage -Path $msix -ExternalLocation $external -ErrorAction Stop
    $installed = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)
    if ($installed.Count -eq 0) { throw 'Windows n a pas confirme l installation du package.' }
    Write-Host ''
    Write-Host 'GEKKO ARCHIVE : package de menu Windows enregistre.' -ForegroundColor Green
    Write-Host 'Ouvre GEKKO ARCHIVE, puis essaie un clic droit sur une archive ZIP.' -ForegroundColor Green
    Write-Host 'Pour annuler : DESINSTALLER_MENU_WINDOWS_V060.bat' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ('[ERREUR] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Si l installation a echoue, le certificat peut deja etre approuve :' -ForegroundColor Yellow
    Write-Host 'utilise le desinstallateur GEKKO pour retirer cette confiance si tu le souhaites.' -ForegroundColor Yellow
    exit 1
}
