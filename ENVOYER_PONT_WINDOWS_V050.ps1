param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('open','zip','7z','extractHere','extractFolder')]
  [string]$Action,
  [Parameter(Mandatory = $true)]
  [string]$Source
)
$ErrorActionPreference = 'Stop'
try {
  $sourceFile = Get-Item -LiteralPath $Source -ErrorAction Stop
  if ((($Action -ne 'zip') -and ($Action -ne '7z')) -and $sourceFile.PSIsContainer) {
    throw 'Cette action attend une archive (fichier), pas un dossier.'
  }
  $base = Join-Path $env:LOCALAPPDATA 'GEKKO_ARCHIVE\shell_bridge'
  [void][System.IO.Directory]::CreateDirectory($base)
  $identity = [guid]::NewGuid().ToString('N')
  $temporary = Join-Path $base ('shell-command-' + $identity + '.tmp')
  $ready = Join-Path $base ('shell-command-' + $identity + '.txt')
  $encoder = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllLines($temporary, [string[]]@($Action, $sourceFile.FullName), $encoder)
  Move-Item -LiteralPath $temporary -Destination $ready -ErrorAction Stop
  # Une commande écrite n'est pas encore une commande reçue.
  $received = $false
  for ($attempt = 0; $attempt -lt 32; $attempt++) {
    if (-not [System.IO.File]::Exists($ready)) {
      $received = $true
      break
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not $received) {
    # Éviter une ancienne demande qui s'exécuterait lors d'un futur démarrage.
    try { Remove-Item -LiteralPath $ready -Force -ErrorAction Stop } catch { }
    Write-Host '[ERREUR] GEKKO ARCHIVE n a pas lu la commande en 8 secondes.' -ForegroundColor Red
    Write-Host 'La file locale fonctionne mais le programme lance ne la consulte pas.' -ForegroundColor Yellow
    Write-Host 'Verifie que tu as relance la version contenant get_shell_launch (React ET Rust).' -ForegroundColor Yellow
    Write-Host 'Regarde aussi dans la fenetre Explorer une archive : une erreur Tauri y sera affichee.' -ForegroundColor Yellow
    exit 6
  }
  Write-Host 'Commande retiree de la file par le backend : reception confirmee.' -ForegroundColor Green
  Write-Host 'Si aucune action n apparait, regarde le message d erreur dans GEKKO ARCHIVE.' -ForegroundColor Yellow
  exit 0
} catch {
  Write-Host ('[ERREUR] ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
