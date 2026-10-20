import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/database.js';
import { fixture, SLOT, NEXT, START, H, type Row } from './repair-fixture.js';
import { staffingPlan } from '../src/repair/workforce.js';
import type { WorkerAvailability } from '../src/repair/schedule.js';
import { RepairRepository, ANY_REVISION } from '../src/repair/repository.js';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';
import { RepairViews } from '../src/repair/views.js';

test('resident staffing message: returned scheduled orders retain original-worker wording', () => {
  const views = new RepairViews(() => START, '', () => {});
  for (const history of [{ previousWorkers: [{ workerId: 'previous' }] }, { workforceReturned: true }]) {
    const row = views.view({ id: 'returned', status: 1, agreedTime: '2026-10-18T10:00:00+08:00',
      releasedAt: new Date(START).toISOString(), ...history,
      timeline: [{ action: 'workforce_returned', label: '内部信息', at: new Date(START).toISOString() }] }, 'resident');
    assert.equal(row.staffingMessage, '原师傅临时有事，正在为您安排新师傅，上门时间不变');
    assert.equal((row.timeline as Row[])[0]!.label, '正在为您安排师傅');
    assert.equal((row.timeline as Row[])[0]!.detail, '原师傅临时有事，正在为您安排新师傅，上门时间不变');
  }
});

test('resident staffing message: never-assigned scheduled orders explain unavailable staffing', () => {
  const views = new RepairViews(() => START, '', () => {});
  const row = views.view({ id: 'never-assigned', status: 1, agreedTime: '2026-10-18T10:00:00+08:00',
    staffingIssue: '暂无符合条件的师傅可接单，请物业协调人手缺口', previousWorkers: [] }, 'resident');
  assert.equal(row.staffingMessage, '原定时间暂时排不开师傅，正在为您安排');
});

test('resident staffing message: unscheduled orders retain arranging-worker wording', () => {
  const views = new RepairViews(() => START, '', () => {});
  const row = views.view({ id: 'unscheduled', status: 1, agreedTime: '', staffingIssue: '暂无符合条件的师傅可接单' }, 'resident');
  assert.equal(row.staffingMessage, '正在为您安排师傅');
});

async function profile(f: Awaited<ReturnType<typeof fixture>>, role: 'worker' | 'worker2') {
  return (await f.call('admin', 'GET', '/management/workers')).find((row: Row) => row.id === f.ids[role]);
}
async function skills(f: Awaited<ReturnType<typeof fixture>>, role: 'worker' | 'worker2', values: string[]) {
  const row = await profile(f, role);
  await f.call(role, 'PUT', '/worker/skills', { workforceRevision: row.revision, skills: values });
}
async function leave(f: Awaited<ReturnType<typeof fixture>>, role: 'worker' | 'worker2', hour = '10') {
  const row = await profile(f, role);
  return f.call('admin', 'POST', `/management/workers/${row.id}/leave`, { revision: row.revision, date: SLOT.slice(0, 10), hour, reason: '虚构休假' });
}

async function cancelLeave(f: Awaited<ReturnType<typeof fixture>>, role: 'worker' | 'worker2') {
  const row = await profile(f, role);
  return f.call('admin', 'DELETE', `/management/workers/${row.id}/leave`, { revision: row.revision, date: SLOT.slice(0, 10), hour: '10' });
}

function staffingNotes(f: Awaited<ReturnType<typeof fixture>>, activeOnly = true) {
  return f.store.db.prepare(`SELECT * FROM notifications WHERE taskKey LIKE 'staffing:%'${activeOnly ? ' AND active=1' : ''}`).all();
}
async function staffingIssue(f: Awaited<ReturnType<typeof fixture>>, row: Row) {
  const resident = await f.detail(row);
  assert.equal(Object.hasOwn(resident, 'staffingIssue'), false);
  return String(f.stored(row).staffingIssue ?? '');
}

