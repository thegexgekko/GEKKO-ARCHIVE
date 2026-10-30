# GEKKO ARCHIVE V0.7.1 - Reconstruction de l'installateur avec prelecture a froid.
# AUCUNE installation automatique, AUCUNE recompilation de DLL, AUCUN certificat touche.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=$PSScriptRoot
function Require([bool]$ok,[string]$msg){ if(-not $ok){throw $msg} }
try {
    Require ([Environment]::OSVersion.Version.Build -ge 22000) 'Windows 11 requis.'
    $source=Join-Path $root 'src-tauri\src\lib.rs'
    $configPath=Join-Path $root 'src-tauri\tauri.conf.json'
    $cargoPath=Join-Path $root 'src-tauri\Cargo.toml'
    $manifestPath=Join-Path $root 'windows-context-menu-v060\package\AppxManifest.xml'
    $dist=Join-Path $root 'src-tauri\windows-dist'
    $npm=Get-Command npm.cmd -ErrorAction SilentlyContinue
    Require ($null -ne $npm) 'npm.cmd introuvable.'
    foreach ($p in @($source,$configPath,$cargoPath,$manifestPath)){
        Require (Test-Path -LiteralPath $p -PathType Leaf) ('Source manquante : '+$p)
    }
    $cfg=Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw | ConvertFrom-Json
    Require ($cfg.version -eq '0.7.1') 'Version Tauri inattendue. Sources V0.7.1 requises.'
    Require ($cfg.app.windows[0].width -eq 960 -and $cfg.app.windows[0].height -eq 630) 'Correctif petite fenetre V0.7.1 absent.'
    $needed=@(
        'resources\7z.exe','resources\7z.dll','resources\LICENSE-7ZIP.txt',
        'windows-dist\GEKKOArchiveContextV0704.dll',
        'windows-dist\GEKKOArchiveShell-v0704.msix',
        'windows-dist\REGISTER_MENU_V070.ps1',
        'windows-dist\GEKKOArchiveAssets\Square150x150Logo.png',
        'windows-dist\GEKKOArchiveAssets\Square44x44Logo.png',
        'windows-dist\GEKKOArchiveAssets\storelogo.png',
        'windows\gekko-installer-hooks.nsh'
    )
    foreach ($rel in $needed) {
        Require (Test-Path -LiteralPath (Join-Path $root ('src-tauri\'+$rel)) -PathType Leaf) ('Ressource de distribution manquante : '+$rel)
    }
    $manifest=[IO.File]::ReadAllText($manifestPath)
    Require ($manifest.Contains('Version="0.7.0.4"') -and $manifest.Contains('GEKKOArchiveContextV0704.dll')) 'Manifeste du menu V0704 inattendu.'
    $registerScript=Get-Content -LiteralPath (Join-Path $dist 'REGISTER_MENU_V070.ps1') -Encoding UTF8 -Raw
    Require ($registerScript.Contains("0.7.0.4") -and $registerScript.Contains('GEKKOArchiveShell-v0704.msix')) 'Enregistrement du menu ne correspond pas au V0704.'
    $json=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    Require ($json.Contains('GEKKOArchiveContextV0704.dll') -and $json.Contains('GEKKOArchiveShell-v0704.msix')) 'Configuration Tauri incompatible avec le menu V0704.'
    $sig=Get-AuthenticodeSignature -LiteralPath (Join-Path $dist 'GEKKOArchiveShell-v0704.msix')
    Require ($sig.Status -eq 'Valid') 'Le MSIX V0704 existant n a pas une signature valide : arret sans construction.'
    Require ((@(Get-Process -Name 'gekko-archive' -ErrorAction SilentlyContinue)).Count -eq 0) 'Fermer GEKKO ARCHIVE avant la compilation.'
    Write-Host 'GEKKO ARCHIVE 0.7.1 : construction NSIS avec optimisation ouverture a froid.' -ForegroundColor Cyan
    Write-Host 'Menu V0704 conserve, aucune recompilation DLL/MSIX.'
    Write-Host 'Ce script n installe PAS automatiquement GEKKO ARCHIVE.' -ForegroundColor Yellow
    Write-Host '[1/2] Verification et application de la prelecture Rust...' -ForegroundColor Cyan
    $encoding=New-Object System.Text.UTF8Encoding($false)
    $before=[IO.File]::ReadAllText($source,$encoding).Replace("`r`n","`n")
    $body=$before
    $openOld=@'
#[tauri::command]
fn list_archive(archive_path:String,password:Option<String>)->Result<ArchiveInfo,String>{
'@
    $openNew=@'
// GEKKO-STARTUP-PREFETCH-V071 : lire en parallele au premier lancement
// sans attendre que WebView2 et React aient fini de demarrer.
struct StartupArchivePrefetch {
    path: PathBuf,
    worker: std::thread::JoinHandle<Result<ArchiveInfo,String>>,
}
static STARTUP_ARCHIVE_PREFETCH: std::sync::OnceLock<Mutex<Option<StartupArchivePrefetch>>> =
    std::sync::OnceLock::new();

#[tauri::command]
fn list_archive(archive_path:String,password:Option<String>)->Result<ArchiveInfo,String>{
    // Le cache ne concerne que l'archive lancee depuis l'Explorateur,
    // sans mot de passe. Tout autre cas conserve la lecture existante.
    if password.as_deref().unwrap_or("").is_empty() {
        if let Some(cache) = STARTUP_ARCHIVE_PREFETCH.get() {
            let pending = match cache.lock() {
                Ok(mut state) => {
                    if state.as_ref().is_some_and(|job| job.path == PathBuf::from(&archive_path)) {
                        state.take()
                    } else { None }
                },
                Err(_) => None,
            };
            if let Some(job) = pending {
                return match job.worker.join() {
                    Ok(result) => result,
                    Err(_) => list_archive_uncached(archive_path,password),
                };
            }
        }
    }
    list_archive_uncached(archive_path,password)
}

fn list_archive_uncached(archive_path:String,password:Option<String>)->Result<ArchiveInfo,String>{
'@
    $runOld=@'
    if let Some(code)=run_shell_extraction().or_else(run_shell_compression){std::process::exit(code);}
    tauri::Builder::default()
'@
    $runNew=@'
    if let Some(code)=run_shell_extraction().or_else(run_shell_compression){std::process::exit(code);}
    start_archive_prefetch();
    tauri::Builder::default()
'@
    $prefetchFn=@'
// GEKKO-STARTUP-PREFETCH-V071 : demarrer la lecture en meme temps que
// le lancement Tauri. Ne maintient aucun processus resident apres fermeture.
fn start_archive_prefetch() {
    let args:Vec<_> = std::env::args_os().skip(1).collect();
    let candidate = match args.as_slice() {
        [path] => path,
        [flag, action, path]
            if flag.to_string_lossy()=="--gekko-shell-action"
                && action.to_string_lossy()=="open" => path,
        _ => return,
    };
    let path=PathBuf::from(candidate.as_os_str());
    let ext=path.extension().and_then(|e|e.to_str()).unwrap_or("").to_ascii_lowercase();
    if !matches!(ext.as_str(),"zip"|"7z"|"rar"|"tar"|"gz"|"bz2"|"xz"|"zst"|"iso"|"cab")
        || !path.is_file() {return;}
    let worker_path=path.clone();
    let worker=std::thread::spawn(move || {
        list_archive_uncached(worker_path.to_string_lossy().into_owned(),None)
    });
    let _=STARTUP_ARCHIVE_PREFETCH.set(Mutex::new(Some(StartupArchivePrefetch{path,worker})));
}


'@
    $marker=@'
#[cfg_attr(mobile, tauri::mobile_entry_point)]
'@
    if ($body.Contains('GEKKO-STARTUP-PREFETCH-V071')) {
        Require ($body.Contains('start_archive_prefetch();') -and $body.Contains('fn list_archive_uncached(')) 'Patch de demarrage partiellement present, arret.'
        Write-Host '[OK] Optimisation deja presente dans la source.' -ForegroundColor Green
    } else {
        Require ([regex]::Matches($body,[regex]::Escape($openOld)).Count -eq 1) 'Point de modification de list_archive introuvable ou ambigu.'
        Require ([regex]::Matches($body,[regex]::Escape($runOld)).Count -eq 1) 'Point de modification de run introuvable ou ambigu.'
        Require ([regex]::Matches($body,[regex]::Escape($marker)).Count -eq 1) 'Point d insertion Rust introuvable ou ambigu.'
        Require ($body.Contains('extract_worker(Some(app.clone()),extraction,cancelled.clone())?') -and
                 $body.Contains('extract_worker(Some(app), extract_req, cancelled.clone())?')) 'Correctif Rust E0308 precedent absent. Arret pour ne pas annuler son effet.'
        $body=$body.Replace($openOld,$openNew).Replace($runOld,$runNew).Replace($marker,$prefetchFn+$marker)
        Require ($body.Contains('start_archive_prefetch();') -and $body.Contains('fn list_archive_uncached(')) 'Verification du patch Rust echouee.'
        $backupSource=$source+'.avant-prefetch-V071.bak'
        if (-not (Test-Path -LiteralPath $backupSource)) {[IO.File]::Copy($source,$backupSource,$false)}
        [IO.File]::WriteAllText($source,$body.Replace("`n","`r`n"),$encoding)
        Write-Host ('[OK] Code Rust modifie. Sauvegarde : '+$backupSource) -ForegroundColor Green
    }
    Write-Host '[2/2] Compilation de l application et construction NSIS...' -ForegroundColor Cyan
    $start=Get-Date
    Push-Location -LiteralPath $root
    try {
        & $npm.Source run tauri build -- --bundles nsis
        $exitCode=$LASTEXITCODE
    } finally { Pop-Location }
    Require ($exitCode -eq 0) 'Echec de compilation Tauri / NSIS. Application installee inchangee.'
    $output=Join-Path $root 'src-tauri\target\release\bundle\nsis'
    $installers=@(Get-ChildItem -LiteralPath $output -Filter '*0.7.1*x64*setup.exe' -File -ErrorAction SilentlyContinue)
    Require ($installers.Count -gt 0) 'Installateur V0.7.1 x64 introuvable. Application installee inchangee.'
    $current=$installers | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Require ($current.LastWriteTime -ge $start.AddSeconds(-5)) 'Installateur existant trop ancien. Aucune nouvelle construction confirmee.'
    Write-Host '[OK] Installateur V0.7.1 reconstruit :' -ForegroundColor Green
    Write-Host $current.FullName
    Write-Host 'L installateur n a pas ete execute : lance-le pour tester le demarrage a froid.' -ForegroundColor Cyan
    exit 0
} catch {
    Write-Host ('[ECHEC] '+$_.Exception.Message) -ForegroundColor Red
    Write-Host 'Installation GEKKO existante et menu contextuel non modifies.' -ForegroundColor Yellow
    exit 1
}
