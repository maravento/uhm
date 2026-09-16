<?php
/**
 * ACLView — uhm ACL list editor
 *
 * Lists the editable ACL files, shows one at a time and saves it back
 * through ../api.php. uhmtool.sh validates every line before writing, so
 * a list the daemon would reject never reaches disk.
 */

header('Cache-Control: no-cache, no-store, must-revalidate, max-age=0');
header('Pragma: no-cache');
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ACLView</title>
<style>
/* -- Variables -- Light (default) ----------------------------- */
#uhacl{
  --bg: #ffffff;
  --bg2: #f8f9fa;
  --border: #dee2e6;
  --border2: #e9ecef;
  --text: #212529;
  --text2: #495057;
  --text3: #868e96;
  --gutter-bg:#f1f3f5;
  --gutter-fg:#adb5bd;
  --editor-bg:#ffffff;
  --editor-fg:#212529;
  --bar-bg: #f1f3f5;
  --err-bg: #f8d7da;
  --err-border:#f5c6cb;
  --err-text:#721c24;
  --ok-bg: #d4edda;
  --ok-border:#c3e6cb;
  --ok-text: #155724;
}
/* -- Variables -- Dark ----------------------------------------- */
#uhacl.dark{
  --bg: #0d1117;
  --bg2: #161b22;
  --border: #21262d;
  --border2: #30363d;
  --text: #e6edf3;
  --text2: #c9d1d9;
  --text3: #8b949e;
  --gutter-bg:#161b22;
  --gutter-fg:#4a6880;
  --editor-bg:#0d1117;
  --editor-fg:#c9d1d9;
  --bar-bg: #111827;
  --err-bg: #3a1a1a;
  --err-border:#6e1a1a;
  --err-text: #f85149;
  --ok-bg: #12261a;
  --ok-border:#238636;
  --ok-text: #56d364;
}

