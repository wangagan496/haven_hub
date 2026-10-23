'use strict';
const $ = id => document.getElementById(id);
let token = sessionStorage.getItem('haven-admin-token') || '';
let tab = 'rooms', rows = [], workers = [], loading = false, epoch = 0, selectedId = '';
let dataset = {rooms: [], repairs: [], workers: []};
let unregisteredCount = 0;
let queueRows = [], shiftDate = '', capacityDate = '', capacityData = null, weekdayData = {};
let pushChanging = false, pushGeneration = 0, pushDisabling = null;
const roomStatus = {1:'待审核',2:'已通过',3:'已打回'};
const repairStatus = {0:'已取消',1:'待派单',2:'处理中',3:'已完成',4:'已取消',5:'待接单',6:'待住户确认'};
// 各列表保持服务端顺序；待安排队列单独来自 repair-queue。
const TODO='todo';
const QUEUE='queue';
const WEEKDAY_NAMES=['周一','周二','周三','周四','周五','周六','周日'];
const isRepairTab=()=>tab==='repairs'||tab==='shifts';
const pages = {
  rooms: {title:'房屋审核',description:'查看住户提交的房屋资料，及时完成审核。',list:'房屋资料',search:'搜索房屋、业主或手机号'},
  repairs: {title:'报修管理',description:'安排合适的维修师傅，跟进每一条报修记录。',list:'报修记录',search:'搜索维修项目、房屋或师傅'},
  workers: {title:'维修人员',description:'管理师傅联系方式，为社区报修安排维修人员。',list:'维修人员名册',search:'搜索师傅姓名或手机号'},
  shifts: {title:'顺延建议',description:'系统只给建议，不会自动挪单。请核实后选择更晚的可选时段。',list:'顺延候选',search:'搜索维修项目、房屋或师傅'},
  capacities: {title:'容量设置',description:'本日覆盖 > 星期模板 > 默认。0 表示该时段不再接受普通预约。',list:'预约容量',search:''}
};
function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text != null) element.textContent = String(text);
  if (className) element.className = className;
  return element;
}
function message(text='') { $('message').textContent=text; }
function logout() {
  void disablePush().catch(() => {});
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
  unregisteredCount=0;
  dataset={rooms:[],repairs:[],workers:[]};
  queueRows=[]; capacityData=null; weekdayData={}; shiftDate=''; capacityDate='';
  $('notification-list').replaceChildren();
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
  if(!response.ok||data.code!==10000) {
    const error=Error(data.message||'操作失败，请重试'); error.status=response.status; throw error;
  }
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
  try { await loadNotifications(); }
  catch (error) { if (generation === epoch) message(error.message); }
  void enablePush(true).catch(() => {});
  const notificationId = new URL(location.href).searchParams.get('notification');
  if (notificationId && /^[a-f0-9-]{36}$/.test(notificationId)) {
    try { await openNotification(notificationId); }
    catch (error) { if (generation === epoch) message(error.message); }
  }
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
  const special=tab==='capacities'||tab==='shifts';
  $('filter-label').hidden=tab==='workers'||special;
  $('quick-filters').hidden=tab==='workers'||special;
  document.querySelector('.toolbar').hidden=tab==='capacities';
  document.querySelector('.desk-grid').classList.toggle('capacity-layout',tab==='capacities');
  $('detail-panel').hidden=tab==='capacities';
  $('filter').replaceChildren();
  $('filter').value='';
  $('quick-filters').replaceChildren();
  const states=tab==='rooms'?roomStatus:repairStatus;
  const entries=Object.entries(states).filter(([key])=>key!=='4');
  for(const [value,label] of tab==='repairs'?[[TODO,'待办'],[QUEUE,'待安排'],['unrated','未定级'],['','全部'],...entries]:[['','全部'],...entries]) {
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
    const extra=tab==='capacities'
      ? Promise.all([api('/management/repair-capacities'+(capacityDate?`?date=${encodeURIComponent(capacityDate)}`:'')),api('/management/repair-capacities/weekdays')])
      : tab==='shifts'?api('/management/repair-shift-suggestions'+(shiftDate?`?date=${encodeURIComponent(shiftDate)}`:''))
      : tab==='repairs'?api('/management/repair-queue'):Promise.resolve([]);
    const results=await Promise.all([...['rooms','repairs','workers'].map(name=>api(`/management/${name}`)),extra,api('/management/workforce-summary')]);
    if(generation!==epoch) return;
    dataset={rooms:results[0],repairs:results[1],workers:results[2]};
    unregisteredCount=results[4].unregisteredCount;
    if(tab==='capacities') [capacityData,weekdayData]=results[3];
    if(tab==='repairs') queueRows=results[3];
    rows=tab==='shifts'?results[3]:dataset[tab]||[]; workers=dataset.workers;
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
  if(tab==='capacities') { $('stats').replaceChildren(); return; }
  const count=status=>rows.filter(row=>row.status===status).length;
  let cards;
  if(tab==='rooms') cards=[
    ['待审核',count(1),'等待物业处理','1'],
    ['已通过',count(2),'房屋资料已确认','2'],
    ['已打回',count(3),'等待住户修改','3'],
    ['全部房屋',rows.length,'当前提交的房屋资料','']
  ];
  else if(isRepairTab()) cards=[
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

const skillNames={plumbing:'水暖',electrical:'电气',doors:'门窗五金'};
function workforceTime(item) {
  return item.start&&item.end?`${item.start.slice(5,10)} ${item.start.slice(11,16)}–${item.end.slice(11,16)}`:'待定';
}
async function previewWorkforce(path,method,body) {
  const generation=epoch;
  const impact=await api(path,method,{...body,preview:true});
  if(generation!==epoch)return false;
  const list=items=>items.length?items.map(item=>`${item.repairItemName} · ${workforceTime(item)}`).join('\n'):'无';
  const shortages=(impact.shortages||[]).map(item=>`${item.message}\n${list(item.orders)}`).join('\n\n')||'无';
  return window.confirm(`会放回可接单列表：\n${list(impact.returned)}\n\n需要物业处理：\n${list(impact.property)}\n\n时段缺人提示：\n${shortages}\n\n确认保存？`);
}
function workerAvailabilityForm(record) {
  const root=node('section',null,'schedule-section');
  root.append(node('h3','技能与休假'),node('p','技能由师傅自行登记，物业未核实，不代表资质认证','muted'));
  if(record.skillChange)root.append(node('p',`最近修改：${record.skillChange.actorName} · ${timeText(record.skillChange.changedAt)}`,'muted'));
  for(const [id,name] of Object.entries(skillNames)) {
    const registered=(record.skills||[]).includes(id),label=node('div',`${name}：${registered?'已登记':'未登记'}`);
    if(registered){const revoke=node('button','撤销','quiet');revoke.onclick=()=>guarded(revoke,async()=>{
      const path='/management/workers/'+encodeURIComponent(record.id)+'/skills';
      const body={workforceRevision:record.revision,skills:record.skills.filter(skill=>skill!==id)};
      if(!await previewWorkforce(path,'PUT',body))return;
      await api(path,'PUT',body);await load();
    });label.append(revoke);}root.append(label);
  }
  const date=labeledInput(root,'休假日期（北京时间）','date'),hour=node('select');
  for(const [value,label] of [['','整天'],...[8,9,10,11,14,15,16,17,19,20,21].map(n=>[String(n).padStart(2,'0'),`${n}:00–${n+1}:00`])]) {
    const option=node('option',label);option.value=value;hour.append(option);
  }
  const hourLabel=node('label','休假时段');hourLabel.append(hour);root.append(hourLabel);
  const reason=labeledInput(root,'休假备注（仅物业可见）','text');reason.maxLength=1000;
  const add=node('button','登记休假','primary');add.onclick=()=>guarded(add,async()=>{
    if(!date.value)throw new Error('请选择休假日期');
    const path='/management/workers/'+encodeURIComponent(record.id)+'/leave';
    const body={revision:record.revision,date:date.value,hour:hour.value,reason:reason.value.trim()};
    if(!await previewWorkforce(path,'POST',body))return;
    await api(path,'POST',body);
    await load();
  });root.append(add);
  for(const leave of record.leaves||[]) {
    const row=node('div',null,'detail-guidance');row.append(node('span',`${leave.date} ${leave.hour?leave.hour+':00–'+(Number(leave.hour)+1)+':00':'整天'} ${leave.reason||''}`));
    const remove=node('button','撤销休假','quiet');remove.onclick=()=>guarded(remove,async()=>{
      await api('/management/workers/'+encodeURIComponent(record.id)+'/leave','DELETE',{revision:record.revision,date:leave.date,hour:leave.hour});await load();
    });row.append(remove);root.append(row);
  }
  return root;
}
function renderQuickFilters() {
  document.querySelectorAll('#quick-filters button').forEach(button=>{
    button.setAttribute('aria-pressed',String(button.dataset.status===$('filter').value));
  });
}
function render() {
  if(tab==='capacities') { renderCapacities(); return; }
  const root=$('content');
  const existingForm=root.querySelector('.worker-form');
  root.replaceChildren();
  if(unregisteredCount>0&&(tab==='workers'||(tab==='repairs'&&$('filter').value===QUEUE))) {
    root.append(node('p',`${unregisteredCount} 位师傅尚未登记技能`,'schedule-section'));
  }
  if(tab==='workers') root.append(existingForm||workerForm());
  if(isRepairTab()) {
    for(const record of dataset.repairs) {
      const shortage=record.poolShortage;
      if(!shortage)continue;
      const notice=node('section',null,'schedule-section pool-shortage');
      notice.append(node('h3','可接单时段缺人'),node('p',shortage.message));
      for(const order of shortage.orders) {
        const open=node('button',`${order.repairItemName} · ${workforceTime(order)}`,'quiet');
        open.onclick=()=>{setTab('repairs');rows=dataset.repairs;selectedId=order.id;renderQuickFilters();renderStats();render();};
        notice.append(open);
      }
      root.append(notice);
    }
  }
  if(tab==='shifts') {
    const controls=node('div',null,'schedule-section');
    const date=node('input'); date.type='date'; date.value=shiftDate; date.setAttribute('aria-label','顺延建议日期');
    const search=node('button','查询顺延建议');
    search.onclick=()=>guarded(search,async()=>{shiftDate=date.value;await load(true);});
    controls.append(date,search,node('p','系统只给建议，不会自动挪单。留空查询全部候选。','muted'));root.append(controls);
  }
  const query=$('search').value.trim().toLowerCase();
  const selected=$('filter').value;
  const source=tab==='repairs'&&selected===QUEUE?queueRows:rows;
  const filtered=source.filter(row=>{
    const status=tab==='repairs'&&row.status===4?0:row.status;
    const matchesStatus=tab==='workers'||tab==='shifts'||!selected||selected===QUEUE||(selected==='unrated'?row.priorityPending:selected===TODO?(row.todo||[]).length>0:String(status)===selected);
    const text=[row.point,row.building,row.room,row.name,row.mobile,row.nickName,row.repairItemName,row.houseInfo,row.workerName,...(row.todo||[])].filter(Boolean).join(' ').toLowerCase();
    return matchesStatus&&(!query||text.includes(query));
  });
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
    if(isRepairTab()) {
      const tags=node('span',null,'schedule-tags');
      const priority={urgent:'急',medium:'中',light:'轻'}[row.priority];
      for(const text of [priority,row.priorityPending?'未定级':'',row.urgentRequest?'紧急诉求':'',...(row.preferenceTags||[]),
        row.shiftCount>0?`已顺延 ${row.shiftCount} 次`:'',row.autoAccepted?'超时生效':'']) {
        if(text) tags.append(node('span',text,'schedule-tag'+(text==='急'?' urgent':'')));
      }
      copy.append(tags);
      if(tab==='shifts'&&!row.canShift) copy.append(node('span',row.shiftReason,'shift-reason'));
    }
    if(isRepairTab()&&(row.todo||[]).length) {
      const tags=node('span',null,'todo-tags');
      for(const tag of row.todo) tags.append(node('span',tag,'todo-tag'));
      copy.append(tags);
    }
    const meta=node('span',null,'request-meta');
    if(isRepairTab()) meta.append(node('span',row.inRepairPool?`可接单 · ${row.eligibleWorkerCount} 位师傅可接`:row.workerName||([0,4].includes(row.status)?'已取消':'待派单')));
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
  return Number.isNaN(date.getTime())?String(value):date.toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',month:'numeric',day:'numeric',weekday:'short',hour:'2-digit',minute:'2-digit'});
}
function windowText(window) {
  if(!window?.start||!window?.end)return '';
  const end=new Date(window.end);
  return timeText(window.start)+'–'+end.toLocaleTimeString('zh-CN',{timeZone:'Asia/Shanghai',hour:'2-digit',minute:'2-digit'});
}
function slotText(slot) {
  // 仅格式化服务端时段编码，不用于判断可预约性。历史 agreedTime 使用 timeText。
  return typeof slot==='string'&&/^\d{4}-\d{2}-\d{2}#\d{2}$/.test(slot)?slot.replace('#',' ') + ':00':'';
}
function labeledInput(root,text,tag) {
  const label=node('label',text),input=node(['text','date'].includes(tag)?'input':tag);
  if(['text','date'].includes(tag))input.type=tag;
  label.append(input);root.append(label);return input;
}
function slotPicker(record,shift=false) {
  const element=node('div',null,'slot-picker');
  const date=labeledInput(element,'预约日期','select');date.disabled=true;
  const slots=labeledInput(element,shift?'更晚的可选时段':'可选时段','select');slots.disabled=true;
  const status=node('p','请查询服务端可选时段。','muted'),retry=node('button','查询可选时段');
  element.append(status,retry);
  const generation=epoch;let sequence=0;
  async function query() {
    const request=++sequence;const selected=date.value;
    date.disabled=true;slots.disabled=true;slots.replaceChildren();status.textContent='正在查询…';
    try {
      const data=await api('/repair/slots?excludeId='+encodeURIComponent(record.id)+(selected?'&date='+encodeURIComponent(selected):''));
      if(generation!==epoch||request!==sequence||!element.isConnected)return;
      date.replaceChildren(...data.dates.map(value=>{const option=node('option',value+(value===data.today?'（今天）':''));option.value=value;return option;}));
      date.value=data.date;
      const available=data.slots.filter(slot=>shift?slot.shiftSelectable:slot.selectable);
      const placeholder=node('option','请选择时段');placeholder.value='';slots.append(placeholder);
      for(const period of [...new Set(available.map(slot=>slot.period))]) {
        const group=node('optgroup');group.label={morning:'上午',afternoon:'下午',evening:'晚上'}[period]||period;
        for(const slot of available.filter(slot=>slot.period===period)) {const option=node('option',windowText(slot));option.value=slot.slot;group.append(option);}
        slots.append(group);
      }
      slots.disabled=!available.length;status.textContent=available.length?'以服务端最新可选时段为准。':'没有可选时段，可选择其他日期。';
    } catch(error) {if(generation===epoch&&request===sequence&&element.isConnected)status.textContent=error.message+'，请重试';}
    finally {if(generation===epoch&&request===sequence)date.disabled=!date.options.length;}
  }
  retry.onclick=()=>guarded(retry,query);date.onchange=()=>guarded(retry,query);
  return {element,value:()=>slots.disabled?'':slots.value};
}
function dispatchPanel(record,mutate) {
  const section=node('section',null,'schedule-section');section.append(node('h3','急单调度'));
  section.append(node('p','急单可超出公开预约容量，但仍须满足技能、休假和全部预约的人手约束。未派单预约也计入；休假冲突保留原预约，改时间须走确认流程。','detail-guidance'));
  const list=node('div'),fetchOptions=node('button','查询空闲师傅'),reason=labeledInput(section,'调度原因（选填）','textarea');reason.maxLength=1000;
  section.append(fetchOptions,list);const generation=epoch;
  fetchOptions.onclick=()=>guarded(fetchOptions,async()=>{
    list.replaceChildren(node('p','正在查询空闲师傅…','muted'));
    try {
      const data=await api(`/management/repairs/${record.id}/dispatch-options`);
      if(generation!==epoch||!section.isConnected)return;
      list.replaceChildren();
      for(const slot of data.slots) {
        const group=node('div',null,'dispatch-slot');group.append(node('strong',windowText(slot)+(slot.current?'（当前时段）':'')));
        group.append(node('p',`公开容量 ${slot.publicCapacity} · 其他订单 ${slot.occupied}（未派师傅 ${slot.unassigned}） · 未休假师傅 ${slot.workerCount} · 可调度 ${slot.workers.length}`,'muted'));
        if(!slot.dispatchable)group.append(node('p',slot.reason||'请刷新调度选项后重试','shift-reason'));
        else {
          const workers=labeledInput(group,'空闲师傅','select');
          const placeholder=node('option','请选择师傅');placeholder.value='';workers.append(placeholder);
          for(const worker of slot.workers) {const option=node('option',`${worker.nickName} · ${worker.mobile}`);option.value=worker.id;workers.append(option);}
          const send=node('button',record.workerId?'改派/重新调度':'确认急单调度','primary');
          send.onclick=()=>{if(!workers.value){message('请选择空闲师傅');return;}mutate(send,`/management/repairs/${record.id}/dispatch`,{revision:record.revision,slot:slot.slot,workerId:workers.value,reason:reason.value.trim()});};
          group.append(send);
        }
        list.append(group);
      }
      const shift=node('button','查看顺延建议');shift.onclick=()=>{if(loading)return;setTab('shifts');void load();};list.append(shift);
    } catch(error) {if(generation===epoch&&section.isConnected)list.replaceChildren(node('p',error.message+'，请重新查询','shift-reason'));}
  });return section;
}
function renderCapacities() {
  const root=$('content');root.replaceChildren();$('result-count').textContent='';
  if(!capacityData)return;
  const generation=epoch,values=capacityData;let saving=false;
  const hours=Object.keys(values.defaults).sort();
  const feedback=node('p');feedback.setAttribute('role','alert');
  root.append(node('p','优先级：本日覆盖 > 星期模板 > 默认。0 表示该时段不再接受普通预约。参考 500：参考值，不是上限。','detail-guidance'),feedback);
  async function save(button,path,body,method='PUT') {
    if(saving||loading||button.disabled)return;saving=true;
    const controls=[...root.querySelectorAll('button,input,select')].map(control=>[control,control.disabled]);
    await guarded(button,async()=>{
      controls.forEach(([control])=>control.disabled=true);
      try {await api(path,method,body);if(generation===epoch)await load(true);}
      finally {controls.forEach(([control,disabled])=>control.disabled=disabled);}
    });saving=false;
  }
  function read(inputs) {
    const capacities={};
    for(const [hour,input] of Object.entries(inputs)) {
      if(input.value==='')continue;
      if(!/^\d+$/.test(input.value)||!input.reportValidity()){feedback.textContent='容量只允许 0 及以上的整数';return null;}
      capacities[hour]=Number(input.value);
    }
    if(!Object.keys(capacities).length){feedback.textContent='请至少填写一个时段，清空整天请使用清空按钮';return null;}
    return {capacities};
  }
  function input(hour,value,placeholder,context) {
    const cell=node('input');cell.type='number';cell.min='0';cell.step='1';cell.value=value??'';
    cell.placeholder=String(placeholder);cell.setAttribute('aria-label',`${context} ${hour}:00`);return cell;
  }
  const defaults=node('section',null,'schedule-section');defaults.append(node('h3','默认容量'));
  const defaultInputs={},grid=node('div',null,'capacity-grid');
  for(const hour of hours){const label=node('label',hour+':00');const cell=input(hour,values.defaults[hour],values.defaults[hour],'默认容量');defaultInputs[hour]=cell;label.append(cell);grid.append(label);}
  const saveDefaults=node('button','保存默认容量','primary');saveDefaults.onclick=()=>{const body=read(defaultInputs);if(body)save(saveDefaults,'/management/repair-capacities',body);};
  defaults.append(grid,saveDefaults);root.append(defaults);
  const weekdays=node('section',null,'schedule-section');weekdays.append(node('h3','星期模板'),node('p','空格沿用默认容量，灰色占位为默认值。保存为部分更新；要移除已设值，请先按天清空。','muted'));
  const scroller=node('div',null,'capacity-scroll'),table=node('table',null,'capacity-table');const head=node('tr');
  for(const text of ['星期',...hours.map(hour=>hour+':00'),'操作'])head.append(node('th',text));const thead=node('thead');thead.append(head);table.append(thead);
  const tbody=node('tbody');
  for(const [day,template] of Object.entries(weekdayData)) {
    const name=WEEKDAY_NAMES[Number(day)-1],row=node('tr'),inputs={};row.append(node('th',name));
    for(const hour of hours){const cell=node('td'),box=input(hour,template[hour],values.defaults[hour],name+'模板');inputs[hour]=box;cell.append(box);row.append(cell);}
    const actions=node('td'),put=node('button','保存'),clear=node('button','清空');
    put.setAttribute('aria-label','保存'+name+'模板');clear.setAttribute('aria-label','清空'+name+'模板');
    put.onclick=()=>{const body=read(inputs);if(body)save(put,`/management/repair-capacities/weekdays/${day}`,body);};
    clear.onclick=()=>save(clear,`/management/repair-capacities/weekdays/${day}`,undefined,'DELETE');
    actions.append(put,clear);row.append(actions);tbody.append(row);
  }table.append(tbody);scroller.append(table);weekdays.append(scroller);root.append(weekdays);
  const day=node('section',null,'schedule-section');day.append(node('h3','单日覆盖'));
  const date=labeledInput(day,'容量日期','input');date.type='date';date.value=capacityDate;
  const query=node('button','查看日期容量');query.onclick=()=>guarded(query,async()=>{capacityDate=date.value;await load(true);});day.append(query);
  if(capacityDate) {
    const inputs={},grid=node('div',null,'capacity-grid');
    for(const hour of hours){
      const source=values.sources[hour];const origin=source==='date'?'本日覆盖':source==='weekday'?WEEKDAY_NAMES[values.weekday-1]+'模板':'默认';
      const label=node('label',hour+':00'),box=input(hour,values.overrides[hour],values.effective[hour],'单日覆盖');inputs[hour]=box;
      label.append(box,node('small',`${origin} · 生效 ${values.effective[hour]}`));grid.append(label);
    }
    const put=node('button','保存单日覆盖','primary'),clear=node('button','删除单日覆盖，恢复模板/默认');
    put.onclick=()=>{const body=read(inputs);if(body)save(put,`/management/repair-capacities/${capacityDate}`,body);};
    clear.onclick=()=>save(clear,`/management/repair-capacities/${capacityDate}`,undefined,'DELETE');day.append(grid,put,clear);
  }
  day.append(node('p',`默认合计 ${values.defaultTotal} · ${capacityDate?'当日':'默认'}生效合计 ${values.effectiveTotal} · 维修人员 ${values.workerCount} 人`,'detail-guidance'));
  for(const warning of values.warnings)day.append(node('p',warning.message,'muted'));root.append(day);
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
      root.append(workerAvailabilityForm(record));
    }
    const note=node('div',null,'detail-guidance');
    note.append(node('strong',`${rows.length} 位维修师傅`),node('p','新增和历史师傅都需要物业核实并登记技能，才能匹配派单。物业派单后，师傅点击“接单”进入处理中。'));
    root.append(note);
    return;
  }
  if(!record) {
    root.append(emptyState('请选择一条记录','从左侧列表选择，查看资料和下一步操作。'));
    return;
  }
  const heading=node('div',null,'detail-heading');
  heading.append(node('span',isRepairTab()?'报修工单 / 记录详情':'住户资料 / 审核详情','eyebrow'));
  const title=tab==='rooms'?[record.point,record.building,record.room].filter(Boolean).join(' '):record.repairItemName;
  heading.append(node('h2',title||pages[tab].title));
  if(isRepairTab()) {
    const remind=node('button','提醒对方处理待办','quiet');
    remind.onclick=()=>guarded(remind,async()=>{
      await api('/notifications/repairs/'+encodeURIComponent(record.id)+'/remind','POST');
      message('已加入提醒队列，实际送达以系统通知为准。');
    });
    heading.append(remind);
  }
  if(tab!=='workers') {
    const status=(tab==='rooms'?roomStatus:repairStatus)[record.status]||'状态未知';
    const tone=(tab==='rooms'?record.status===2:record.status===3)?'done':tab==='rooms'&&record.status===3?'rejected':tab==='repairs'&&record.status===2?'processing':[0,4].includes(record.status)?'cancelled':'';
    heading.append(node('span',status,`status ${tone}`));
  }
  root.append(heading);
  if(isRepairTab()) {
    if(record.needsAdmin) root.append(node('p','师傅请求物业协助','detail-guidance urgent'));
    root.append(repairProgress(record));
  }
  if(tab==='rooms') {
    for(const [label,value] of [['房屋',[record.point,record.building,record.floor,record.room].filter(Boolean).join(' ')],['业主',record.name],['联系电话',record.mobile],['审核状态',roomStatus[record.status]],['打回原因',record.reviewReason]]) field(root,label,value);
  } else {
    const open=kind=>(record.pendings||[]).find(item=>item.kind===kind&&!item.resolvedAt);
    const reschedule=open('reschedule');
    for(const [label,value] of [
      ['房屋',record.houseInfo],['住户电话',record.mobile],['期望时间',timeText(record.expectedTime)||record.appointment],
      ['约定时间',timeText(record.agreedTime)||'未约定'],
      ['当前时段',windowText(record.slotWindow)],['最初期望时段',slotText(record.expectedSlot)],
      ['顺延次数',String(record.shiftCount||0)],
      ['待回应改约',reschedule?`${{resident:'住户',worker:'师傅',admin:'物业'}[reschedule.by]||'对方'}提议 ${slotText(reschedule.proposedSlot)||timeText(reschedule.proposedTime)}${reschedule.reason?`：${reschedule.reason}`:''}`:''],
      ['问题描述',record.description],['维修人员',record.workerName?`${record.workerName} · ${record.workerMobile||''}`:''],
      ['维修轮次',`第 ${record.round||1} 轮${record.reworkUsed?'（重新排查）':''}`],
      ['确认期限',timeText(record.confirmDeadline)],['售后期至',timeText(record.warrantyEnd)]
    ]) if(value) field(root,label,value);
    for(const round of record.rounds||[]) if(round.number === record.round) field(root,`第${round.number}轮`,
      `${round.note}；上报费用 ${round.cost??0} 元${round.verifiedNote?`；物业核实：${round.verifiedNote}`:''}${round.rejectReason?`；未修好：${round.rejectReason}`:''}`);
    for(const round of record.rounds||[]) if(round.number === record.round) field(root,'本次排查',`问题：${round.problem||record.description||''}；原因：${round.cause||'待排查'}`);
    for(const fee of record.fees||[]) field(root,`第${fee.number}轮费用`,`${fee.cost} 元；${fee.verifiedNote||'待核实'}`);
  }
  const photos=node('div',null,'photos');
  for(const url of tab==='rooms'?[record.idcardFrontUrl,record.idcardBackUrl]:(record.attachment||[])) {
    const image=photo(url); if(image) photos.append(image);
  }
  if(photos.childElementCount) root.append(photos);
  const actionError=node('p'); actionError.setAttribute('role','alert'); root.append(actionError);
  let saving=false;
  async function mutate(button,path,body,method='PUT') {
    if(saving||loading||button.disabled) return;
    if(root.querySelector('[aria-busy="true"]')) { actionError.textContent='正在查询可选安排，请稍后提交'; return; }
    saving=true;
    const generation=epoch;
    actionError.textContent='';
    const controls=[...root.querySelectorAll('button, select, textarea, input')].map(control=>[control,control.disabled]);
    controls.forEach(([control])=>control.disabled=true);
    button.setAttribute('aria-busy','true');
    try {
      await api(path,method,body);
      if(generation!==epoch) return;
      await load(true);
      if(generation===epoch) await loadNotifications();
    } catch(error) {
      if(generation!==epoch) return;
      if(error.status===409) {
        await load(true);
        if(generation===epoch) message(error.message+'；已刷新最新状态');
      } else actionError.textContent=error.message;
    } finally {
      saving=false;
      controls.forEach(([control,disabled])=>control.disabled=disabled);
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
  if(isRepairTab()) {
    if(Array.isArray(record.timeline)) {
      const history=node('ol',null,'history');
      for(const event of record.timeline) {
        const item=node('li',event.label+(event.detail?` · ${event.detail}`:''));
        if(event.previousWorkerId) item.append(node('small',`原师傅：${(workers.find(worker=>worker.id===event.previousWorkerId)||{}).nickName||event.previousWorkerId}`));
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
    const active=[1,5,2].includes(record.status);
    const offer=record.rescheduleOffer&&!record.rescheduleOffer.resolvedAt?record.rescheduleOffer:null;
    if(offer) root.append(node('p',`等待住户改选时间（截止 ${timeText(offer.deadline)}）`,'detail-guidance'));
    if(!offer&&record.inRepairPool&&record.slot&&record.eligibleWorkerCount===0) {
      const section=node('section',null,'schedule-section');
      section.append(node('h3','可用的备选时间'));
      if(!offer) section.append(node('p','住户未改时间，请电话联系'));
      const list=node('div'),errorLine=node('p');errorLine.setAttribute('role','alert');
      const notified=labeledInput(section,'已电话告知住户','input');notified.type='checkbox';
      section.append(list,errorLine);root.append(section);
      const generation=epoch;
      let currentRevision=revision,request=0;
      async function refreshOptions() {
        const sequence=++request;
        list.replaceChildren(node('p','正在查询备选时间…'));
        try {
          const data=await api(`${base}/unstaffed-options`);
          if(generation!==epoch||!section.isConnected||sequence!==request)return;
          currentRevision=data.revision;list.replaceChildren();
          if(!data.slots.length)list.append(node('p','暂无可选时段，请协调人手后刷新'));
          for(const slot of data.slots) {
            const item=node('div');item.append(node('p',`${windowText(slot)} · ${slot.eligibleWorkerCount} 位师傅可接`));
            const button=node('button','已电话告知住户，改到这个时间');item.append(button);list.append(item);
            button.onclick=async()=>{
              if(saving||loading)return;
              if(!notified.checked){errorLine.textContent='请先勾选已电话告知住户';return;}
              saving=true;errorLine.textContent='';
              list.querySelectorAll('button').forEach(control=>control.disabled=true);
              try {
                await api(`${base}/unstaffed-reschedule`,'PUT',{revision:currentRevision,slot:slot.slot,notified:true});
                if(generation!==epoch||!section.isConnected)return;
                await load(true);if(generation===epoch)await loadNotifications();
              } catch(error) {
                if(generation!==epoch||!section.isConnected)return;
                errorLine.textContent=error.message;
                await refreshOptions();
              } finally {saving=false;}
            };
          }
        } catch(error) {if(generation===epoch&&section.isConnected)errorLine.textContent=error.message;}
      }
      void refreshOptions();
    }
    if(active) {
      const section=node('section',null,'schedule-section'); section.append(node('h3','工单定级'));
      const priority=labeledInput(section,'等级','select');
      for(const [value,text] of [['','请选择等级'],['urgent','急'],['medium','中'],['light','轻']]) {const option=node('option',text);option.value=value;priority.append(option);}
      priority.value=record.priority||'';
      const reason=labeledInput(section,'定级原因','textarea');reason.maxLength=500;
      const save=node('button','保存等级');
      save.onclick=()=>{if(!priority.value){actionError.textContent='请选择等级';return;}if(require(reason,'请填写定级原因'))mutate(save,`${base}/priority`,{revision,priority:priority.value,reason:reason.value.trim()});};
      section.append(save);root.append(section);
      if(!record.slot&&!record.agreedTime) {
        const proposal=node('section',null,'schedule-section'); proposal.append(node('h3','首次上门时间提议'),node('p','住户同意或超时后才生效。','muted'));
        const picker=slotPicker(record);proposal.append(picker.element);
        const reason=labeledInput(proposal,'提议原因','textarea');reason.maxLength=500;
        const notified=labeledInput(proposal,'已电话告知住户','input');notified.type='checkbox';
        const send=node('button','发送首次提议','primary');
        send.onclick=()=>{
          if(!picker.value()){actionError.textContent='请选择可用时段';return;}
          if(!require(reason,'请填写提议原因'))return;
          if(!notified.checked){actionError.textContent='请先电话告知住户并勾选确认';return;}
          mutate(send,`${base}/reschedule`,{revision,slot:picker.value(),reason:reason.value.trim(),notified:true},'POST');
        };proposal.append(send);root.append(proposal);
      }
      if(record.priority==='urgent') root.append(dispatchPanel(record,mutate));
    }
    if(tab==='shifts') {
      const section=node('section',null,'schedule-section');section.append(node('h3','手动顺延'));
      const shift=node('button','确认顺延','primary');shift.disabled=!record.canShift;
      if(!record.canShift) section.append(node('p',record.shiftReason,'shift-reason'));
      else {
        const picker=slotPicker(record,true);section.append(picker.element);
        const reason=labeledInput(section,'顺延原因','textarea');reason.maxLength=500;
        shift.onclick=()=>{if(!picker.value()){actionError.textContent='请选择更晚的可用时段';return;}if(require(reason,'请填写顺延原因'))mutate(shift,`${base}/shift`,{revision,slot:picker.value(),reason:reason.value.trim()});};
      }
      section.append(shift);root.append(section);
    }
    if(record.staffingIssue&&!offer) root.append(node('p','待协调：'+record.staffingIssue+(record.inRepairPool&&record.slot&&record.eligibleWorkerCount===0
      ? '。原预约保留，可电话确认后选择备选时间。' : '。原预约保留，改时间请发起改约。'),'detail-guidance'));
    if([1,2,5].includes(record.status)&&['1001','1003'].includes(record.repairItemId)) {
      const section=node('section',null,'schedule-section'),select=node('select');section.append(node('h3','明确维修技能'));
      for(const [id,name] of Object.entries(skillNames)){const option=node('option',name);option.value=id;select.append(option);}
      if(record.requiredSkill)select.value=record.requiredSkill;
      const label=node('label','需要的技能');label.append(select);section.append(label);
      const reason=labeledInput(section,'分类依据','text');reason.maxLength=500;
      const save=node('button','确认技能','primary');save.onclick=()=>{if(require(reason,'请填写分类依据'))mutate(save,`${base}/skill`,{revision,skill:select.value,reason:reason.value.trim()});};section.append(save);root.append(section);
    }
    const revoke=open('revoke');
    if(revoke) root.append(node('p','住户已申请撤销，请先处理撤销申请','detail-guidance'));
    if(!revoke&&record.priority!=='urgent'&&[1,2,5].includes(record.status)) {
      const label=node('label','指派维修人员'),select=node('select');
      const option=node('option','请选择维修人员'); option.value=''; select.append(option);
      select.disabled=true;
      label.append(select); root.append(label);
      if(!workers.length) root.append(node('p','请先在“维修人员”中添加师傅。','detail-guidance'));
      const button=node('button',record.status===2||record.status===5||record.releasedAt?'重新派单':'确认派单','primary');
      button.disabled=true;
      api(`${base}/assignment-options`).then(options=>{
        if(!select.isConnected)return;
        for(const worker of options){
          const item=node('option',`${worker.nickName} · ${worker.mobile}${worker.reason?' · '+worker.reason:''}`);
          item.value=worker.id;item.disabled=!worker.selectable;select.append(item);
        }
        select.disabled=false;button.disabled=!options.some(worker=>worker.selectable);
      }).catch(error=>{if(select.isConnected)actionError.textContent=error.message||'师傅可用性查询失败，请刷新';});
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
    if(reschedule?.firstSchedule) {
      const pending=node('section',null,'schedule-section');pending.append(node('h3','等待住户确认'));
      field(pending,'提议时段',slotText(reschedule.proposedSlot)||timeText(reschedule.proposedTime));
      field(pending,'确认期限',timeText(reschedule.deadline));
      pending.append(node('p','住户同意或超时后才生效，物业不能代为确认。','muted'));root.append(pending);
    } else if(reschedule) {
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
      ['verify','核实处理内容和费用',(record.fees||[]).length>0||(record.rounds||[]).some(round=>round.completedAt)],['resolveNeedsAdmin','已处理协助请求',Boolean(record.needsAdmin)],['follow','跟进记录',true]]) {
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
      const body={revision,target:target.value==='resolveNeedsAdmin'?'follow':target.value,content:content.value.trim()};
      if(target.value==='resolveNeedsAdmin')body.resolveNeedsAdmin=true;
      if(target.value==='verify'&&cost.value!=='') body.cost=Number(cost.value);
      mutate(save,`${base}/notes`,body,'POST');
    };
    const actions=node('div',null,'actions'); actions.append(save); root.append(actions);
  }
}
async function pushCall(request) {
  if (!window.havenPush) throw Error('通知服务尚未加载，请刷新页面');
  const result = JSON.parse(await window.havenPush(JSON.stringify(request)));
  if (result.error) throw Error(result.error);
  return result;
}
async function enablePush(resume=false) {
  if (!token) return;
  if (pushChanging) {
    if (resume) return;
    throw Error('通知设置正在处理，请稍后再试');
  }
  pushChanging = true;
  const generation = epoch;
  const settingGeneration = pushGeneration;
  const cancelled = () => generation !== epoch || settingGeneration !== pushGeneration || !token;
  let registeredId = '';
  try {
  if (!resume) await pushCall({action:'requestPermission'});
  await pushDisabling;
  if (cancelled()) return;
  if (localStorage.getItem('haven-admin-push-revoke-pending')) {
    await disablePush();
    if (resume) return;
    throw Error('旧订阅已解绑，请再次开启系统通知');
  }
  if (!resume && localStorage.getItem('haven-admin-push-stale')) {
    // 上次平台解绑没成功：开启前尽力再清理一次，失败也继续。
    try { await pushCall({action:'disable'}); } catch { /* 服务端早已解绑。 */ }
    localStorage.removeItem('haven-admin-push-stale');
  }
  const config = await api('/notifications/config');
  if (cancelled()) return;
  const registration = await pushCall({action:resume?'resume':'enable', publicKey:config.webPublicKey, profileId:config.profileId});
  if (!registration.platform) return;
  if (cancelled()) { await pushCall({action:'disable'}); return; }
  registeredId = registration.installationId;
  localStorage.setItem('haven-admin-push-installation',registration.installationId);
  await api('/notifications/devices','POST',registration);
  if (cancelled()) throw Error('登录或通知设置已变化，请重试');
  // 登记已完成，后面待办加载失败不能回滚订阅。
  registeredId = '';
  if (!resume) message('设备已登记，实际送达请以系统通知为准。');
  await loadNotifications();
  } catch (error) {
    if (resume && !cancelled()) {
      // 同一会话的恢复失败（断网、超时）保留订阅，提示后下次进入页面再试。
      message('系统通知暂时无法恢复：'+(error.message||'请稍后重试')+'；待办仍保留。');
      throw error;
    }
    if (registeredId) {
      try { await pushDisabling; } catch { /* Retry after the previous cleanup. */ }
      localStorage.setItem('haven-admin-push-installation',registeredId);
      try { await disablePush(); } catch { /* Preserve the registration error. */ }
    }
    throw error;
  } finally { pushChanging = false; }
}
function disablePush() {
  pushGeneration++;
  return pushDisabling ||= revokePush().finally(() => { pushDisabling = null; });
}
// 与 App 一致：账号隔离以服务端解绑为准；浏览器订阅解绑失败只记为待清理，不阻塞再次开启。
async function revokePush() {
  const id = localStorage.getItem('haven-admin-push-installation');
  localStorage.setItem('haven-admin-push-revoke-pending','true');
  let platformDisabled = false;
  try { await pushCall({action:'disable'}); platformDisabled = true; } catch { /* 见下方 stale 标记。 */ }
  if (id) {
    let done = false;
    try {
      const response = await fetch('/notifications/unregister',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({installationId:id})});
      const result = await response.json();
      done = response.ok && result.code === 10000;
    } catch { /* 网络失败，保留 pending。 */ }
    if (!done) throw Error('服务端解绑未完成，请联网后重试');
    localStorage.removeItem('haven-admin-push-installation');
  }
  if (!platformDisabled) localStorage.setItem('haven-admin-push-stale','true');
  localStorage.removeItem('haven-admin-push-revoke-pending');
}
async function openNotification(id) {
  if (loading) { message('正在刷新数据，请稍后打开工单'); return; }
  const generation = epoch;
  const note = await api('/notifications/'+encodeURIComponent(id)+'/read','POST');
  if (generation !== epoch) return;
  if (loading) { message('正在刷新数据，请稍后打开工单'); return; }
  setTab('repairs');
  await load();
  if (generation !== epoch) return;
  $('filter').value='';
  selectedId=note.repairId;
  renderQuickFilters();renderStats();render();
  $('detail-panel').scrollIntoView({block:'start',behavior:'smooth'});
}
async function loadNotifications() {
  if (!token) return;
  const generation=epoch;
  const notes=await api('/notifications');
  if (generation!==epoch) return;
  const items=notes.filter(note=>note.active).map(note=>{
    const item=node('div',null,'panel-heading');
    const content=node('div');
    content.append(node('strong',note.title||note.body));
    if(note.title)content.append(node('p',note.body));
    const states=note.deliveries.map(d=>d.status==='accepted'?'推送服务已接收，送达未确认'
      :d.stopped?(note.kind==='info'?'已停止自动重试':'已停止自动重试，请点“重试提醒”'):d.status==='failed'?`${d.reason}（第 ${d.attempts} 次失败）`:d.reason||'等待发送');
    content.append(node('p',states.length?[...new Set(states)].join('；'):(note.kind==='info'?'尚未登记接收设备，通知已保存':'尚未登记接收设备，待办已保存'),'muted'));
    const open=node('button','打开工单','quiet');
    open.onclick=()=>guarded(open,()=>openNotification(note.id));
    const retry=node('button','重试提醒','quiet');
    retry.onclick=()=>guarded(retry,async()=>{await api('/notifications/'+encodeURIComponent(note.id)+'/retry','POST');await loadNotifications();});
    item.append(content,open);
    if(note.kind!=='info')item.append(retry);
    return item;
  });
  $('notification-list').replaceChildren(...(items.length?items:[node('p','暂无待处理通知','muted')]));
}
$('enable-push').onclick=()=>guarded($('enable-push'),()=>enablePush());
$('disable-push').onclick=()=>guarded($('disable-push'),async()=>{await disablePush();message('本机推送已停用，待办仍保留。');});
$('refresh-notifications').onclick=()=>guarded($('refresh-notifications'),loadNotifications);
window.addEventListener('haven-notification',event=>{if(token)void openNotification(event.detail).catch(error=>message(error.message));});
setInterval(()=>{if(token && !document.hidden)void loadNotifications().catch(()=>{});},30000);
if(token) enter().catch(error=>{logout();message(error.message);});
