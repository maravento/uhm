<?php
/**
 * ToolView — uhm reports and search
 *
 * Local ACL reports and UniFi controller reports, both served by
 * uhmtool.sh through ../api.php. Read-only: the actions that delete
 * vouchers or forget clients stay in uhmunifi.sh, on the terminal.
 */

header('Cache-Control: no-cache, no-store, must-revalidate, max-age=0');
header('Pragma: no-cache');
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ToolView</title>
<style>
/* -- Variables -- Light (default) ----------------------------- */
#uhtool{
  --bg: #ffffff;
  --bg2: #f8f9fa;
  --border: #dee2e6;
  --border2: #e9ecef;
  --text: #212529;
  --text2: #495057;
  --text3: #868e96;
  --th-bg: #f1f3f5;
  --th-color: #495057;
  --row-hover:#f1f3f5;
  --bar-bg: #f1f3f5;
  --mc-color: #1565c0;
  --err-bg: #f8d7da;
  --err-border:#f5c6cb;
  --err-text:#721c24;
}
/* -- Variables -- Dark ----------------------------------------- */
#uhtool.dark{
  --bg: #0d1117;
  --bg2: #161b22;
  --border: #21262d;
  --border2: #30363d;
  --text: #e6edf3;
  --text2: #c9d1d9;
  --text3: #8b949e;
  --th-bg: #161b22;
  --th-color: #8b949e;
  --row-hover:#161b22;
  --bar-bg: #111827;
  --mc-color: #79c0ff;
  --err-bg: #3a1a1a;
  --err-border:#6e1a1a;
  --err-text: #f85149;
}

