use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, State};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ArchiveFile {
    path: String, size: u64, packed_size: Option<u64>, modified: String,
    is_dir: bool, is_link: bool,
    #[serde(skip_serializing)]
    link_reason: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ArchiveInfo {path:String, name:String, format:String, bytes:u64, files:Vec<ArchiveFile>}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExtractRequest {
    archive_path: String, destination: String, selected_paths: Vec<String>,
    password: Option<String>, policy: String, decisions: HashMap<String,String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExtractPreview {files:usize, folders:usize, total_bytes:u64, conflicts:Vec<String>}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExtractResult {extracted:usize, skipped:usize, destination:String}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Progress {phase:String, percent:u8, message:String}
#[derive(Default)]
struct ExtractState { active:Mutex<Option<Arc<AtomicBool>>> }

// Recherche d'abord le moteur local déjà installé par le correctif validé.
fn find_engine()->Result<PathBuf,String>{
    let mut candidates=Vec::new();
    if let Ok(exe)=std::env::current_exe(){ if let Some(d)=exe.parent(){
        candidates.push(d.join("7z.exe"));
        candidates.push(d.join("resources").join("7z.exe"));
        candidates.push(d.join("..\\..\\..\\src-tauri\\resources\\7z.exe"));
    }}
    if let Some(d)=std::env::var_os("GEKKO_ARCHIVE_7ZIP_DIR"){ candidates.push(PathBuf::from(d).join("7z.exe")); }
    if let Ok(d)=std::env::var("ProgramFiles"){candidates.push(Path::new(&d).join("7-Zip").join("7z.exe"));}
    if let Ok(d)=std::env::var("ProgramFiles(x86)"){candidates.push(Path::new(&d).join("7-Zip").join("7z.exe"));}
    candidates.into_iter().find(|p|p.is_file()&&p.with_file_name("7z.dll").is_file())
        .ok_or_else(||"Moteur 7-Zip introuvable (7z.exe et 7z.dll). Relance le correctif moteur V2 déjà validé.".into())
}
// Preuve positive de redirection : ne jamais traiter une propriete vide ou
// negative comme un lien. Le controle du dossier temporaire reste actif.
fn link_evidence(v:&BTreeMap<String,String>)->Vec<String>{
    let mut proof=Vec::new();
    for field in ["Symbolic Link", "Hard Link", "Copy Link", "Link"] {
        if let Some(raw)=v.get(field){
            let target=raw.trim();
            let negative=target.is_empty() || ["-", "0", "false", "no", "none", "null", "n/a", "off"]
                .iter().any(|x|target.eq_ignore_ascii_case(x));
            if !negative {
                proof.push(format!("{field}={}",target.chars().take(96).collect::<String>()));
            }
        }
    }
    for field in ["Mode", "Attributes"] {
        if let Some(attr)=v.get(field) {
            for token in attr.split_whitespace(){
                // Unix : lrwxrwxrwx ; ne pas confondre avec -rw-r--r--.
                if token.starts_with('l') && token.chars().count()==10 {
                    proof.push(format!("{field}={token}"));
                }
                // Attribut Windows L : indicateur 7-Zip de reparse point.
                if field=="Attributes" && token=="L" {
                    proof.push("Attributes=L".into());
                }
            }
        }
    }
    proof
}
fn fields_to_file(v:&BTreeMap<String,String>)->Option<ArchiveFile>{
    let path=v.get("Path")?.trim().to_string();if path.is_empty(){return None;}
    let attr=v.get("Attributes").map(String::as_str).unwrap_or("");
    let is_dir=v.get("Folder").is_some_and(|s|s.trim()=="+")||attr.starts_with('D')||path.ends_with('/')||path.ends_with('\\');
    // GEKKO-LINK-GUARD-0.2.4 : 7-Zip -slt peut retourner des champs
    // de lien vides ou des indicateurs negatifs (0, No, False, etc.).
    // Seules les cibles explicites et les attributs de lien sont bloquees.
    let link_evidence = link_evidence(v);
    let is_link = !link_evidence.is_empty();
    Some(ArchiveFile{path,size:v.get("Size").and_then(|s|s.parse().ok()).unwrap_or(0),packed_size:v.get("Packed Size").and_then(|s|s.parse().ok()),modified:v.get("Modified").cloned().unwrap_or_default(),is_dir,is_link,link_reason:link_evidence.join(" ; ")})
}
fn parse_listing(s:&str)->Vec<ArchiveFile>{
    let mut started=false;let mut v=BTreeMap::new();let mut files=Vec::new();
    for raw in s.lines(){let line=raw.trim_end_matches('\r');
        if !started {if line.trim()=="----------" {started=true;}continue;}
        if line.trim().is_empty(){if let Some(f)=fields_to_file(&v){files.push(f);}v.clear();}
        else if let Some((k,value))=line.split_once(" = "){v.insert(k.trim().into(),value.into());}
    }
    if let Some(f)=fields_to_file(&v){files.push(f);}files
}
fn read_listing(archive:&Path,password:Option<&str>)->Result<Vec<ArchiveFile>,String>{
    let engine=find_engine()?;
    let mut cmd=Command::new(engine);
    cmd.arg("l").arg("-slt").arg("-sccUTF-8").arg("-bd");
    if let Some(pass)=password.filter(|p|!p.is_empty()){cmd.arg(format!("-p{pass}"));}
    let output=cmd.arg("--").arg(archive).output().map_err(|e|format!("Impossible de lancer 7-Zip : {e}"))?;
    if !output.status.success(){
        let out=String::from_utf8_lossy(&output.stdout);
        let err=String::from_utf8_lossy(&output.stderr);
        if out.contains("Wrong password")||err.contains("Wrong password")||out.contains("Can not open encrypted archive"){
            return Err("Mot de passe requis ou incorrect.".into());
        }
        return Err(format!("Lecture de l'archive impossible : {}",err.trim()));
    }
    let output=String::from_utf8(output.stdout).map_err(|_|"Sortie 7-Zip non UTF-8.".to_string())?;
    if !output.contains("----------"){return Err("Format de liste 7-Zip non reconnu.".into());}
    Ok(parse_listing(&output))
}
#[tauri::command]
fn list_archive(archive_path:String,password:Option<String>)->Result<ArchiveInfo,String>{
    let archive=PathBuf::from(&archive_path);
    let m=archive.metadata().map_err(|e|format!("Archive introuvable : {e}"))?;
    if !m.is_file(){return Err("Le chemin sélectionné n'est pas une archive.".into());}
    let files=read_listing(&archive,password.as_deref())?;
    let name=archive.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let format=name.rsplit('.').next().unwrap_or("Archive").to_uppercase();
    Ok(ArchiveInfo{path:archive_path,name,format,bytes:m.len(),files})
}

// Refus des chemins dangereux, collisions Windows, noms spéciaux et flux NTFS.
fn member_key(name:&str)->String{
    name.replace('\\',"/").trim_start_matches("./").trim_end_matches('/').to_string()
}
fn safe_member(name:&str)->Result<PathBuf,String>{
    let normalized=member_key(name);
    if normalized.is_empty()||normalized.starts_with('/')||normalized.contains('\0')||normalized.contains('\n')||normalized.contains('\r') {return Err(format!("Chemin d'archive refusé : {name}"));}
    let mut out=PathBuf::new();
    for component in normalized.split('/') {
        if component.is_empty()||component=="."||component==".."||component.ends_with(' ')||component.ends_with('.')||component.contains(':')||component.chars().any(|c|c<' '||"<>\"|?*".contains(c)){
            return Err(format!("Chemin d'archive non sûr : {name}"));
        }
        let stem=component.split('.').next().unwrap_or("").to_uppercase();
        if matches!(stem.as_str(),"CON"|"PRN"|"AUX"|"NUL"|"COM1"|"COM2"|"COM3"|"COM4"|"COM5"|"COM6"|"COM7"|"COM8"|"COM9"|"LPT1"|"LPT2"|"LPT3"|"LPT4"|"LPT5"|"LPT6"|"LPT7"|"LPT8"|"LPT9"){
            return Err(format!("Nom réservé Windows refusé : {name}"));
        }
        out.push(component);
    }
    if out.components().any(|c|!matches!(c,Component::Normal(_))){return Err("Chemin hors dossier refusé".into());}
    Ok(out)
}
fn selected_files<'a>(all:&'a [ArchiveFile],selected:&[String])->Result<Vec<&'a ArchiveFile>,String>{
    for f in all {if f.is_dir && member_key(&f.path).is_empty() {continue;}
        safe_member(&f.path)?;
        if f.is_link{return Err(format!("GEKKO 0.2.4 — Lien détecté dans l'archive : {} (indice : {}). Un fichier ordinaire ne doit pas être bloqué.",f.path,f.link_reason));}
    }
    let available:HashSet<String>=all.iter().map(|f|member_key(&f.path)).collect();
    for s in selected {let s=member_key(s);safe_member(&s)?;
        if !available.contains(&s)&&!all.iter().any(|f|member_key(&f.path).starts_with(&(s.clone()+"/"))){return Err(format!("Élément absent de l'archive : {s}"));}}
    let mut seen=HashSet::new();
    let mut picked=Vec::new();
    for f in all.iter().filter(|f|!f.is_dir || !member_key(&f.path).is_empty()){
        let name=member_key(&f.path);
        if selected.is_empty()||selected.iter().any(|s|{let s=member_key(s);name==s||name.starts_with(&(s+"/"))}){
            let key=name.to_lowercase();if !seen.insert(key){return Err(format!("Collision de noms Windows dans l'archive : {name}"));}
            picked.push(f);
        }
    }
    Ok(picked)
}
#[cfg(windows)]
fn is_reparse(m:&fs::Metadata)->bool{
    use std::os::windows::fs::MetadataExt;
    m.file_attributes() & 0x400 != 0
}
#[cfg(not(windows))]
fn is_reparse(_: &fs::Metadata)->bool{false}
fn guard_target(path:&Path,root:&Path)->Result<(),String>{
    let relative=path.strip_prefix(root).map_err(|_|"Destination invalide.".to_string())?;
    let mut walk=root.to_path_buf();
    for part in relative.components(){walk.push(part.as_os_str());
        match fs::symlink_metadata(&walk){
            Ok(m) if m.file_type().is_symlink()||is_reparse(&m)=>return Err(format!("Lien/redirection interdit dans la destination : {}",walk.display())),
            Ok(_)=>{},
            Err(e) if e.kind()==std::io::ErrorKind::NotFound=>{},
            Err(e)=>return Err(format!("Destination inaccessible : {e}")),
        }
    }Ok(())
}
fn prepare(req:&ExtractRequest)->Result<(PathBuf,PathBuf,Vec<ArchiveFile>,Vec<String>),String>{
    let archive=PathBuf::from(&req.archive_path);
    if !archive.is_file(){return Err("Archive source introuvable.".into());}
    let dest=fs::canonicalize(&req.destination).map_err(|e|format!("Dossier de destination inaccessible : {e}"))?;
    if !dest.is_dir(){return Err("La destination doit être un dossier.".into());}
    let all=read_listing(&archive,req.password.as_deref())?;
    let files=selected_files(&all,&req.selected_paths)?;
    let mut conflicts=Vec::new();
    for f in &files{let relative=safe_member(&f.path)?;let target=dest.join(relative);guard_target(&target,&dest)?;
        if let (Ok(s),Ok(t))=(fs::canonicalize(&archive),fs::canonicalize(&target)){if s==t{return Err("Extraction refusée : un fichier de sortie écraserait l'archive d'origine.".into());}}
        if target.exists(){
            if f.is_dir&&target.is_dir(){continue;}
            if !f.is_dir&&target.is_file(){conflicts.push(member_key(&f.path));continue;}
            return Err(format!("Un fichier ou dossier empêche l'extraction : {}",target.display()));
        }
    }
    Ok((archive,dest,files.into_iter().cloned().collect(),conflicts))
}
#[tauri::command]
fn preview_extraction(req:ExtractRequest)->Result<ExtractPreview,String>{
    let (_archive,_dest,files,conflicts)=prepare(&req)?;
    let total_bytes=files.iter().filter(|f|!f.is_dir).fold(0u64,|n,f|n.saturating_add(f.size));
    Ok(ExtractPreview{files:files.iter().filter(|f|!f.is_dir).count(),folders:files.iter().filter(|f|f.is_dir).count(),total_bytes,conflicts})
}
fn emit_progress(app:&AppHandle,phase:&str,percent:u8,message:&str){
    let _=app.emit("gekko-extraction-progress",Progress{phase:phase.into(),percent,message:message.into()});
}
struct TempStage(PathBuf);
impl Drop for TempStage{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
fn create_stage()->Result<TempStage,String>{
    let stamp=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e|e.to_string())?.as_nanos();
    for n in 0..8 {let p=std::env::temp_dir().join(format!("gekko-archive-{}-{stamp}-{n}",std::process::id()));
        match fs::create_dir(&p){Ok(())=>return Ok(TempStage(p)),Err(e) if e.kind()==std::io::ErrorKind::AlreadyExists=>continue,Err(e)=>return Err(format!("Dossier temporaire inaccessible : {e}"))}}
    Err("Création d'un dossier temporaire impossible.".into())
}
fn read_progress<R:Read>(mut reader:R,app:AppHandle){
    let mut b=[0u8;8192];let mut token=Vec::new();
    while let Ok(n)=reader.read(&mut b){if n==0{break;}
        for x in &b[..n]{if *x==b'\r'||*x==b'\n'{
            let line=String::from_utf8_lossy(&token);
            for word in line.split_whitespace(){if let Some(p)=word.strip_suffix('%').and_then(|t|t.parse::<u8>().ok()){emit_progress(&app,"extraction",p.min(100).saturating_mul(80)/100,"Décompression en cours…");break;}}
            token.clear();
        }else if token.len()<4096{token.push(*x);}}
    }
}
fn ensure_stage_safe(root:&Path)->Result<(),String>{
    fn visit(dir:&Path,root:&Path)->Result<(),String>{
        for item in fs::read_dir(dir).map_err(|e|e.to_string())?{
            let entry=item.map_err(|e|e.to_string())?;let path=entry.path();
            let m=fs::symlink_metadata(&path).map_err(|e|e.to_string())?;
            if m.file_type().is_symlink()||is_reparse(&m){return Err("Archive contenant un lien dangereux : extraction interrompue.".into());}
            let rel=path.strip_prefix(root).map_err(|e|e.to_string())?;
            safe_member(&rel.to_string_lossy())?;
            if m.is_dir(){visit(&path,root)?;}else if !m.is_file(){return Err("Type de fichier non pris en charge.".into());}
        }Ok(())
    }visit(root,root)
}
fn transfer_file(src:&Path,dest:&Path,replace:bool)->Result<(),String>{
    let folder=dest.parent().ok_or("Destination invalide.")?;
    let stamp=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e|e.to_string())?.as_nanos();
    let temp=folder.join(format!(".gekko-part-{}-{stamp}",std::process::id()));
    let backup=folder.join(format!(".gekko-backup-{}-{stamp}",std::process::id()));
    if let Err(e)=fs::copy(src,&temp){let _=fs::remove_file(&temp);return Err(format!("Copie impossible : {e}"));}
    let had_existing=replace&&dest.exists();
    if had_existing {if let Err(e)=fs::rename(dest,&backup){let _=fs::remove_file(&temp);return Err(format!("Sauvegarde du fichier existant impossible : {e}"));}}
    match fs::rename(&temp,dest){
        Ok(())=>{if had_existing{let _=fs::remove_file(&backup);}Ok(())},
        Err(e)=>{let _=fs::remove_file(&temp);if had_existing{let _=fs::rename(&backup,dest);}Err(format!("Écriture impossible : {e}"))}
    }
}
fn extract_worker(app:AppHandle,req:ExtractRequest,cancel:Arc<AtomicBool>)->Result<ExtractResult,String>{
    let (archive,dest,files,_)=prepare(&req)?;
    if !matches!(req.policy.as_str(),"skip"|"replace"|"ask"){return Err("Politique de conflits non reconnue.".into());}
    if files.is_empty(){return Err("Aucun fichier à extraire.".into());}
    let stage=create_stage()?;let engine=find_engine()?;
    emit_progress(&app,"extraction",0,"Préparation de l'extraction…");
    let mut cmd=Command::new(engine);
    cmd.arg("x").arg("-y").arg("-aoa").arg("-sccUTF-8").arg("-scsUTF-8").arg("-spd").arg("-bsp1").arg("-bb0").arg("-bso0").arg("-bse1");
    let output_dir=stage.0.join("output");
    fs::create_dir(&output_dir).map_err(|e|e.to_string())?;
    cmd.arg(format!("-o{}",output_dir.display()));
    if let Some(password)=req.password.as_deref().filter(|p|!p.is_empty()){cmd.arg(format!("-p{password}"));}
    // La liste de sélection évite toute ambiguïté avec les caractères joker.
    if !req.selected_paths.is_empty(){
        let list=stage.0.join("selected-files.txt");
        let mut f=fs::File::create(&list).map_err(|e|e.to_string())?;
        for entry in &files{writeln!(f,"{}",entry.path).map_err(|e|e.to_string())?;}
        drop(f);
        cmd.arg(format!("-i@{}",list.display()));
    }
    cmd.arg("--").arg(&archive);
    let mut child=cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e|format!("Impossible de lancer 7-Zip : {e}"))?;
    let out=child.stdout.take().ok_or("Sortie du moteur inaccessible.")?;
    let err=child.stderr.take().ok_or("Erreurs du moteur inaccessibles.")?;
    let ap=app.clone();let progress=std::thread::spawn(move||read_progress(out,ap));
    let errors=std::thread::spawn(move||{let mut text=String::new();let _=std::io::BufReader::new(err).read_to_string(&mut text);text});
    let status=loop{
        if cancel.load(Ordering::SeqCst){let _=child.kill();break child.wait().map_err(|e|e.to_string())?;}
        match child.try_wait().map_err(|e|e.to_string())?{Some(code)=>break code,None=>std::thread::sleep(Duration::from_millis(100))}
    };
    let _=progress.join();let error_text=errors.join().unwrap_or_default();
    if cancel.load(Ordering::SeqCst){return Err("Extraction annulée avant copie des fichiers.".into());}
    if !status.success(){return Err(format!("Échec 7-Zip ({}). Vérifie le mot de passe ou l'intégrité de l'archive. {}",status,error_text.chars().take(400).collect::<String>()));}
    // La liste d'inclusion ne doit pas être copiée dans le dossier final.
    ensure_stage_safe(&output_dir)?;
    emit_progress(&app,"copie",82,"Transfert vers la destination…");
    let total=files.len();let mut copied=0;let mut skipped=0;
    for (i,f) in files.iter().enumerate(){
        if cancel.load(Ordering::SeqCst){return Err(format!("Extraction annulée : {copied} fichier(s) déjà transféré(s) ont été conservés."));}
        let rel=safe_member(&f.path)?;let source=output_dir.join(&rel);
        if !f.is_dir&&!source.is_file(){return Err(format!("Fichier extrait manquant : {}",f.path));}
        let target=dest.join(&rel);guard_target(&target,&dest)?;
        if f.is_dir{fs::create_dir_all(&target).map_err(|e|format!("Création du dossier impossible : {e}"))?;continue;}
        if let Some(p)=target.parent(){fs::create_dir_all(p).map_err(|e|format!("Création du dossier impossible : {e}"))?;}
        guard_target(&target,&dest)?;
        let current_policy=if req.policy=="ask"{req.decisions.get(&member_key(&f.path)).map(String::as_str).unwrap_or("skip")}else{req.policy.as_str()};
        if target.exists(){
            if current_policy=="skip"{skipped+=1;continue;}
            if current_policy!="replace"{return Err("Décision de remplacement invalide.".into());}
        }
        transfer_file(&source,&target,target.exists())?;copied+=1;
        let pct=82+(((i+1)*18/total) as u8);
        emit_progress(&app,"copie",pct,&format!("{}/{} fichiers transférés",i+1,total));
    }
    emit_progress(&app,"terminé",100,"Extraction terminée.");
    Ok(ExtractResult{extracted:copied,skipped,destination:req.destination})
}
#[tauri::command]
async fn extract_archive(app:AppHandle,state:State<'_,ExtractState>,req:ExtractRequest)->Result<ExtractResult,String>{
    let flag=Arc::new(AtomicBool::new(false));
    {let mut active=state.active.lock().map_err(|e|e.to_string())?;
        if active.is_some(){return Err("Une extraction est déjà en cours.".into());}
        *active=Some(flag.clone());
    }
    let answer=tauri::async_runtime::spawn_blocking(move||extract_worker(app,req,flag)).await
        .map_err(|e|format!("Erreur de tâche : {e}"));
    *state.active.lock().map_err(|e|e.to_string())?=None;
    answer?
}
#[tauri::command]
fn cancel_extraction(state:State<'_,ExtractState>)->Result<(),String>{
    if let Some(flag)=state.active.lock().map_err(|e|e.to_string())?.as_ref(){flag.store(true,Ordering::SeqCst);}
    Ok(())
}

