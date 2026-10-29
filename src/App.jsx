import React, {useEffect, useMemo, useRef, useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {getCurrentWindow} from '@tauri-apps/api/window';
import {open, save} from '@tauri-apps/plugin-dialog';
import {listen} from '@tauri-apps/api/event';
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
function Settings({bg,setBg,alpha,setAlpha,info,setInfo,menuOps,setMenuOps,setImage}) {
  const fileInput=useRef(null);
  return <div className="page-inner">
    <div className="crumbs">Accueil / <strong>Paramètres</strong></div>
    <div className="workspace-heading"><div><h1>Personnalisation</h1><p>Apparence et options du futur menu contextuel Windows</p></div></div>
    <section className="setting-section"><h2>Apparence</h2>
      <div className="setting-row"><div><label htmlFor="bgSelector">Fond de l'interface</label><small>Choisir une ambiance propre à GEKKO ARCHIVE</small></div>
        <select id="bgSelector" value={bg} onChange={e=>setBg(e.target.value)}><option value="default">Bleu & cuivre</option><option value="amber">Or nocturne</option><option value="blue">Bleu profond</option><option value="custom">Image personnelle</option></select></div>
      <div className="setting-row"><div><label htmlFor="alphaSelector">Opacité</label><small>Rendu visuel de l'interface</small></div><select id="alphaSelector" value={alpha} onChange={e=>setAlpha(e.target.value)}><option value="0.56">Très transparent</option><option value="0.82">Transparent</option><option value="0.97">Opaque</option></select></div>
      <div className="setting-row"><div><label>Fond personnalisé</label><small>Aperçu d'une image locale</small></div><button className="toolbtn" onClick={()=>fileInput.current?.click()}><Icon name="folder-open"/> Parcourir…</button>
        <input ref={fileInput} className="hidden" type="file" accept="image/*" onChange={e=>{if(e.target.files?.[0])setImage(e.target.files[0]);e.target.value='';}}/></div>
      <div className="setting-row"><div><label htmlFor="infoToggle">Panneau d'informations</label><small>Affiché sous le contenu d'une archive</small></div><input id="infoToggle" type="checkbox" checked={info} onChange={e=>setInfo(e.target.checked)}/></div>
    </section>
    <section className="setting-section"><h2>Menu contextuel Windows 11</h2><p>Choix préparatoires : l'intégration à Windows sera développée ultérieurement.</p>
      {menuLabels.map(([id,label])=><div className="setting-row" key={id}><label htmlFor={'menu_'+id}>{label}</label><input id={'menu_'+id} type="checkbox" checked={menuOps.includes(id)} onChange={e=>setMenuOps(current=>e.target.checked?[...current,id]:current.filter(x=>x!==id))}/></div>)}
    </section>
  </div>;
}
function CreationDialog({onClose,onCreated}) {
  const [sources,setSources]=useState([]);
  const [format,setFormat]=useState('7z');
  const [destination,setDestination]=useState('');
  const [level,setLevel]=useState('5');
  const [password,setPassword]=useState('');
  const [passwordConfirm,setPasswordConfirm]=useState('');
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState('');
  const [progress,setProgress]=useState({phase:'',percent:0,message:''});
  const [result,setResult]=useState(null);
  const [cancelAsked,setCancelAsked]=useState(false);
  useEffect(()=>{let unlisten;let mounted=true;
    listen('gekko-compression-progress',event=>{if(mounted)setProgress(event.payload);})
      .then(fn=>{if(mounted)unlisten=fn;else fn();}).catch(()=>{});
    return ()=>{mounted=false;unlisten?.();};
  },[]);
  const leaf=path=>String(path||'').split(/[\\/]/).filter(Boolean).at(-1)||'Archive';
  function suggestedOutput(paths,fmt){
    if(!paths.length)return '';
    const dir=archiveParentDirectory(paths[0]);
    const basename=paths.length===1?leaf(paths[0]):'Nouvelle_archive';
    const base=basename.replace(/\.(7z|zip|rar|tar|gz|xz)$/i,'')||'Nouvelle_archive';
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
    setDestination(prev=>prev?prev.replace(/\.(7z|zip)$/i,'')+'.'+fmt:suggestedOutput(sources,fmt));
  }
  async function chooseDestination(){
    try{
      const chosen=await save({defaultPath:destination||'Nouvelle_archive.'+format,
        filters:[{name:format.toUpperCase(),extensions:[format]}]});
      if(chosen)setDestination(/\.(zip|7z)$/i.test(chosen)?chosen:chosen+'.'+format);
    }catch(e){setError(String(e));}
  }
  async function launch(){
    if(busy)return;
    if(!sources.length){setError('Sélectionne des fichiers ou un dossier source.');return;}
    if(!destination.trim()){setError("Choisis l'emplacement de l'archive.");return;}
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
    <div className="extract-grid"><label className="field">Format<select value={format} disabled={busy} onChange={e=>changeFormat(e.target.value)}><option value="7z">7z</option><option value="zip">ZIP</option></select></label>
      <label className="field">Niveau de compression<select value={level} disabled={busy} onChange={e=>setLevel(e.target.value)}><option value="0">Sans compression</option><option value="1">Rapide</option><option value="5">Normal</option><option value="9">Maximum</option></select></label></div>
    <div className="extract-grid"><label className="field">Mot de passe (facultatif)<input type="password" autoComplete="new-password" disabled={busy} value={password} onChange={e=>setPassword(e.target.value)}/></label>
      <label className="field">Confirmer le mot de passe<input type="password" autoComplete="new-password" disabled={busy} value={passwordConfirm} onChange={e=>setPasswordConfirm(e.target.value)}/></label></div>
    {password&&<p className="fine-print">Chiffrement AES-256. En 7z, le nom des fichiers est également masqué ; en ZIP, les noms restent visibles.</p>}
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
      const path=await open({multiple:false,directory:false,filters:[{name:'Archives',extensions:['zip','7z','rar','tar','gz','bz2','xz','zst','cab','iso','wim','arj','lzma']}]});
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

function ExtractionDialog({archive,selected,onClose,onFinished,defaultPassword}) {
  const [destination,setDestination]=useState(()=>archiveParentDirectory(archive.path));
  const [password,setPassword]=useState(defaultPassword||'');
  const [policy,setPolicy]=useState('ask');
  const [preview,setPreview]=useState(null);
  const [decisions,setDecisions]=useState({});
  const [working,setWorking]=useState(false);
  const [phase,setPhase]=useState({phase:'préparation',percent:0,message:''});
  const [result,setResult]=useState(null);
  const [error,setError]=useState('');
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
  async function prepare(){
    if(working)return;
    if(!destination){setError('Choisis un dossier de destination.');return;}
    setError('');setWorking(true);
    setPhase({phase:'vérification',percent:0,message:''});
    try {
      // Vérification automatique au clic sur Extraire, sans étape intermédiaire.
      const p=await invoke('preview_extraction',{req});
      if(policy==='ask'&&p.conflicts.length>0){
        // Il faut seulement un deuxième clic lorsqu'un véritable conflit demande une décision.
        setPreview(p);
        setDecisions(Object.fromEntries(p.conflicts.map(k=>[k,'skip'])));
        return;
      }
      setPreview(null);
      setCancelAsked(false);
      setPhase({phase:'préparation',percent:0,message:'Démarrage…'});
      const r=await invoke('extract_archive',{req});
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
  return <div className="extract-overlay" role="presentation">
    <section className="extract-modal" role="dialog" aria-modal="true" aria-label="Extraire les fichiers">
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
        {!result&&!working&&(preview?<button className="toolbtn primary" onClick={launch}><Icon name="package-open"/> Confirmer l’extraction</button>:<button className="toolbtn primary" onClick={prepare}><Icon name="package-open"/> Extraire</button>)}
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
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState('');
  const [toast,setToast]=useState('');
  const [bg,setBg]=useState('default');
  const [alpha,setAlpha]=useState('0.82');
  const [info,setInfo]=useState(true);
  const [menuOps,setMenuOps]=useState(['zip','7z','extractHere','extractFolder','open']);
  const [customBg,setCustomBg]=useState('');
  const [extractOpen,setExtractOpen]=useState(false);
  const [createOpen,setCreateOpen]=useState(false);
  const [convertOpen,setConvertOpen]=useState(false);
  const [archivePassword,setArchivePassword]=useState('');
  const [passwordPending,setPasswordPending]=useState('');
  const [passwordRetry,setPasswordRetry]=useState(null);
  const popupTimer=useRef(null);
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
    } catch(e){
      const message=String(e);setError(message);setRoute('archive');
      if(message.toLowerCase().includes('mot de passe')){setPasswordRetry(chosen);}
    }finally{setBusy(false);}
  }
  async function chooseArchive(){
    if(busy)return;
    if(!window.__TAURI_INTERNALS__){setError('Cette fonction nécessite GEKKO ARCHIVE pour Windows.');setRoute('archive');return;}
    try {
      const chosen=await open({multiple:false,directory:false,filters:[{name:'Archives',extensions:['zip','7z','rar','tar','gz','bz2','xz','zst','cab','iso','wim','arj','lzma']},{name:'Tous les fichiers',extensions:['*']}]});
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
  function doAction(action){if(action==='open'){chooseArchive();return;}if(action==='extract'){openExtraction();return;}if(action==='create'){setCreateOpen(true);return;}if(action==='convert'){setConvertOpen(true);return;}future(action);}
  function setImage(file){setCustomBg(URL.createObjectURL(file));setBg('custom');}
  const entries=useMemo(()=>archive?childrenOf(archive.files,folder).filter(f=>f.path.split('/').at(-1).toLocaleLowerCase('fr').includes(search.toLocaleLowerCase('fr'))):[],[archive,folder,search]);
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
        {actions.map(a=><button key={a.id} title={a.text} className="side-link" onClick={()=>doAction(a.id)}><Icon name={a.icon}/><span>{a.text}</span></button>)}
        <div className="side-bottom"><button className={'side-link'+(route==='settings'?' active':'')} onClick={()=>goTo('settings')} title="Paramètres"><Icon name="settings"/><span>Paramètres</span></button><button className="side-collapse" title={collapsed?'Déployer le menu':'Réduire le menu'} onClick={()=>setCollapsed(v=>!v)}><Icon name="chevron"/><span>{collapsed?'Déployer le menu':'Réduire le menu'}</span></button></div>
      </aside>
      <section className="content"><main className="page" id="page">
        {route==='home'&&<div className="page-inner"><section className="hero"><div className="hero-copy"><div className="eyebrow">Gestionnaire d’archives · Windows 11</div><h1>Vos archives.<br/><em>En toute maîtrise.</em></h1><p>Créez, explorez et organisez vos archives dans un espace pensé pour la simplicité, la rapidité et la maîtrise de vos fichiers.</p><div className="hero-buttons"><AppButton action={actions[0]} primary onClick={()=>doAction('create')}/><AppButton action={{text:'Ouvrir une archive',icon:'folder-open'}} onClick={chooseArchive}/></div></div><img className="hero-logo" src={heroLogo} alt="Logo GEKKO ARCHIVE"/></section></div>}
        {route==='archive'&&<div className="page-inner">
          <div className="workspace-heading"><div><h1>{archive?.name||'Explorer une archive'}</h1><p>{archive?'Contenu réel de l’archive — extraction disponible':'Choisissez une archive pour voir son contenu'}</p></div><button className="toolbtn primary" disabled={busy} onClick={chooseArchive}><Icon name="folder-open"/>{busy?'Lecture en cours…':'Ouvrir une archive'}</button></div>
          {error&&<div role="alert" className="error-message">{error}</div>}
          {busy&&<div className="loading-message" role="status">Lecture de l'archive en cours…</div>}
          {passwordRetry&&<div className="password-retry"><label>Mot de passe de l’archive <input type="password" autoComplete="off" value={passwordPending} onChange={e=>setPasswordPending(e.target.value)} onKeyDown={e=>{if(e.key==='Enter')loadArchive(passwordRetry,passwordPending);}} placeholder="Saisir le mot de passe"/></label><button className="toolbtn primary" disabled={busy} onClick={()=>loadArchive(passwordRetry,passwordPending)}>Réessayer</button></div>}
          {!archive&&!busy&&<div className="no-archive"><Icon name="archive"/><h2>Aucune archive ouverte</h2><p>Ouvre un fichier ZIP, 7z ou RAR pour parcourir ses fichiers sans les extraire.</p><button className="toolbtn primary" onClick={chooseArchive}><Icon name="folder-open"/> Ouvrir une archive</button></div>}
          {archive&&<>
            <div className="pathbar"><Icon name="folder"/><button className="pathpart" onClick={()=>{setFolder('');setSelected([]);}}>{archive.name}</button>{folderTrail.map((part,i)=><React.Fragment key={i}><span>/</span><button className="pathpart" onClick={()=>{setFolder(folderTrail.slice(0,i+1).join('/'));setSelected([]);}}>{part}</button></React.Fragment>)}<span className="pill">{archive.format}</span></div>
            <div className="list-actions"><button className="toolbtn" onClick={openExtraction}><Icon name="package-open"/> Extraire</button><div className="search"><Icon name="search"/><input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Rechercher dans ce dossier…" aria-label="Rechercher dans ce dossier"/></div></div>
            <section className="listpanel"><div className="list-head"><span>Nom</span><span>Type</span><span>Taille</span><span>Compressé</span><span>Modifié le</span></div>
              {folder&&<div className="file-line" tabIndex={0} role="button" onClick={()=>{setFolder(folder.split('/').slice(0,-1).join('/'));setSelected([]);}} onKeyDown={e=>{if(e.key==='Enter'){setFolder(folder.split('/').slice(0,-1).join('/'));setSelected([]);}}}><b><Icon name="folder"/><span className="name">..</span></b><span>Dossier parent</span><span>—</span><span>—</span><span>—</span></div>}
              {entries.map(f=><div key={f.path} tabIndex={0} role="button" aria-label={`${f.isDir?'Ouvrir le dossier':'Sélectionner le fichier'} ${f.path}`} className={'file-line'+(selected.includes(f.path)?' selected':'')} onClick={()=>toggleSelected(f.path)} onDoubleClick={()=>{if(f.isDir){setFolder(f.path);setSelected([]);setSearch('');}}} onKeyDown={e=>{if(e.key==='Enter'){if(f.isDir){setFolder(f.path);setSearch('');setSelected([]);}else toggleSelected(f.path);}}}>
                <b><Icon name={f.isDir?'folder':'file'}/><span className="name">{f.path.split('/').at(-1)}</span></b><span>{f.isDir?'Dossier':(f.path.split('.').at(-1)||'Fichier').toUpperCase()}</span><span>{f.isDir?'—':bytes(f.size)}</span><span>{f.isDir?'—':bytes(f.packedSize)}</span><span>{f.modified||'—'}</span>
              </div>)}
              {entries.length===0&&!folder&&<div className="empty"><Icon name="search"/><p>{search?'Aucun résultat dans ce dossier.':'Cette archive ne contient aucun élément visible.'}</p></div>}
              {entries.length===0&&folder&&<div className="empty"><p>Ce dossier ne contient aucun élément correspondant.</p></div>}
            </section>
            {info&&<div className="info-panel"><div className="stat"><small>Format</small><strong>{archive.format}</strong></div><div className="stat"><small>Taille de l'archive</small><strong>{bytes(archive.bytes)}</strong></div><div className="stat"><small>Éléments</small><strong>{archive.files.length}</strong></div><div className="stat"><small>Sélection</small><strong>{selected.length} élément(s)</strong></div></div>}
          </>}
        </div>}
        {route==='settings'&&<Settings {...{bg,setBg,alpha,setAlpha,info,setInfo,menuOps,setMenuOps,setImage}}/>}
      </main></section>
    </div>
    {createOpen&&<CreationDialog onClose={()=>setCreateOpen(false)} onCreated={(r,openNow=false)=>{if(openNow)loadArchive(r.path);else notify('Archive créée et vérifiée.');}}/>}
    {convertOpen&&<ConversionDialog archive={archive} defaultPassword={archivePassword} onClose={()=>setConvertOpen(false)} onConverted={()=>notify('Archive convertie et vérifiée. Original conservé.')}/>}
    {extractOpen&&archive&&<ExtractionDialog key={archive.path} archive={archive} selected={selected} defaultPassword={archivePassword} onClose={()=>setExtractOpen(false)} onFinished={r=>notify(`${r.extracted} fichier(s) extrait(s).`)}/>}
    <div className={'toast'+(toast?' show':'')} role="status" aria-live="polite">{toast}</div>
  </div>;
}