test('workforce: healthy assigned order is not flagged by an unassigned shortage; cancellation clears tasks', async t => {
  const f = await fixture(t);
  const assigned = await f.processing();
  const pending = await f.create();
  await leave(f, 'worker2');
  assert.equal(await staffingIssue(f, assigned), '');
  assert.match(await staffingIssue(f, pending), /缺口/);
  assert.equal(staffingNotes(f).length, 0);
  assert(f.store.one("SELECT id FROM notifications WHERE repairId=? AND taskKey LIKE 'unstaffed_offer:%' AND active=1", pending.id));
  await f.change('resident', await f.detail(pending), 'revoke', { reason: '取消', notified: true });
  assert.equal(await staffingIssue(f, assigned), '');
  assert.equal(staffingNotes(f).length, 0);
  await leave(f, 'worker');
  assert.match(await staffingIssue(f, assigned), /缺口/);
  assert.equal(f.stored(assigned).status, 1);
  assert.equal(staffingNotes(f).length, 0);
  assert(f.store.one("SELECT id FROM notifications WHERE repairId=? AND taskKey LIKE 'unstaffed_offer:%' AND active=1", assigned.id));
});

test('workforce: duplicate legacy assignments flag both orders regardless of row order', async t => {
  const f = await fixture(t);
  const first = await f.processing(); const second = await f.create();
  f.store.save('repairs', f.ids.resident, { ...f.stored(second), workerId: f.ids.worker }, true);
  for (const row of [second, first]) assert.match(await staffingIssue(f, row), /该师傅此时段已有安排/);
  assert.equal(staffingNotes(f).length, 2);
});

test('workforce: staffing reason changes replace notification bodies and cleared incidents never reuse keys', async t => {
  const f = await fixture(t); const row = await f.processing();
  f.at(Date.parse('2026-10-18T10:00:00+08:00'));
  await leave(f, 'worker');
  const original = staffingNotes(f)[0]!;
  assert.match(String(original.body), /休假/);
  await cancelLeave(f, 'worker');
  assert.equal(staffingNotes(f).length, 0);
  // 已登记的其他技能不包含水暖，形成新的技能不符事件。
  await skills(f, 'worker', ['doors']);
  assert.equal(staffingNotes(f).length, 1);
  const changed = staffingNotes(f)[0]!;
  assert.match(String(changed.body), /未登记此类维修技能/);
  assert.notEqual(changed.taskKey, original.taskKey);
  assert.equal(f.store.one('SELECT active FROM notifications WHERE id=?', String(original.id))!.active, 0);
  await skills(f, 'worker', ['plumbing']);
  assert.equal(staffingNotes(f).length, 0);
  await skills(f, 'worker', ['doors']);
  const recurring = staffingNotes(f)[0]!;
  assert.notEqual(recurring.taskKey, changed.taskKey);
  assert.equal(f.store.one('SELECT active FROM notifications WHERE id=?', String(changed.id))!.active, 0);
  assert.equal(await staffingIssue(f, row), '该师傅未登记此类维修技能');
});

test('workforce: settlement and mutation increment incidents for every reason transition', async t => {
  const f = await fixture(t); const row = await f.processing();
  f.at(Date.parse('2026-10-18T10:00:00+08:00'));
  await leave(f, 'worker');
  const before = f.stored(row);
  // 一次事务内把休假改成明确技能不符，模拟无“清除”中间状态的原因替换。
  f.store.run('DELETE FROM worker_leaves WHERE workerId=?', f.ids.worker);
  f.store.run('DELETE FROM worker_skills WHERE workerId=?', f.ids.worker);
  f.store.run("INSERT INTO worker_skills VALUES (?, 'doors')", f.ids.worker);
  const changed = await f.detail(row);
  assert.equal(f.stored(row).staffingIncident, Number(before.staffingIncident) + 1);
  assert.match(String(staffingNotes(f)[0]!.body), /未登记此类维修技能/);
  assert.equal(staffingNotes(f).length, 1);
  const repository = new RepairRepository(f.store, f.time, () => {}, f.config.publicBaseUrl);
  const incident = Number(f.stored(row).staffingIncident);
  repository.mutate(changed.id, ANY_REVISION, () => {}, record => { record.workerId = f.ids.worker2; });
  f.notifications.sync(f.ids.resident, f.stored(row));
  assert.equal(f.stored(row).staffingIncident, incident + 1);
  assert.equal(staffingNotes(f).length, 0);
  repository.mutate(changed.id, ANY_REVISION, () => {}, record => { record.workerId = f.ids.worker; });
  f.notifications.sync(f.ids.resident, f.stored(row));
  assert.equal(f.stored(row).staffingIncident, incident + 2);
  assert.equal(staffingNotes(f).length, 1);
});

