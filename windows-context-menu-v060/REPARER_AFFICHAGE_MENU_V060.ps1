# GEKKO ARCHIVE V0.6.0 - correctif cible du package sparse MSIX.
# Copie uniquement la DLL COM dans l'emplacement externe deja declare.
# Pas de droits administrateur, de recompilation, ni de certificat ajoute.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try {
    $here = $PSScriptRoot
    $root = (Resolve-Path -LiteralPath (Join-Path $here '..')).Path
    $packageName = 'GEKKOSoftware.GEKKOArchiveShell'
    $dllName = 'GEKKOArchiveContextV060.dll'
    $package = @(Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue)
    if ($package.Count -ne 1) {
        throw 'Le package GEKKO V0.6.0 n est pas confirme comme installe pour ton compte. Aucun fichier modifie. Conserve le message de FINALISER_MENU_WINDOWS_V060.bat.'
    }
    $manifest = Get-AppxPackageManifest -Package $package[0].PackageFullName -ErrorAction Stop
    $manifestText = $manifest.OuterXml
    foreach ($expected in @('windows.fileExplorerContextMenus', 'GEKKOArchiveContextV060.dll', '348348C7-F21A-4D5F-8E16-35C9F55212D4')) {
        if (-not $manifestText.Contains($expected)) {
            throw ('Le manifeste installe ne contient pas l enregistrement attendu : ' + $expected + '. Aucun fichier modifie.')
        }
    }
    $source = Join-Path $here ('build\' + $dllName)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw ('DLL deja compilee introuvable : ' + $source + '. Aucun fichier modifie.')
    }
    # Meme ordre que l installateur/finaliseur V0.6.0 : debug avant release.
    $external = $null
    foreach ($mode in @('debug', 'release')) {
        $candidate = Join-Path $root ('src-tauri\target\' + $mode)
        if (Test-Path -LiteralPath (Join-Path $candidate 'gekko-archive.exe') -PathType Leaf) {
            $external = $candidate
            break
        }
    }
    if ($null -eq $external) { throw 'Emplacement de GEKKO ARCHIVE introuvable. Aucun fichier modifie.' }
    $target = Join-Path $external $dllName
    Write-Host ('Package installe : ' + $package[0].PackageFullName) -ForegroundColor Cyan
    Write-Host ('Emplacement externe utilise par l installateur : ' + $external)
    Write-Host ('DLL source : ' + $source)
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $already = (Test-Path -LiteralPath $target -PathType Leaf)
    if ($already -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $sourceHash) {
        Write-Host 'La DLL est deja a sa place et identique. Aucun changement necessaire.' -ForegroundColor Green
    } else {
        Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($targetHash -ne $sourceHash) { throw 'Copie non valide : empreinte de la DLL differente.' }
        Write-Host 'DLL native copiee dans le dossier externe et empreinte verifiee.' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'Le package et le certificat n ont pas ete modifies.' -ForegroundColor Green
    Write-Host 'Pour recharger le menu, redemarre l Explorateur Windows depuis le Gestionnaire des taches, ou deconnecte/reconnecte ta session.' -ForegroundColor Yellow
    Write-Host 'Ensuite, clic droit sur un fichier ZIP : GEKKO ARCHIVE doit apparaitre dans le menu moderne.' -ForegroundColor Yellow
    Write-Host 'Si le menu reste absent, conserve la sortie de ce script : l inscription COM devra etre diagnostiquee.' -ForegroundColor Yellow
    exit 0
} catch {
    Write-Host ('[ERREUR] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Aucun certificat, registre ou application n a ete modifie.' -ForegroundColor Yellow
    exit 1
}