// V0.3.0 : création ZIP / 7z, sans remplacement implicite des archives existantes.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateRequest {
    source_paths: Vec<String>, destination: String, format: String,
    level: u8, password: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateResult {path:String, bytes:u64}
#[derive(Default)]
struct CreateState {active:Mutex<Option<Arc<AtomicBool>>>}

fn ensure_source_tree_safe(path:&Path)->Result<(),String>{
    let meta=fs::symlink_metadata(path).map_err(|e|format!("Source inaccessible : {e}"))?;
    if meta.file_type().is_symlink()||is_reparse(&meta){
        return Err(format!("Lien ou redirection dans la source : {}",path.display()));
    }
    if meta.is_file(){return Ok(());}
    if !meta.is_dir(){return Err(format!("Type de fichier non pris en charge : {}",path.display()));}
    for child in fs::read_dir(path).map_err(|e|format!("Lecture du dossier impossible : {e}"))?{
        let child=child.map_err(|e|e.to_string())?;
        ensure_source_tree_safe(&child.path())?;
    }
    Ok(())
}

fn validate_create(req:&CreateRequest)->Result<(PathBuf,PathBuf,Vec<String>),String>{
    let kind=req.format.to_ascii_lowercase();
    if !matches!(kind.as_str(),"zip"|"7z"){return Err("Formats de création disponibles : ZIP et 7z.".into());}
    if !matches!(req.level,0|1|5|9){return Err("Niveau de compression invalide.".into());}
    if req.source_paths.is_empty(){return Err("Sélectionne d'abord les fichiers ou un dossier à compresser.".into());}
    if req.source_paths.len()>10000{return Err("Trop de fichiers sélectionnés.".into());}
    let destination=PathBuf::from(req.destination.trim());
    let ext=destination.extension().and_then(|e|e.to_str()).unwrap_or("");
    if !ext.eq_ignore_ascii_case(&kind){return Err(format!("L'archive de sortie doit se terminer par .{kind}."));}
    let name=destination.file_name().and_then(|n|n.to_str()).ok_or("Nom de destination invalide.")?;
    if name.starts_with('.') || (name.contains('\r') || name.contains('\n')){return Err("Nom de l'archive invalide.".into());}
    if destination.exists(){return Err("Cette archive existe déjà. Choisis un autre nom : aucun remplacement automatique.".into());}
    let parent=destination.parent().filter(|p|!p.as_os_str().is_empty()).ok_or("Choisis un dossier de destination valide.")?;
    let parent=fs::canonicalize(parent).map_err(|e|format!("Dossier de sortie inaccessible : {e}"))?;
    if !parent.is_dir(){return Err("La destination doit être un dossier.".into());}
    let destination=parent.join(name);
    let mut common_parent=None;
    let mut args=Vec::new();
    let mut seen=HashSet::new();
    for source in &req.source_paths {
        let path=fs::canonicalize(source).map_err(|e|format!("Source inaccessible ({source}) : {e}"))?;
        ensure_source_tree_safe(&path)?;
        if path==destination || (path.is_dir() && destination.starts_with(&path)){
            return Err("L'archive de sortie ne peut pas être placée dans le dossier source sélectionné.".into());
        }
        let dir=path.parent().ok_or("Source sans dossier parent.")?.to_path_buf();
        if let Some(ref root)=common_parent {
            if *root!=dir{return Err("Pour sélectionner plusieurs fichiers, utilise un même dossier source. Pour réunir plusieurs dossiers, sélectionne leur dossier parent.".into());}
        }else{common_parent=Some(dir);}
        let filename=path.file_name().and_then(|v|v.to_str()).ok_or("Nom de fichier non compatible.")?;
        if filename.contains('\r') || filename.contains('\n'){return Err("Nom de fichier contenant un saut de ligne non pris en charge.".into());}
        if !seen.insert(filename.to_lowercase()){return Err(format!("Nom de source en double : {filename}"));}
        // Un chemin relatif explicite évite l'interprétation de '-' ou '@' en option 7-Zip.
        args.push(format!(".\\{filename}"));
    }
    Ok((common_parent.ok_or("Aucune source.")?,destination,args))
}