html,body{height:100%;margin:0;background:var(--bg,#fff)}
#uhacl *{box-sizing:border-box}
#uhacl{font-family:'Segoe UI',system-ui,sans-serif;display:flex;flex-direction:column;height:100vh;background:var(--bg)}

/* -- Toolbar (always dark) ------------------------------------ */
.uh-toolbar{background:#1e2a35;padding:10px 14px;display:flex;align-items:center;gap:8px;flex-wrap:wrap;flex-shrink:0;border-bottom:3px solid #3498db}
.uh-toolbar .title{font-size:13px;font-weight:700;color:#fff;display:flex;align-items:center;gap:6px;white-space:nowrap}
.uh-toolbar .title .icon{background:rgba(255,255,255,.1);border-radius:5px;padding:3px 6px;font-size:12px}
.uh-toolbar select{background:#253545;border:1px solid #3a4f63;color:#e6eef8;padding:7px 8px;border-radius:6px;font-size:11px;outline:none;cursor:pointer;min-width:160px}
.uh-toolbar select option{background:#1e2a35}
.uh-btn{padding:6px 12px;border-radius:6px;font-size:11px;font-weight:600;cursor:pointer;border:none;white-space:nowrap;background:#37474f;color:#e6eef8}
.uh-btn:hover{background:#455a64}
.uh-btn.save{background:#1565c0;margin-left:auto}
.uh-btn.save:hover{background:#1976d2}
.uh-btn[disabled]{opacity:.45;cursor:default}

/* -- Status bar ----------------------------------------------- */
.uh-bar{background:var(--bar-bg);padding:5px 14px;display:flex;gap:14px;align-items:center;font-size:10px;color:var(--text3);flex-shrink:0;flex-wrap:wrap;border-bottom:1px solid var(--border)}
.uh-bar b{color:var(--text2)}
.uh-bar .lp{margin-left:auto;font-family:'Consolas','Liberation Mono',monospace}

/* -- Message -------------------------------------------------- */
.uh-msg{display:none;padding:7px 14px;font-size:11px;font-weight:600;flex-shrink:0;border-bottom:1px solid transparent}
.uh-msg.err{display:block;background:var(--err-bg);border-bottom-color:var(--err-border);color:var(--err-text)}
.uh-msg.ok{display:block;background:var(--ok-bg);border-bottom-color:var(--ok-border);color:var(--ok-text)}

/* -- Editor --------------------------------------------------- */
.uh-ed{flex:1;display:flex;overflow:hidden;background:var(--editor-bg)}
.uh-gutter{background:var(--gutter-bg);color:var(--gutter-fg);text-align:right;padding:10px 8px;font-family:'Consolas','Liberation Mono',monospace;font-size:12.5px;line-height:1.5;overflow:hidden;user-select:none;border-right:1px solid var(--border);min-width:48px}
.uh-gutter span{display:block}
.uh-gutter span.bad{background:var(--err-bg);color:var(--err-text);font-weight:700}
.uh-ta{flex:1;border:none;outline:none;resize:none;padding:10px 12px;font-family:'Consolas','Liberation Mono',monospace;font-size:12.5px;line-height:1.5;background:var(--editor-bg);color:var(--editor-fg);white-space:pre;overflow:auto}
.uh-ta::-webkit-scrollbar{width:6px;height:6px}
.uh-ta::-webkit-scrollbar-thumb{background:var(--border2);border-radius:3px}

/* -- Format hint ---------------------------------------------- */
.uh-hint{background:var(--bg2);padding:6px 14px;font-size:10.5px;color:var(--text3);flex-shrink:0;border-top:1px solid var(--border);font-family:'Consolas','Liberation Mono',monospace}
</style>
</head>
<body>

<div id="uhacl">
<div class="uh-toolbar">
  <div class="title"><span class="icon">&#9998;</span> ACLView</div>
  <select id="uhFile"></select>
  <button class="uh-btn" id="uhReload" type="button" title="Discard changes and reload">Reload</button>
  <button class="uh-btn save" id="uhSave" type="button" title="Validate and save">Save</button>
</div>
<div class="uh-bar">
  <span><b id="uhLines">0</b> lines</span>
  <span id="uhDirty"></span>
  <span class="lp" id="uhPath">--</span>
</div>
<div class="uh-msg" id="uhMsg"></div>
<div class="uh-ed">
  <div class="uh-gutter" id="uhGutter"></div>
  <textarea class="uh-ta" id="uhTa" spellcheck="false" wrap="off"></textarea>
</div>
<div class="uh-hint" id="uhHint"></div>
</div>

<script>
(function(){
var API='../api.php';
var current='',dirty=false;

// Line formats are the ones uhmleases.sh enforces; shown here so a manual
// edit is written right the first time.
var HINTS={
  'uhm-auth':'a;MAC;IP;HOST;EPOCH;   -- "#" in front deactivates the entry',
  'uhm-grace':'a;MAC;IP;HOST;EPOCH;   -- no "#" variant',
  'uhm-queue':'MAC   -- one bare MAC per line',
  'blockdhcp':'a;MAC;IP;HOST;   -- no "#" variant',
  'mac':'a;MAC;IP;HOST;   -- "#" in front deactivates the entry'
};

function setDark(on){
  var mod=document.getElementById('uhacl');
  if(on)mod.classList.add('dark');else mod.classList.remove('dark');
}
try{setDark(localStorage.getItem('uh_dm')==='1')}catch(e){}
window.addEventListener('message',function(ev){
  if(ev.data&&typeof ev.data.uhDark==='boolean')setDark(ev.data.uhDark);
});

var ta=document.getElementById('uhTa');
var gutter=document.getElementById('uhGutter');
var msg=document.getElementById('uhMsg');

function showMessage(text,kind){
  msg.textContent=text;
  msg.className='uh-msg '+kind;
}
function clearMessage(){msg.className='uh-msg';msg.textContent=''}

function lineCount(){
  var text=ta.value;
  if(text==='')return 0;
  return text.replace(/\n$/,'').split('\n').length;
}

function renderGutter(badLine){
  var total=lineCount(),html='';
  for(var i=1;i<=total;i++){
    html+='<span'+(i===badLine?' class="bad"':'')+'>'+i+'</span>';
  }
  gutter.innerHTML=html||'<span>1</span>';
  gutter.scrollTop=ta.scrollTop;
  document.getElementById('uhLines').textContent=total;
}

function setDirty(on){
  dirty=on;
  document.getElementById('uhDirty').textContent=on?'unsaved changes':'';
}

ta.addEventListener('input',function(){setDirty(true);renderGutter(0)});
ta.addEventListener('scroll',function(){gutter.scrollTop=ta.scrollTop});

function hintFor(name){
  if(HINTS[name])return HINTS[name];
  return HINTS['mac'];
}

function loadList(){
  fetch(API+'?g=acl&a=list').then(function(r){return r.json()}).then(function(d){
    if(d.error){showMessage(d.error,'err');return}
    var select=document.getElementById('uhFile');
    select.innerHTML=(d.files||[]).map(function(name){
      return '<option value="'+name+'">'+name+'.txt</option>';
    }).join('');
    if((d.files||[]).length)loadFile(d.files[0]);
  }).catch(function(){showMessage('cannot reach the API','err')});
}

function loadFile(name){
  clearMessage();
  fetch(API+'?g=acl&a=read&name='+encodeURIComponent(name)).then(function(r){return r.json()}).then(function(d){
    if(d.error){showMessage(d.error,'err');return}
    current=d.name;
    ta.value=d.content||'';
    document.getElementById('uhPath').textContent=d.path||'--';
    document.getElementById('uhHint').textContent=hintFor(current.indexOf('mac-')===0?'mac':current);
    setDirty(false);
    renderGutter(0);
  }).catch(function(){showMessage('cannot reach the API','err')});
}

function saveFile(){
  if(!current)return;
  var button=document.getElementById('uhSave');
  button.disabled=true;
  clearMessage();
  fetch(API+'?g=acl&a=write&name='+encodeURIComponent(current),{
    method:'POST',
    headers:{'Content-Type':'text/plain'},
    body:ta.value
  }).then(function(r){return r.json()}).then(function(d){
    button.disabled=false;
    if(d.error){
      showMessage(d.line?(d.error+' on line '+d.line+': '+d.content):d.error,'err');
      renderGutter(d.line||0);
      return;
    }
    showMessage('Saved '+d.name+'.txt -- '+d.lines+' lines','ok');
    setDirty(false);
    renderGutter(0);
  }).catch(function(){button.disabled=false;showMessage('cannot reach the API','err')});
}

document.getElementById('uhFile').addEventListener('change',function(){
  if(dirty&&!confirm('Discard unsaved changes?')){
    this.value=current;
    return;
  }
  loadFile(this.value);
});
document.getElementById('uhReload').addEventListener('click',function(){
  if(dirty&&!confirm('Discard unsaved changes?'))return;
  loadFile(current);
});
document.getElementById('uhSave').addEventListener('click',saveFile);

loadList();
})();
</script>
</body>
</html>
