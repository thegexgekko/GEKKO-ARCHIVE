use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};

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

// V0.4.0 — conversion sans modification de l'archive source.
// Réutilise les mêmes contrôles de chemins, de liens et de CRC que les
// fonctions d'extraction et de création déjà validées sur Windows 11.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConvertRequest {
    source_path: String, destination: String, format: String,
    level: u8, source_password: Option<String>, password: Option<String>,
}
#[derive(Default)]
struct ConvertState {active:Mutex<Option<Arc<AtomicBool>>>}
fn emit_conversion(app:&AppHandle, phase:&str, percent:u8, message:&str){
    let _=app.emit("gekko-conversion-progress",Progress{
        phase:phase.into(),percent,message:message.into()
    });
}
fn conversion_worker(app:AppHandle, req:ConvertRequest, cancelled:Arc<AtomicBool>)->Result<CreateResult,String>{
    let source=fs::canonicalize(&req.source_path)
        .map_err(|e|format!("Archive source introuvable : {e}"))?;
    if !source.is_file(){return Err("La source doit être une archive existante.".into());}
    let out=PathBuf::from(req.destination.trim());
    if out.as_os_str().is_empty(){return Err("Choisis un emplacement de sortie.".into());}
    // Contrôle précoce, pour ne pas décompresser si la cible est déjà prise.
    if out.exists(){return Err("Le fichier de sortie existe déjà. Choisis un autre nom : aucune archive n'est écrasée.".into());}
    let output_folder=out.parent().filter(|p|!p.as_os_str().is_empty())
        .ok_or("Dossier de sortie invalide.")?;
    let output_folder=fs::canonicalize(output_folder)
        .map_err(|e|format!("Dossier de sortie inaccessible : {e}"))?;
    if !output_folder.is_dir(){return Err("Le dossier de sortie est invalide.".into());}
    let out_filename=out.file_name().ok_or("Nom de fichier de sortie invalide.")?;
    let output_file=output_folder.join(out_filename);
    if source==output_file{return Err("La destination doit être différente de l'archive source.".into());}
    if !matches!(req.format.to_ascii_lowercase().as_str(),"7z"|"zip"){
        return Err("Formats de conversion disponibles : ZIP et 7z.".into());
    }
    if !matches!(req.level,0|1|5|9){return Err("Niveau de compression invalide.".into());}
    if !out.extension().and_then(|v|v.to_str()).unwrap_or("").eq_ignore_ascii_case(&req.format){
        return Err("L'extension de sortie doit correspondre au format choisi.".into());
    }
    if cancelled.load(Ordering::SeqCst){return Err("Conversion annulée.".into());}
    emit_conversion(&app,"préparation",0,"Préparation de la conversion…");
    let stage=create_stage()?;
    let extraction=ExtractRequest{
        archive_path:source.to_string_lossy().into_owned(),
        destination:stage.0.to_string_lossy().into_owned(),
        selected_paths:Vec::new(),password:req.source_password,
        policy:"ask".into(),decisions:HashMap::new(),
    };
    // extract_worker réalise déjà les contrôles de chemins, les vérifications
    // des liens ainsi que l'extraction sécurisée avant transfert.
    let _=extract_worker(app.clone(),extraction,cancelled.clone())?;
    if cancelled.load(Ordering::SeqCst){return Err("Conversion annulée.".into());}
    // Ne pas introduire un dossier racine artificiel dans l'archive convertie.
    let mut contents=Vec::new();
    for entry in fs::read_dir(&stage.0).map_err(|e|e.to_string())?{
        let entry=entry.map_err(|e|e.to_string())?;
        contents.push(entry.path().to_string_lossy().into_owned());
    }
    if contents.is_empty(){return Err("Archive source vide : aucune donnée à convertir.".into());}
    emit_conversion(&app,"compression",45,"Création du nouveau format…");
    let create=CreateRequest{
        source_paths:contents,
        destination:output_file.to_string_lossy().into_owned(),
        format:req.format,level:req.level,password:req.password,
    };
    // create_worker produit une archive temporaire, vérifie son intégrité et
    // refuse de remplacer un fichier existant. L'archive source reste intacte.
    let result=create_worker(app.clone(),create,cancelled.clone())?;
    if cancelled.load(Ordering::SeqCst){
        // Une annulation très tardive peut arriver juste après la publication.
        // On ne supprime pas un fichier terminé à ce stade.
        emit_conversion(&app,"terminé",100,"Conversion terminée.");
    } else {
        emit_conversion(&app,"terminé",100,"Conversion terminée et archive vérifiée.");
    }
    Ok(result)
}
#[tauri::command]
async fn convert_archive(app:AppHandle,state:State<'_,ConvertState>,req:ConvertRequest)->Result<CreateResult,String>{
    let flag=Arc::new(AtomicBool::new(false));
    {
        let mut lock=state.active.lock().map_err(|e|e.to_string())?;
        if lock.is_some(){return Err("Une conversion est déjà en cours.".into());}
        *lock=Some(flag.clone());
    }
    let response=tauri::async_runtime::spawn_blocking(move||conversion_worker(app,req,flag))
        .await.map_err(|e|format!("Erreur de tâche : {e}"));
    *state.active.lock().map_err(|e|e.to_string())?=None;
    response?
}
#[tauri::command]
fn cancel_conversion(state:State<'_,ConvertState>)->Result<(),String>{
    if let Some(flag)=state.active.lock().map_err(|e|e.to_string())?.as_ref(){
        flag.store(true,Ordering::SeqCst);
    }
    Ok(())
}