// Fichier temporaire dans le dossier de destination : aucune archive incomplète publiée.
struct TemporaryArchive(PathBuf);
impl Drop for TemporaryArchive{fn drop(&mut self){let _=fs::remove_file(&self.0);}}
fn compression_progress<R:Read>(mut input:R,app:AppHandle){
    let mut buf=[0u8;8192];let mut token=Vec::new();
    while let Ok(n)=input.read(&mut buf){if n==0{break;}
        for b in &buf[..n]{
            if *b==b'\r'||*b==b'\n'{
                let line=String::from_utf8_lossy(&token);
                for word in line.split_whitespace(){
                    if let Some(p)=word.strip_suffix('%').and_then(|v|v.parse::<u8>().ok()){
                        let _=app.emit("gekko-compression-progress",Progress{phase:"compression".into(),percent:p.min(100).saturating_mul(88)/100,message:"Compression en cours…".into()});
                        break;
                    }
                }
                token.clear();
            }else if token.len()<4096{token.push(*b);}
        }
    }
}
fn emit_compression(app:&AppHandle,phase:&str,percent:u8,message:&str){
    let _=app.emit("gekko-compression-progress",Progress{phase:phase.into(),percent,message:message.into()});
}
fn create_worker(app:AppHandle,req:CreateRequest,cancel:Arc<AtomicBool>)->Result<CreateResult,String>{
    let (base,destination,source_names)=validate_create(&req)?;
    let engine=find_engine()?;
    let kind=req.format.to_ascii_lowercase();
    let stamp=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e|e.to_string())?.as_nanos();
    let temporary=TemporaryArchive(destination.parent().ok_or("Dossier de sortie invalide.")?
        .join(format!(".gekko-create-{}-{stamp}.{kind}",std::process::id())));
    if temporary.0.exists(){return Err("Un fichier de travail existe déjà, recommence l'opération.".into());}
    emit_compression(&app,"préparation",0,"Préparation des fichiers…");
    if cancel.load(Ordering::SeqCst){return Err("Compression annulée.".into());}
    let mut cmd=Command::new(&engine);
    cmd.current_dir(&base).arg("a").arg(format!("-t{kind}")).arg(format!("-mx={}",req.level))
        .arg("-y").arg("-sccUTF-8").arg("-scsUTF-8").arg("-spd")
        .arg("-bsp1").arg("-bb0").arg("-bso0").arg("-bse1");
    if let Some(pass)=req.password.as_deref().filter(|p|!p.is_empty()){
        cmd.arg(format!("-p{pass}"));
        if kind=="7z" {cmd.arg("-mhe=on");}
        else {cmd.arg("-mem=AES256");}
    }
    cmd.arg("--").arg(&temporary.0).args(&source_names);
    let mut child=cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().map_err(|e|format!("Démarrage de 7-Zip impossible : {e}"))?;
    let stdout=child.stdout.take().ok_or("Progression du moteur inaccessible.")?;
    let stderr=child.stderr.take().ok_or("Erreurs du moteur inaccessibles.")?;
    let progress_app=app.clone();
    let progress_thread=std::thread::spawn(move||compression_progress(stdout,progress_app));
    let error_thread=std::thread::spawn(move||{
        let mut output=String::new();
        // Toujours vider stderr pour ne pas bloquer le processus si 7-Zip
        // écrit beaucoup de diagnostics ; limiter uniquement le message rendu.
        let _=std::io::BufReader::new(stderr).read_to_string(&mut output);
        output
    });
    let status=loop{
        if cancel.load(Ordering::SeqCst){let _=child.kill();break child.wait().map_err(|e|e.to_string())?;}
        match child.try_wait().map_err(|e|e.to_string())?{
            Some(code)=>break code,
            None=>std::thread::sleep(Duration::from_millis(100)),
        }
    };
    let _=progress_thread.join();let errors=error_thread.join().unwrap_or_default();
    if cancel.load(Ordering::SeqCst){return Err("Compression annulée. Aucune archive créée.".into());}
    if !status.success(){return Err(format!("Échec de compression 7-Zip ({status}) : {}",errors.chars().take(500).collect::<String>()));}
    if !temporary.0.is_file(){return Err("Le moteur n'a pas produit de fichier d'archive.".into());}
    emit_compression(&app,"vérification",90,"Vérification de la nouvelle archive…");
    let mut test=Command::new(&engine);
    test.arg("t").arg("-y").arg("-bsp0").arg("-bso0").arg("-bse0");
    if let Some(pass)=req.password.as_deref().filter(|p|!p.is_empty()){test.arg(format!("-p{pass}"));}
    let mut verify=test.arg("--").arg(&temporary.0).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
        .spawn().map_err(|e|format!("Vérification impossible : {e}"))?;
    let check=loop{
        if cancel.load(Ordering::SeqCst){let _=verify.kill();break verify.wait().map_err(|e|e.to_string())?;}
        match verify.try_wait().map_err(|e|e.to_string())?{
            Some(code)=>break code,
            None=>std::thread::sleep(Duration::from_millis(100)),
        }
    };
    if cancel.load(Ordering::SeqCst){return Err("Compression annulée. Aucune archive créée.".into());}
    if !check.success(){return Err("L'archive créée n'a pas passé le test d'intégrité 7-Zip. Elle ne sera pas conservée.".into());}
    emit_compression(&app,"finalisation",96,"Enregistrement de l'archive…");
    // create_new interdit tout écrasement, y compris si une autre application
    // a créé un fichier au même emplacement pendant la compression.
    let mut output=fs::OpenOptions::new().write(true).create_new(true).open(&destination)
        .map_err(|e|format!("Impossible de créer l'archive finale (fichier peut-être déjà présent) : {e}"))?;
    let copy_result=(||->std::io::Result<u64>{
        let mut source=fs::File::open(&temporary.0)?;
        let bytes=std::io::copy(&mut source,&mut output)?;
        output.sync_all()?;
        Ok(bytes)
    })();
    drop(output);
    let bytes=match copy_result{Ok(value)=>value,Err(e)=>{
        let _=fs::remove_file(&destination);
        return Err(format!("Écriture de l'archive impossible : {e}"));
    }};
    emit_compression(&app,"terminé",100,"Archive créée et vérifiée.");
    Ok(CreateResult{path:destination.to_string_lossy().into_owned(),bytes})
}
#[tauri::command]
async fn create_archive(app:AppHandle,state:State<'_,CreateState>,req:CreateRequest)->Result<CreateResult,String>{
    let flag=Arc::new(AtomicBool::new(false));
    {
        let mut lock=state.active.lock().map_err(|e|e.to_string())?;
        if lock.is_some(){return Err("Une compression est déjà en cours.".into());}
        *lock=Some(flag.clone());
    }
    let result=tauri::async_runtime::spawn_blocking(move||create_worker(app,req,flag)).await
        .map_err(|e|format!("Erreur de tâche : {e}"));
    *state.active.lock().map_err(|e|e.to_string())?=None;
    result?
}
#[tauri::command]
fn cancel_compression(state:State<'_,CreateState>)->Result<(),String>{
    if let Some(flag)=state.active.lock().map_err(|e|e.to_string())?.as_ref(){flag.store(true,Ordering::SeqCst);}
    Ok(())
}

