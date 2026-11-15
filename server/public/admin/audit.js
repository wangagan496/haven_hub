'use strict';
const auditHeaders = { 'X-Client-Version': window.HAVEN_ADMIN_CLIENT_VERSION, 'X-Client-Platform': 'admin-web' };
const auditElement = id => document.getElementById(id);
const auditLabels = {
  'room.review':'房屋审核', 'worker.save':'保存维修人员', 'worker.access':'停用或恢复账号',
  'worker.leave.save':'登记休假', 'worker.leave.remove':'取消休假', 'worker.skills':'变更维修技能',
  'repair.assign':'派单或改派', 'repair.priority':'调整优先级', 'repair.shift':'顺延上门',
  'repair.dispatch':'安排急单', 'repair.skill':'确定维修类别', 'repair.aftersale':'审核售后',
  'repair.note':'记录跟进处理', 'repair.reschedule.propose':'提出改约', 'repair.reschedule.respond':'处理改约',
  'repair.unstaffed':'协调缺人时段', 'capacity.save':'保存预约容量', 'capacity.clear':'清除容量覆盖',
};
const auditTypes = {room:'房屋',repair:'报修',worker:'维修人员','capacity-default':'默认容量','capacity-weekday':'星期容量','capacity-date':'日期容量'};
const auditFields = {revision:'记录版本',status:'状态',workerId:'师傅编号',priority:'优先级',requiredSkill:'维修技能',slot:'上门时段',
  needsAdmin:'需要物业协助',roundCount:'维修轮数',eventCount:'业务事件数',pendingCounts:'待办数量',role:'角色',enabled:'账号可用',skills:'已登记技能',leaves:'休假时段',capacities:'预约容量'};
const auditSkills = {plumbing:'水暖',electrical:'电气',doors:'门窗五金'};
let auditBusy = false, auditCursor = null, auditRows = [], auditGeneration = 0;
let auditSession = sessionStorage.getItem('haven-admin-token') || '';
let auditAppliedFilters = {};

function setAuditBusy(busy) {
  auditBusy = busy;
  [...auditElement('audit-filters').querySelectorAll('input,select,button'), auditElement('audit-more')]
    .forEach(control => { control.disabled = busy; });
}

function auditNode(tag, text, className) {
  const item = document.createElement(tag);
  if (text != null) item.textContent = String(text);
  if (className) item.className = className;
  return item;
}

function auditValue(key, value, type) {
  if (value == null || value === '') return '无';
  if (key === 'status') return (type === 'room' ? {1:'待审核',2:'已通过',3:'已打回'} : {0:'已取消',1:'待派单',2:'处理中',3:'已完成',4:'已取消',5:'待接单',6:'待住户确认'})[value] || '未知状态';
  if (key === 'priority') return {urgent:'紧急',medium:'一般',light:'轻微'}[value] || '未定级';
  if (key === 'requiredSkill') return auditSkills[value] || '未确定';
  if (key === 'role') return {worker:'维修师傅',admin:'物业管理员',resident:'住户'}[value] || '未知';
  if (key === 'skills') return value.map(skill => auditSkills[skill] || '未知').join('、') || '未登记';
  if (key === 'leaves') return value.map(leave => `${leave.date} ${leave.hour ? leave.hour + '时' : '全天'}`).join('、') || '无';
  if (key === 'capacities') return Object.entries(value).map(([hour, count]) => `${hour}时：${count}`).join('；') || '无覆盖';
  if (key === 'pendingCounts') return Object.entries(value).map(([kind, count]) => `${{reschedule:'改约',revoke:'撤销',aftersale:'售后',feedback:'反馈'}[kind] || '事项'}：待处理${count.open}，已处理${count.resolved}`).join('；');
  return typeof value === 'boolean' ? value ? '是' : '否' : String(value);
}

function auditSnapshot(snapshot, row) {
  if (snapshot == null) return row.source === 'live' ? '无记录' : '历史记录未保存这一侧的变更详情';
  return Object.entries(snapshot).filter(([key]) => auditFields[key]).map(([key, value]) => `${auditFields[key]}：${auditValue(key, value, row.targetType)}`).join('\n');
}

