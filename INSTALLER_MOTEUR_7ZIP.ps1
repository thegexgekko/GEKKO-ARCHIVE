# GEKKO ARCHIVE - Préparation ponctuelle du moteur officiel 7-Zip pour le développement.
# Source vérifiée: https://www.7-zip.org/download.html ; 7-Zip Extra 26.05 (Windows x86/x64).
# Aucun fichier n'est envoyé, aucune installation système de 7-Zip n'est effectuée.
param()
$ErrorActionPreference = 'Stop'
$project = $PSScriptRoot
$dest = Join-Path $project 'src-tauri\resources'
if (-not (Test-Path -LiteralPath (Join-Path $project 'src-tauri\Cargo.toml'))) {
    throw 'Place ces fichiers dans le dossier principal GEKKO_ARCHIVE_V0.1.0_ALPHA (a cote du fichier LANCER_GEKKO_ARCHIVE.bat).'
}
$exePath = Join-Path $dest '7z.exe'
$dllPath = Join-Path $dest '7z.dll'
if ((Test-Path -LiteralPath $exePath) -and (Test-Path -LiteralPath $dllPath)) {
    Write-Host 'Le moteur 7-Zip local est deja present. Rien a faire.' -ForegroundColor Green
    exit 0
}
$session = Join-Path $env:TEMP ('gekko-7zip-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $session '7z2605-extra.7z'
$unpack = Join-Path $session 'extrait'
New-Item -ItemType Directory -Force -Path $unpack | Out-Null
try {
    $sources = @(
        'https://github.com/ip7z/7zip/releases/download/26.05/7z2605-extra.7z',
        'https://sourceforge.net/projects/sevenzip/files/7-Zip/26.05/7z2605-extra.7z/download'
    )
    $downloaded = $false
    foreach ($source in $sources) {
        try {
            Write-Host 'Telechargement du paquet officiel 7-Zip Extra 26.05...' -ForegroundColor Cyan
            Invoke-WebRequest -Uri $source -OutFile $archive -UseBasicParsing -MaximumRedirection 10
            if ((Get-Item -LiteralPath $archive).Length -lt 100000) { throw 'Reponse inattendue du serveur.' }
            $downloaded = $true
            break
        } catch {
            Write-Warning ('Source inaccessible : ' + $_.Exception.Message)
        }
    }
    if (-not $downloaded) { throw 'Telechargement impossible. Verifie la connexion et reessaie.' }
    # Windows 11 fournit tar.exe (libarchive), capable de lire les archives .7z.
    $tar = Get-Command tar.exe -ErrorAction Stop
    & $tar.Source -xf $archive -C $unpack
    if ($LASTEXITCODE -ne 0) { throw 'Extraction du paquet officiel 7-Zip impossible via tar.exe.' }
    $pairs = @(Get-ChildItem -LiteralPath $unpack -Recurse -File -Filter '7z.exe' | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.DirectoryName '7z.dll')
    })
    if ($pairs.Count -eq 0) { throw '7z.exe et 7z.dll introuvables dans le paquet recu.' }
    # Préférer le sous-dossier x64 quand le paquet inclut les deux architectures.
    $selected = $pairs | Sort-Object -Property @{Expression={ if ($_.FullName -match '(?i)[\\/]x64[\\/]') { 0 } elseif ($_.FullName -match '(?i)[\\/]x86[\\/]') { 2 } else { 1 } }} | Select-Object -First 1
    $tmpExe = Join-Path $session '7z.exe'
    $tmpDll = Join-Path $session '7z.dll'
    Copy-Item -LiteralPath $selected.FullName -Destination $tmpExe
    Copy-Item -LiteralPath (Join-Path $selected.DirectoryName '7z.dll') -Destination $tmpDll

    # La redistribution du moteur exige que la documentation de licence l'accompagne.
    $license = Join-Path $session 'LICENSE-7ZIP.txt'
    $licenseLink = 'https://www.7-zip.org/license.txt'
    try { Invoke-WebRequest -Uri $licenseLink -OutFile $license -UseBasicParsing } catch {
        $localLicense = Get-ChildItem -LiteralPath $unpack -Recurse -File | Where-Object { $_.Name -ieq 'license.txt' } | Select-Object -First 1
        if ($localLicense) { Copy-Item -LiteralPath $localLicense.FullName -Destination $license }
    }
    if (-not (Test-Path -LiteralPath $license)) { throw 'Impossible de recuperer les informations de licence officielles de 7-Zip.' }

    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -LiteralPath $tmpExe -Destination $exePath -Force
    Copy-Item -LiteralPath $tmpDll -Destination $dllPath -Force
    Copy-Item -LiteralPath $license -Destination (Join-Path $dest 'LICENSE-7ZIP.txt') -Force
    $lgpl = Get-ChildItem -LiteralPath $unpack -Recurse -File | Where-Object { $_.Name -in @('copying.txt', 'COPYING.txt') } | Select-Object -First 1
    if ($lgpl) { Copy-Item -LiteralPath $lgpl.FullName -Destination (Join-Path $dest 'COPYING-7ZIP.txt') -Force }

    Write-Host 'Verification du moteur...' -ForegroundColor Cyan
    & $exePath i > $null
    if ($LASTEXITCODE -ne 0) { throw '7z.exe n a pas reussi sa verification de lancement.' }
    Write-Host 'Moteur 7-Zip operationnel dans GEKKO ARCHIVE.' -ForegroundColor Green
    Write-Host 'Tu peux maintenant relancer LANCER_GEKKO_ARCHIVE.bat.' -ForegroundColor Green
} catch {
    # Éviter de laisser un moteur incomplet/partiel s'il n'a pas passé la vérification.
    if ((Test-Path -LiteralPath $exePath) -xor (Test-Path -LiteralPath $dllPath)) {
        Remove-Item -LiteralPath $exePath,$dllPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host ('ECHEC : ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    Remove-Item -LiteralPath $session -Recurse -Force -ErrorAction SilentlyContinue
}