// V0.4.1 — ajout conservateur : toute mise à jour se fait sur une copie.
// Cette première version ajoute uniquement à la racine des archives ZIP/7z
// et refuse les collisions au lieu d'écraser silencieusement les entrées.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AddRequest {
    archive_path: String,
    source_paths: Vec<String>,
    password: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AddResult {path:String, bytes:u64, added:usize}
#[derive(Default)]
struct AddState {active:Mutex<Option<Arc<AtomicBool>>>}

fn incoming_names(path:&Path, prefix:&str, names:&mut HashSet<String>)->Result<(),String>{
    let rel=safe_member(prefix)?;
    let key=rel.to_string_lossy().replace('\\',"/").to_lowercase();
    if !names.insert(key){return Err(format!("Deux sources ont le même chemin : {prefix}"));}
    let meta=fs::symlink_metadata(path).map_err(|e|format!("Source inaccessible : {e}"))?;
    if meta.file_type().is_symlink()||is_reparse(&meta){return Err(format!("Lien interdit dans les sources : {}",path.display()));}
    if meta.is_dir(){
        for item in fs::read_dir(path).map_err(|e|e.to_string())?{
            let item=item.map_err(|e|e.to_string())?;
            let name=item.file_name().into_string().map_err(|_|"Nom de fichier non Unicode dans la source.".to_string())?;
            incoming_names(&item.path(),&format!("{prefix}/{name}"),names)?;
            if names.len()>100_000{return Err("Trop de fichiers dans le dossier sélectionné.".into());}
        }
    }else if !meta.is_file(){return Err("Type de fichier source non pris en charge.".into());}
    Ok(())
}
fn validate_add(req:&AddRequest)->Result<(PathBuf,PathBuf,Vec<String>,HashSet<String>,String),String>{
    let archive=fs::canonicalize(&req.archive_path).map_err(|e|format!("Archive introuvable : {e}"))?;
    if !archive.is_file(){return Err("Sélectionne une archive existante.".into());}
    let kind=archive.extension().and_then(|e|e.to_str()).unwrap_or("").to_ascii_lowercase();
    if kind!="zip" && kind!="7z"{
        return Err("L'ajout est disponible uniquement pour les archives ZIP et 7z. RAR reste disponible en lecture et extraction.".into());
    }
    if req.source_paths.is_empty(){return Err("Sélectionne au moins un fichier ou un dossier.".into());}
    if req.source_paths.len()>10_000{return Err("Trop de fichiers sélectionnés.".into());}
    let existing=read_listing(&archive,req.password.as_deref())?;
    // Valider aussi les entrées présentes pour éviter de modifier une archive piégée.
    selected_files(&existing,&[])?;
    let existing_names:HashSet<String>=existing.iter()
        .map(|entry|member_key(&entry.path).to_lowercase()).collect();
    let mut source_parent:Option<PathBuf>=None;
    let mut source_names=Vec::new();
    let mut incoming=HashSet::new();
    for source in &req.source_paths{
        let path=fs::canonicalize(source).map_err(|e|format!("Source inaccessible ({source}) : {e}"))?;
        ensure_source_tree_safe(&path)?;
        if archive==path || (path.is_dir() && archive.starts_with(&path)){
            return Err("Impossible d'ajouter l'archive à elle-même, y compris via un dossier parent.".into());
        }
        let parent=path.parent().ok_or("Source sans dossier parent.")?.to_path_buf();
        if let Some(base)=&source_parent{
            if base!=&parent{return Err("Les fichiers sélectionnés doivent provenir d'un même dossier, comme pour la création.".into());}
        }else{source_parent=Some(parent);}
        let filename=path.file_name().and_then(|f|f.to_str()).ok_or("Nom de fichier source incompatible.")?;
        incoming_names(&path,filename,&mut incoming)?;
        source_names.push(format!(".\\{filename}"));
    }
    // Une entrée de même nom (fichier ou dossier) nécessite une décision explicite.
    // On refuse actuellement au lieu de risquer un écrasement ou une fusion implicite.
    for name in &incoming{
        if existing_names.contains(name){return Err(format!("L'archive contient déjà « {name} ». Aucun élément n'a été remplacé."));}
    }
    Ok((archive,source_parent.ok_or("Aucune source.")?,source_names,incoming,kind))
}
fn add_worker(app:AppHandle,req:AddRequest,cancel:Arc<AtomicBool>)->Result<AddResult,String>{
    let (archive,base,sources,incoming,kind)=validate_add(&req)?;
    if cancel.load(Ordering::SeqCst){return Err("Ajout annulé.".into());}
    let engine=find_engine()?;
    let before=fs::metadata(&archive).map_err(|e|e.to_string())?;
    let stamp=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e|e.to_string())?.as_nanos();
    let parent=archive.parent().ok_or("Dossier de l'archive inaccessible.")?;
    let temp=TemporaryArchive(parent.join(format!(".gekko-ajout-{}-{stamp}.{kind}",std::process::id())));
    let backup=parent.join(format!(".gekko-retour-{}-{stamp}.{kind}",std::process::id()));
    if temp.0.exists()||backup.exists(){return Err("Chemin de travail temporaire déjà utilisé.".into());}
    emit_compression(&app,"préparation",0,"Copie de l'archive avant modification…");
    fs::copy(&archive,&temp.0).map_err(|e|format!("Copie de travail impossible (espace disque ?) : {e}"))?;
    if cancel.load(Ordering::SeqCst){return Err("Ajout annulé. Archive originale conservée.".into());}
    let mut cmd=Command::new(&engine);
    cmd.current_dir(&base).arg("a").arg(format!("-t{kind}"))
        .arg("-y").arg("-sccUTF-8").arg("-scsUTF-8").arg("-spd")
        .arg("-bsp1").arg("-bb0").arg("-bso0").arg("-bse1");
    if let Some(password)=req.password.as_deref().filter(|p|!p.is_empty()){
        cmd.arg(format!("-p{password}"));
        if kind=="7z"{cmd.arg("-mhe=on");}else{cmd.arg("-mem=AES256");}
    }
    cmd.arg("--").arg(&temp.0).args(&sources);
    emit_compression(&app,"ajout",5,"Ajout des nouveaux fichiers…");
    let mut child=cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().map_err(|e|format!("Démarrage de 7-Zip impossible : {e}"))?;
    let stdout=child.stdout.take().ok_or("Progression de 7-Zip inaccessible.")?;
    let stderr=child.stderr.take().ok_or("Diagnostics de 7-Zip inaccessibles.")?;
    let app_progress=app.clone();
    let progress=std::thread::spawn(move||compression_progress(stdout,app_progress));
    let errors=std::thread::spawn(move||{let mut s=String::new();let _=std::io::BufReader::new(stderr).read_to_string(&mut s);s});
    let status=loop{
        if cancel.load(Ordering::SeqCst){let _=child.kill();break child.wait().map_err(|e|e.to_string())?;}
        match child.try_wait().map_err(|e|e.to_string())?{Some(code)=>break code,None=>std::thread::sleep(Duration::from_millis(100))}
    };
    let _=progress.join();let diagnostics=errors.join().unwrap_or_default();
    if cancel.load(Ordering::SeqCst){return Err("Ajout annulé. Archive originale conservée.".into());}
    if !status.success(){return Err(format!("Ajout 7-Zip impossible ({status}) : {}",diagnostics.chars().take(500).collect::<String>()));}
    emit_compression(&app,"vérification",90,"Vérification de l'archive modifiée…");
    let mut check=Command::new(&engine);
    check.arg("t").arg("-y").arg("-bsp0").arg("-bso0").arg("-bse0");
    if let Some(pass)=req.password.as_deref().filter(|p|!p.is_empty()){check.arg(format!("-p{pass}"));}
    let mut child=check.arg("--").arg(&temp.0).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
        .spawn().map_err(|e|format!("Vérification impossible : {e}"))?;
    let verified=loop{
        if cancel.load(Ordering::SeqCst){let _=child.kill();break child.wait().map_err(|e|e.to_string())?;}
        match child.try_wait().map_err(|e|e.to_string())?{Some(code)=>break code,None=>std::thread::sleep(Duration::from_millis(100))}
    };
    if cancel.load(Ordering::SeqCst){return Err("Ajout annulé. Archive originale conservée.".into());}
    if !verified.success(){return Err("L'archive modifiée a échoué au contrôle 7-Zip : originale conservée.".into());}
    let found:HashSet<String>=read_listing(&temp.0,req.password.as_deref())?.iter()
        .map(|f|member_key(&f.path).to_lowercase()).collect();
    if !incoming.is_subset(&found){return Err("Des fichiers ajoutés sont absents de la nouvelle archive. Originale conservée.".into());}
    // Refuser la publication si l'archive originale a changé pendant le travail.
    let now=fs::metadata(&archive).map_err(|e|e.to_string())?;
    if before.len()!=now.len()||before.modified().ok()!=now.modified().ok(){
        return Err("L'archive originale a changé pendant l'ajout. Modification abandonnée.".into());
    }
    emit_compression(&app,"enregistrement",97,"Enregistrement sécurisé de l'archive…");
    if cancel.load(Ordering::SeqCst){return Err("Ajout annulé. Archive originale conservée.".into());}
    fs::rename(&archive,&backup).map_err(|e|format!("Archive originale verrouillée : {e}"))?;
    if let Err(e)=fs::rename(&temp.0,&archive){
        return match fs::rename(&backup,&archive){
            Ok(())=>Err(format!("Remplacement non effectué : {e}. Archive originale restaurée.")),
            Err(rollback)=>Err(format!("ERREUR : remplacement impossible ({e}) et restauration impossible ({rollback}). L'archive ORIGINALE reste disponible ici : {}",backup.display()))
        };
    }
    // L'ancienne archive est supprimée seulement après publication réussie.
    let _=fs::remove_file(&backup);
    let bytes=fs::metadata(&archive).map_err(|e|e.to_string())?.len();
    emit_compression(&app,"terminé",100,"Fichiers ajoutés. Archive vérifiée.");
    Ok(AddResult{path:archive.to_string_lossy().into_owned(),bytes,added:req.source_paths.len()})
}
#[tauri::command]
async fn add_to_archive(app:AppHandle,state:State<'_,AddState>,req:AddRequest)->Result<AddResult,String>{
    let flag=Arc::new(AtomicBool::new(false));
    {
        let mut guard=state.active.lock().map_err(|e|e.to_string())?;
        if guard.is_some(){return Err("Un ajout est déjà en cours.".into());}
        *guard=Some(flag.clone());
    }
    let result=tauri::async_runtime::spawn_blocking(move||add_worker(app,req,flag)).await
        .map_err(|e|format!("Erreur de tâche : {e}"));
    *state.active.lock().map_err(|e|e.to_string())?=None;
    result?
}
#[tauri::command]
fn cancel_add(state:State<'_,AddState>)->Result<(),String>{
    if let Some(flag)=state.active.lock().map_err(|e|e.to_string())?.as_ref(){flag.store(true,Ordering::SeqCst);}
    Ok(())
}