function renderAudit() {
  const content = auditElement('audit-rows');
  content.replaceChildren(...auditRows.map(row => {
    const article = auditNode('article', null, 'audit-record');
    const date = row.createdAt ? new Date(row.createdAt).toLocaleString('zh-CN') : '历史时间未记录';
    article.append(auditNode('h2', `${auditLabels[row.action] || '管理变更'} · ${date}`),
      auditNode('p', `操作人：${row.actorId}（${{admin:'物业',worker:'师傅',unknown:'历史身份未记录'}[row.actorRole] || '未知'}）`),
      auditNode('p', `${auditTypes[row.targetType] || '对象'}编号：${row.targetId} · 记录序号：${row.seq}`));
    if (row.source !== 'live') article.append(auditNode('p', row.source === 'legacy-skill-latest'
      ? '历史导入：旧系统仅保存最后一次技能变更，更早记录无法补回。' : '历史导入：原有账号状态记录。', 'muted'));
    const details = auditNode('details');
    details.append(auditNode('summary', '查看变更前后'));
    const changes = auditNode('div', null, 'audit-changes');
    for (const [title, snapshot] of [['变更前', row.before], ['变更后', row.after]]) {
      const side = auditNode('div');
      side.append(auditNode('strong', title), auditNode('pre', auditSnapshot(snapshot, row)));
      changes.append(side);
    }
    details.append(changes); article.append(details);
    return article;
  }));
  auditElement('audit-more').hidden = auditCursor == null;
}

function checkAuditSession() {
  const current = sessionStorage.getItem('haven-admin-token') || '';
  if (current && current === auditSession) return true;
  auditGeneration++;
  auditRows = []; auditCursor = null; auditSession = current; auditAppliedFilters = {};
  setAuditBusy(false);
  renderAudit();
  auditElement('audit-status').textContent = current ? '登录账号已变化，请重新查询。' : '请返回物业工作台登录后查看操作记录。';
  return false;
}

async function loadAudit(reset = true) {
  if (auditBusy) return;
  if (!checkAuditSession()) return;
  if (!reset && auditCursor == null) return;
  const token = auditSession, generation = ++auditGeneration;
  const query = new URLSearchParams({limit:'50'});
  if (reset) {
    auditAppliedFilters = {};
    for (const key of ['actorId','targetId','targetType','action']) {
      const value = auditElement(key).value.trim();
      if (value) auditAppliedFilters[key] = value;
    }
  }
  for (const [key, value] of Object.entries(auditAppliedFilters)) query.set(key, value);
  if (!reset) query.set('before', String(auditCursor));
  if (reset) { auditRows = []; auditCursor = null; renderAudit(); }
  setAuditBusy(true);
  auditElement('audit-status').textContent = '正在加载操作记录…';
  try {
    const response = await fetch('/management/audit-events?' + query, { headers:{...auditHeaders,Authorization:`Bearer ${token}`} });
    const body = await response.json();
    if (generation !== auditGeneration || !checkAuditSession()) return;
    if (response.status === 401) {
      sessionStorage.removeItem('haven-admin-token'); checkAuditSession(); return;
    }
    if (!response.ok || body.code !== 10000) {
      const receipt = response.headers.get('x-request-id') || '';
      throw Error((body.message || '查询失败，请重试') + (/^[a-f0-9-]{36}$/i.test(receipt) ? `\n排查编号：${receipt}` : ''));
    }
    auditRows = reset ? body.data.rows : [...auditRows, ...body.data.rows];
    auditCursor = body.data.nextCursor;
    renderAudit();
    auditElement('audit-status').textContent = auditRows.length ? `已加载${auditRows.length}条${auditCursor == null ? '，已到最早记录' : ''}` : '没有符合条件的操作记录。';
  } catch (error) {
    if (generation === auditGeneration && checkAuditSession()) auditElement('audit-status').textContent = error.message || '查询失败，请重试';
  } finally {
    if (generation === auditGeneration) setAuditBusy(false);
  }
}

for (const [value, label] of Object.entries(auditLabels)) {
  const option = auditNode('option', label); option.value = value; auditElement('action').append(option);
}
auditElement('audit-filters').onsubmit = event => { event.preventDefault(); void loadAudit(); };
auditElement('audit-reset').onclick = () => { auditElement('audit-filters').reset(); void loadAudit(); };
auditElement('audit-more').onclick = () => { void loadAudit(false); };
window.addEventListener('pageshow', checkAuditSession);
window.addEventListener('storage', checkAuditSession);
void loadAudit();
