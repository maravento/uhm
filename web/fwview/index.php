<?php
/**
 * FWView — uhm firewall switches
 * FILE: fwview/index.php
 *
 * Lists the on/off switches of toggles.conf and changes one at a time
 * through ../api.php. uhmiptables.sh applies them on the next reload.
 */

header('Cache-Control: no-cache, no-store, must-revalidate, max-age=0');
header('Pragma: no-cache');
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FWView</title>
<style>
/* -- Variables -- Light (default) ----------------------------- */
#uhfw{
  --bg: #ffffff;
  --bg2: #f8f9fa;
  --border: #dee2e6;
  --text: #212529;
  --text2: #495057;
  --text3: #868e96;
  --bar-bg: #f1f3f5;
  --row-hover:#f1f3f5;
  --off: #ced4da;
  --on: #1565c0;
  --act-allow:#1565c0;
  --act-drop: #c2410c;
  --err-bg: #f8d7da;
  --err-border:#f5c6cb;
  --err-text:#721c24;
  --ok-bg: #d4edda;
  --ok-border:#c3e6cb;
  --ok-text: #155724;
}
/* -- Variables -- Dark ----------------------------------------- */
#uhfw.dark{
  --bg: #0d1117;
  --bg2: #161b22;
  --border: #21262d;
  --text: #e6edf3;
  --text2: #c9d1d9;
  --text3: #8b949e;
  --bar-bg: #111827;
  --row-hover:#161b22;
  --off: #30363d;
  --on: #1f6feb;
  --act-allow:#58a6ff;
  --act-drop: #f0883e;
  --err-bg: #3a1a1a;
  --err-border:#6e1a1a;
  --err-text: #f85149;
  --ok-bg: #12261a;
  --ok-border:#238636;
  --ok-text: #56d364;
}

