# Utilitaire eleve : ne traite que le certificat public GEKKO V0.6.0 exact.
param(
    [Parameter(Mandatory=$true)][ValidateSet('Installer','Retirer')][string]$Operation,
    [Parameter(Mandatory=$true)][string]$CertPath,
    [Parameter(Mandatory=$true)][string]$Thumbprint
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try {
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertPath)
    if ($cert.Subject -ne 'CN=GEKKO-Archive-Dev' -or $cert.Issuer -ne $cert.Subject -or $cert.Thumbprint -ne $Thumbprint) {
        throw 'Identite ou empreinte du certificat inattendue. Aucune modification.'
    }
    $item = 'Cert:\LocalMachine\TrustedPeople\' + $Thumbprint
    if ($Operation -eq 'Installer') {
        if (-not (Test-Path -LiteralPath $item)) {
            Import-Certificate -FilePath $CertPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' -ErrorAction Stop | Out-Null
        }
        if (-not (Test-Path -LiteralPath $item)) { throw 'Echec de confirmation du certificat.' }
        Write-Host 'Certificat public GEKKO importe dans LocalMachine\TrustedPeople.' -ForegroundColor Green
    } else {
        if (Test-Path -LiteralPath $item) {
            Remove-Item -LiteralPath $item -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $item) { throw 'Certificat toujours present.' }
        Write-Host 'Confiance systeme du certificat GEKKO retiree.' -ForegroundColor Green
    }
    exit 0
} catch {
    Write-Host ('[ERREUR ADMIN] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