html,body{height:100%;margin:0;background:var(--bg,#fff)}
#uhtool *{box-sizing:border-box}
#uhtool{font-family:'Segoe UI',system-ui,sans-serif;display:flex;flex-direction:column;height:100vh;background:var(--bg)}

/* -- Toolbar (always dark) ------------------------------------ */
.uh-toolbar{background:#1e2a35;padding:10px 14px;display:flex;align-items:center;gap:8px;flex-wrap:wrap;flex-shrink:0;border-bottom:3px solid #3498db}
.uh-toolbar .title{font-size:13px;font-weight:700;color:#fff;display:flex;align-items:center;gap:6px;white-space:nowrap}
.uh-toolbar .title .icon{background:rgba(255,255,255,.1);border-radius:5px;padding:3px 6px;font-size:12px}
.uh-toolbar select{background:#253545;border:1px solid #3a4f63;color:#e6eef8;padding:7px 8px;border-radius:6px;font-size:11px;outline:none;cursor:pointer;min-width:190px}
.uh-toolbar select option{background:#1e2a35}
.uh-toolbar optgroup{background:#1e2a35;color:#90a4ae}
.uh-search{flex:1;min-width:200px;display:flex;gap:5px;align-items:center}
.uh-search input{flex:1;background:#253545;border:1px solid #3a4f63;color:#e6eef8;padding:7px 10px;border-radius:6px;font-size:12px;outline:none}
.uh-search input::placeholder{color:#607d8b}
.uh-search input:focus{border-color:#3498db}
.uh-search input[disabled]{opacity:.4}
.uh-btn{padding:6px 30px;border-radius:6px;font-size:14px;font-weight:600;cursor:pointer;border:none;white-space:nowrap;background:#1565c0;color:#fff}
.uh-btn:hover{background:#1976d2}
.uh-btn[disabled]{opacity:.45;cursor:default}

/* -- Summary bar ---------------------------------------------- */
.uh-bar{background:var(--bar-bg);padding:5px 14px;display:flex;gap:14px;align-items:center;font-size:10px;color:var(--text3);flex-shrink:0;flex-wrap:wrap;border-bottom:1px solid var(--border)}
.uh-bar b{color:var(--text2)}
.uh-bar:empty{display:none;padding:0}

/* -- Message -------------------------------------------------- */
.uh-msg{display:none;padding:7px 14px;font-size:11px;font-weight:600;flex-shrink:0;background:var(--err-bg);border-bottom:1px solid var(--err-border);color:var(--err-text)}
.uh-msg.on{display:block}

/* -- Table ---------------------------------------------------- */
.uh-tw{flex:1;overflow:auto;background:var(--bg)}
.uh-tw table{width:100%;border-collapse:collapse;font-size:12.5px}
.uh-tw thead{position:sticky;top:0;z-index:5}
.uh-tw thead th{background:var(--th-bg);color:var(--th-color);font-weight:600;padding:9px 12px;text-align:left;border-bottom:2px solid var(--border);white-space:nowrap;font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.uh-tw tbody tr{border-bottom:1px solid var(--border2)}
.uh-tw tbody tr:hover{background:var(--row-hover)}
.uh-tw td{padding:7px 12px;color:var(--text);vertical-align:top}
.uh-tw td.mono{font-family:'Consolas','Liberation Mono',monospace;color:var(--mc-color);white-space:nowrap}
.uh-tw td.warn{color:var(--err-text);font-size:11.5px}
.uh-empty{text-align:center;padding:50px 20px;color:var(--text3)}

/* -- Marks ---------------------------------------------------- */
.mk{display:inline-block;min-width:18px;text-align:center;font-weight:700}
.mk.y{color:#2e7d32}
.mk.n{color:var(--text3)}
.tag{display:inline-block;padding:2px 8px;border-radius:10px;font-weight:700;font-size:10px;text-transform:uppercase;letter-spacing:.4px}
.tag.ok{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
.tag.w{background:#fff3cd;color:#856404;border:1px solid #ffeeba}
.tag.e{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
.tag.i{background:#d1ecf1;color:#0c5460;border:1px solid #bee5eb}
#uhtool.dark .tag.ok{background:#12261a;color:#56d364;border-color:#238636}
#uhtool.dark .tag.w{background:#3a2a00;color:#ffc107;border-color:#d29922}
#uhtool.dark .tag.e{background:#3a1a1a;color:#f85149;border-color:#6e1a1a}
#uhtool.dark .tag.i{background:#1a2a3a;color:#90caf9;border-color:#1565c0}
.uh-tw::-webkit-scrollbar{width:6px;height:6px}
.uh-tw::-webkit-scrollbar-thumb{background:var(--border2);border-radius:3px}
</style>
</head>
<body>

<div id="uhtool">
<div class="uh-toolbar">
  <div class="title"><span class="icon">&#128269;</span> ToolView</div>
  <select id="uhReport">
    <optgroup label="Local ACL">
      <option value="report:mac">Check MAC</option>
      <option value="report:grace">Grace period</option>
      <option value="report:consistency">Consistency check</option>
      <option value="report:search">Search by IP or hostname</option>
    </optgroup>
    <optgroup label="UniFi">
      <option value="unifi:status">Connection status</option>
      <option value="unifi:authorized">Authorized</option>
      <option value="unifi:vouchers">Vouchers</option>
      <option value="unifi:guests">Guest sessions</option>
      <option value="unifi:unauthorized">Unauthorized</option>
    </optgroup>
  </select>
  <div class="uh-search">
    <input id="uhQ" type="text" placeholder="MAC address" onkeydown="if(event.key==='Enter')uhRun()">
  </div>
  <button class="uh-btn" id="uhRunBtn" type="button">Run</button>
</div>
<div class="uh-bar" id="uhBar"></div>
<div class="uh-msg" id="uhMsg"></div>
<div class="uh-tw" id="uhTW">
  <div class="uh-empty" id="uhEM">Select a report and press Run</div>
  <table id="uhTable" style="display:none"><thead id="uhTH"></thead><tbody id="uhTB"></tbody></table>
</div>
</div>

<script>
(function(){
var API='../api.php';

// Column layout per report. mark renders the presence flags as Y/N, tag
// renders a status word as a colored pill.
var COLUMNS={
  'report:mac':[
    {key:'mac',label:'MAC',cls:'mono'},
    {key:'auth',label:'uhm-auth',type:'mark'},
    {key:'grace',label:'uhm-grace',type:'mark'},
    {key:'block',label:'blockdhcp',type:'mark'},
    {key:'acl',label:'mac-*',type:'mark'},
    {key:'leases',label:'leases',type:'mark'},
    {key:'files',label:'Files'},
    {key:'grace_left',label:'Grace left'},
    {key:'warnings',label:'Warnings',type:'list'}
  ],
  'report:grace':[
    {key:'mac',label:'MAC',cls:'mono'},
    {key:'ip',label:'IP',cls:'mono'},
    {key:'name',label:'Name'},
    {key:'expires',label:'Expires in'}
  ],
  'unifi:status':[
    {key:'endpoint',label:'Endpoint',cls:'mono'},
    {key:'rc',label:'RC',type:'tag'},
    {key:'entries',label:'Entries'}
  ],
  'unifi:authorized':[
    {key:'mac',label:'MAC',cls:'mono'},
    {key:'ip',label:'IP',cls:'mono'},
    {key:'host',label:'Hostname'},
    {key:'code',label:'Voucher',cls:'mono'},
    {key:'status',label:'Status',type:'tag'},
    {key:'expires',label:'Expires',cls:'mono'},
    {key:'online',label:'On',type:'mark'}
  ],
  'unifi:vouchers':[
    {key:'code',label:'Code',cls:'mono'},
    {key:'quota',label:'Quota'},
    {key:'used',label:'Used'},
    {key:'duration',label:'Duration'},
    {key:'note',label:'Note'}
  ],
  'unifi:guests':[
    {key:'mac',label:'MAC',cls:'mono'},
    {key:'hostname',label:'Hostname'},
    {key:'authorized_by',label:'Authorized by'},
    {key:'code',label:'Voucher',cls:'mono'},
    {key:'category',label:'Category',type:'tag'}
  ],
  'unifi:unauthorized':[
    {key:'mac',label:'MAC',cls:'mono'},
    {key:'ip',label:'IP',cls:'mono'},
    {key:'hostname',label:'Hostname'},
    {key:'essid',label:'ESSID'},
    {key:'is_guest',label:'Guest',type:'mark'}
  ]
};
COLUMNS['report:consistency']=COLUMNS['report:mac'];
COLUMNS['report:search']=COLUMNS['report:mac'];

var TAGS={
  'ok':'ok','VALID':'ok','MULTI':'ok','MANAGED':'ok','VOUCHER':'i',
  'CONSUMED':'w','NO-VOUCHER':'w','UNKNOWN':'e','error':'e'
};

function setDark(on){
  var mod=document.getElementById('uhtool');
  if(on)mod.classList.add('dark');else mod.classList.remove('dark');
}
try{setDark(localStorage.getItem('uh_dm')==='1')}catch(e){}
window.addEventListener('message',function(ev){
  if(ev.data&&typeof ev.data.uhDark==='boolean')setDark(ev.data.uhDark);
});

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}

var input=document.getElementById('uhQ');
var select=document.getElementById('uhReport');
var message=document.getElementById('uhMsg');

function needsQuery(){
  return select.value==='report:mac'||select.value==='report:search';
}

function syncInput(){
  input.disabled=!needsQuery();
  input.placeholder=select.value==='report:search'?'IP address or hostname':'MAC address';
  if(input.disabled)input.value='';
}

function showError(text){
  message.textContent=text;
  message.className='uh-msg on';
}
function clearError(){message.className='uh-msg';message.textContent=''}

function renderCell(column,row){
  var value=row[column.key];
  if(column.type==='mark'){
    var on=(value===1||value===true);
    return '<span class="mk '+(on?'y':'n')+'">'+(on?'Y':'N')+'</span>';
  }
  if(column.type==='tag'){
    var text=String(value===undefined||value===null?'':value);
    if(text==='')return '';
    return '<span class="tag '+(TAGS[text]||'i')+'">'+esc(text)+'</span>';
  }
  if(column.type==='list'){
    if(!value||!value.length)return '';
    return value.map(esc).join('<br>');
  }
  return esc(value===undefined||value===null?'':value);
}

function renderTable(columns,rows){
  var table=document.getElementById('uhTable');
  var empty=document.getElementById('uhEM');
  if(!rows||!rows.length){
    table.style.display='none';
    empty.style.display='block';
    empty.textContent='No results';
    return;
  }
  document.getElementById('uhTH').innerHTML='<tr>'+columns.map(function(column){
    return '<th>'+esc(column.label)+'</th>';
  }).join('')+'</tr>';
  document.getElementById('uhTB').innerHTML=rows.map(function(row){
    return '<tr>'+columns.map(function(column){
      var cls=column.cls?' class="'+column.cls+'"':(column.type==='list'?' class="warn"':'');
      return '<td'+cls+'>'+renderCell(column,row)+'</td>';
    }).join('')+'</tr>';
  }).join('');
  empty.style.display='none';
  table.style.display='';
}

function renderSummary(data){
  var bar=document.getElementById('uhBar');
  if(data.summary){
    var s=data.summary;
    bar.innerHTML='MACs <b>'+s.total+'</b> | Grace <b>'+s.grace+'</b> | Blocked <b>'+s.block+'</b> | '+
      'ACL <b>'+s.acl+'</b> | Auth <b>'+s.auth+'</b> | Leases <b>'+s.leases+'</b> | '+
      'Warnings <b>'+s.warnings+'</b>';
    return;
  }
  if(data.total!==undefined){
    bar.innerHTML='Total <b>'+data.total+'</b> | Expired <b>'+data.expired+'</b> | Active <b>'+data.active+'</b>';
    return;
  }
  if(data.controller){
    bar.innerHTML='Controller <b>'+esc(data.controller)+'</b> | Site <b>'+esc(data.site)+'</b> | Type <b>'+esc(data.type)+'</b>';
    return;
  }
  bar.innerHTML='';
}

window.uhRun=function(){
  var choice=select.value;
  var parts=choice.split(':');
  var url=API+'?g='+parts[0]+'&a='+parts[1];
  var button=document.getElementById('uhRunBtn');

  clearError();
  if(needsQuery()){
    var query=input.value.trim();
    if(!query){showError('enter a value to search');return}
    url+='&q='+encodeURIComponent(query);
  }

  button.disabled=true;
  document.getElementById('uhTable').style.display='none';
  var empty=document.getElementById('uhEM');
  empty.style.display='block';
  empty.textContent='Running...';
  document.getElementById('uhBar').innerHTML='';

  fetch(url).then(function(r){return r.json()}).then(function(d){
    button.disabled=false;
    if(d.error){
      empty.textContent='No results';
      showError(d.error);
      return;
    }
    renderSummary(d);
    renderTable(COLUMNS[choice],d.rows);
  }).catch(function(){
    button.disabled=false;
    empty.textContent='No results';
    showError('cannot reach the API');
  });
};

select.addEventListener('change',syncInput);
document.getElementById('uhRunBtn').addEventListener('click',uhRun);
syncInput();
})();
</script>
</body>
</html>