#[cfg(test)]
mod tests{
    use super::*;
    #[test]
    fn create_format_validation(){
        let req=CreateRequest{source_paths:vec![],destination:"Archive.rar".into(),format:"rar".into(),level:5,password:None};
        assert!(validate_create(&req).unwrap_err().contains("ZIP et 7z"));
    }
    #[test]
    fn source_without_files_rejected(){
        let req=CreateRequest{source_paths:vec![],destination:"Archive.zip".into(),format:"zip".into(),level:5,password:None};
        assert!(validate_create(&req).unwrap_err().contains("Sélectionne"));
    }
    #[test]fn listing(){let s="Path = a.zip\nType = zip\n\n----------\nPath = docs/\nFolder = +\n\nPath = docs/a.txt\nSize = 42\nPacked Size = 19\n\n";let v=parse_listing(s);assert_eq!(v.len(),2);assert_eq!(v[1].size,42);}
    #[test]fn refuse_traversal(){for s in ["../foo","C:/foo","/etc/file","AUX","folder/COM1.txt","file:stream","x/../y","x\\..\\y"]{assert!(safe_member(s).is_err(),"{s}");}}
    #[test]fn select_nested(){let all=vec![ArchiveFile{path:"a/b.txt".into(),size:3,packed_size:None,modified:String::new(),is_dir:false,is_link:false,link_reason:String::new()}];assert_eq!(selected_files(&all,&["a".into()]).unwrap().len(),1);}
    #[test]
    fn regular_rar_with_empty_link_properties_can_be_extracted() {
        // Un véritable 7z -slt sur RAR présente ces champs même sans lien.
        let listing="Path = exemple.rar\nType = Rar5\n\n----------\nPath = python-3.11.9-amd64.exe\nFolder = -\nSize = 25000000\nAttributes = A -rw-r--r--\nSymbolic Link = \nHard Link = \nCopy Link = \n\n";
        let files=parse_listing(listing);
        assert_eq!(files.len(),1);
        assert!(!files[0].is_link);
        assert!(selected_files(&files,&[]).is_ok());
    }
    #[test]
    fn actual_links_are_still_blocked() {
        for (key,target) in [("Symbolic Link","other.txt"),
                             ("Hard Link","other.txt"),
                             ("Copy Link","other.txt"),
                             ("Link","other.txt")] {
            let mut fields=BTreeMap::new();
            fields.insert("Path".to_string(),"link.txt".to_string());
            fields.insert(key.to_string(),target.to_string());
            let file=fields_to_file(&fields).expect("Fichier valide");
            assert!(file.is_link,"L'attribut {key} doit signaler un lien");
            assert!(selected_files(&[file],&[]).is_err());
        }
        let mut fields=BTreeMap::new();
        fields.insert("Path".to_string(),"unix-link".to_string());
        fields.insert("Mode".to_string(),"lrwxrwxrwx".to_string());
        assert!(fields_to_file(&fields).unwrap().is_link);
    }
    #[test]
    fn rar5_normal_file_with_link_flags_no_false_positive() {
        let s="Path = example.rar\nType = Rar5\n\n----------\nPath = python-3.11.9-amd64.exe\nFolder = -\nSize = 25000000\nPacked Size = 24700000\nAttributes = A -rw-r--r--\nHost OS = Windows\nSymbolic Link = \nHard Link = \nCopy Link = \nLink = No\n\n";
        let files=parse_listing(s);
        assert_eq!(files.len(),1);
        assert!(!files[0].is_link);
        assert!(selected_files(&files,&[]).is_ok());
    }
    #[test]
    fn negative_link_properties_never_mark_regular_file() {
        for value in ["", " ", "-", "0", "False", "No", "none", "N/A", "Off"]{
            let mut p=BTreeMap::new();
            p.insert("Path".into(),"example.exe".into());
            p.insert("Attributes".into(),"A -rw-r--r--".into());
            p.insert("Symbolic Link".into(),value.into());
            p.insert("Hard Link".into(),value.into());
            p.insert("Copy Link".into(),value.into());
            p.insert("Link".into(),value.into());
            assert!(!fields_to_file(&p).unwrap().is_link,"wrong value {value:?}");
        }
    }
    #[test]
    fn blank_or_minus_link_properties_are_not_links() {
        let mut fields=BTreeMap::new();
        fields.insert("Path".to_string(),"normal.exe".to_string());
        for key in ["Symbolic Link","Hard Link","Copy Link","Link"] {
            fields.insert(key.to_string()," - ".to_string());
        }
        assert!(!fields_to_file(&fields).unwrap().is_link);
    }

}
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run(){tauri::Builder::default().plugin(tauri_plugin_dialog::init()).manage(ExtractState::default()).manage(CreateState::default())
    .invoke_handler(tauri::generate_handler![list_archive,preview_extraction,extract_archive,cancel_extraction,create_archive,cancel_compression])
    .run(tauri::generate_context!()).expect("Impossible de lancer GEKKO ARCHIVE");}