test('workforce: unknown skills preserve existing acceptance and completion but reject all new matching', async t => {
  const f = await fixture(t);
  let row = await f.create(); row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  // 真正从未登记：技能与审计两处都为空，不通过清空技能接口伪造。
  f.store.run('DELETE FROM worker_skills');
  f.store.run('DELETE FROM worker_skill_audit');
  row = await f.detail(row);
  assert.equal(await staffingIssue(f, row), ''); assert.equal(staffingNotes(f).length, 0);
  row = await f.change('worker', row, 'accept');
  const pending = await f.create('');
  const options = await f.call('admin', 'GET', `/management/repairs/${pending.id}/assignment-options`);
  assert(options.every((item: Row) => !item.selectable && /未登记此类维修技能/.test(item.reason)));
  assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${pending.id}/assign`, { revision: pending.revision, workerId: f.ids.worker })).status, 409);
  assert.equal((await f.raw('resident', 'POST', '/repair', { ...f.body, slot: NEXT })).status, 409);
  const slots = await f.call('resident', 'GET', '/repair/slots?date=2026-10-18&repairItemId=1004');
  assert(slots.slots.every((item: Row) => !item.selectable));
  assert.equal((await f.change('worker', row, 'complete', { result: '维修完成', cost: 0 })).status, 6);
});

test('workforce: legacy unclassified assignments remain valid while unassigned orders require classification', async t => {
  const f = await fixture(t);
  for (const repairItemId of ['1001', '1003']) {
    let row = await f.create(''); row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
    f.store.save('repairs', f.ids.resident, { ...f.stored(row), repairItemId, slot: SLOT }, true);
    f.store.run('DELETE FROM worker_skills WHERE workerId=?', f.ids.worker);
    f.store.run('DELETE FROM worker_skill_audit WHERE workerId=?', f.ids.worker);
    row = await f.detail(row); assert.equal(await staffingIssue(f, row), '');
    row = await f.change('worker', row, 'accept');
    await f.change('worker', row, 'complete', { result: '历史维修完成' });
    const pending = await f.create('', { repairItemId });
    assert.match(await staffingIssue(f, pending), /请物业明确所需技能/);
    await skills(f, 'worker', ['plumbing']);
  }
});

test('workforce: summary counts only workers without any registered skill and reaches zero', async t => {
  const f = await fixture(t);
  await skills(f, 'worker', []); await skills(f, 'worker2', []);
  assert.equal((await f.call('admin', 'GET', '/management/workforce-summary')).unregisteredCount, 2);
  assert.equal((await f.raw('resident', 'GET', '/management/workforce-summary')).status, 403);
  await skills(f, 'worker', ['doors']);
  assert.equal((await f.call('admin', 'GET', '/management/workforce-summary')).unregisteredCount, 1);
  await skills(f, 'worker2', ['plumbing']);
  assert.equal((await f.call('admin', 'GET', '/management/workforce-summary')).unregisteredCount, 0);
});

test('workforce: v5 accepted order migrates with unknown skills, no task and successful completion', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-v5-accepted-'));
  const path = join(folder, 'test.sqlite');
  const store = new Store(path);
  store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('legacy-worker','19900000111','旧师傅','worker'),('owner','19900000112','住户','resident'),('admin','19900000113','物业','admin')");
  store.save('repairs', 'owner', { id: 'accepted', repairItemId: '1004', status: 2, workerId: 'legacy-worker', slot: SLOT, agreedTime: '2026-10-18 10:00', revision: 0 });
  store.db.exec('DROP TABLE worker_skills; DROP TABLE worker_leaves; ALTER TABLE users DROP COLUMN workforceRevision; PRAGMA user_version=5');
  store.close();
  const runtime = createApp({ ...readConfig({}), databasePath: path }, { now: () => START, pushTimer: false, log: () => {} });
  try {
    const { RepairService } = await import('../src/repair/service.js');
    const repairs = new RepairService(runtime.store, () => START, '4000000000', () => {}, 'http://127.0.0.1:3000');
    const repository = new RepairRepository(runtime.store, () => START, () => {}, 'http://127.0.0.1:3000');
    repository.settleAll();
    const row = repository.load('accepted').record;
    assert.equal(String(row.staffingIssue ?? ''), '');
    assert.equal(repository.staffingIssue(row), '');
    runtime.notifications.sync('owner', row);
    assert.equal(runtime.store.one("SELECT COUNT(*) AS n FROM notifications WHERE taskKey LIKE 'staffing:%' AND active=1")!.n, 0);
    assert.equal(repairs.complete('legacy-worker', 'accepted', { revision: Number(row.revision ?? 0), result: '维修完成' }).status, 6);
  } finally { await runtime.notifications.stop(); runtime.store.close(); rmSync(folder, { recursive: true, force: true }); }
});

test('workforce: demo startup repairs old empty demo skills on every launch without changing other users', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-demo-skills-'));
  mkdirSync(join(folder, 'data'));
  const path = join(folder, 'data', 'workflow-demo.sqlite');
  const store = new Store(path);
  store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('demo','19900000003','张师傅','worker'),('outside','19900000999','其他师傅','worker')");
  store.db.exec('DROP TABLE worker_skills; DROP TABLE worker_leaves; ALTER TABLE users DROP COLUMN workforceRevision; PRAGMA user_version=5');
  store.close();
  const script = fileURLToPath(new URL('../tool/workflow-demo.ts', import.meta.url));
  const tsx = new URL('../node_modules/tsx/dist/loader.mjs', import.meta.url).href;
  async function startDemo() {
    const child = spawn(process.execPath, ['--import', tsx, script], { cwd: folder, env: { ...process.env, NODE_ENV: 'development', HOST: '127.0.0.1' }, stdio: ['ignore', 'pipe', 'pipe'] });
    const stopped = new Promise<void>(resolve => child.once('close', () => resolve()));
    let output = '';
    try {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`demo startup timeout: ${output}`)), 15000);
        child.stdout.on('data', data => { output += String(data); if (output.includes('物业后台：')) { clearTimeout(timer); resolve(); } });
        child.stderr.on('data', data => { output += String(data); });
        child.once('error', error => { clearTimeout(timer); reject(error); });
        child.once('exit', code => { clearTimeout(timer); reject(new Error(`demo exited ${code}: ${output}`)); });
      });
    } finally { child.kill(); await stopped; }
  }
  try {
    for (let launch = 0; launch < 2; launch++) {
      await startDemo();
      const check = new Store(path);
      try {
        assert.deepEqual(check.db.prepare('SELECT skill FROM worker_skills WHERE workerId=? ORDER BY skill').all('demo').map(row => row.skill), ['doors', 'electrical', 'plumbing']);
        assert.equal(check.one("SELECT COUNT(*) AS n FROM worker_skills WHERE workerId='outside'")!.n, 0);
      } finally { check.close(); }
    }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});

test('workforce: matching preserves the only electrician and never counts a multi-skilled worker twice', async t => {
  const f = await fixture(t);
  await skills(f, 'worker', ['plumbing', 'electrical']);
  await skills(f, 'worker2', ['plumbing']);
  const plumbing = await f.create();
  const electric = await f.create(SLOT, { repairItemId: '1005' });
  const rejected = await f.raw('admin', 'PUT', `/management/repairs/${plumbing.id}/assign`, { revision: plumbing.revision, workerId: f.ids.worker });
  assert.equal(rejected.status, 409);
  assert.match(rejected.message, /人手或技能不足/);
  await f.change('admin', plumbing, 'assign', { workerId: f.ids.worker2 });
  await f.change('admin', electric, 'assign', { workerId: f.ids.worker });
  assert.equal((await f.raw('resident', 'POST', '/repair', { ...f.body, slot: SLOT })).status, 409);
});

test('workforce: matching is independent of record and worker order', () => {
  const workers: WorkerAvailability[] = [{ id: 'a', skills: ['electrical', 'plumbing'], skillsKnown: true, leaves: [] }, { id: 'b', skills: ['plumbing'], skillsKnown: true, leaves: [] }];
  const rows = [{ id: 'p', slot: SLOT, repairItemId: '1004', status: 1 }, { id: 'e', slot: SLOT, repairItemId: '1005', status: 1 }];
  for (const people of [workers, [...workers].reverse()]) for (const records of [rows, [...rows].reverse()]) {
    assert.equal(staffingPlan(records, SLOT, people).shortage, 0);
    assert.equal(staffingPlan([...records, { id: 'e2', slot: SLOT, repairItemId: '1005', status: 1 }], SLOT, people).shortage, 1);
  }
});

test('workforce: existing matching fixes healthy assignments and includes invalid assignments in the remainder', () => {
  const workers: WorkerAvailability[] = [
    { id: 'a', skills: ['plumbing'], skillsKnown: true, leaves: [] },
    { id: 'b', skills: ['electrical'], skillsKnown: true, leaves: [{ date: SLOT.slice(0, 10), hour: '10' }] },
    { id: 'c', skills: ['plumbing', 'electrical'], skillsKnown: true, leaves: [] },
  ];
  const rows = [
    { id: 'healthy', workerId: 'a', slot: SLOT, repairItemId: '1004', status: 2 },
    { id: 'invalid', workerId: 'b', slot: SLOT, repairItemId: '1005', status: 2 },
    { id: 'pending', slot: SLOT, repairItemId: '1004', status: 1 },
  ];
  for (const records of [rows, [...rows].reverse()]) for (const people of [workers, [...workers].reverse()]) {
    const plan = staffingPlan(records, SLOT, people);
    assert.equal(plan.issues.has('healthy'), false);
    assert.match(plan.issues.get('invalid')!, /休假/);
    assert.equal(plan.issues.has('pending'), false);
    assert.equal(plan.shortage, 1);
    const enough = staffingPlan(records, SLOT, [...people, { id: 'd', skills: ['plumbing'], skillsKnown: true, leaves: [] }]);
    assert.equal(enough.shortage, 0);
    assert.deepEqual([...enough.issues.keys()], ['invalid']);
  }
});

test('workforce: unknown skills cannot schedule first visits, reschedule or dispatch urgent work', async t => {
  const f = await fixture(t);
  let unscheduled = await f.create(''); unscheduled = await f.change('admin', unscheduled, 'assign', { workerId: f.ids.worker });
  let existing = await f.processing(NEXT, 'worker2');
  f.store.run('DELETE FROM worker_skills');
  f.store.run('DELETE FROM worker_skill_audit');
  unscheduled = await f.detail(unscheduled);
  assert.equal((await f.raw('worker', 'PUT', `/worker/repairs/${unscheduled.id}/accept`, { revision: unscheduled.revision, slot: SLOT, reason: '首次安排' })).status, 409);
  unscheduled = await f.change('worker', unscheduled, 'accept');
  assert.equal(unscheduled.status, 2);
  existing = await f.detail(existing);
  assert.equal((await f.raw('worker2', 'POST', `/worker/repairs/${existing.id}/reschedule`, { revision: existing.revision, slot: SLOT, reason: '改约', notified: true })).status, 409);
  let urgent = await f.create('', { urgentRequest: true });
  urgent = await f.change('admin', urgent, 'priority', { priority: 'urgent', reason: '核实急单' });
  const options = await f.call('admin', 'GET', `/management/repairs/${urgent.id}/dispatch-options?limit=77`);
  assert(options.slots.every((slot: Row) => !slot.dispatchable && slot.workers.length === 0 && slot.workerCount === 0));
  assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${urgent.id}/dispatch`, { revision: urgent.revision, workerId: f.ids.worker, slot: SLOT })).status, 409);
});