html,body{height:100%;margin:0;background:var(--bg,#fff)}
#uhfw *{box-sizing:border-box}
#uhfw{font-family:'Segoe UI',system-ui,sans-serif;display:flex;flex-direction:column;height:100vh;background:var(--bg);color:var(--text)}

/* -- Toolbar (always dark) ------------------------------------ */
.uh-toolbar{background:#1e2a35;padding:10px 14px;display:flex;align-items:center;gap:8px;flex-wrap:wrap;flex-shrink:0;border-bottom:3px solid #3498db}
.uh-toolbar .title{font-size:13px;font-weight:700;color:#fff;display:flex;align-items:center;gap:6px;white-space:nowrap}
.uh-toolbar .title .icon{background:rgba(255,255,255,.1);border-radius:5px;padding:3px 6px;font-size:12px}
.uh-btn{padding:6px 12px;border-radius:6px;font-size:11px;font-weight:600;cursor:pointer;border:none;white-space:nowrap;background:#37474f;color:#e6eef8;margin-left:auto}
.uh-btn:hover{background:#455a64}

/* -- Status bar ----------------------------------------------- */
.uh-bar{background:var(--bar-bg);padding:5px 14px;display:flex;gap:14px;align-items:center;font-size:10px;color:var(--text3);flex-shrink:0;flex-wrap:wrap;border-bottom:1px solid var(--border)}
.uh-bar b{color:var(--text2)}
.uh-bar .lp{margin-left:auto;font-family:'Consolas','Liberation Mono',monospace}

/* -- Message -------------------------------------------------- */
.uh-msg{display:none;padding:7px 14px;font-size:11px;font-weight:600;flex-shrink:0;border-bottom:1px solid transparent}
.uh-msg.err{display:block;background:var(--err-bg);border-bottom-color:var(--err-border);color:var(--err-text)}
.uh-msg.ok{display:block;background:var(--ok-bg);border-bottom-color:var(--ok-border);color:var(--ok-text)}

/* -- Switch list ---------------------------------------------- */
.uh-list{flex:1;overflow:auto}
.uh-row{display:flex;align-items:center;gap:12px;padding:8px 14px;border-bottom:1px solid var(--border)}
.uh-row:hover{background:var(--row-hover)}
.uh-row .lbl{flex:1;min-width:0}
.uh-row .lbl div{font-size:12.5px;color:var(--text)}
/* Action badge: blue/orange stay distinct for red-green color blindness,
   and the word plus symbol carry the meaning on their own. */
.uh-act{display:inline-block;font-size:10px;font-weight:700;letter-spacing:.3px;padding:1px 6px;border-radius:4px;border:1px solid;vertical-align:1px}
.uh-act.allow{color:var(--act-allow);border-color:var(--act-allow)}
.uh-act.drop{color:var(--act-drop);border-color:var(--act-drop)}
.uh-act.limit,.uh-act.mode{color:var(--text3);border-color:var(--text3)}
.uh-sw{position:relative;width:38px;height:20px;flex-shrink:0}
.uh-sw input{opacity:0;width:0;height:0;position:absolute}
.uh-sw span{position:absolute;inset:0;background:var(--off);border-radius:20px;cursor:pointer;transition:background .15s}
.uh-sw span:before{content:"";position:absolute;width:14px;height:14px;left:3px;top:3px;background:#fff;border-radius:50%;transition:transform .15s}
.uh-sw input:checked+span{background:var(--on)}
/* When on, the switch takes the color of its action; the ON/OFF word next
   to it says the state without relying on color. */
.uh-sw.drop input:checked+span{background:var(--act-drop)}
.uh-sw.limit input:checked+span,.uh-sw.mode input:checked+span{background:var(--text3)}
.uh-state{width:28px;font-size:10px;font-weight:700;color:var(--text3);text-align:right;flex-shrink:0}
.uh-state.on{color:var(--text)}
.uh-sw input:checked+span:before{transform:translateX(18px)}
.uh-sw input:disabled+span{opacity:.5;cursor:default}
.uh-sw input:focus-visible+span{outline:2px solid var(--on);outline-offset:2px}

/* -- Hint ----------------------------------------------------- */
.uh-hint{background:var(--bg2);padding:6px 14px;font-size:10.5px;color:var(--text3);flex-shrink:0;border-top:1px solid var(--border)}
</style>
</head>
<body>

<div id="uhfw">
<div class="uh-toolbar">
  <div class="title"><span class="icon">&#128737;</span> FWView</div>
  <button class="uh-btn" id="uhReload" type="button" title="Reload switches">Reload</button>
</div>
<div class="uh-bar">
  <span><b id="uhOn">0</b> on</span>
  <span><b id="uhTotal">0</b> switches</span>
  <span class="lp" id="uhPath">--</span>
</div>
<div class="uh-msg" id="uhMsg"></div>
<div class="uh-list" id="uhList"></div>
<div class="uh-hint">Changes are saved at once and applied by uhmiptables.sh on the next reload.</div>
</div>

<script>
(function(){
var API='../api.php';
var BADGE={ALLOW:'✓',DROP:'✕',LIMIT:'◐',MODE:'⇄'};
var list=document.getElementById('uhList');
var msg=document.getElementById('uhMsg');

function setDark(on){
  var mod=document.getElementById('uhfw');
  if(on)mod.classList.add('dark');else mod.classList.remove('dark');
}
try{setDark(localStorage.getItem('uh_dm')==='1')}catch(e){}
window.addEventListener('message',function(ev){
  if(ev.data&&typeof ev.data.uhDark==='boolean')setDark(ev.data.uhDark);
});

function showMessage(text,kind){msg.textContent=text;msg.className='uh-msg '+kind}
function clearMessage(){msg.className='uh-msg';msg.textContent=''}

function countOn(){
  var boxes=list.querySelectorAll('input');
  var on=0;
  boxes.forEach(function(b){if(b.checked)on++});
  document.getElementById('uhOn').textContent=on;
  document.getElementById('uhTotal').textContent=boxes.length;
}

// Built with DOM nodes, never innerHTML: labels come from a file on disk.
function row(t){
  var r=document.createElement('div');r.className='uh-row';
  var lbl=document.createElement('div');lbl.className='lbl';
  // Label shape: "KEY: ACTION description". The action is shown as a badge
  // with its word and a symbol, so it never depends on color alone.
  var m=/^([A-Z0-9]+):\s+(ALLOW|DROP|LIMIT|MODE)\s+(.*)$/.exec(t.label||'');
  var name=document.createElement('div');
  if(m){
    var tag=document.createElement('b');tag.textContent=m[1]+' ';
    var badge=document.createElement('span');
    badge.className='uh-act '+m[2].toLowerCase();
    badge.textContent=(BADGE[m[2]]||'')+' '+m[2];
    name.appendChild(tag);name.appendChild(badge);
    name.appendChild(document.createTextNode(' '+m[3]));
  }else{
    name.textContent=t.label||t.key;
  }
  lbl.appendChild(name);
  var sw=document.createElement('label');sw.className='uh-sw'+(m?' '+m[2].toLowerCase():'');
  var box=document.createElement('input');box.type='checkbox';box.checked=t.value==='on';
  box.setAttribute('aria-label',t.label||t.key);
  var knob=document.createElement('span');
  sw.appendChild(box);sw.appendChild(knob);
  var state=document.createElement('span');
  function showState(){state.textContent=box.checked?'ON':'OFF';state.className='uh-state'+(box.checked?' on':'')}
  showState();
  box.addEventListener('change',function(){showState();save(t.key,box,showState)});
  r.appendChild(lbl);r.appendChild(state);r.appendChild(sw);
  return r;
}

function load(){
  clearMessage();
  fetch(API+'?g=fw&a=read').then(function(r){return r.json()}).then(function(d){
    if(d.error){showMessage(d.error,'err');return}
    list.textContent='';
    (d.toggles||[]).forEach(function(t){list.appendChild(row(t))});
    document.getElementById('uhPath').textContent=d.path||'--';
    countOn();
  }).catch(function(){showMessage('cannot reach the API','err')});
}

function save(key,box,done){
  var value=box.checked?'on':'off';
  box.disabled=true;
  clearMessage();
  fetch(API+'?g=fw&a=write&key='+encodeURIComponent(key)+'&value='+value,{
    method:'POST',
    headers:{'X-UHM-FW-Write':'1'}
  }).then(function(r){return r.json()}).then(function(d){
    box.disabled=false;
    if(d.error){box.checked=!box.checked;done();showMessage(d.error,'err');countOn();return}
    showMessage(d.key+' set to '+d.value+' -- applies on the next reload','ok');
    countOn();
  }).catch(function(){
    box.disabled=false;box.checked=!box.checked;done();countOn();
    showMessage('cannot reach the API','err');
  });
}

document.getElementById('uhReload').addEventListener('click',load);
load();
})();
</script>
</body>
</html>
