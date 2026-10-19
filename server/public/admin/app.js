'use strict';
const $ = id => document.getElementById(id);
let token = sessionStorage.getItem('haven-admin-token') || '';
let tab = 'rooms', rows = [], workers = [], loading = false, epoch = 0, selectedId = '';
let dataset = {rooms: [], repairs: [], workers: []};
const roomStatus = {1:'待审核',2:'已通过',3:'已打回'};
const repairStatus = {0:'已取消',1:'待派单',2:'处理中',3:'已完成',4:'已取消',5:'待接单',6:'待住户确认'};
// 选中“待办”时只显示有待办标签的工单；急单优先，其余按时间倒序。
const TODO='todo';
const pages = {
  rooms: {title:'房屋审核',description:'查看住户提交的房屋资料，及时完成审核。',list:'房屋资料',search:'搜索房屋、业主或手机号'},
  repairs: {title:'报修管理',description:'安排合适的维修师傅，跟进每一条报修记录。',list:'报修记录',search:'搜索维修项目、房屋或师傅'},
  workers: {title:'维修人员',description:'管理师傅联系方式，为社区报修安排维修人员。',list:'维修人员名册',search:'搜索师傅姓名或手机号'}
};
function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text != null) element.textContent = String(text);
  if (className) element.className = className;
  return element;
}
function message(text='') { $('message').textContent=text; }
function logout() {
  epoch++;
  loading=false;
  token='';
  sessionStorage.removeItem('haven-admin-token');
  $('workspace').hidden=true;
  $('login-panel').hidden=false;
  $('logout').hidden=true;
  $('account-name').hidden=true;
  selectedId='';
  $('detail-panel').replaceChildren();
  $('code').value='';
  $('code-hint').textContent='使用已开通权限的物业账号登录';
  $('content').replaceChildren();
  $('stats').replaceChildren();
  message();
  rows=[]; workers=[];
  dataset={rooms:[],repairs:[],workers:[]};
}
async function api(path, method='GET', body) {
  const requestToken=token;
  const response=await fetch(path,{
    method,
    headers:{...(requestToken?{Authorization:`Bearer ${requestToken}`}:{}),...(body?{'Content-Type':'application/json'}:{})},
    ...(body?{body:JSON.stringify(body)}:{})
  });
  const data=await response.json();
  if(response.status===401) {
    if(requestToken===token) logout();
    throw Error('登录已过期，请重新登录');
  }
  if(!response.ok||data.code!==10000) throw Error(data.message||'操作失败，请重试');
  return data.data;
}
async function guarded(button, action) {
  if(button.disabled) return;
  const generation=epoch;
  button.disabled=true;
  button.setAttribute('aria-busy','true');
  message();
  try { await action(); }
  catch(error) { if(generation===epoch || !token) message(error.message); }
  finally { button.disabled=false; button.removeAttribute('aria-busy'); }
}
$('send-code').onclick=()=>guarded($('send-code'),async()=>{
  if(!$('mobile').reportValidity()) return;
  const mobile=$('mobile').value;
  const data=await api(`/code?mobile=${encodeURIComponent(mobile)}`);
  if(mobile!==$('mobile').value) return;
  if(data.development) {
    $('code').value=data.code;
    $('code-hint').textContent='开发验证码已填入，点击下方按钮即可登录。';
  } else $('code-hint').textContent='验证码已发送，请查收。';
});
$('login-form').onsubmit=event=>{
  event.preventDefault();
  guarded(event.submitter,async()=>{
    const data=await api('/login','POST',{mobile:$('mobile').value,code:$('code').value});
    token=data.token;
    try { await enter(); if(token) sessionStorage.setItem('haven-admin-token',token); }
    catch(error) { logout(); throw error; }
  });
};
async function enter() {
  const generation=epoch;
  const me=await api('/userInfo');
  if(generation!==epoch) return;
  if(me.role!=='admin') throw Error('此账号不是物业管理员');
  $('login-panel').hidden=true;
  $('workspace').hidden=false;
  $('logout').hidden=false;
  $('account-name').textContent=me.nickName||'物业管理员';
  $('account-name').hidden=false;
  $('today').textContent=new Date().toLocaleDateString('zh-CN',{year:'numeric',month:'long',day:'numeric',weekday:'long'});
  setTab('rooms');
  await load();
}
$('logout').onclick=logout;
$('refresh').onclick=()=>load();
$('filter').onchange=()=>{renderQuickFilters();renderStats();render();};
$('search').oninput=render;
document.querySelectorAll('[data-tab]').forEach(button=>button.onclick=()=>{
  if(loading) return;
  setTab(button.dataset.tab);
  load();
});
function skeleton() {
  $('content').replaceChildren(node('span','正在加载记录','sr-only'),...Array.from({length:3},()=>node('div',null,'skeleton')));
  $('content').setAttribute('aria-busy','true');
}
function setTab(value) {
  tab=value;
  selectedId='';
  document.querySelectorAll('[data-tab]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.tab===tab)));
  const page=pages[tab];
  $('title').textContent=page.title;
  $('breadcrumb-page').textContent=page.title;
  $('page-description').textContent=page.description;
  $('list-title').textContent=page.list;
  $('search').placeholder=page.search;
  $('search').value='';
  $('filter-label').hidden=tab==='workers';
  $('quick-filters').hidden=tab==='workers';
  $('filter').replaceChildren();
  $('filter').value='';
  $('quick-filters').replaceChildren();
  const states=tab==='rooms'?roomStatus:repairStatus;
  const entries=Object.entries(states).filter(([key])=>key!=='4');
  for(const [value,label] of tab==='repairs'?[[TODO,'待办'],['','全部'],...entries]:[['','全部'],...entries]) {
    const option=node('option',label); option.value=value; $('filter').append(option);
    const quick=node('button',label); quick.type='button'; quick.dataset.status=value;
    quick.onclick=()=>{$('filter').value=value;renderQuickFilters();renderStats();render();};
    $('quick-filters').append(quick);
  }
  if(tab==='repairs') $('filter').value=TODO;
  renderQuickFilters();
  $('result-count').textContent='';
  $('stats').replaceChildren();
  rows=[];
  skeleton();
  renderDetail(null);
}
// keep=true 用于处理完一条记录后刷新：保留筛选条件、所选记录和列表滚动位置。
async function load(keep=false) {
  if(loading||!token) return;
  loading=true;
  const generation=epoch;
  const scroll=keep?(document.querySelector('.request-list')?.scrollTop??0):0;
  const pageScroll=keep?window.scrollY:0;
  $('search').disabled=true;
  $('filter').disabled=true;
  $('refresh').disabled=true;
  document.querySelectorAll('[data-tab]').forEach(button=>button.disabled=true);
  message();
  if(!keep) { skeleton(); renderDetail(null); }
  try {
    const results=await Promise.all(['rooms','repairs','workers'].map(name=>api(`/management/${name}`)));
    if(generation!==epoch) return;
    dataset={rooms:results[0],repairs:results[1],workers:results[2]};
    rows=dataset[tab]; workers=dataset.workers;
    if(!rows.some(row=>row.id===selectedId)) selectedId=rows[0]?.id||'';
    $('rooms-count').textContent=dataset.rooms.filter(row=>row.status===1).length;
    $('repairs-count').textContent=dataset.repairs.filter(row=>(row.todo||[]).length).length;
    $('updated-at').textContent='更新于 '+new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'});
    renderStats();
    render();
    if(keep) {
      const list=document.querySelector('.request-list');
      if(list) list.scrollTop=scroll;
      window.scrollTo(0,pageScroll);
    }
  } catch(error) {
    if(generation!==epoch) return;
    message(error.message);
    $('stats').replaceChildren();
    $('content').replaceChildren(emptyState('暂时无法加载','请点击“刷新数据”重试。'));
    $('result-count').textContent='加载失败';
    renderDetail(null);
  } finally {
    if(generation===epoch) {
      loading=false;
      $('search').disabled=false;
      $('filter').disabled=false;
      $('refresh').disabled=false;
      $('content').removeAttribute('aria-busy');
      document.querySelectorAll('[data-tab]').forEach(button=>button.disabled=false);
    }
  }
}
function renderStats() {
  const count=status=>rows.filter(row=>row.status===status).length;
  let cards;
  if(tab==='rooms') cards=[
    ['待审核',count(1),'等待物业处理','1'],
    ['已通过',count(2),'房屋资料已确认','2'],
    ['已打回',count(3),'等待住户修改','3'],
    ['全部房屋',rows.length,'当前提交的房屋资料','']
  ];
  else if(tab==='repairs') cards=[
    ['待办',rows.filter(row=>(row.todo||[]).length).length,'需要物业跟进的工单',TODO],
    ['待派单',count(1),'等待安排维修师傅','1'],
    ['处理中',count(2),'师傅正在处理','2'],
    ['待住户确认',count(6),'师傅已提交完工','6']
  ];
  else cards=[
    ['维修人员',rows.length,'已开通的师傅账号',null],
    ['待派单',dataset.repairs.filter(row=>row.status===1).length,'等待安排师傅',null],
    ['待接单',dataset.repairs.filter(row=>row.status===5).length,'已分配的报修',null],
    ['处理中',dataset.repairs.filter(row=>row.status===2).length,'正在处理的报修',null]
  ];
  $('stats').replaceChildren(...cards.map(([label,value,note,status],index)=>{
    const card=node(status===null?'div':'button',null,'stat'+(index===0?' featured':''));
    const heading=node('span',label,'stat-label');
    if(status!==null) {
      const arrow=node('span','↗'); arrow.setAttribute('aria-hidden','true'); heading.append(arrow);
      card.type='button';
      card.setAttribute('aria-pressed',String($('filter').value===status));
      card.onclick=()=>{$('filter').value=status;renderQuickFilters();renderStats();render();};
    }
    card.append(heading,node('span',value,'stat-value'),node('span',note,'stat-note'));
    return card;
  }));
}
function emptyState(title, description) {
  const empty=node('div',null,'empty');
  const symbol=node('span','▤','empty-symbol'); symbol.setAttribute('aria-hidden','true');
  empty.append(symbol,node('strong',title),node('span',description));
  return empty;
}
function workerForm() {
  const form=node('form',null,'worker-form');
  const name=node('input'); name.required=true; name.minLength=2; name.maxLength=20; name.placeholder='例如：张师傅';
  const mobile=node('input'); mobile.type='tel'; mobile.required=true; mobile.pattern='1[3-9][0-9]{9}'; mobile.maxLength=11; mobile.placeholder='用于师傅登录的手机号';
  for(const [text,input] of [['师傅姓名',name],['登录手机号',mobile]]) { const label=node('label',text); label.append(input); form.append(label); }
  const add=node('button','添加维修人员','primary'); add.type='submit'; form.append(add);
  form.onsubmit=event=>{event.preventDefault();guarded(add,async()=>{
    await api('/management/workers','POST',{nickName:name.value,mobile:mobile.value});
    name.value='';mobile.value='';
    await load();
  });};
  return form;
}
function renderQuickFilters() {
  document.querySelectorAll('#quick-filters button').forEach(button=>{
    button.setAttribute('aria-pressed',String(button.dataset.status===$('filter').value));
  });
}
function render() {
  const root=$('content');
  const existingForm=root.querySelector('.worker-form');
  root.replaceChildren();
  if(tab==='workers') root.append(existingForm||workerForm());
  const query=$('search').value.trim().toLowerCase();
  const selected=$('filter').value;
  const filtered=rows.filter(row=>{
    const status=tab==='repairs'&&row.status===4?0:row.status;
    const matchesStatus=tab==='workers'||!selected||(selected===TODO?(row.todo||[]).length>0:String(status)===selected);
    const text=[row.point,row.building,row.room,row.name,row.mobile,row.nickName,row.repairItemName,row.houseInfo,row.workerName,...(row.todo||[])].filter(Boolean).join(' ').toLowerCase();
    return matchesStatus&&(!query||text.includes(query));
  });
  if(tab==='repairs'&&selected===TODO) filtered.sort((a,b)=>Number(Boolean(b.urgent))-Number(Boolean(a.urgent)));
  $('result-count').textContent=`${filtered.length} 条`;
  if(!filtered.some(row=>row.id===selectedId)) selectedId=filtered[0]?.id||'';
  if(!filtered.length) {
    root.append(emptyState(tab==='workers'&&!query?'还没有维修人员':'暂无匹配记录',tab==='workers'&&!query?'在上方添加师傅后，就可以安排维修。':'可以调整搜索内容或切换状态查看。'));
    renderDetail(null);
    return;
  }
  const list=node('div',null,'request-list');
  for(const row of filtered) {
    const item=node('button',null,'request-row'+(row.id===selectedId?' selected':''));
    item.type='button';
    item.setAttribute('aria-pressed',String(row.id===selectedId));
    item.onclick=()=>{selectedId=row.id;render();};
    const icon=node('span',tab==='rooms'?'⌂':tab==='workers'?'工':'↗','record-symbol');
    icon.setAttribute('aria-hidden','true');
    const copy=node('span',null,'request-copy');
    const headline=node('span',null,'request-headline');
    const title=tab==='rooms'?[row.point,row.building,row.room].filter(Boolean).join(' '):tab==='workers'?row.nickName:row.repairItemName;
    headline.append(node('strong',title||'未命名记录'));
    if(tab!=='workers') {
      const statusLabel=(tab==='rooms'?roomStatus:repairStatus)[row.status]||'状态未知';
      const tone=(tab==='rooms'?row.status===2:row.status===3)?'done':tab==='rooms'&&row.status===3?'rejected':tab==='repairs'&&row.status===2?'processing':[0,4].includes(row.status)?'cancelled':'';
      headline.append(node('span',statusLabel,`status ${tone}`));
    }
    const subtitle=tab==='rooms'?`${row.name||'住户'} · ${row.mobile||'未留电话'}`:tab==='workers'?row.mobile:`${row.houseInfo||'房屋待确认'} · ${timeText(row.agreedTime||row.expectedTime)||row.appointment||'未预约'}`;
    copy.append(headline,node('span',subtitle,'request-subtitle'));
    if(tab==='repairs'&&(row.todo||[]).length) {
      const tags=node('span',null,'todo-tags');
      for(const tag of row.todo) tags.append(node('span',tag,'todo-tag'));
      copy.append(tags);
    }
    const meta=node('span',null,'request-meta');
    if(tab==='repairs') meta.append(node('span',row.workerName||([0,4].includes(row.status)?'已取消':'待派单')));
    else if(tab==='workers') meta.append(node('span','维修师傅'));
    else meta.append(node('span',roomStatus[row.status]||'待审核'));
    item.append(icon,copy,meta,node('span','›','row-chevron'));
    list.append(item);
  }
  root.append(list);
  renderDetail(filtered.find(row=>row.id===selectedId)||null);
}
function timeText(value) {
  if(!value) return '';
  const date=new Date(value);
  return Number.isNaN(date.getTime())?String(value):date.toLocaleString('zh-CN',{month:'numeric',day:'numeric',weekday:'short',hour:'2-digit',minute:'2-digit'});
}
function repairProgress(record) {
  const list=node('ol',null,'progress');
  list.setAttribute('aria-label','报修进度');
  const active={1:1,5:2,2:3,6:4,3:5}[record.status];
  ['住户申请','物业派单','待接单','处理中','待确认','已完成'].forEach((label,index)=>{
    const item=node('li',label,index<active?'complete':index===active?'current':'');
    if(index===active) item.setAttribute('aria-current','step');
    list.append(item);
  });
  return list;
}
function photo(url) {
  try {
    const parsed=new URL(url);
    if(!['http:','https:'].includes(parsed.protocol)) return null;
    const link=node('a'); link.href=parsed.href; link.target='_blank'; link.rel='noopener noreferrer';
    const img=node('img'); img.src=parsed.href; img.alt='报修或房屋资料照片，点击查看原图'; link.append(img);
    return link;
  } catch { return null; }
}
function field(root,label,value) {
  const row=node('div',null,'detail-row');
  row.append(node('span',label),node('span',value||'—'));
  root.append(row);
}
function renderDetail(record) {
  const root=$('detail-panel');
  root.replaceChildren();
  if(tab==='workers') {
    const heading=node('div',null,'detail-heading');
    heading.append(node('span','维修人员 / 接单团队','eyebrow'),node('h2','师傅名册'));
    root.append(heading);
    if(record) {
      field(root,'师傅姓名',record.nickName);
      field(root,'联系电话',record.mobile);
    }
    const note=node('div',null,'detail-guidance');
    note.append(node('strong',`${rows.length} 位维修师傅`),node('p','新增的师傅账号可以登录工作台接收派单。物业派单后，师傅点击“接单”就会进入处理中。'));
    root.append(note);
    return;
  }
  if(!record) {
    root.append(emptyState('请选择一条记录','从左侧列表选择，查看资料和下一步操作。'));
    return;
  }
  const heading=node('div',null,'detail-heading');
  heading.append(node('span',tab==='repairs'?'报修工单 / 记录详情':'住户资料 / 审核详情','eyebrow'));
  const title=tab==='rooms'?[record.point,record.building,record.room].filter(Boolean).join(' '):record.repairItemName;
  heading.append(node('h2',title||pages[tab].title));
  if(tab!=='workers') {
    const status=(tab==='rooms'?roomStatus:repairStatus)[record.status]||'状态未知';
    const tone=(tab==='rooms'?record.status===2:record.status===3)?'done':tab==='rooms'&&record.status===3?'rejected':tab==='repairs'&&record.status===2?'processing':[0,4].includes(record.status)?'cancelled':'';
    heading.append(node('span',status,`status ${tone}`));
  }
  root.append(heading);
  if(tab==='repairs') root.append(repairProgress(record));
  if(tab==='rooms') {
    for(const [label,value] of [['房屋',[record.point,record.building,record.floor,record.room].filter(Boolean).join(' ')],['业主',record.name],['联系电话',record.mobile],['审核状态',roomStatus[record.status]],['打回原因',record.reviewReason]]) field(root,label,value);
  } else {
    const open=kind=>(record.pendings||[]).find(item=>item.kind===kind&&!item.resolvedAt);
    const reschedule=open('reschedule');
    for(const [label,value] of [
      ['房屋',record.houseInfo],['住户电话',record.mobile],['期望时间',timeText(record.expectedTime)||record.appointment],
      ['约定时间',timeText(record.agreedTime)||'未约定'],
      ['待回应改约',reschedule?`${reschedule.by==='resident'?'住户':'师傅'}提议改为 ${timeText(reschedule.proposedTime)}：${reschedule.reason}`:''],
      ['问题描述',record.description],['维修人员',record.workerName?`${record.workerName} · ${record.workerMobile||''}`:''],
      ['维修轮次',`第 ${record.round||1} 轮${record.reworkUsed?'（返修机会已用）':''}`],
      ['确认期限',timeText(record.confirmDeadline)],['售后期至',timeText(record.warrantyEnd)]
    ]) if(value) field(root,label,value);
    for(const round of record.rounds||[]) if(round.completedAt) field(root,`第${round.number}轮`,
      `${round.note}；上报费用 ${round.cost??0} 元${round.verifiedNote?`；物业核实：${round.verifiedNote}`:''}${round.rejectReason?`；未修好：${round.rejectReason}`:''}`);
  }
  const photos=node('div',null,'photos');
  for(const url of tab==='rooms'?[record.idcardFrontUrl,record.idcardBackUrl]:(record.attachment||[])) {
    const image=photo(url); if(image) photos.append(image);
  }
  if(photos.childElementCount) root.append(photos);
  const actionError=node('p'); actionError.setAttribute('role','alert'); root.append(actionError);
  let saving=false;
  async function mutate(button,path,body,method='PUT') {
    if(saving) return;
    saving=true;
    const generation=epoch;
    actionError.textContent='';
    const controls=[...root.querySelectorAll('button, select, textarea, input')];
    controls.forEach(control=>control.disabled=true);
    button.setAttribute('aria-busy','true');
    try {
      await api(path,method,body);
      if(generation!==epoch) return;
      await load(true);
    } catch(error) {
      if(generation===epoch) actionError.textContent=error.message;
    } finally {
      saving=false;
      controls.forEach(control=>control.disabled=false);
      button.removeAttribute('aria-busy');
    }
  }
  if(tab==='rooms'&&record.status===1) {
    const label=node('label','打回原因（打回时必填）'),reason=node('textarea');
    reason.maxLength=1000; reason.placeholder='请说明需要住户补充或修改的内容'; label.append(reason); root.append(label);
    const actions=node('div',null,'actions'),reject=node('button','打回'),approve=node('button','通过','primary');
    approve.onclick=()=>mutate(approve,`/management/rooms/${record.id}/review`,{revision:record.revision||0,decision:'approve'});
    reject.onclick=()=>{
      if(!reason.value.trim()) {actionError.textContent='请填写打回原因';reason.focus();return;}
      mutate(reject,`/management/rooms/${record.id}/review`,{revision:record.revision||0,decision:'reject',reason:reason.value.trim()});
    };
    actions.append(reject,approve); root.append(actions);
  }
  if(tab==='repairs') {
    if(Array.isArray(record.timeline)) {
      const history=node('ol',null,'history');
      for(const event of record.timeline) {
        const item=node('li',event.label+(event.detail?` · ${event.detail}`:''));
        item.append(node('small',new Date(event.at).toLocaleString('zh-CN')));
        history.append(item);
      }
      root.append(history);
    }
    const base=`/management/repairs/${record.id}`;
    const revision=record.revision||0;
    const open=kind=>(record.pendings||[]).find(item=>item.kind===kind&&!item.resolvedAt);
    const textBox=(labelText,placeholder)=>{
      const label=node('label',labelText),input=node('textarea');
      input.maxLength=500; input.placeholder=placeholder; label.append(input); root.append(label);
      return input;
    };
    const require=(input,text)=>{ if(input.value.trim()) return true; actionError.textContent=text; input.focus(); return false; };
    if(record.status===1||record.status===5) {
      const label=node('label','指派维修人员'),select=node('select');
      const option=node('option','请选择维修人员'); option.value=''; select.append(option);
      for(const worker of workers) {
        const item=node('option',`${worker.nickName} · ${worker.mobile}`);
        item.value=worker.id; select.append(item);
      }
      label.append(select); root.append(label);
      if(!workers.length) root.append(node('p','请先在“维修人员”中添加师傅。','detail-guidance'));
      const button=node('button',record.status===5||record.releasedAt?'重新派单':'确认派单','primary');
      button.disabled=!workers.length;
      button.onclick=()=>{
        if(!select.value) {actionError.textContent='请选择维修人员';return;}
        mutate(button,`${base}/assign`,{revision,workerId:select.value});
      };
      root.append(button);
    }
    const aftersale=open('aftersale');
    if(aftersale) {
      root.append(node('p',`住户申请售后返修：${aftersale.reason}`,'detail-guidance'));
      const reason=textBox('审核说明（拒绝时必填）','说明审核结果，拒绝时请写明原因');
      const actions=node('div',null,'actions'),reject=node('button','拒绝'),approve=node('button','通过，交回原师傅','primary');
      approve.onclick=()=>mutate(approve,`${base}/aftersale`,{revision,approve:true,reason:reason.value.trim()});
      reject.onclick=()=>{ if(require(reason,'拒绝售后申请必须填写原因')) mutate(reject,`${base}/aftersale`,{revision,approve:false,reason:reason.value.trim()}); };
      actions.append(reject,approve); root.append(actions);
    }
    const reschedule=open('reschedule');
    if(reschedule) {
      root.append(node('p','改约待对方回应。已与双方电话核实后，可代为确认或保持原约定。','detail-guidance'));
      const reason=textBox('跟进说明（保持原约定时必填）','例如：已电话联系师傅，同意下午上门');
      const actions=node('div',null,'actions'),decline=node('button','保持原约定'),accept=node('button','确认新时间','primary');
      accept.onclick=()=>mutate(accept,`${base}/reschedule`,{revision,accept:true,reason:reason.value.trim()});
      decline.onclick=()=>{ if(require(reason,'请填写跟进说明')) mutate(decline,`${base}/reschedule`,{revision,accept:false,reason:reason.value.trim()}); };
      actions.append(decline,accept); root.append(actions);
    }
    const feedback=open('feedback');
    const objection=(record.pendings||[]).find(item=>item.objection&&!item.reply);
    if(feedback) root.append(node('p',`住户反馈：${feedback.reason}`,'detail-guidance'));
    if(objection) root.append(node('p',`师傅对撤销有异议：${objection.objection}`,'detail-guidance'));
    // 回复反馈、处理异议、核实内容与费用、一般跟进：只追加记录，不改变工单状态。
    const label=node('label','物业记录'),target=node('select');
    for(const [value,text,show] of [['feedback','回复问题反馈',Boolean(feedback)],['objection','处理撤销异议',Boolean(objection)],
      ['verify','核实处理内容和费用',(record.rounds||[]).some(round=>round.completedAt)],['follow','跟进记录',true]]) {
      if(!show) continue;
      const item=node('option',text); item.value=value; target.append(item);
    }
    label.append(target); root.append(label);
    const content=textBox('记录内容','写明与住户、师傅核实或沟通的结果');
    const costLabel=node('label','核实费用（元，可不填）'),cost=node('input');
    cost.type='number'; cost.min='0'; cost.step='0.01'; costLabel.append(cost); root.append(costLabel);
    const syncCost=()=>{ costLabel.hidden=target.value!=='verify'; };
    target.onchange=syncCost; syncCost();
    const save=node('button','保存记录');
    save.onclick=()=>{
      if(!require(content,'请填写记录内容')) return;
      const body={revision,target:target.value,content:content.value.trim()};
      if(target.value==='verify'&&cost.value!=='') body.cost=Number(cost.value);
      mutate(save,`${base}/notes`,body,'POST');
    };
    const actions=node('div',null,'actions'); actions.append(save); root.append(actions);
  }
}
if(token) enter().catch(error=>{logout();message(error.message);});