test('workforce: unrelated shortage does not block first-proposal auto confirmation', async t => {
  const f = await fixture(t);
  let row = await f.create(''); row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  row = await f.change('worker', row, 'accept', { slot: SLOT, reason: '首次安排' });
  const waiting = await f.create(); await leave(f, 'worker2');
  f.at(START + 3 * H);
  row = await f.detail(row);
  await f.detail(waiting);
  assert.equal(await staffingIssue(f, row), ''); assert.equal(row.autoAccepted, true);
  assert.equal(staffingNotes(f).length, 1);
});

test('workforce: v5 migration preserves orders, leaves old skills unknown and reopens safely', () => {
  const folder=mkdtempSync(join(tmpdir(),'haven-workforce-migration-')); const path=join(folder,'test.sqlite');
  let store: Store | undefined;
  try {
    store=new Store(path);
    store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('w','19900000111','旧师傅','worker')");
    store.save('repairs','w',{id:'legacy',repairItemId:'1001',status:1,slot:SLOT});
    const payload=store.one("SELECT payload FROM repairs WHERE id='legacy'")!.payload;
    store.db.exec('DROP TABLE worker_skills; DROP TABLE worker_leaves; ALTER TABLE users DROP COLUMN workforceRevision; PRAGMA user_version=5');
    store.close(); store=undefined; store=new Store(path);
    assert.equal(store.one('PRAGMA user_version')!.user_version,7);
    assert.equal(store.one('SELECT COUNT(*) AS n FROM worker_skills')!.n,0);
    assert.equal(store.one("SELECT workforceRevision FROM users WHERE id='w'")!.workforceRevision,0);
    assert.equal(store.one("SELECT payload FROM repairs WHERE id='legacy'")!.payload,payload);
    store.run("INSERT INTO worker_skills VALUES ('w','plumbing')");
    store.run("INSERT INTO worker_leaves VALUES ('w','2026-10-18','10','虚构')");
    store.close(); store=undefined; store=new Store(path);
    assert.equal(store.one('SELECT COUNT(*) AS n FROM worker_skills')!.n,1);
    assert.equal(store.one('SELECT COUNT(*) AS n FROM worker_leaves')!.n,1);
  } finally { store?.close(); rmSync(folder,{recursive:true,force:true}); }
});