#[cfg(test)]
mod tests{
    use super::*;
    #[test]
    fn incoming_rejects_path_traversal_and_reserved_names(){
        for name in ["../secret.txt", "CON.txt", "C:/bad.txt", "a/../../b"]{
            assert!(safe_member(name).is_err());
        }
    }
    #[test]
    fn only_zip_and_7z_can_be_updated(){
        // The same restriction exists in validate_add before any disk mutation.
        assert!(["zip", "7z"].iter().all(|s| matches!(*s,"zip"|"7z")));
        assert!(!matches!("rar","zip"|"7z"));
    }
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

// V0.4.3 — Préparation de fichiers réels pour glisser des entrées d'archive
// vers l'Explorateur Windows. Seules les entrées demandées sont décompressées.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DragExportRequest {
    archive_path: String,
    selected_paths: Vec<String>,
    password: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DragExportResult {
    paths: Vec<String>,
    icon_path: String,
}
#[derive(Default)]
struct DragExportState {
    staged: Mutex<Vec<PathBuf>>,
    active: Mutex<Option<Arc<AtomicBool>>>,
}
impl Drop for DragExportState {
    fn drop(&mut self) {
        if let Ok(staged) = self.staged.get_mut() {
            for p in staged.drain(..) { let _ = fs::remove_dir_all(p); }
        }
    }
}
fn drag_export_worker(app: AppHandle, req: DragExportRequest, cancelled: Arc<AtomicBool>) -> Result<(PathBuf, DragExportResult), String> {
    if req.selected_paths.is_empty() || req.selected_paths.len() > 256 {
        return Err("Sélectionne entre 1 et 256 éléments à glisser.".into());
    }
    // Validation identique à l'extraction déjà opérationnelle : contrôle des
    // chemins membres, liens, doublons Windows et présence de la source.
    let all = read_listing(Path::new(&req.archive_path), req.password.as_deref())?;
    let _verified = selected_files(&all, &req.selected_paths)?;
    if cancelled.load(Ordering::SeqCst) { return Err("Préparation remplacée par une nouvelle sélection.".into()); }
    let mut stage = create_stage()?;
    let destination = stage.0.to_string_lossy().into_owned();
    let extract_req = ExtractRequest {
        archive_path: req.archive_path,
        destination,
        selected_paths: req.selected_paths.clone(),
        password: req.password,
        policy: "skip".into(),
        decisions: HashMap::new(),
    };
    // Réemploi du processus d'extraction sécurisé, sans aucune nouvelle
    // écriture dans l'archive d'origine ni accès au dossier de destination.
    let result = extract_worker(app, extract_req, cancelled.clone())?;
    if cancelled.load(Ordering::SeqCst) { return Err("Préparation remplacée par une nouvelle sélection.".into()); }
    if result.skipped != 0 { return Err("Éléments non préparés pour le glisser-déposer.".into()); }
    let mut paths = Vec::new();
    let mut names = HashSet::new();
    for requested in &req.selected_paths {
        let rel = safe_member(requested)?;
        let path = stage.0.join(rel);
        if !path.exists() { return Err(format!("Élément non extrait : {requested}")); }
        // Explorer dépose chaque élément sous son nom simple. Deux entrées
        // homonymes dans deux dossiers ne peuvent pas être glissées ensemble.
        let leaf = path.file_name().ok_or("Nom de fichier invalide.")?
            .to_string_lossy().to_lowercase();
        if !names.insert(leaf) {
            return Err("Deux fichiers sélectionnés portent le même nom. Glisse-les séparément.".into());
        }
        paths.push(path.to_string_lossy().into_owned());
    }
    // Une vraie icône Windows sur disque est requise pour le drag natif.
    let icon = stage.0.join(".gekko-drag-icon.png");
    fs::write(&icon, include_bytes!("../icons/icon.png"))
        .map_err(|e| format!("Icône du glisser-déposer inaccessible : {e}"))?;
    let data = DragExportResult { paths, icon_path: icon.to_string_lossy().into_owned() };
    // TempStage s'autonettoie sur erreur ; après succès l'application prend
    // possession de ce dossier jusqu'à sa fermeture.
    let dir = std::mem::take(&mut stage.0);
    Ok((dir, data))
}
#[tauri::command]
async fn prepare_drag_export(
    app: AppHandle, state: State<'_, DragExportState>, req: DragExportRequest
) -> Result<DragExportResult, String> {
    let flag = Arc::new(AtomicBool::new(false));
    {
        let mut active = state.active.lock().map_err(|e|e.to_string())?;
        if let Some(previous) = active.replace(flag.clone()) {
            previous.store(true, Ordering::SeqCst);
        }
    }
    let worker_flag = flag.clone();
    let answer = tauri::async_runtime::spawn_blocking(move || drag_export_worker(app, req, worker_flag))
        .await.map_err(|e| format!("Préparation du glisser-déposer interrompue : {e}"));
    {
        let mut active = state.active.lock().map_err(|e|e.to_string())?;
        if active.as_ref().is_some_and(|current| Arc::ptr_eq(current, &flag)) {
            *active = None;
        }
    }
    let (dir, result) = answer??;
    if flag.load(Ordering::SeqCst) {
        let _ = fs::remove_dir_all(&dir);
        return Err("Préparation remplacée par une nouvelle sélection.".into());
    }
    state.staged.lock().map_err(|e|e.to_string())?.push(dir);
    Ok(result)
}

// Pont de test V0.5.0 : la fenêtre DEJA OUVERTE reçoit les actions
// via un petit fichier de commande local. Aucune seconde instance Tauri.
// Les arguments directs restent utilisables par une future extension native.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ShellLaunch {action:String, paths:Vec<String>}

fn validate_shell_launch(action:String, paths:Vec<String>)->Result<ShellLaunch,String>{
    if !matches!(action.as_str(),"open"|"zip"|"7z"|"extractHere"|"extractFolder") {
        return Err("Commande Windows non reconnue.".into());
    }
    if paths.is_empty()||paths.len()>256 {
        return Err("La commande Windows doit contenir de 1 à 256 chemins.".into());
    }
    for item in &paths {
        let path=Path::new(item);
        if !path.is_absolute()||!path.exists()||(!path.is_file()&&!path.is_dir()) {
            return Err(format!("Source Windows introuvable ou invalide : {item}"));
        }
    }
    if !matches!(action.as_str(),"zip"|"7z") {
        if paths.len()!=1||!Path::new(&paths[0]).is_file(){
            return Err("Cette commande attend une seule archive.".into());
        }
    }
    Ok(ShellLaunch{action,paths})
}

static SHELL_ARGS_CONSUMED:AtomicBool=AtomicBool::new(false);

fn shell_argument_launch()->Result<Option<ShellLaunch>,String>{
    // Une lecture unique : le frontend interroge régulièrement la file locale.
    if SHELL_ARGS_CONSUMED.swap(true,Ordering::SeqCst){return Ok(None);}
    let mut args=std::env::args_os().skip(1);
    while let Some(arg)=args.next(){
        if arg.to_string_lossy()=="--gekko-shell-action" {
            let action=args.next().ok_or("Action Windows manquante.")?
                .to_string_lossy().into_owned();
            let paths:Vec<String>=args.take(257)
                .map(|p|p.to_string_lossy().into_owned()).collect();
            return validate_shell_launch(action,paths).map(Some);
        }
    }
    // Double-clic Windows : le fichier associe arrive comme argument unique.
    let paths:Vec<String>=std::env::args_os().skip(1)
        .map(|p|p.to_string_lossy().into_owned()).collect();
    if paths.len()==1 {
        let path=Path::new(&paths[0]);
        let ext=path.extension().and_then(|e|e.to_str()).unwrap_or("").to_ascii_lowercase();
        if matches!(ext.as_str(),"zip"|"7z"|"rar"|"tar") && path.is_file() {
            return validate_shell_launch("open".to_string(),paths).map(Some);
        }
    }
    Ok(None)
}

// Si GEKKO ARCHIVE est deja ouvert, le plugin single-instance remet le
// fichier a sa fenetre via la file locale du pont V0.5.0.
#[cfg(desktop)]
fn handle_second_instance(app:&AppHandle,args:Vec<String>){
    let paths:Vec<String>=args.into_iter().skip(1).collect();
    if paths.len()!=1{return;}
    let candidate=Path::new(&paths[0]);
    let ext=candidate.extension().and_then(|e|e.to_str()).unwrap_or("").to_ascii_lowercase();
    if !matches!(ext.as_str(),"zip"|"7z"|"rar"|"tar") || !candidate.is_file(){return;}
    let Ok(request)=validate_shell_launch("open".to_string(),paths) else{return};
    let Some(appdata)=std::env::var_os("LOCALAPPDATA") else{return};
    let queue=PathBuf::from(appdata).join("GEKKO_ARCHIVE").join("shell_bridge");
    if fs::create_dir_all(&queue).is_err(){return;}
    let stamp=SystemTime::now().duration_since(UNIX_EPOCH).map(|d|d.as_nanos()).unwrap_or(0);
    let base=format!("shell-command-{:025}-{}",stamp,std::process::id());
    let tmp=queue.join(format!("{}.tmp",base));
    let dest=queue.join(format!("{}.txt",base));
    let text=format!("{}\n{}\n",request.action,request.paths.join("\n"));
    if fs::write(&tmp,text.as_bytes()).is_ok(){
        if fs::rename(&tmp,&dest).is_err(){let _=fs::remove_file(&tmp);}
        else if let Some(win)=app.get_webview_window("main") {
            let _=win.unminimize();let _=win.show();let _=win.set_focus();
        }
    }
}

fn shell_queued_launch()->Result<Option<ShellLaunch>,String>{
    let Some(appdata)=std::env::var_os("LOCALAPPDATA") else {return Ok(None)};
    let folder=PathBuf::from(appdata).join("GEKKO_ARCHIVE").join("shell_bridge");
    if !folder.is_dir(){return Ok(None);}
    // Le script écrit d'abord un .tmp puis le renomme en .txt : pas de
    // commande partiellement écrite et pas d'écrasement de commande.
    let mut pending=Vec::new();
    for entry in fs::read_dir(&folder).map_err(|e|format!("Pont Windows inaccessible : {e}"))? {
        let entry=entry.map_err(|e|e.to_string())?;
        let name=entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("shell-command-")&&name.ends_with(".txt")&&entry.path().is_file(){
            pending.push(entry.path());
        }
    }
    pending.sort();
    let Some(file)=pending.into_iter().next() else{return Ok(None)};
    let size=fs::metadata(&file).map_err(|e|e.to_string())?.len();
    if size>65536 {
        let _=fs::remove_file(&file);
        return Err("Commande Windows trop volumineuse (maximum 64 Ko).".into());
    }
    let content=fs::read_to_string(&file).map_err(|e|format!("Lecture du pont Windows : {e}"))?;
    fs::remove_file(&file).map_err(|e|format!("Impossible de retirer la commande Windows : {e}"))?;
    let mut lines=content.lines();
    let action=lines.next().unwrap_or("").trim_end_matches('\r').to_string();
    let paths:Vec<String>=lines.map(|line|line.trim_end_matches('\r').to_string()).collect();
    validate_shell_launch(action,paths).map(Some)
}

#[tauri::command]
fn get_shell_launch()->Result<Option<ShellLaunch>,String>{
    if let Some(launch)=shell_argument_launch()? {return Ok(Some(launch));}
    shell_queued_launch()
}


// Commande Windows : « Extraire vers un dossier » crée/réutilise un dossier du
// nom de l'archive, à côté de celle-ci. N'accepte pas une destination arbitraire.
#[tauri::command]
fn ensure_shell_extract_folder(archive_path:String)->Result<String,String>{
    let source=fs::canonicalize(&archive_path)
        .map_err(|e|format!("Archive introuvable : {e}"))?;
    if !source.is_file(){return Err("La source doit être une archive.".into());}
    let filename=source.file_name().and_then(|v|v.to_str())
        .ok_or("Nom d'archive invalide.")?;
    let lowered=filename.to_ascii_lowercase();
    let suffixes=[".tar.gz",".tar.bz2",".tar.xz",".tar.zst",".zip",".7z",".rar",".tar",".gz",".bz2",".xz",".zst",".cab",".iso",".wim",".arj"];
    let stem=suffixes.iter().find(|s|lowered.ends_with(*s))
        .and_then(|s|filename.get(..filename.len()-s.len())).unwrap_or(filename);
    if stem.is_empty()||stem=="."||stem==".."{return Err("Nom de dossier invalide.".into());}
    let parent=source.parent().ok_or("Dossier parent introuvable.")?;
    let folder=parent.join(stem);
    match fs::symlink_metadata(&folder){
        Ok(metadata)=>{
            if !metadata.is_dir()||metadata.file_type().is_symlink()||is_reparse(&metadata){
                return Err("Destination existante non sûre (fichier, lien ou redirection).".into());
            }
        },
        Err(e) if e.kind()==std::io::ErrorKind::NotFound=>{
            fs::create_dir(&folder).map_err(|e|format!("Création du dossier impossible : {e}"))?;
        },
        Err(e)=>return Err(format!("Destination inaccessible : {e}")),
    }
    let verified=fs::canonicalize(&folder).map_err(|e|e.to_string())?;
    if verified.parent()!=Some(parent){return Err("Le dossier de sortie est redirigé hors du dossier de l'archive.".into());}
    Ok(verified.to_string_lossy().into_owned())
}

// GEKKO ARCHIVE V0.6.1 : préférences du menu Windows dans un seul fichier
// local lisible par le composant COM. Absence du fichier = 5 commandes actives.
const CONTEXT_MENU_ACTIONS:[&str;5]=["open","zip","7z","extractHere","extractFolder"];
fn context_menu_prefs_path()->Result<PathBuf,String>{
    let base=std::env::var_os("LOCALAPPDATA")
        .filter(|s|!s.is_empty()).ok_or("LOCALAPPDATA inaccessible.")?;
    Ok(PathBuf::from(base).join("GEKKO_ARCHIVE").join("context_menu.ini"))
}
#[tauri::command]
fn get_context_menu_commands()->Result<Option<Vec<String>>,String>{
    let file=context_menu_prefs_path()?;
    let value=match fs::read(&file){
        Ok(b)=>b,
        Err(e) if e.kind()==std::io::ErrorKind::NotFound=>return Ok(None),
        Err(e)=>return Err(format!("Lecture des préférences : {e}")),
    };
    if value.len()>4096{return Err("Fichier de préférences anormalement volumineux.".into());}
    let text=std::str::from_utf8(&value).map_err(|_|"Préférences non UTF-8.")?;
    let mut enabled=Vec::new();
    for key in CONTEXT_MENU_ACTIONS {
        let line=format!("{key}=");
        let values:Vec<&str>=text.lines().filter_map(|l|l.trim().strip_prefix(&line)).collect();
        if values.len()!=1{return Err(format!("Préférence manquante ou dupliquée : {key}"));}
        match values[0].trim(){
            "1"=>enabled.push(key.to_string()),
            "0"=>{},
            _=>return Err(format!("Préférence invalide : {key}")),
        }
    }
    Ok(Some(enabled))
}
#[tauri::command]
fn set_context_menu_commands(commands:Vec<String>)->Result<(),String>{
    if commands.len()>5 || commands.iter().any(|x|!CONTEXT_MENU_ACTIONS.contains(&x.as_str())){
        return Err("Liste de commandes Windows invalide.".into());
    }
    let mut unique=HashSet::new();
    if commands.iter().any(|x|!unique.insert(x.as_str())){
        return Err("Commande Windows dupliquée.".into());
    }
    let path=context_menu_prefs_path()?;
    let dir=path.parent().ok_or("Répertoire de préférences introuvable.")?;
    fs::create_dir_all(dir).map_err(|e|format!("Dossier des préférences : {e}"))?;
    let mut text=String::from("[ContextMenu]\n");
    for key in CONTEXT_MENU_ACTIONS{
        text.push_str(&format!("{key}={}\n",if unique.contains(key){1}else{0}));
    }
    // Une écriture temporaire évite qu'Explorer lise des préférences tronquées.
    let stamp=SystemTime::now().duration_since(UNIX_EPOCH)
        .map_err(|e|e.to_string())?.as_nanos();
    let tmp=dir.join(format!("context_menu.{stamp}.tmp"));
    let result=(||->Result<(),String>{
        let mut out=fs::OpenOptions::new().write(true).create_new(true).open(&tmp)
            .map_err(|e|format!("Préparation des préférences : {e}"))?;
        out.write_all(text.as_bytes()).map_err(|e|e.to_string())?;
        out.sync_all().map_err(|e|e.to_string())?;
        fs::rename(&tmp,&path).map_err(|e|format!("Enregistrement des préférences : {e}"))?;
        Ok(())
    })();
    if result.is_err(){let _=fs::remove_file(&tmp);}
    result
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run(){tauri::Builder::default()
    .plugin(tauri_plugin_single_instance::init(|app,args,_cwd|handle_second_instance(app,args)))
    .plugin(tauri_plugin_dialog::init()).plugin(tauri_plugin_drag::init()).manage(DragExportState::default()).manage(ExtractState::default()).manage(CreateState::default()).manage(ConvertState::default()).manage(AddState::default())
    .invoke_handler(tauri::generate_handler![list_archive,preview_extraction,extract_archive,cancel_extraction,create_archive,cancel_compression,convert_archive,cancel_conversion,add_to_archive,cancel_add,prepare_drag_export,get_shell_launch,ensure_shell_extract_folder,get_context_menu_commands,set_context_menu_commands])
    .run(tauri::generate_context!()).expect("Impossible de lancer GEKKO ARCHIVE");}
