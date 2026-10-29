# GEKKO ARCHIVE V0.6.0 - supprime uniquement son menu et, sur accord,
# la confiance accordee au certificat public GEKKO sur cet ordinateur.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$name = 'GEKKOSoftware.GEKKOArchiveShell'
$cer = Join-Path $PSScriptRoot 'build\GEKKOArchiveDev.cer'
$admin = Join-Path $PSScriptRoot 'GERER_CERTIFICAT_ADMIN_V060.ps1'
try {
    $registered = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)
    foreach ($p in $registered) {
        Write-Host ('Suppression du package ' + $p.PackageFullName)
        Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
    }
    if ($registered.Count -eq 0) { Write-Host 'Pas de package GEKKO enregistre pour ce compte.' }
    else { Write-Host 'Package GEKKO retire du compte Windows.' -ForegroundColor Green }
    if (Test-Path -LiteralPath $cer) {
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cer)
        if ($certificate.Subject -ne 'CN=GEKKO-Archive-Dev') { throw 'Certificat inattendu : retrait ignore.' }
        $thumbprint = $certificate.Thumbprint
        $userItem = 'Cert:\CurrentUser\TrustedPeople\' + $thumbprint
        $machineItem = 'Cert:\LocalMachine\TrustedPeople\' + $thumbprint
        $hasUser = Test-Path -LiteralPath $userItem
        $hasMachine = Test-Path -LiteralPath $machineItem
        if ($hasUser -or $hasMachine) {
            Write-Host ('Certificat GEKKO : ' + $thumbprint) -ForegroundColor Yellow
            if ($hasMachine) { Write-Host 'La confiance de ce certificat vaut pour TOUS les comptes du PC.' -ForegroundColor Yellow }
            $choice = Read-Host 'Ecris RETIRER pour supprimer cette confiance (sinon Entree)'
            if ($choice -ceq 'RETIRER') {
                if ($hasMachine) {
                    $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $admin + '" -Operation Retirer -CertPath "' + $cer + '" -Thumbprint ' + $thumbprint
                    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args -Wait -PassThru
                    if ($process.ExitCode -ne 0) { throw 'Retrait administrateur du certificat non confirme.' }
                }
                if ($hasUser) { Remove-Item -LiteralPath $userItem -ErrorAction Stop }
                Write-Host 'Certificat GEKKO retire des magasins de confiance utilises pour ce test.' -ForegroundColor Green
            }
        }
    } else {
        Write-Host 'Certificat public introuvable : aucun certificat ne sera supprime automatiquement.' -ForegroundColor Yellow
    }
    Write-Host 'Les fichiers du projet et ses moteurs restent intacts.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ('[ERREUR] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