test('workforce: leaving and booking serialize; no successful new booking bypasses leave', async t => {
  const f=await fixture(t);await skills(f,'worker2',['doors']);
  const worker=await profile(f,'worker');
  const [absence,booking]=await Promise.all([
    f.raw('admin','POST',`/management/workers/${worker.id}/leave`,{revision:worker.revision,date:'2026-10-18',hour:'10'}),
    f.raw('resident','POST','/repair',{...f.body,slot:SLOT}),
  ]);
  assert.equal(absence.code,10000);
  if(booking.code===10000) {
    const row=await f.detail({id:booking.data.createdId});assert.match(await staffingIssue(f,row),/缺口/);
  } else assert.equal(booking.status,409);
  assert.equal((await f.raw('resident','POST','/repair',{...f.body,slot:SLOT})).status,409);
});

test('workforce: other and legacy water/electricity orders require property classification', async t => {
  const f = await fixture(t);
  for (const repairItemId of ['1001', '1003']) {
    assert.equal((await f.raw('resident', 'POST', '/repair', { ...f.body, repairItemId, slot: SLOT })).status, 409);
    let row = await f.create('', { repairItemId });
    assert.match(await staffingIssue(f, row), /明确/);
    assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/assign`, { revision: row.revision, workerId: f.ids.worker })).status, 409);
    assert.equal((await f.raw('resident', 'PUT', `/management/repairs/${row.id}/skill`, { revision: row.revision, skill: 'plumbing', reason: '管道' })).status, 403);
    row = await f.change('admin', row, 'skill', { skill: 'plumbing', reason: '图片及电话核实为管道漏水' });
    row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
    assert.equal(row.status, 5);
  }
  const catalog = await f.call('resident', 'GET', '/repairItem');
  assert.deepEqual(catalog.map((row: Row) => row.id), ['1004', '1005', '1002', '1003']);
});

test('workforce: leave returns accepted appointment unchanged and permits coordinated reassignment', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  const time = row.agreedTime;
  await leave(f, 'worker');
  row = await f.detail(row);
  assert.equal(row.agreedTime, time); assert.equal(row.slot, SLOT); assert.equal(row.status, 1);
  assert.equal(await staffingIssue(f, row), '');
  assert.equal(row.staffingMessage, '原师傅临时有事，正在为您安排新师傅，上门时间不变');
  const notes = () => f.store.db.prepare("SELECT * FROM notifications WHERE repairId=? AND taskKey LIKE 'staffing:%' AND active=1").all(row.id);
  assert.equal(notes().length, 0);
  await leave(f, 'worker'); await f.detail(row);
  assert.equal(notes().length, 0);
  const assigned = await f.change('admin', row, 'assign', { workerId: f.ids.worker2 });
  assert.equal(assigned.slot, SLOT); assert.equal(assigned.agreedTime, time); assert.equal(assigned.status, 5);
  assert.equal(assigned.staffingIssue, ''); assert.equal(notes().length, 0);
  assert.equal((await f.raw('worker', 'GET', `/worker/repairs/${row.id}`)).status, 404);
  await f.change('worker2', assigned, 'accept');
});

test('workforce: leave accounts for unassigned reservations and cancellation clears coordination task', async t => {
  const f = await fixture(t);
  const first = await f.create(); const second = await f.create();
  await leave(f, 'worker');
  const row = await f.detail(first);
  assert.equal(await staffingIssue(f, row), '');
  // 两张都可接；实际接走一张后，剩余一张才因无人可接进入物业待办。
  assert.equal(await staffingIssue(f, second), '');
  assert.equal(staffingNotes(f).length, 0);
  const list = await f.call('admin', 'GET', '/notifications');
  assert(!list.some((item: Row) => item.title === '人手待协调' && item.active));
  const choices = await f.call('resident', 'GET', `/repair/slots?date=${SLOT.slice(0,10)}&repairItemId=1004`);
  assert.equal(choices.slots.find((slot: Row) => slot.slot === SLOT).selectable, false);
  const latest = await f.detail(second); await f.change('resident', latest, 'revoke', { reason: '取消', notified: true });
  assert.equal(await staffingIssue(f, first), '');
});

test('workforce: last compatible reservation is checked in the write transaction', async t => {
  const f = await fixture(t);
  await skills(f, 'worker2', ['doors']);
  const results = await Promise.all([f.raw('resident','POST','/repair',{...f.body,slot:SLOT}), f.raw('resident','POST','/repair',{...f.body,slot:SLOT})]);
  assert.deepEqual(results.map(row => row.status).sort(), [200,409]);
});

test('workforce: urgent options and stale dispatch both honor skills and leave', async t => {
  const f = await fixture(t);
  await skills(f, 'worker2', ['plumbing']);
  let row = await f.create('', { repairItemId: '1005', urgentRequest: true });
  row = await f.change('admin', row, 'priority', { priority: 'urgent', reason: '核实急单' });
  const options = await f.call('admin','GET',`/management/repairs/${row.id}/dispatch-options?limit=77`);
  assert.deepEqual(options.slots.find((slot: Row) => slot.slot === SLOT).workers.map((worker: Row) => worker.id), [f.ids.worker]);
  await leave(f, 'worker');
  const failed = await f.raw('admin','PUT',`/management/repairs/${row.id}/dispatch`,{revision:row.revision,workerId:f.ids.worker,slot:SLOT});
  assert.equal(failed.status,409); assert.match(failed.message,/休假/);
  const fresh = await f.call('admin','GET',`/management/repairs/${row.id}/dispatch-options?limit=77`);
  assert.equal(fresh.slots.find((slot: Row) => slot.slot === SLOT).dispatchable,false);
  assert(f.store.one("SELECT id FROM notifications WHERE repairId=? AND taskKey='urgent_dispatch' AND active=1",row.id));
});

test('workforce: staffing edit revisions reject concurrent overwrite; invalid dates/hours and roles cannot write', async t => {
  const f = await fixture(t); const worker = await profile(f,'worker');
  const path=`/management/workers/${worker.id}/leave`;
  const body={revision:worker.revision,date:'2026-10-18',hour:'10'};
  const writes=await Promise.all([f.raw('admin','POST',path,body),f.raw('admin','POST',path,{...body,hour:'11'})]);
  assert.deepEqual(writes.map(row=>row.status).sort(),[200,409]);
  for(const input of [{...body,date:'2026-02-30'},{...body,hour:'12'},{...body,hour:'18'}]) {
    assert.notEqual((await f.raw('admin','POST',path,input)).code,10000);
  }
  assert.equal((await f.raw('worker','POST',path,body)).status,403);
  assert.equal((await f.raw('resident','DELETE',path,body)).status,403);
});

test('workforce: whole day and individual hour leave affect only the selected Beijing date', async t => {
  const f = await fixture(t); await skills(f,'worker2',['doors']); await leave(f,'worker','');
  const choices=await f.call('resident','GET','/repair/slots?date=2026-10-18&repairItemId=1004');
  assert(choices.slots.every((row:Row)=>!row.selectable));
  assert((await f.call('resident','GET','/repair/slots?date=2026-10-19&repairItemId=1004')).slots.some((row:Row)=>row.selectable));
  const worker=await profile(f,'worker');
  await f.call('admin','DELETE',`/management/workers/${worker.id}/leave`,{revision:worker.revision,date:'2026-10-18',hour:''});
  await leave(f,'worker');
  const next=await f.call('resident','GET','/repair/slots?date=2026-10-18&repairItemId=1004');
  assert.equal(next.slots.find((row:Row)=>row.slot===NEXT).selectable,true);
});

test('workforce: removing a skill returns existing work and revokes previous worker access', async t => {
  const f=await fixture(t); let row=await f.create(''); row=await f.change('admin',row,'assign',{workerId:f.ids.worker});
  await skills(f,'worker',['doors']); row=await f.detail(row); assert.equal(row.status,1);
  assert.equal((await f.raw('worker','PUT',`/worker/repairs/${row.id}/accept`,{revision:row.revision})).status,404);
});

test('workforce: unavailable first proposal never auto-confirms; future returned orders allow shift while reschedule needs consent', async t => {
  const f=await fixture(t); let row=await f.create(''); row=await f.change('admin',row,'assign',{workerId:f.ids.worker});
  row=await f.change('worker',row,'accept',{slot:SLOT,reason:'首次安排'}); await leave(f,'worker');
  f.at(START+3*H); row=await f.detail(row);
  assert.equal(row.agreedTime,''); assert.equal(row.slot,''); assert.equal(row.autoAccepted,false);
  assert.equal(row.status,1);
  row=await f.change('admin',row,'assign',{workerId:f.ids.worker});
  row=await f.change('worker',row,'accept',{slot:NEXT,reason:'可用时段'});
  row=await f.change('resident',row,'reschedule',{accept:true});
  await leave(f,'worker','11'); row=await f.detail(row);
  row=await f.change('admin',row,'shift',{slot:'2026-10-18#14',reason:'人手待协调顺延'});
  assert.equal(row.slot,'2026-10-18#14'); assert.equal(row.agreedTime,'2026-10-18T14:00:00+08:00');
  const original=row.agreedTime;
  row=await f.change('admin',row,'reschedule',{slot:'2026-10-18#15',reason:'协商改约',notified:true},'POST');
  assert.equal(row.agreedTime,original);
  row=await f.change('resident',row,'reschedule',{accept:true});assert.notEqual(row.agreedTime,original);
});

test('workforce: urgent leave conflict cannot change confirmed time through dispatch', async t => {
  const f=await fixture(t);let row=await f.processing();row=await f.change('admin',row,'priority',{priority:'urgent',reason:'核实急单'});
  await leave(f,'worker');row=await f.detail(row);
  const result=await f.raw('admin','PUT',`/management/repairs/${row.id}/dispatch`,{revision:row.revision,workerId:f.ids.worker2,slot:NEXT});
  assert.equal(result.code,40001);assert.match(result.message,/确认流程/);assert.equal(f.stored(row).slot,SLOT);
  const options=await f.call('admin','GET',`/management/repairs/${row.id}/dispatch-options?limit=77`);
  assert.equal(options.slots.find((item:Row)=>item.slot===NEXT).dispatchable,false);
  row=await f.change('admin',row,'dispatch',{workerId:f.ids.worker2,slot:SLOT});assert.equal(row.staffingIssue,'');
});

test('workforce: leave task queues without an open property page, retries and deduplicates', async t => {
  let sent=0;let fail=true;
  const f=await fixture(t,{pushTransport:{publicConfig:()=>({webPublicKey:'',harmonyConfigured:true}),send:async(_device,message)=>{
    if(message.title==='人手待协调')sent++;
    return {status:fail?'failed':'accepted',reason:'fake transport'};
  }}});
  f.notifications.register(f.ids.admin,{platform:'harmony',token:'fake-workforce-device',installationId:'c'.repeat(64)});
  let row=await f.processing();await leave(f,'worker2');await leave(f,'worker');
  row=await f.detail(row);
  await f.change('resident',row,'unstaffed-choice',{offerId:row.rescheduleOffer.id,keep:true});
  const note=f.store.one("SELECT id FROM notifications WHERE repairId=? AND taskKey LIKE 'staffing:%' AND active=1",row.id)!;
  await f.notifications.dispatch();assert.equal(sent,1);
  assert.equal(f.store.one('SELECT status FROM push_deliveries WHERE notificationId=?',String(note.id))!.status,'failed');
  await leave(f,'worker');await f.notifications.dispatch();assert.equal(sent,1);
  fail=false;f.at(f.time()+60001);await f.notifications.dispatch();assert.equal(sent,2);
  assert.equal(f.store.one('SELECT status FROM push_deliveries WHERE notificationId=?',String(note.id))!.status,'accepted');
  f.notifications.read(f.ids.admin,String(note.id));assert.equal(f.store.one('SELECT active FROM notifications WHERE id=?',String(note.id))!.active,1);
});
