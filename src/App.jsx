import React, {useEffect, useMemo, useRef, useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {getCurrentWindow} from '@tauri-apps/api/window';
import {getCurrentWebview} from '@tauri-apps/api/webview';
import {open, save} from '@tauri-apps/plugin-dialog';
import {listen} from '@tauri-apps/api/event';
import {startDrag} from '@crabnebula/tauri-plugin-drag';
import {Icon} from './icons.jsx';
import heroLogo from './assets/GEKKO_ARCHIVE.png';
import brandLogo from './assets/GEKKO_ARCHIVE_LOGO.png';
import brandTitle from './assets/GEKKO_ARCHIVE_TITRE.png';
import minimizeIcon from './assets/gekko-minimize-gold.png';
import maximizeIcon from './assets/gekko-maximize-copper.png';
import closeIcon from './assets/gekko-close-ruby.png';

const mainNav = [{id:'home',text:'Accueil',icon:'home'},{id:'archive',text:'Explorer une archive',icon:'archive'}];
const actions = [
  {id:'create',text:'Créer une archive',icon:'plus'},
  {id:'open',text:'Ouvrir une archive',icon:'folder-open'},
  {id:'add',text:'Ajouter',icon:'file-plus'},
  {id:'extract',text:'Extraire une archive',icon:'package-open'},
  {id:'convert',text:'Convertir une archive',icon:'repeat'}
];
// Les preferences d'interface sont propres a GEKKO ARCHIVE et persistent entre deux lancements.
const CREATE_FORMATS=[['7z','7z'],['zip','ZIP'],['tar','TAR'],['tar.gz','TAR.GZ'],['tar.xz','TAR.XZ'],['tar.bz2','TAR.BZ2']];
const SUPPORTED_OPEN_EXTENSIONS=['zip','7z','rar','tar','gz','xz','bz2','zst','iso','cab','wim','arj','lzma'];
const SUPPORTED_SUFFIX=/\.(?:tar\.(?:gz|xz|bz2)|7z|zip|rar|tar|gz|xz|bz2|zst|iso|cab)$/i;
function stripArchiveExtension(value){return String(value).replace(SUPPORTED_SUFFIX,'');}
function createFormatSupportedPassword(format){return format==='7z'||format==='zip';}
const APPEARANCE_KEY='gekko.archive.appearance.v1';
function appearanceSetting(key,fallback){
  try {const v=JSON.parse(localStorage.getItem(APPEARANCE_KEY)||'{}');return v[key]??fallback;}
  catch {return fallback;}
}
const BACKGROUND_DATABASE='gekko.archive.background.v1';
function backgroundDatabase(){
  return new Promise((resolve,reject)=>{
    const request=indexedDB.open(BACKGROUND_DATABASE,1);
    request.onupgradeneeded=()=>request.result.createObjectStore('images');
    request.onsuccess=()=>resolve(request.result);
    request.onerror=()=>reject(request.error||new Error('Stockage du fond inaccessible.'));
  });
}
async function backgroundImageRead(){
  const db=await backgroundDatabase();
  try {return await new Promise((resolve,reject)=>{
    const tx=db.transaction('images','readonly');
    const req=tx.objectStore('images').get('active');
    req.onsuccess=()=>resolve(req.result||null);
    req.onerror=()=>reject(req.error||new Error('Lecture du fond impossible.'));
  });} finally {db.close();}
}
async function backgroundImageSave(image){
  const db=await backgroundDatabase();
  try {await new Promise((resolve,reject)=>{
    const tx=db.transaction('images','readwrite');
    tx.objectStore('images').put(image,'active');
    tx.oncomplete=resolve;
    tx.onabort=()=>reject(tx.error||new Error('Ecriture interrompue.'));
    tx.onerror=()=>reject(tx.error||new Error('Sauvegarde impossible.'));
  });} finally {db.close();}
}

const menuLabels = [
  ['zip','Compresser en ZIP'], ['7z','Compresser en 7z'],
  ['extractHere','Extraire ici'], ['extractFolder','Extraire dans un dossier…'],
  ['open','Ouvrir avec GEKKO ARCHIVE']
];
function bytes(value) {
  if (!Number.isFinite(value)) return '—';
  if (value < 1024) return `${value} o`;
  const units=['Ko','Mo','Go','To'];let v=value,i=-1;
  do {v/=1024;i++;} while(v>=1024 && i<units.length-1);
  return `${v.toLocaleString('fr-FR',{maximumFractionDigits:1})} ${units[i]}`;
}
function normalize(value) {return String(value||'').replaceAll('\\','/').replace(/^\.\//,'').replace(/^\/+|\/+$/g,'');}
// Par défaut, extraire dans le même dossier que le fichier archive (chemins Windows et UNC).
function archiveParentDirectory(path) {
  const value=String(path||'');
  const index=Math.max(value.lastIndexOf('\\'),value.lastIndexOf('/'));
  if(index<0)return '';
  // Une archive directement à la racine d'un disque doit pointer vers C:\, pas C:.
  if(index===2 && /^[A-Za-z]:[\\/]/.test(value))return value.slice(0,3);
  return value.slice(0,index)||value.slice(0,1);
}
function childrenOf(files, current) {
  // Reconstruit les dossiers implicites : beaucoup de ZIP n'ont pas d'entrée de dossier explicite.
  const all=new Map();
  for (const f of files) {
    const key=normalize(f.path);if(!key)continue;
    const parts=key.split('/');
    for(let i=1;i<parts.length;i++){
      const parent=parts.slice(0,i).join('/');
      if(!all.has(parent))all.set(parent,{path:parent,isDir:true,size:0,packedSize:null,modified:''});
    }
    all.set(key,{...f,path:key});
  }
  const prefix=current?current+'/':'';
  return [...all.values()].filter(f=>{
    if(!f.path.startsWith(prefix) || f.path===current)return false;
    const relative=f.path.slice(prefix.length);
    return relative.length>0 && !relative.includes('/');
  }).sort((a,b)=> Number(b.isDir)-Number(a.isDir)||a.path.localeCompare(b.path,'fr',{numeric:true}));
}
function AppButton({action,primary=false,onClick}) {
  return <button className={`toolbtn${primary?' primary':''}`} onClick={onClick}><Icon name={action.icon}/>{action.text}</button>;
}
function Settings({bg,setBg,alpha,setAlpha,info,setInfo,menuOps,setMenuOps,setImage,menuReady,menuStatus,backgroundStatus}) {
  const fileInput=useRef(null);
  return <div className="page-inner">
    <div className="crumbs">Accueil / <strong>Paramètres</strong></div>
    <div className="workspace-heading"><div><h1>Personnalisation</h1><p>Apparence et commandes Windows 11</p></div></div>
    <section className="setting-section"><h2>Apparence</h2>
      <div className="setting-row"><div><label htmlFor="bgSelector">Fond de l'interface</label><small>Choisir une ambiance propre à GEKKO ARCHIVE</small></div>
        <select id="bgSelector" value={bg} onChange={e=>setBg(e.target.value)}><option value="default">Bleu & cuivre</option><option value="amber">Or nocturne</option><option value="blue">Bleu profond</option><option value="custom">Image personnelle</option></select></div>
      <div className="setting-row"><div><label htmlFor="alphaSelector">Opacité</label><small>Rendu visuel de l'interface</small></div><select id="alphaSelector" value={alpha} onChange={e=>setAlpha(e.target.value)}><option value="0.56">Très transparent</option><option value="0.82">Transparent</option><option value="0.97">Opaque</option></select></div>
      <div className="setting-row"><div><label>Fond personnalisé</label><small>Aperçu d'une image locale</small></div><button className="toolbtn" onClick={()=>fileInput.current?.click()}><Icon name="folder-open"/> Parcourir…</button>
        <input ref={fileInput} className="hidden" type="file" accept="image/*" onChange={e=>{if(e.target.files?.[0])setImage(e.target.files[0]);e.target.value='';}}/></div>
      {backgroundStatus&&<p role="status" aria-live="polite">{backgroundStatus}</p>}
      <div className="setting-row"><div><label htmlFor="infoToggle">Panneau d'informations</label><small>Affiché sous le contenu d'une archive</small></div><input id="infoToggle" type="checkbox" checked={info} onChange={e=>setInfo(e.target.checked)}/></div>
    </section>
    <section className="setting-section"><h2>Menu contextuel Windows 11</h2><p>Choisis les commandes qui apparaissent au clic droit dans l’Explorateur Windows. Les changements sont enregistrés localement et pris en compte à l’ouverture du menu.</p>
      {menuLabels.map(([id,label])=><div className="setting-row" key={id}><label htmlFor={'menu_'+id}>{label}</label><input id={'menu_'+id} type="checkbox" disabled={!menuReady} checked={menuOps.includes(id)} onChange={e=>setMenuOps(current=>e.target.checked?[...current,id]:current.filter(x=>x!==id))}/></div>)}
      <p role="status" aria-live="polite">{menuStatus}</p>
    </section>
  </div>;
}
function CreationDialog({onClose,onCreated,initialSources=[],initialFormat='7z',initialError=''}) {
  const leaf=path=>String(path||'').split(/[\\/]/).filter(Boolean).at(-1)||'Archive';
  const [sources,setSources]=useState(()=>initialSources);
  const [format,setFormat]=useState(()=>initialFormat);
  const [destination,setDestination]=useState(()=>initialSources.length?suggestedOutput(initialSources,initialFormat):'');
  const [level,setLevel]=useState('5');
  const [password,setPassword]=useState('');
  const [passwordConfirm,setPasswordConfirm]=useState('');
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState(initialError);
  const [progress,setProgress]=useState({phase:'',percent:0,message:''});
  const [result,setResult]=useState(null);
  const [cancelAsked,setCancelAsked]=useState(false);
  useEffect(()=>{let unlisten;let mounted=true;
    listen('gekko-compression-progress',event=>{if(mounted)setProgress(event.payload);})
      .then(fn=>{if(mounted)unlisten=fn;else fn();}).catch(()=>{});
    return ()=>{mounted=false;unlisten?.();};
  },[]);
  function suggestedOutput(paths,fmt){
    if(!paths.length)return '';
    const dir=archiveParentDirectory(paths[0]);
    const basename=paths.length===1?leaf(paths[0]):'Nouvelle_archive';
    const base=stripArchiveExtension(basename)||'Nouvelle_archive';
    return (dir.endsWith('\\')||dir.endsWith('/')?dir:dir+'\\')+base+'.'+fmt;
  }
  async function chooseFiles(directory){
    if(busy)return;
    try{
      const chosen=await open({directory,multiple:!directory});
      if(!chosen)return;
      const paths=Array.isArray(chosen)?chosen:[chosen];
      setSources(paths);setDestination(suggestedOutput(paths,format));setResult(null);setError('');
    }catch(e){setError(String(e));}
  }
  function changeFormat(fmt){
    setFormat(fmt);
    setDestination(prev=>prev?stripArchiveExtension(prev)+'.'+fmt:suggestedOutput(sources,fmt));
    if(!createFormatSupportedPassword(fmt)){setPassword('');setPasswordConfirm('');}
  }
  async function chooseDestination(){
    try{
      const chosen=await save({defaultPath:destination||'Nouvelle_archive.'+format,
        filters:[{name:format.toUpperCase(),extensions:[format]}]});
      if(chosen)setDestination(chosen.toLowerCase().endsWith('.'+format)?chosen:stripArchiveExtension(chosen)+'.'+format);
    }catch(e){setError(String(e));}
  }
  async function launch(){
    if(busy)return;
    if(!sources.length){setError('Sélectionne des fichiers ou un dossier source.');return;}
    if(!destination.trim()){setError("Choisis l'emplacement de l'archive.");return;}
    if(!createFormatSupportedPassword(format)&&password){setError('Le chiffrement est disponible uniquement pour ZIP et 7z.');return;}
    if(password!==passwordConfirm){setError('Les deux mots de passe ne correspondent pas.');return;}
    setError('');setBusy(true);setCancelAsked(false);
    setProgress({phase:'préparation',percent:0,message:'Préparation…'});
    try{
      const r=await invoke('create_archive',{req:{sourcePaths:sources,destination,
        format,level:Number(level),password:password||null}});
      setResult(r);onCreated(r);
    }catch(e){setError(String(e));}finally{setBusy(false);}
  }
  async function cancel(){setCancelAsked(true);try{await invoke('cancel_compression');}catch(e){setError(String(e));}}
  return <div className="extract-overlay" role="presentation"><section className="extract-modal" role="dialog" aria-modal="true" aria-label="Créer une archive">
    <div className="extract-header"><Icon name="plus"/><h2>Créer une archive</h2><button className="iconbtn" onClick={onClose} disabled={busy} aria-label="Fermer"><Icon name="close"/></button></div>
    <div className="create-sources"><div className="create-source-label"><strong>Fichiers et dossiers à compresser</strong><span>{sources.length?`${sources.length} élément(s)`:'Aucune source sélectionnée'}</span></div>
      {sources.length>0&&<div className="create-path-list" title={sources.join('\n')}>{sources.map(item=><div key={item}>{leaf(item)}</div>)}</div>}
      <div className="create-source-buttons"><button className="toolbtn" disabled={busy} onClick={()=>chooseFiles(false)}><Icon name="file"/> Choisir des fichiers</button><button className="toolbtn" disabled={busy} onClick={()=>chooseFiles(true)}><Icon name="folder-open"/> Choisir un dossier</button></div>
      <small>La sélection multiple de fichiers doit provenir d'un même dossier.</small>
    </div>
    <label className="field">Emplacement et nom de l'archive</label>
    <div className="extract-destination"><input value={destination} disabled={busy} onChange={e=>setDestination(e.target.value)} placeholder="Dossier\\Archive.7z"/><button className="toolbtn" disabled={busy} onClick={chooseDestination}><Icon name="folder-open"/> Parcourir</button></div>
    <div className="extract-grid"><label className="field">Format<select value={format} disabled={busy} onChange={e=>changeFormat(e.target.value)}>{CREATE_FORMATS.map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label>
      <label className="field">Niveau de compression<select value={level} disabled={busy||format==='tar'} onChange={e=>setLevel(e.target.value)}><option value="0">Sans compression</option><option value="1">Rapide</option><option value="5">Normal</option><option value="9">Maximum</option></select></label></div>
    {createFormatSupportedPassword(format)?<div className="extract-grid"><label className="field">Mot de passe (facultatif)<input type="password" autoComplete="new-password" disabled={busy} value={password} onChange={e=>setPassword(e.target.value)}/></label>
      <label className="field">Confirmer le mot de passe<input type="password" autoComplete="new-password" disabled={busy} value={passwordConfirm} onChange={e=>setPasswordConfirm(e.target.value)}/></label></div>:<p className="fine-print">Ce format ne prend pas en charge le chiffrement. TAR regroupe les fichiers sans compression ; TAR.GZ, TAR.XZ et TAR.BZ2 utilisent deux couches.</p>}
    {password&&createFormatSupportedPassword(format)&&<p className="fine-print">Chiffrement AES-256. En 7z, les noms peuvent être masqués ; en ZIP, ils restent visibles.</p>}
    {busy&&<div className="extract-progress" role="status"><div className="extract-progress-caption"><span>{progress.message||'Compression en cours…'}</span><strong>{progress.percent}%</strong></div><div className="extract-track"><div style={{width:`${progress.percent}%`}}/></div></div>}
    {error&&<div role="alert" className="error-message">{error}</div>}
    {result&&<div role="status" className="extract-success"><Icon name="check"/><strong>Archive créée et vérifiée</strong><p>{result.path}<br/>{bytes(result.bytes)}</p></div>}
    <div className="extract-footer">{busy?<button className="toolbtn" disabled={cancelAsked} onClick={cancel}>{cancelAsked?'Annulation demandée…':'Annuler la compression'}</button>:<button className="toolbtn" onClick={onClose}>{result?'Fermer':'Annuler'}</button>}
      {!busy&&!result&&<button className="toolbtn primary" onClick={launch}><Icon name="plus"/> Créer l'archive</button>}
      {!busy&&result&&<button className="toolbtn primary" onClick={()=>{onClose();onCreated(result,true);}}><Icon name="folder-open"/> Ouvrir l'archive</button>}
    </div>
    <p className="fine-print">Aucun fichier source n'est modifié. Une archive existante n'est jamais écrasée automatiquement.</p>
  </section></div>;
}

function DeleteDialog({archive,selected,defaultPassword,onClose,onDeleted}) {
  const [password,setPassword]=useState(defaultPassword||'');
  const [busy,setBusy]=useState(false);
  const [cancelAsked,setCancelAsked]=useState(false);
  const [error,setError]=useState('');
  const [result,setResult]=useState(null);
  const [progress,setProgress]=useState({percent:0,message:''});
  useEffect(()=>{
    let active=true;let off;
    listen('gekko-deletion-progress',e=>{if(active)setProgress(e.payload);})
      .then(unlisten=>{if(active)off=unlisten;else unlisten();}).catch(()=>{});
    return ()=>{active=false;off?.();};
  },[]);
  async function remove(){
    if(busy||!selected.length)return;
    setBusy(true);setCancelAsked(false);setError('');setResult(null);
    setProgress({percent:0,message:'Préparation de la copie…'});
    try {
      const r=await invoke('delete_from_archive',{req:{
        archivePath:archive.path,selectedPaths:selected,password:password||null
      }});
      setResult(r);
      await onDeleted(r,password);
    } catch(e){setError(String(e));}
    finally{setBusy(false);}
  }
  async function cancel(){
    setCancelAsked(true);
    try{await invoke('cancel_delete');}catch(e){setError(String(e));}
  }
  return <div className="extract-overlay" role="presentation"><section className="extract-modal" role="dialog" aria-modal="true" aria-label="Supprimer de l’archive">
    <div className="extract-header"><Icon name="trash"/><h2>Supprimer de l’archive</h2><button className="iconbtn" disabled={busy} onClick={onClose} aria-label="Fermer"><Icon name="close"/></button></div>
    <div className="extract-summary"><strong>{archive.name}</strong><span>{selected.length} élément(s) sélectionné(s)</span></div>
    <p className="delete-confirm-note">Les éléments suivants seront supprimés de l’archive. Les dossiers sélectionnés incluent tous leurs fichiers et sous-dossiers.</p>
    <div className="create-path-list delete-path-list">{selected.map(s=><div key={s}>{s}</div>)}</div>
    <label className="field">Mot de passe de l’archive (si nécessaire)<input type="password" autoComplete="off" disabled={busy} value={password} onChange={e=>setPassword(e.target.value)} placeholder="Laisser vide si l’archive n’est pas protégée"/></label>
    {busy&&<div className="extract-progress" role="status"><div className="extract-progress-caption"><span>{progress.message||'Suppression en cours…'}</span><strong>{progress.percent}%</strong></div><div className="extract-track"><div style={{width:`${progress.percent}%`}}/></div></div>}
    {error&&<div role="alert" className="error-message">{error}</div>}
    {result&&<div className="extract-success" role="status"><Icon name="check"/><strong>Archive mise à jour et vérifiée</strong><p>{result.removed} entrée(s) supprimée(s). Les autres fichiers sont conservés.</p></div>}
    <div className="extract-footer">
      {busy?<button className="toolbtn" disabled={cancelAsked} onClick={cancel}>{cancelAsked?'Annulation demandée…':'Annuler la suppression'}</button>:<button className="toolbtn" onClick={onClose}>{result?'Fermer':'Annuler'}</button>}
      {!busy&&!result&&<button className="toolbtn danger" onClick={remove}><Icon name="trash"/> Confirmer la suppression</button>}
    </div>
    <p className="fine-print">ZIP et 7z uniquement. Une copie est modifiée puis vérifiée avant remplacement ; l’archive originale reste intacte en cas d’échec.</p>
  </section></div>;
}

function AddDialog({archive,defaultPassword,onClose,onAdded,initialSources=[]}) {
  const [sources,setSources]=useState(()=>initialSources);
  const [password,setPassword]=useState(defaultPassword||'');
  const [busy,setBusy]=useState(false);
  const [cancelAsked,setCancelAsked]=useState(false);
  const [error,setError]=useState('');
  const [result,setResult]=useState(null);
  const [progress,setProgress]=useState({percent:0,message:''});
  useEffect(()=>{let unlisten;let mounted=true;
    listen('gekko-compression-progress',e=>{if(mounted)setProgress(e.payload);})
      .then(off=>{if(mounted)unlisten=off;else off();}).catch(()=>{});
    return ()=>{mounted=false;unlisten?.();};
  },[]);
  const leaf=path=>String(path||'').split(/[\\/]/).filter(Boolean).at(-1)||'';
  async function choose(directory){
    if(busy)return;
    try{
      const chosen=await open({directory,multiple:!directory});
      if(chosen){setSources(Array.isArray(chosen)?chosen:[chosen]);setError('');setResult(null);}
    }catch(e){setError(String(e));}
  }
  async function add(sourcePaths=sources){
    if(!sourcePaths.length){setError('Sélectionne au moins un fichier ou un dossier.');return;}
    if(busy){setError('Un ajout est déjà en cours.');return;}
    setBusy(true);setError('');setCancelAsked(false);setProgress({percent:0,message:'Préparation de l’ajout…'});
    try{
      const r=await invoke('add_to_archive',{req:{archivePath:archive.path,sourcePaths:sourcePaths,password:password||null}});
      setResult(r);onAdded(r,password);
    }catch(e){setError(String(e));}
    finally{setBusy(false);}
  }
  async function cancel(){setCancelAsked(true);try{await invoke('cancel_add');}catch(e){setError(String(e));}}
  const launchedFromDrop=useRef(null);
  useEffect(()=>{
    if(initialSources.length && launchedFromDrop.current!==initialSources){
      launchedFromDrop.current=initialSources;
      if(busy){setError('Attends la fin de l’ajout en cours.');return;}
      setSources(initialSources);
      add(initialSources);
    }
  },[initialSources]);
  return <div className="extract-overlay" role="presentation"><section className="extract-modal" data-gekkodrop="modal-add" role="dialog" aria-modal="true" aria-label="Ajouter à une archive">
    <div className="extract-header"><Icon name="file-plus"/><h2>Ajouter à une archive</h2><button className="iconbtn" disabled={busy} onClick={onClose} aria-label="Fermer"><Icon name="close"/></button></div>
    <div className="extract-summary"><strong>{archive.name}</strong><span>Ajout à la racine de l'archive</span></div>
    <div className="create-sources"><div className="create-source-label"><strong>Fichiers et dossiers à ajouter</strong><span>{sources.length?`${sources.length} élément(s)`:'Aucune source'}</span></div>
      {sources.length>0&&<div className="create-path-list">{sources.map(s=><div key={s}>{leaf(s)}</div>)}</div>}
      <div className="create-source-buttons"><button className="toolbtn" disabled={busy} onClick={()=>choose(false)}><Icon name="file"/> Choisir des fichiers</button><button className="toolbtn" disabled={busy} onClick={()=>choose(true)}><Icon name="folder-open"/> Choisir un dossier</button></div>
      <small>La sélection multiple doit provenir d'un même dossier. Aucun fichier existant n'est remplacé.</small>
    </div>
    <label className="field">Mot de passe de l'archive (si nécessaire)<input type="password" autoComplete="off" value={password} disabled={busy} onChange={e=>setPassword(e.target.value)} placeholder="Laisser vide si l'archive n'est pas protégée"/></label>
    {busy&&<div className="extract-progress" role="status"><div className="extract-progress-caption"><span>{progress.message||'Ajout en cours…'}</span><strong>{progress.percent}%</strong></div><div className="extract-track"><div style={{width:`${progress.percent}%`}}/></div></div>}
    {error&&<div className="error-message" role="alert">{error}</div>}
    {result&&<div className="extract-success" role="status"><Icon name="check"/><strong>Archive mise à jour et vérifiée</strong><p>{result.path}<br/>{bytes(result.bytes)}</p></div>}
    <div className="extract-footer">
      {busy?<button className="toolbtn" disabled={cancelAsked} onClick={cancel}>{cancelAsked?'Annulation demandée…':'Annuler l’ajout'}</button>:<button className="toolbtn" onClick={onClose}>{result?'Fermer':'Annuler'}</button>}
      {!busy&&!result&&<button className="toolbtn primary" onClick={()=>add()}><Icon name="file-plus"/> Ajouter</button>}
    </div>
    <p className="fine-print">Disponible pour ZIP et 7z. Le logiciel travaille sur une copie, vérifie le résultat, puis remplace l'archive originale. Les sources restent inchangées.</p>
  </section></div>;
}

function ConversionDialog({archive,defaultPassword,onClose,onConverted}) {
  const suggestedFormat=path=>/\.7z$/i.test(String(path||''))?'zip':'7z';
  const suggestedDestination=(path,fmt)=>{
    if(!path)return '';
    const parent=archiveParentDirectory(path);
    const name=String(path).split(/[\\/]/).at(-1)||'archive';
    const stem=name.replace(/\.(tar\.(?:gz|bz2|xz|zst)|zip|7z|rar|tar|gz|bz2|xz|zst)$/i,'')||'archive';
    return (parent.endsWith('\\')||parent.endsWith('/')?parent:parent+'\\')+stem+'_converti.'+fmt;
  };
  const [source,setSource]=useState(archive?.path||'');
  const [format,setFormat]=useState(()=>suggestedFormat(archive?.path));
  const [destination,setDestination]=useState(()=>suggestedDestination(archive?.path,suggestedFormat(archive?.path)));
  const [level,setLevel]=useState('5');
  const [sourcePassword,setSourcePassword]=useState(defaultPassword||'');
  const [password,setPassword]=useState('');
  const [confirm,setConfirm]=useState('');
  const [busy,setBusy]=useState(false);
  const [cancelAsked,setCancelAsked]=useState(false);
  const [error,setError]=useState('');
  const [result,setResult]=useState(null);
  const [progress,setProgress]=useState({phase:'préparation',percent:0,message:''});
  useEffect(()=>{
    let active=true;const off=[];
    const add=(name,callback)=>listen(name,e=>{if(active)callback(e.payload)}).then(fn=>{if(active)off.push(fn);else fn();}).catch(()=>{});
    add('gekko-extraction-progress',p=>setProgress({phase:'extraction',percent:Math.round((p.percent||0)*.45),message:'Lecture et extraction temporaire…'}));
    add('gekko-compression-progress',p=>setProgress({phase:'compression',percent:45+Math.round((p.percent||0)*.54),message:'Création et vérification de la nouvelle archive…'}));
    add('gekko-conversion-progress',p=>{
      if(p.phase==='terminé')setProgress(p);
      else if(p.phase==='préparation')setProgress(p);
    });
    return ()=>{active=false;off.forEach(fn=>fn());};
  },[]);
  async function chooseSource(){
    if(busy)return;
    try {
      const path=await open({multiple:false,directory:false,filters:[{name:'Archives',extensions:SUPPORTED_OPEN_EXTENSIONS}]});
      if(path){const next=suggestedFormat(path);setSource(path);setFormat(next);setDestination(suggestedDestination(path,next));setSourcePassword(path===archive?.path?defaultPassword||'':'');setResult(null);setError('');}
    }catch(e){setError(String(e));}
  }
  function changeFormat(next){setFormat(next);setDestination(suggestedDestination(source,next));setResult(null);setError('');}
  async function chooseDestination(){
    try {
      const chosen=await save({defaultPath:destination||'Archive_convertie.'+format,filters:[{name:format.toUpperCase(),extensions:[format]}]});
      if(chosen)setDestination(/\.(zip|7z)$/i.test(chosen)?chosen:chosen+'.'+format);
    }catch(e){setError(String(e));}
  }
  async function launch(){
    if(busy)return;
    if(!source){setError('Sélectionne une archive source.');return;}
    if(!destination.trim()){setError('Choisis un emplacement de sortie.');return;}
    if(password!==confirm){setError('Les mots de passe de sortie ne correspondent pas.');return;}
    setBusy(true);setCancelAsked(false);setError('');setResult(null);
    setProgress({phase:'préparation',percent:0,message:'Préparation de la conversion…'});
    try {
      const r=await invoke('convert_archive',{req:{sourcePath:source,destination,format,level:Number(level),sourcePassword:sourcePassword||null,password:password||null}});
      setResult(r);onConverted(r);
    }catch(e){setError(String(e));}finally{setBusy(false);}
  }
  async function cancel(){setCancelAsked(true);try{await invoke('cancel_conversion');}catch(e){setError(String(e));}}
  return <div className="extract-overlay" role="presentation"><section className="extract-modal" role="dialog" aria-modal="true" aria-label="Convertir une archive">
    <div className="extract-header"><Icon name="repeat"/><h2>Convertir une archive</h2><button className="iconbtn" disabled={busy} onClick={onClose} aria-label="Fermer"><Icon name="close"/></button></div>
    <label className="field">Archive source</label>
    <div className="extract-destination"><input value={source} readOnly placeholder="Sélectionne une archive à convertir…"/><button className="toolbtn" disabled={busy} onClick={chooseSource}><Icon name="folder-open"/> Parcourir</button></div>
    <label className="field">Emplacement et nom de l'archive convertie</label>
    <div className="extract-destination"><input value={destination} disabled={busy} onChange={e=>setDestination(e.target.value)} placeholder="Dossier\\Archive_convertie.7z"/><button className="toolbtn" disabled={busy} onClick={chooseDestination}><Icon name="folder-open"/> Parcourir</button></div>
    <div className="extract-grid"><label className="field">Format de sortie<select value={format} disabled={busy} onChange={e=>changeFormat(e.target.value)}><option value="7z">7z</option><option value="zip">ZIP</option></select></label>
      <label className="field">Niveau de compression<select value={level} disabled={busy} onChange={e=>setLevel(e.target.value)}><option value="0">Sans compression</option><option value="1">Rapide</option><option value="5">Normal</option><option value="9">Maximum</option></select></label></div>
    <label className="field">Mot de passe de l'archive source (si nécessaire)<input type="password" autoComplete="off" disabled={busy} value={sourcePassword} onChange={e=>setSourcePassword(e.target.value)} placeholder="Pour une archive chiffrée"/></label>
    <div className="extract-grid"><label className="field">Mot de passe de sortie (facultatif)<input type="password" autoComplete="new-password" disabled={busy} value={password} onChange={e=>setPassword(e.target.value)}/></label>
      <label className="field">Confirmer le mot de passe<input type="password" autoComplete="new-password" disabled={busy} value={confirm} onChange={e=>setConfirm(e.target.value)}/></label></div>
    {busy&&<div className="extract-progress" role="status"><div className="extract-progress-caption"><span>{progress.message||'Conversion en cours…'}</span><strong>{progress.percent}%</strong></div><div className="extract-track"><div style={{width:`${progress.percent}%`}}/></div></div>}
    {error&&<div role="alert" className="error-message">{error}</div>}
    {result&&<div className="extract-success" role="status"><Icon name="check"/><strong>Conversion terminée</strong><p>{result.path}<br/>{bytes(result.bytes)}</p></div>}
    <div className="extract-footer">{busy?<button className="toolbtn" disabled={cancelAsked} onClick={cancel}>{cancelAsked?'Annulation demandée…':'Annuler la conversion'}</button>:<button className="toolbtn" onClick={onClose}>{result?'Fermer':'Annuler'}</button>}
      {!busy&&!result&&<button className="toolbtn primary" onClick={launch}><Icon name="repeat"/> Convertir</button>}
    </div>
    <p className="fine-print">L'original est conservé. Conversion locale avec vérification automatique ; aucun fichier existant n'est écrasé.</p>
  </section></div>;
}

function ExtractionDialog({archive,selected,onClose,onFinished,defaultPassword,initialDestination,autoStart=false,initialPreview=null,initialError=''}) {
  const [destination,setDestination]=useState(()=>initialDestination||archiveParentDirectory(archive.path));
  const [password,setPassword]=useState(defaultPassword||'');
  const [policy,setPolicy]=useState('ask');
  const [preview,setPreview]=useState(initialPreview);
  const [decisions,setDecisions]=useState(()=>initialPreview?.conflicts?Object.fromEntries(initialPreview.conflicts.map(k=>[k,'skip'])):{});
  const [working,setWorking]=useState(false);
  const [phase,setPhase]=useState({phase:'préparation',percent:0,message:''});
  const [result,setResult]=useState(null);
  const [error,setError]=useState(initialError);
  const [cancelAsked,setCancelAsked]=useState(false);
  useEffect(()=>{let unsub;let mounted=true;
    listen('gekko-extraction-progress',event=>{if(mounted)setPhase(event.payload);}).then(fn=>{if(mounted)unsub=fn;else fn();}).catch(()=>{});
    return ()=>{mounted=false;unsub?.();};
  },[]);
  const req={archivePath:archive.path,destination,selectedPaths:selected,password:password||null,policy,decisions};
  async function chooseFolder(){
    try{const path=await open({directory:true,multiple:false});if(path){setDestination(path);setPreview(null);setError('');}}
    catch(e){setError(String(e));}
  }
  async function prepare(destinationOverride=null){
    if(working)return;
    if(!(destinationOverride||destination)){setError('Choisis un dossier de destination.');return;}
    setError('');setWorking(true);
    setPhase({phase:'vérification',percent:0,message:''});
    try {
      const effectiveReq=destinationOverride?{...req,destination:destinationOverride}:req;
      // Vérification automatique au clic sur Extraire, sans étape intermédiaire.
      const p=await invoke('preview_extraction',{req:effectiveReq});
      if(policy==='ask'&&p.conflicts.length>0){
        // Il faut seulement un deuxième clic lorsqu'un véritable conflit demande une décision.
        setPreview(p);
        setDecisions(Object.fromEntries(p.conflicts.map(k=>[k,'skip'])));
        return;
      }
      setPreview(null);
      setCancelAsked(false);
      setPhase({phase:'préparation',percent:0,message:'Démarrage…'});
      const r=await invoke('extract_archive',{req:effectiveReq});
      setResult(r);
      onFinished(r);
    }
    catch(e){setError(String(e));}finally{setWorking(false);}
  }
  async function launch(){
    if(!preview)return;
    setWorking(true);setError('');setCancelAsked(false);
    setPhase({phase:'préparation',percent:0,message:'Démarrage…'});
    try {const r=await invoke('extract_archive',{req});setResult(r);onFinished(r);}
    catch(e){setError(String(e));}finally{setWorking(false);}
  }
  async function cancel(){try{setCancelAsked(true);await invoke('cancel_extraction');}catch(e){setError(String(e));}}
  const launchedFromDrop=useRef(false);
  useEffect(()=>{
    if(autoStart && initialDestination && launchedFromDrop.current!==initialDestination){
      launchedFromDrop.current=initialDestination;
      setDestination(initialDestination);
      setPreview(null);
      prepare(initialDestination);
    }
  },[initialDestination,autoStart]);
  return <div className="extract-overlay" role="presentation">
    <section className="extract-modal" data-gekkodrop="modal-extract" role="dialog" aria-modal="true" aria-label="Extraire les fichiers">
      <div className="extract-header"><Icon name="package-open"/><h2>Extraire une archive</h2><button className="iconbtn" disabled={working} onClick={onClose} aria-label="Fermer"><Icon name="close"/></button></div>
      <div className="extract-summary"><strong>{archive.name}</strong><span>{selected.length?`${selected.length} élément(s) sélectionné(s)`:'Archive complète'}</span></div>
      <label className="field">Dossier de destination</label>
      <div className="extract-destination"><input value={destination} readOnly placeholder="Choisir un emplacement sur Windows…"/><button className="toolbtn" disabled={working} onClick={chooseFolder}><Icon name="folder-open"/> Parcourir</button></div>
      <div className="extract-grid"><label className="field">Fichiers existants<select value={policy} disabled={working} onChange={e=>{setPolicy(e.target.value);setPreview(null);}}><option value="ask">Demander</option><option value="skip">Ignorer</option><option value="replace">Remplacer</option></select></label>
      <label className="field">Mot de passe (si nécessaire)<input type="password" autoComplete="off" value={password} disabled={working} onChange={e=>{setPassword(e.target.value);setPreview(null);}} placeholder="Non conservé après fermeture"/></label></div>
      {preview&&!result&&<div className="extract-preview">
        <strong>{preview.files} fichier(s) · {bytes(preview.totalBytes)} à extraire</strong>
        <p>{preview.conflicts.length?`${preview.conflicts.length} fichier(s) existent déjà dans la destination.`:'Aucun conflit de fichiers détecté.'}</p>
        {policy==='ask'&&preview.conflicts.length>0&&<div className="extract-conflicts"><div className="extract-conflicts-head"><span>Décisions par fichier</span><div><button onClick={()=>setDecisions(Object.fromEntries(preview.conflicts.map(k=>[k,'skip'])))}>Tout ignorer</button><button onClick={()=>setDecisions(Object.fromEntries(preview.conflicts.map(k=>[k,'replace'])))}>Tout remplacer</button></div></div>{preview.conflicts.map(name=><label className="extract-conflict" key={name}><span title={name}>{name}</span><select value={decisions[name]||'skip'} onChange={e=>setDecisions(old=>({...old,[name]:e.target.value}))}><option value="skip">Ignorer</option><option value="replace">Remplacer</option></select></label>)}</div>}
        {policy==='replace'&&preview.conflicts.length>0&&<p className="extract-warning">Les fichiers portant le même nom seront remplacés après extraction réussie.</p>}
      </div>}
      {working&&phase.message&&<div className="extract-progress" role="status"><div className="extract-progress-caption"><span>{phase.message}</span><strong>{phase.percent}%</strong></div><div className="extract-track"><div style={{width:`${phase.percent}%`}}/></div></div>}
      {error&&<div className="error-message" role="alert">{error}</div>}
      {result&&<div className="extract-success" role="status"><Icon name="check"/><strong>Extraction terminée</strong><p>{result.extracted} fichier(s) extrait(s), {result.skipped} ignoré(s).<br/>Destination : {result.destination}</p></div>}
      <div className="extract-footer">
        {working&&phase.message?<button className="toolbtn" disabled={cancelAsked} onClick={cancel}>{cancelAsked?'Annulation demandée…':'Annuler l’extraction'}</button>:<button className="toolbtn" onClick={onClose}>{result?'Fermer':'Annuler'}</button>}
        {!result&&!working&&(preview?<button className="toolbtn primary" onClick={launch}><Icon name="package-open"/> Confirmer l’extraction</button>:<button className="toolbtn primary" onClick={()=>prepare()}><Icon name="package-open"/> Extraire</button>)}
      </div>
      <p className="fine-print">Extraction locale via 7-Zip. Les fichiers ne sont jamais remplacés sans la politique choisie.</p>
    </section>
  </div>;
}

export default function App(){
  const [route,setRoute]=useState('home');
  const [collapsed,setCollapsed]=useState(false);
  const [archive,setArchive]=useState(null);
  const [folder,setFolder]=useState('');
  const [search,setSearch]=useState('');
  const [selected,setSelected]=useState([]);
  const [outDragStatus,setOutDragStatus]=useState('');
  const outDragReady=useRef(null);
  const outDragArmed=useRef(null);
  const outDragTicket=useRef(0);
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState('');
  const [toast,setToast]=useState('');
  const [bg,setBg]=useState(()=>appearanceSetting('bg','default'));
  const [alpha,setAlpha]=useState(()=>appearanceSetting('alpha','0.82'));
  const [info,setInfo]=useState(()=>appearanceSetting('info',true));
  const [menuOps,setMenuOps]=useState(()=>{
    const defaults=['zip','7z','extractHere','extractFolder','open'];
    try {
      const value=JSON.parse(localStorage.getItem('gekko.archive.context.commands')||'null');
      return Array.isArray(value)?defaults.filter(id=>value.includes(id)):defaults;
    } catch {return defaults;}
  });
  const [shellCreate,setShellCreate]=useState(null);
  const [shellJob,setShellJob]=useState(null);
  const shellBusy=useRef(false);
  const [menuReady,setMenuReady]=useState(false);
  const [menuStatus,setMenuStatus]=useState('Chargement des préférences Windows…');
  // La configuration native est la référence : évite d'écraser les préférences
  // existantes avec les valeurs initiales React lors du démarrage.
  useEffect(()=>{
    let live=true;
    invoke('get_context_menu_commands').then(saved=>{
      if(!live)return;
      if(Array.isArray(saved))setMenuOps(menuLabels.map(([id])=>id).filter(id=>saved.includes(id)));
      setMenuReady(true);
      setMenuStatus('Préférences prêtes.');
    }).catch(err=>{
      if(!live)return;
      setMenuStatus('Impossible de lire les préférences Windows : '+String(err));
    });
    return ()=>{live=false;};
  },[]);
  useEffect(()=>{
    if(!menuReady)return;
    setMenuStatus('Enregistrement des commandes du clic droit…');
    const timer=setTimeout(()=>{
      invoke('set_context_menu_commands',{commands:menuOps}).then(()=>{
        try{localStorage.setItem('gekko.archive.context.commands',JSON.stringify(menuOps));}catch{}
        setMenuStatus('Commandes enregistrées. Rouvre le menu du clic droit pour voir le changement.');
      }).catch(err=>setMenuStatus('Enregistrement impossible : '+String(err)));
    },200);
    return ()=>clearTimeout(timer);
  },[menuOps,menuReady]);
  const [customBg,setCustomBg]=useState('');
  const [backgroundStatus,setBackgroundStatus]=useState('');
  // La precedente URL.createObjectURL n'etait valable que pour la session.
  // IndexedDB conserve les octets de l'image, meme apres fermeture du logiciel.
  useEffect(()=>{
    let live=true;
    backgroundImageRead().then(image=>{
      if(!live)return;
      if(image instanceof Blob&&image.size>0)setCustomBg(URL.createObjectURL(image));
      else if(bg==='custom')setBackgroundStatus('Ancienne image introuvable : choisis-la de nouveau.');
    }).catch(err=>{if(live)setBackgroundStatus('Chargement du fond impossible : '+String(err));});
    return ()=>{live=false;};
  },[]);
  useEffect(()=>{
    try{localStorage.setItem(APPEARANCE_KEY,JSON.stringify({bg,alpha,info}));}
    catch(err){setBackgroundStatus('Enregistrement des préférences impossible : '+String(err));}
  },[bg,alpha,info]);
  const [extractOpen,setExtractOpen]=useState(false);
  const [createOpen,setCreateOpen]=useState(false);
  const [convertOpen,setConvertOpen]=useState(false);
  const [addOpen,setAddOpen]=useState(false);
  const [deleteOpen,setDeleteOpen]=useState(false);
  const [droppedSources,setDroppedSources]=useState([]);
  const [extractLaunch,setExtractLaunch]=useState(null);
  const [dropHint,setDropHint]=useState('');
  const [archivePassword,setArchivePassword]=useState('');
  const [passwordPending,setPasswordPending]=useState('');
  const [passwordRetry,setPasswordRetry]=useState(null);
  const popupTimer=useRef(null);
  const dropContext=useRef(null);
  const handleNativeDrop=useRef(null);
  dropContext.current={archive,archivePassword,selected,route,busy,addOpen,deleteOpen,extractOpen,createOpen,convertOpen};
  // Après la sélection, prépare uniquement les éléments sélectionnés.
  // Le navigateur seul ne peut pas transférer des fichiers d'archive vers
  // Explorer ; le plugin Tauri lance un glisser natif sur de vrais chemins.
  useEffect(()=>{
    const ticket=++outDragTicket.current;
    outDragReady.current=null;
    outDragArmed.current=null;
    if(!archive || !selected.length || route!=='archive'){
      setOutDragStatus('');return;
    }
    setOutDragStatus('Préparation de la sélection pour le glisser-déposer…');
    const timer=setTimeout(()=>{
      invoke('prepare_drag_export',{req:{
        archivePath:archive.path,selectedPaths:[...selected],password:archivePassword||null
      }}).then(result=>{
        if(outDragTicket.current!==ticket)return;
        outDragReady.current={key:selected.join('|'),data:result};
        setOutDragStatus('Sélection prête : glisse-la vers un dossier Windows.');
      }).catch(err=>{
        if(outDragTicket.current!==ticket)return;
        setOutDragStatus('Glisser-déposer indisponible : '+String(err));
      });
    },250);
    return ()=>clearTimeout(timer);
  },[archive?.path,archive?.bytes,archivePassword,selected.join('|'),route]);
  function armExport(e,file){
    if(e.button!==0)return;
    const keys=selected.includes(file)?selected:[file];
    outDragArmed.current={x:e.clientX,y:e.clientY,key:keys.join('|')};
  }
  function moveExport(e){
    const armed=outDragArmed.current;
    if(!armed || !(e.buttons&1))return;
    if(Math.abs(e.clientX-armed.x)+Math.abs(e.clientY-armed.y)<8)return;
    const ready=outDragReady.current;
    if(!ready||ready.key!==armed.key){
      // Rester armé : si la décompression finit avant le relâchement, le
      // mouvement suivant pourra lancer le glisser natif.
      return;
    }
    outDragArmed.current=null;
    e.preventDefault();
    startDrag({item:ready.data.paths,icon:ready.data.iconPath,mode:'copy'})
      .catch(err=>notify('Glisser vers Windows impossible : '+String(err)));
  }
  const archiveFile=path=>/\.(zip|7z|rar|tar|gz|bz2|xz|zst|cab|iso|wim|arj|lzma)$/i.test(path);
  const archiveWritable=path=>/\.(zip|7z)$/i.test(path);
  const dropTarget=position=>{
    const scale=window.devicePixelRatio||1;
    const candidate=document.elementFromPoint(position.x/scale,position.y/scale);
    return candidate?.closest('[data-gekkodrop]')?.getAttribute('data-gekkodrop')||'none';
  };
  useEffect(()=>{
    if(!window.__TAURI_INTERNALS__)return;
    let disposed=false;let stop;
    getCurrentWebview().onDragDropEvent(event=>{
      if(disposed)return;
      const p=event.payload;
      if(p.type==='leave'){setDropHint('');return;}
      if(p.type==='enter'||p.type==='over'){
        const target=dropTarget(p.position);
        setDropHint(target==='extract'?'extract':target==='add'||target==='modal-add'?'add':target==='open'?'open':target==='modal-extract'?'destination':'');
        return;
      }
      if(p.type==='drop'){
        setDropHint('');
        const paths=p.paths||[];
        if(paths.length)handleNativeDrop.current?.(paths,dropTarget(p.position));
      }
    }).then(fn=>{if(disposed)fn();else stop=fn;}).catch(e=>console.error('Glisser-déposer Windows indisponible',e));
    return ()=>{disposed=true;stop?.();};
  },[]);

  // La progression des commandes Windows est visible sans clic de confirmation.
  useEffect(()=>{
    let mounted=true;const unlisteners=[];
    for(const [event,kind] of [['gekko-compression-progress','compression'],['gekko-extraction-progress','extraction']]){
      listen(event,payload=>{
        if(!mounted)return;
        setShellJob(previous=>previous?.kind===kind?{
          ...previous,percent:payload.payload.percent||0,
          message:payload.payload.message||previous.message
        }:previous);
      }).then(stop=>{if(mounted)unlisteners.push(stop);else stop();}).catch(()=>{});
    }
    return ()=>{mounted=false;unlisteners.forEach(stop=>stop());};
  },[]);
  async function cancelShellJob(){
    if(!shellJob||shellJob.cancelAsked)return;
    setShellJob(previous=>previous?{...previous,cancelAsked:true,message:'Annulation demandée…'}:null);
    try{await invoke(shellJob.kind==='compression'?'cancel_compression':'cancel_extraction');}
    catch(e){setError('Impossible de demander l’annulation : '+String(e));}
  }
  function suggestedShellOutput(paths,format){
    const path=String(paths[0]||'');
    const leaf=path.split(/[\\/]/).filter(Boolean).at(-1)||'Archive';
    const parent=archiveParentDirectory(path);
    const stem=leaf.replace(/\.(7z|zip|rar|tar|gz|xz)$/i,'')||'Nouvelle_archive';
    // Si le fichier source est déjà au format cible, évite son nom de sortie.
    const base=stem+((leaf.toLowerCase()===stem+'.'+format)?'_compresse':'')+'.'+format;
    return (parent.endsWith('\\')||parent.endsWith('/')?parent:parent+'\\')+base;
  }
  async function processShellCompression(action,paths){
    setShellJob({kind:'compression',percent:0,message:'Préparation de la compression…',cancelAsked:false});
    const destination=suggestedShellOutput(paths,action);
    try {
      const r=await invoke('create_archive',{req:{sourcePaths:paths,destination,format:action,level:5,password:null}});
      notify('Archive '+action.toUpperCase()+' créée et vérifiée : '+r.path);
    } catch(e) {
      const message=String(e);
      if(!message.toLowerCase().includes('annul')){
        // Ne pas inventer de nouveau nom ni remplacer un fichier existant.
        // La fenêtre d'édition n'apparaît que lorsque l'opération automatique échoue.
        setShellCreate({sources:paths,format:action,error:message});
        setCreateOpen(true);
      } else notify('Compression annulée.');
    } finally {setShellJob(null);}
  }
  async function processShellExtraction(action,archivePath){
    const opened=await loadArchive(archivePath);
    if(!opened)return; // Les archives chiffrées nécessitent parfois le mot de passe dès la lecture.
    let destination=archiveParentDirectory(archivePath);
    if(action==='extractFolder'){
      try{destination=await invoke('ensure_shell_extract_folder',{archivePath});}
      catch(e){setError('Impossible de préparer le dossier : '+String(e));setRoute('archive');return;}
    }
    const req={archivePath,destination,selectedPaths:[],password:null,policy:'ask',decisions:{}};
    try {
      const preview=await invoke('preview_extraction',{req});
      if(preview.conflicts.length){
        // La décision d'écraser ou ignorer doit rester explicite.
        setExtractLaunch({destination,autoStart:false,preview});
        setExtractOpen(true);
        return;
      }
      setShellJob({kind:'extraction',percent:0,message:'Extraction automatique en cours…',cancelAsked:false});
      const r=await invoke('extract_archive',{req});
      notify('Extraction terminée : '+r.extracted+' fichier(s) vers '+r.destination);
    } catch(e) {
      const message=String(e);
      if(!message.toLowerCase().includes('annul')){
        // En cas de mot de passe manquant, afficher le formulaire habituel.
        setExtractLaunch({destination,autoStart:false,error:message});
        setExtractOpen(true);
      } else notify('Extraction annulée.');
    } finally {setShellJob(null);}
  }
  // Le .bat de test remet la commande à la fenêtre Tauri existante.
  // Pas de nouvelle instance : une vérification légère de la file locale.
  useEffect(()=>{
    if(!window.__TAURI_INTERNALS__)return;
    let active=true;
    let inProgress=false;
    async function receiveWindowsCommand(){
      if(!active||inProgress)return;
      inProgress=true;
      try {
        const request=await invoke('get_shell_launch');
        if(!active||!request)return;
        const {action,paths}=request;
        // Une commande Windows se lance immédiatement avec les réglages habituels.
        // La fenêtre classique ne s'affiche qu'en cas d'erreur ou de conflit.
        if(shellBusy.current)return;
        shellBusy.current=true;
        try {
          if(action==='zip'||action==='7z')await processShellCompression(action,paths);
          else if(action==='open')await loadArchive(paths[0]);
          else if(action==='extractHere'||action==='extractFolder')await processShellExtraction(action,paths[0]);
        } finally {shellBusy.current=false;}
      } catch(e){
        if(active){
          // Le message doit être visible même si l'application est sur l'accueil.
          setError('Pont Windows indisponible : '+String(e));
          setRoute('archive');
        }
      } finally {inProgress=false;}
    }
    receiveWindowsCommand();
    const timer=setInterval(receiveWindowsCommand,900);
    return ()=>{active=false;clearInterval(timer);};
  },[]);
  useEffect(()=>()=>{if(popupTimer.current)clearTimeout(popupTimer.current);},[]);
  useEffect(()=>()=>{if(customBg)URL.revokeObjectURL(customBg);},[customBg]);
  function notify(text){setToast(text);clearTimeout(popupTimer.current);popupTimer.current=setTimeout(()=>setToast(''),4000);}
  async function windowAction(action){
    try {
      if(!window.__TAURI_INTERNALS__) {notify('Les commandes de fenêtre sont actives dans la version Tauri Windows.');return;}
      const win=getCurrentWindow();
      if(action==='minimize')await win.minimize();
      if(action==='maximize')await win.toggleMaximize();
      if(action==='close')await win.close();
    } catch(e){notify('Commande de fenêtre indisponible : '+String(e));}
  }
  async function loadArchive(chosen,password=''){
    try {
      setBusy(true);setError('');
      const result=await invoke('list_archive',{archivePath:chosen,password:password||null});
      setArchive(result);setArchivePassword(password);setFolder('');setSearch('');setSelected([]);setRoute('archive');setPasswordRetry(null);setPasswordPending('');
      return result;
    } catch(e){
      const message=String(e);setError(message);setRoute('archive');
      if(message.toLowerCase().includes('mot de passe')){setPasswordRetry(chosen);}
    }finally{setBusy(false);}
  }
  async function chooseArchive(){
    if(busy)return;
    if(!window.__TAURI_INTERNALS__){setError('Cette fonction nécessite GEKKO ARCHIVE pour Windows.');setRoute('archive');return;}
    try {
      const chosen=await open({multiple:false,directory:false,filters:[{name:'Archives',extensions:SUPPORTED_OPEN_EXTENSIONS},{name:'Tous les fichiers',extensions:['*']}]});
      if(chosen)await loadArchive(chosen);
    }catch(e){setError(String(e));setRoute('archive');}
  }
  function openExtraction(){
    if(!archive){notify('Ouvre d’abord une archive pour l’extraire.');setRoute('archive');return;}
    setExtractOpen(true);
  }
  function goTo(routeName){
    if(routeName==='archive'&&!archive){chooseArchive();return;}
    setRoute(routeName);
  }
  function future(action){
    const labels={create:'La création d’archives',add:'L’ajout de fichiers',extract:'L’extraction',convert:'La conversion'};
    notify((labels[action]||'Cette fonction')+' sera développée lors des prochaines étapes.');
  }
  function doAction(action){if(action==='open'){chooseArchive();return;}if(action==='extract'){openExtraction();return;}if(action==='create'){setCreateOpen(true);return;}if(action==='convert'){setConvertOpen(true);return;}if(action==='add'){if(!archive){notify('Ouvre d’abord une archive ZIP ou 7z.');chooseArchive();return;}if(!/\.(zip|7z)$/i.test(archive.path)){notify('L’ajout est disponible uniquement pour ZIP et 7z.');return;}setAddOpen(true);return;}future(action);}
  handleNativeDrop.current=async(paths,target)=>{
    const context=dropContext.current;
    if(context.busy){notify('Une opération est en cours.');return;}
    if(context.addOpen){
      if(target==='modal-add'){setDroppedSources([...paths]);return;}
      notify('Dépose les fichiers dans la fenêtre « Ajouter ».');return;
    }
    if(context.extractOpen){
      if(target==='modal-extract'&&paths.length===1&&!archiveFile(paths[0])){
        setExtractLaunch({destination:paths[0],autoStart:true});return;
      }
      notify('Dépose un dossier de destination dans la fenêtre « Extraire ».');return;
    }
    if(context.createOpen||context.convertOpen||context.deleteOpen){
      notify('Ferme la fenêtre en cours avant un glisser-déposer.');return;
    }
    // Une archive déposée directement sur « Extraire » : extraction automatique
    // dans son dossier, avec l'écran des conflits uniquement si nécessaire.
    if(target==='extract'){
      if(paths.length!==1){notify('Dépose une seule archive ou un seul dossier sur « Extraire ».');return;}
      const path=paths[0];
      if(archiveFile(path)){
        const loaded=await loadArchive(path);
        if(!loaded)return;
        setExtractLaunch({destination:archiveParentDirectory(path),autoStart:true});
        setExtractOpen(true);
        return;
      }
      // Déposer un dossier Windows sur « Extraire » choisit sa destination
      // pour les éléments sélectionnés de l'archive déjà ouverte.
      if(!context.archive){notify('Ouvre une archive avant de déposer un dossier de destination.');return;}
      setExtractLaunch({destination:path,autoStart:true});
      setExtractOpen(true);
      return;
    }
    if(target==='open'){
      if(paths.length!==1||!archiveFile(paths[0])){
        notify('Dépose un fichier archive pour l’ouvrir.');return;
      }
      await loadArchive(paths[0]);return;
    }
    if(target==='add'){
      if(!context.archive){
        if(paths.length===1&&archiveFile(paths[0]))await loadArchive(paths[0]);
        else notify('Ouvre une archive ZIP ou 7z avant de déposer des fichiers.');
        return;
      }
      if(!archiveWritable(context.archive.path)){
        notify('L’ajout par glisser-déposer est disponible uniquement pour ZIP et 7z.');return;
      }
      if(paths.length>10000){notify('Sélection trop importante.');return;}
      setDroppedSources(paths);
      setAddOpen(true);
    }
  };
  async function setImage(file){
    if(!file||!file.type.startsWith('image/')){setBackgroundStatus('Sélectionne une image valide.');return;}
    try {
      await backgroundImageSave(file);
      setCustomBg(URL.createObjectURL(file));
      setBg('custom');
      setBackgroundStatus('Image sauvegardée : elle sera restaurée au prochain démarrage.');
    }catch(err){setBackgroundStatus('Impossible de sauvegarder le fond : '+String(err));}
  }
  const entries=useMemo(()=>archive?childrenOf(archive.files,folder).filter(f=>f.path.split('/').at(-1).toLocaleLowerCase('fr').includes(search.toLocaleLowerCase('fr'))):[],[archive,folder,search]);
  // Sélectionner les éléments visibles du dossier courant, y compris les dossiers.
  // La préparation des fichiers pour le glisser-déposer se déclenche déjà
  // automatiquement lorsque `selected` change.
  const allVisibleSelected=entries.length>0&&entries.every(f=>selected.includes(f.path));
  function toggleSelectAll(){setSelected(allVisibleSelected?[]:entries.map(f=>f.path));}
  const folderTrail=folder?folder.split('/'):[];
  function toggleSelected(key){setSelected(prev=>prev.includes(key)?prev.filter(x=>x!==key):[...prev,key]);}
  return <div className="app" id="app" data-bg={bg} style={{'--alpha':alpha,...(customBg?{'--custom-bg':`url("${customBg}")`}:{})}}>
    <header className="titlebar" onMouseDown={e=>{if(e.button===0&&!e.target.closest('button')){if(window.__TAURI_INTERNALS__)getCurrentWindow().startDragging().catch(()=>{});}}} onDoubleClick={e=>{if(!e.target.closest('button'))windowAction('maximize');}}>
      <div className="brandmini" aria-label="GEKKO ARCHIVE"><img className="brand-mark" src={brandLogo} alt=""/><img className="brand-title" src={brandTitle} alt="GEKKO ARCHIVE"/></div>
      <div className="spacer"/>
      <div className="windows" aria-label="Commandes de fenêtre">
        <button className="winbtn" title="Réduire" aria-label="Réduire" onClick={()=>windowAction('minimize')}><img src={minimizeIcon} alt=""/></button>
        <button className="winbtn" title="Agrandir ou restaurer" aria-label="Agrandir ou restaurer" onClick={()=>windowAction('maximize')}><img src={maximizeIcon} alt=""/></button>
        <button className="winbtn" title="Fermer" aria-label="Fermer" onClick={()=>windowAction('close')}><img src={closeIcon} alt=""/></button>
      </div>
    </header>
    <div className="workspace">
      <aside className={`sidebar${collapsed?' is-collapsed':''}`}>
        <div className="side-section-label">Espace de travail</div>
        {mainNav.map(n=><button key={n.id} title={n.text} className={'side-link'+(route===n.id?' active':'')} onClick={()=>goTo(n.id)}><Icon name={n.icon}/><span>{n.text}</span></button>)}
        <div className="side-section-label">Outils</div>
        {actions.map(a=><button key={a.id} data-gekkodrop={a.id==='extract'?'extract':a.id==='add'?'add':a.id==='open'?'open':undefined} title={a.text} className="side-link" onClick={()=>doAction(a.id)}><Icon name={a.icon}/><span>{a.text}</span></button>)}
        <div className="side-bottom"><button className={'side-link'+(route==='settings'?' active':'')} onClick={()=>goTo('settings')} title="Paramètres"><Icon name="settings"/><span>Paramètres</span></button><button className="side-collapse" title={collapsed?'Déployer le menu':'Réduire le menu'} onClick={()=>setCollapsed(v=>!v)}><Icon name="chevron"/><span>{collapsed?'Déployer le menu':'Réduire le menu'}</span></button></div>
      </aside>
      <section className="content"><main className="page" id="page" data-gekkodrop={route==='archive'?(archive?'add':'open'):route==='home'?'open':undefined}>
        {route==='home'&&<div className="page-inner"><section className="hero"><div className="hero-copy"><div className="eyebrow">Gestionnaire d’archives · Windows 11</div><h1>Vos archives.<br/><em>En toute maîtrise.</em></h1><p>Créez, explorez et organisez vos archives dans un espace pensé pour la simplicité, la rapidité et la maîtrise de vos fichiers.</p><div className="hero-buttons"><AppButton action={actions[0]} primary onClick={()=>doAction('create')}/><AppButton action={{text:'Ouvrir une archive',icon:'folder-open'}} onClick={chooseArchive}/></div></div><img className="hero-logo" src={heroLogo} alt="Logo GEKKO ARCHIVE"/></section></div>}
        {route==='archive'&&<div className="page-inner">
          <div className="workspace-heading"><div><h1>{archive?.name||'Explorer une archive'}</h1><p>{archive?'Contenu réel de l’archive — extraction disponible':'Choisissez une archive pour voir son contenu'}</p></div><button className="toolbtn primary" disabled={busy} onClick={chooseArchive}><Icon name="folder-open"/>{busy?'Lecture en cours…':'Ouvrir une archive'}</button></div>
          {error&&<div role="alert" className="error-message">{error}</div>}
          {busy&&<div className="loading-message" role="status">Lecture de l'archive en cours…</div>}
          {passwordRetry&&<div className="password-retry"><label>Mot de passe de l’archive <input type="password" autoComplete="off" value={passwordPending} onChange={e=>setPasswordPending(e.target.value)} onKeyDown={e=>{if(e.key==='Enter')loadArchive(passwordRetry,passwordPending);}} placeholder="Saisir le mot de passe"/></label><button className="toolbtn primary" disabled={busy} onClick={()=>loadArchive(passwordRetry,passwordPending)}>Réessayer</button></div>}
          {!archive&&!busy&&<div className="no-archive"><Icon name="archive"/><h2>Aucune archive ouverte</h2><p>Ouvre une archive ZIP, 7z, RAR, TAR, GZIP, XZ, BZIP2, ZSTD, ISO ou CAB pour consulter et extraire ses fichiers.</p><button className="toolbtn primary" onClick={chooseArchive}><Icon name="folder-open"/> Ouvrir une archive</button></div>}
          {archive&&<>
            <div className="pathbar"><Icon name="folder"/><button className="pathpart" onClick={()=>{setFolder('');setSelected([]);}}>{archive.name}</button>{folderTrail.map((part,i)=><React.Fragment key={i}><span>/</span><button className="pathpart" onClick={()=>{setFolder(folderTrail.slice(0,i+1).join('/'));setSelected([]);}}>{part}</button></React.Fragment>)}<span className="pill">{archive.format}</span></div>
            <div className="list-actions"><button className="toolbtn" onClick={openExtraction}><Icon name="package-open"/> Extraire</button><button className="toolbtn" disabled={!selected.length||!archive||!/\.(zip|7z)$/i.test(archive.path)} title="Supprimer les éléments sélectionnés de cette archive ZIP ou 7z" onClick={()=>setDeleteOpen(true)}><Icon name="trash"/> Supprimer</button><button className="toolbtn" disabled={!entries.length} onClick={toggleSelectAll} title="Sélectionner tous les éléments affichés dans ce dossier" aria-label={allVisibleSelected?"Tout désélectionner":"Tout sélectionner"}><Icon name="check"/> {allVisibleSelected?"Tout désélectionner":"Tout sélectionner"}</button><div className="search"><Icon name="search"/><input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Rechercher dans ce dossier…" aria-label="Rechercher dans ce dossier"/></div></div>
            <section className="listpanel"><div className="list-head"><span>Nom</span><span>Type</span><span>Taille</span><span>Compressé</span><span>Modifié le</span></div>
              {folder&&<div className="file-line" tabIndex={0} role="button" onClick={()=>{setFolder(folder.split('/').slice(0,-1).join('/'));setSelected([]);}} onKeyDown={e=>{if(e.key==='Enter'){setFolder(folder.split('/').slice(0,-1).join('/'));setSelected([]);}}}><b><Icon name="folder"/><span className="name">..</span></b><span>Dossier parent</span><span>—</span><span>—</span><span>—</span></div>}
              {entries.map(f=><div key={f.path} tabIndex={0} role="button" aria-label={`${f.isDir?'Ouvrir le dossier':'Sélectionner le fichier'} ${f.path}`} className={'file-line'+(selected.includes(f.path)?' selected':'')+' file-export'} onPointerDown={e=>armExport(e,f.path)} onPointerMove={moveExport} onPointerUp={()=>{outDragArmed.current=null;}} onPointerCancel={()=>{outDragArmed.current=null;}} onClick={()=>toggleSelected(f.path)} onDoubleClick={()=>{if(f.isDir){setFolder(f.path);setSelected([]);setSearch('');}}} onKeyDown={e=>{if(e.key==='Enter'){if(f.isDir){setFolder(f.path);setSearch('');setSelected([]);}else toggleSelected(f.path);}}}>
                <b><Icon name={f.isDir?'folder':'file'}/><span className="name">{f.path.split('/').at(-1)}</span></b><span>{f.isDir?'Dossier':(f.path.split('.').at(-1)||'Fichier').toUpperCase()}</span><span>{f.isDir?'—':bytes(f.size)}</span><span>{f.isDir?'—':bytes(f.packedSize)}</span><span>{f.modified||'—'}</span>
              </div>)}
              {entries.length===0&&!folder&&<div className="empty"><Icon name="search"/><p>{search?'Aucun résultat dans ce dossier.':'Cette archive ne contient aucun élément visible.'}</p></div>}
              {entries.length===0&&folder&&<div className="empty"><p>Ce dossier ne contient aucun élément correspondant.</p></div>}
            </section>
            {selected.length>0&&<p className="gekko-drag-out-hint" role="status">{outDragStatus||"Sélectionne les éléments à extraire par glisser-déposer."}</p>}
            {info&&<div className="info-panel"><div className="stat"><small>Format</small><strong>{archive.format}</strong></div><div className="stat"><small>Taille de l'archive</small><strong>{bytes(archive.bytes)}</strong></div><div className="stat"><small>Éléments</small><strong>{archive.files.length}</strong></div><div className="stat"><small>Sélection</small><strong>{selected.length} élément(s)</strong></div></div>}
          </>}
        </div>}
        {route==='settings'&&<Settings {...{bg,setBg,alpha,setAlpha,info,setInfo,menuOps,setMenuOps,setImage,menuReady,menuStatus,backgroundStatus}}/>}
      </main></section>
    </div>
    {shellJob&&<div className="extract-overlay"><section className="extract-modal" role="dialog" aria-modal="true" aria-label="Opération Windows en cours"><div className="extract-header"><Icon name="archive"/><h2>{shellJob.kind==='compression'?'Compression automatique':'Extraction automatique'}</h2></div><div className="extract-progress" role="status"><div className="extract-progress-caption"><span>{shellJob.message}</span><strong>{shellJob.percent}%</strong></div><div className="extract-track"><div style={{width:`${shellJob.percent}%`}}/></div></div><div className="extract-footer"><button className="toolbtn" disabled={shellJob.cancelAsked} onClick={cancelShellJob}>{shellJob.cancelAsked?'Annulation demandée…':'Annuler'}</button></div></section></div>}
    {createOpen&&<CreationDialog initialSources={shellCreate?.sources||[]} initialFormat={shellCreate?.format||'7z'} initialError={shellCreate?.error||''} onClose={()=>{setCreateOpen(false);setShellCreate(null);}} onCreated={(r,openNow=false)=>{if(openNow)loadArchive(r.path);else notify('Archive créée et vérifiée.');}}/>}
    {deleteOpen&&archive&&<DeleteDialog archive={archive} selected={[...selected]} defaultPassword={archivePassword} onClose={()=>setDeleteOpen(false)} onDeleted={async(_r,pass)=>{await loadArchive(archive.path,pass);notify('Éléments supprimés. Archive vérifiée.');}}/>}
    {addOpen&&archive&&<AddDialog initialSources={droppedSources} archive={archive} defaultPassword={archivePassword} onClose={()=>{setAddOpen(false);setDroppedSources([]);}} onAdded={(_r,pass)=>{loadArchive(archive.path,pass);notify('Archive mise à jour et vérifiée.');}}/>}
    {convertOpen&&<ConversionDialog archive={archive} defaultPassword={archivePassword} onClose={()=>setConvertOpen(false)} onConverted={()=>notify('Archive convertie et vérifiée. Original conservé.')}/>}
    {extractOpen&&archive&&<ExtractionDialog key={archive.path+'|'+(extractLaunch?.destination||'')} archive={archive} selected={selected} initialDestination={extractLaunch?.destination} autoStart={!!extractLaunch?.autoStart} initialPreview={extractLaunch?.preview||null} initialError={extractLaunch?.error||''} defaultPassword={archivePassword} onClose={()=>{setExtractOpen(false);setExtractLaunch(null);}} onFinished={r=>notify(`${r.extracted} fichier(s) extrait(s).`)}/>}
    {dropHint&&<div className="gekko-drop-indicator" aria-hidden="true">
      {dropHint==='extract'?'Relâche pour extraire dans le dossier de l’archive':dropHint==='add'?'Relâche pour ajouter les fichiers dans l’archive':dropHint==='destination'?'Relâche pour extraire dans ce dossier':'Relâche pour ouvrir cette archive'}
    </div>}
    <div className={'toast'+(toast?' show':'')} role="status" aria-live="polite">{toast}</div>
  </div>;
}
