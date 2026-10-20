import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, SLOT, NEXT, START, H, type Row } from './repair-fixture.js';
import { Store, type RecordData } from '../src/database.js';
import { RepairRepository } from '../src/repair/repository.js';
import { holdingEligibility, readWorkforce, StaffingContext, staffingRejection } from '../src/repair/workforce.js';
import { RepairService } from '../src/repair/service.js';
import type { WorkerAvailability } from '../src/repair/schedule.js';
import { ensureRounds } from '../src/repair/model.js';

type F = Awaited<ReturnType<typeof fixture>>;
const shortageNotes = (f: F) => f.store.db.prepare("SELECT * FROM notifications WHERE taskKey LIKE 'pool_shortage:%' AND active=1").all();
async function skills(f: F, who: 'worker' | 'worker2', values: string[], preview = false) {
  const profile = await f.call(who, 'GET', '/worker/skills');
  return f.call(who, 'PUT', '/worker/skills', { workforceRevision: profile.workforceRevision, skills: values, preview });
}
async function leave(f: F, preview = false) {
  const profile = await f.call('worker', 'GET', '/worker/skills');
  return f.call('admin', 'POST', `/management/workers/${f.ids.worker}/leave`, {
    revision: profile.workforceRevision, date: '2026-10-18', hour: '10', preview,
  });
}
const pool = (f: F, who: 'worker' | 'worker2' = 'worker') => f.call(who, 'GET', '/worker/repair-pool') as Promise<Row[]>;
const ids = (rows: Row[]) => rows.map(row => row.id).sort();

test('skillsKnown: audit or registered skills mean known; only never registered workers retain legacy work', () => {
  const store = new Store(':memory:');
  try {
    for (const id of ['legacy','registered','cleared']) store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')",id,id,id);
    store.run("INSERT INTO worker_skills VALUES ('registered','plumbing')");
    store.run("INSERT INTO worker_skill_audit VALUES ('cleared','cleared','cleared','2026-10-17')");
    const workers = readWorkforce(store);
    assert.deepEqual(Object.fromEntries(workers.map(worker=>[worker.id,worker.skillsKnown])),{legacy:false,registered:true,cleared:true});
    for (const repairItemId of ['1001','1003','1004']) {
      assert.equal(holdingEligibility(workers.find(w=>w.id==='legacy'),{id:'r',workerId:'legacy',repairItemId},SLOT),'');
      assert.match(holdingEligibility(workers.find(w=>w.id==='cleared'),{id:'r',workerId:'cleared',repairItemId},SLOT),/未登记/);
    }
  } finally { store.close(); }
});

for (const actor of ['worker','admin'] as const) test(`skills cleared by ${actor}: preview returns sole-skill visit, preserves time and revokes old access`, async t => {
  const f=await fixture(t); await skills(f,'worker',['plumbing']);
  const row=await f.processing();
  const profile=await f.call('worker','GET','/worker/skills');
  const path=actor==='worker'?'/worker/skills':`/management/workers/${f.ids.worker}/skills`;
  const body={workforceRevision:profile.workforceRevision,skills:[]};
  const preview=await f.call(actor,'PUT',path,{...body,preview:true});
  if(actor==='admin') assert.deepEqual(ids(preview.returned),[row.id]);
  else {assert.equal(preview.returned.length,1);assert(!JSON.stringify(preview).includes('"id"'));}
  assert.equal(preview.returned[0].start,'2026-10-18T10:00:00+08:00');
  assert.equal(preview.returned[0].end,'2026-10-18T11:00:00+08:00');
  assert.equal(f.stored(row).status,2);
  await f.call(actor,'PUT',path,body);
  const saved=f.stored(row); assert.equal(saved.status,1);assert.equal(saved.workerId,'');
  assert.equal(saved.slot,row.slot);assert.equal(saved.agreedTime,row.agreedTime);
  assert.equal((await f.raw('worker','GET',`/worker/repairs/${row.id}`)).status,404);
  assert.equal((await f.call('admin','GET','/management/workforce-summary')).unregisteredCount,1);
});

test('dispatch: returned urgent order clears return flag and permits later shift', async t => {
  const f=await fixture(t);let row=await f.processing();await leave(f);row=await f.detail(row);
  assert.equal(f.stored(row).workforceReturned,true);
  row=await f.change('admin',row,'priority',{priority:'urgent',reason:'核实急单'});
  row=await f.change('admin',row,'dispatch',{workerId:f.ids.worker2,slot:SLOT});
  assert.equal(row.workforceReturned,false);assert.equal(row.assignmentSource,'admin');
  row=await f.change('admin',row,'shift',{slot:NEXT,reason:'协调顺延'});assert.equal(row.slot,NEXT);
});

test('shift: nobody can claim original slot, later staffed slot allows shift and claim; started slot rejects', async t => {
  const f=await fixture(t);await skills(f,'worker2',['doors']);let row=await f.processing();await leave(f);row=await f.detail(row);
  assert.match(f.stored(row).staffingIssue,/暂无/);
  row=await f.change('admin',row,'shift',{slot:NEXT,reason:'顺延到有人时段'});assert.equal(row.slot,NEXT);
  assert.deepEqual(ids(await pool(f)),[row.id]);
  row=await f.change('worker',row,'claim');assert.equal(row.workforceReturned,false);
  f.at(Date.parse('2026-10-18T11:00:00+08:00'));
  const profile=await f.call('worker','GET','/worker/skills');
  await f.call('admin','POST',`/management/workers/${f.ids.worker}/leave`,{revision:profile.workforceRevision,date:'2026-10-18',hour:'11'});
  row=await f.detail(row);
  const result=await f.raw('admin','PUT',`/management/repairs/${row.id}/shift`,{revision:row.revision,slot:'2026-10-18#14',reason:'顺延'});
  assert.equal(result.code,40001);assert.equal(result.message,'该时段已开始，请改派');
});

test('shortages: returned pair shares one worker, preview and task agree, claim closes aggregate and flags remainder', async t => {
  const f=await fixture(t);let a=await f.processing();f.at(START+1);const b=await f.processing(SLOT,'worker2');
  // 两位原师傅退出后只留一位替补，使用真实技能接口和休假接口。
  const id='10000000-0000-4000-8000-000000000003';
  f.store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,'19900000003','替补','worker')",id);
  f.store.run("INSERT INTO worker_skills VALUES (?,'plumbing')",id);
  await skills(f,'worker2',[]);
  const preview=await leave(f,true);
  assert.equal(preview.shortages.length,1);assert.equal(preview.shortages[0].shortage,1);
  assert.deepEqual(ids(preview.shortages[0].orders),ids([a,b]));
  await leave(f);let notes=shortageNotes(f);assert.equal(notes.length,1);assert.equal(notes[0]!.repairId,a.id);
  assert.match(String(notes[0]!.taskKey),/^pool_shortage:2026-10-18#10:/);
  assert.match(String(notes[0]!.body),/可能有 1 张/);
  assert.equal(f.stored(a).staffingIssue,'');assert.equal(f.stored(b).staffingIssue,'');
  const resident=await f.detail(a);assert(!JSON.stringify(resident).includes('poolShortage'));
  // 用现有 worker2 的合法会话作为替补，技能增加会把 M 降为 0；再移除临时替补。
  await skills(f,'worker2',['plumbing']);assert.equal(shortageNotes(f).length,0);
  f.store.run('DELETE FROM worker_skills WHERE workerId=?',id);
  await f.call('admin','GET','/management/repairs');notes=shortageNotes(f);assert.equal(notes.length,1);
  const workerPool=await pool(f,'worker2');assert(!JSON.stringify(workerPool).includes('poolShortage'));
  a=await f.change('worker2',await f.detail(a),'claim');assert.equal(a.workforceReturned,false);
  assert(!JSON.stringify(a).includes('poolShortage'));assert.equal(shortageNotes(f).length,0);
  assert.match(f.stored(b).staffingIssue,/暂无/);
  assert(f.store.one("SELECT id FROM notifications WHERE repairId=? AND taskKey LIKE 'unstaffed_offer:%' AND active=1",b.id));
  assert.equal(f.store.one("SELECT id FROM notifications WHERE repairId=? AND taskKey LIKE 'staffing:%' AND active=1",b.id),undefined);
  assert.equal(f.store.one("SELECT COUNT(*) AS n FROM notifications WHERE taskKey LIKE 'pool_shortage:%' AND role!='admin'")!.n,0);
});

test('shortages: sufficient workers or wholly impossible orders do not add aggregate deficit', () => {
  const workers:WorkerAvailability[]=[{id:'a',skills:['plumbing'],skillsKnown:true,leaves:[]},{id:'b',skills:['plumbing'],skillsKnown:true,leaves:[]}];
  const rows:RecordData[]=[{id:'p1',repairItemId:'1004',status:1,slot:SLOT},{id:'p2',repairItemId:'1004',status:1,slot:SLOT}];
  assert.deepEqual(new StaffingContext(workers,rows).shortages(),[]);
  assert.deepEqual(new StaffingContext(workers,[...rows,{id:'e',repairItemId:'1005',status:1,slot:SLOT}]).shortages(),[]);
  const shortage=new StaffingContext(workers.slice(0,1),rows).shortages()[0]!;
  assert.equal(shortage.shortage,1);assert.equal(shortage.matched,1);
});

test('shortages: skill preview includes unchanged pool orders and matching detects skill bottlenecks', async t => {
  const f=await fixture(t);const a=await f.create();const b=await f.create();
  const preview=await skills(f,'worker',['doors'],true);
  assert.deepEqual(preview.returned,[]);assert.equal(preview.shortages[0].shortage,1);
  assert.equal(preview.shortages[0].orders.length,2);assert(!JSON.stringify(preview).includes('"id"'));assert.equal(shortageNotes(f).length,0);
  await skills(f,'worker',['doors']);assert.equal(shortageNotes(f).length,1);
  const workers:WorkerAvailability[]=[
    {id:'p',skills:['plumbing'],skillsKnown:true,leaves:[]},
    ...['e1','e2','e3'].map(id=>({id,skills:['electrical'] as const,skillsKnown:true,leaves:[]})),
  ];
  const rows:RecordData[]=['1004','1004','1005','1005'].map((repairItemId,i)=>({id:`r${i}`,repairItemId,status:1,slot:SLOT}));
  const shortage=new StaffingContext(workers,rows).shortages()[0]!;
  assert.equal(shortage.orderCount,4);assert.equal(shortage.workerCount,4);
  assert.equal(shortage.matched,3);assert.equal(shortage.shortage,1);
});

test('shortages: assignment or shift closes aggregate without blocking a first proposal timeout', async t => {
  for (const action of ['assign','shift'] as const) {
    const f=await fixture(t);const first=await f.create();const second=await f.create();await leave(f);
    assert.equal(shortageNotes(f).length,1);
    const row=await f.detail(second);
    if(action==='assign'){
      const assigned=await f.change('admin',row,action,{workerId:f.ids.worker2});
      assert.equal(assigned.workforceReturned,false);assert.equal(assigned.assignmentSource,'admin');
    }
    else await f.change('admin',row,action,{slot:NEXT,reason:'协调人手'});
    assert.equal(shortageNotes(f).length,0);
    if(action==='shift')assert.equal(f.stored(first).staffingIssue ?? '','');
  }
  const f=await fixture(t);const pending=await f.create('');
  let first=await f.change('worker',pending,'claim',{slot:NEXT});
  await f.create();await f.create();await leave(f);assert.equal(shortageNotes(f).length,1);
  f.at(START+3*H);first=await f.detail(first);assert.equal(first.autoAccepted,true);
});

test('pool: scarce electrician is reserved; timed visibility respects skills, leave and occupied workers', async t => {
  const f = await fixture(t);
  await skills(f, 'worker', ['plumbing', 'electrical']); await skills(f, 'worker2', ['plumbing']);
  const p = await f.create(); const e = await f.create(SLOT, { repairItemId: '1005' });
  assert.deepEqual(ids(await pool(f)), [e.id]); assert.deepEqual(ids(await pool(f, 'worker2')), [p.id]);
  await f.change('worker', e, 'claim');
  assert.deepEqual(await pool(f), []);
  await f.change('worker2', p, 'claim');
  const free = await f.create('');
  assert.deepEqual(ids(await pool(f)), [free.id]); // 没时间只查技能
  await leave(f);
  assert(!ids(await pool(f)).includes(e.id));
});

test('pool: server whitelist excludes contacts, floor, door and photos and filters urgent/unrated/unclassified', async t => {
  const f = await fixture(t);
  const regular = await f.create('', { description: '漏水' });
  f.store.save('repairs', f.ids.resident, { ...f.stored(regular), houseInfo: '秘密 8层 888室', mobile: '13800138000',
    residentName: '私密姓名', floor: '8', room: '888', attachment: ['private-image'], timeline: [{ detail: 'secret' }] }, true);
  await f.create('', { repairItemId: '1003' });
  await f.create('', { urgentRequest: true });
  const urgent = await f.create(''); await f.change('admin', urgent, 'priority', { priority: 'urgent', reason: '急单' });
  const rows = await pool(f); assert.deepEqual(ids(rows), [regular.id]);
  assert.deepEqual(Object.keys(rows[0]!).sort(), ['id','revision','repairItemId','repairItemName','slot','agreedTime','community','building','description'].sort());
  assert.equal(rows[0]!.community, '测试小区'); assert.equal(rows[0]!.building, '1栋');
  assert(!JSON.stringify(rows).includes('private-image')); assert(!JSON.stringify(rows).includes('13800138000'));
  const assigned = await f.change('admin', await f.detail(regular), 'assign', { workerId: f.ids.worker });
  assert.deepEqual(await pool(f), []);
  await f.change('worker', assigned, 'release', { reason: '退回' });
  assert.deepEqual(ids(await pool(f)), [regular.id]);
});

test('claim: timed claim keeps appointment, returns worker contact and records one composed transition', async t => {
  const f = await fixture(t); const row = await f.create();
  const accepted = await f.change('worker', row, 'claim');
  assert.equal(accepted.status, 2); assert.equal(accepted.slot, SLOT); assert.equal(accepted.agreedTime, row.agreedTime);
  assert.equal((await f.detail(row)).workerMobile, '13800138002');
  assert.equal(accepted.timeline.at(-1).label, '师傅从列表接单');
  assert.deepEqual(accepted.timeline.slice(-3).map((event: Row) => event.action), ['assigned','accept','pool_claimed']);
});

test('claim: unscheduled claim requires slot and uses first proposal occupancy, resident agreement and timeout', async t => {
  const f = await fixture(t); let row = await f.create('');
  assert.equal((await f.raw('worker','PUT',`/worker/repairs/${row.id}/claim`,{revision:row.revision})).code,40001);
  const options = await f.call('worker','GET',`/repair/slots?date=2026-10-18&excludeId=${row.id}`);
  assert(options.slots.find((slot: Row) => slot.slot === SLOT).selectable);
  row = await f.change('worker', row, 'claim', { slot: SLOT });
  assert.equal(row.status,2); assert.equal(row.agreedTime,''); assert.equal(row.slot,SLOT);
  assert.equal(row.pendingSchedule.firstSchedule,true);
  row = await f.change('resident', row, 'reschedule', { accept: true }); assert(row.agreedTime);
  let second = await f.create(''); second = await f.change('worker2', second, 'claim', { slot: NEXT });
  f.at(START+3*H); second=await f.detail(second); assert.equal(second.autoAccepted,true);
});

test('claim: concurrent workers have one winner; assigned and ordinary revision conflicts stay distinct', async t => {
  const f = await fixture(t); const row = await f.create();
  const results = await Promise.all(['worker','worker2'].map(who => f.raw(who as 'worker'|'worker2','PUT',`/worker/repairs/${row.id}/claim`,{revision:row.revision})));
  assert.deepEqual(results.map(result=>result.status).sort(),[200,409]);
  assert.equal(results.find(result=>result.status===409)!.message,'已被其他师傅接走');
  const other=await f.create(NEXT); await f.change('admin',other,'assign',{workerId:f.ids.worker});
  assert.equal((await f.raw('worker2','PUT',`/worker/repairs/${other.id}/claim`,{revision:other.revision})).message,'物业已安排其他师傅');
  const stale=await f.create(''); await f.change('admin',stale,'priority',{priority:'light',reason:'已核实'});
  assert.equal((await f.raw('worker','PUT',`/worker/repairs/${stale.id}/claim`,{revision:stale.revision,slot:NEXT})).message,'记录已更新，请刷新后再操作');
});

test('return: leave preview is read-only, save matches preview and preserves time with previous-worker 404', async t => {
  const f = await fixture(t); const row=await f.processing(); const before=f.stored(row);
  const impact=await leave(f,true); assert.deepEqual(ids(impact.returned),[row.id]); assert.deepEqual(impact.property,[]);
  assert.deepEqual(f.stored(row),before); assert.equal(f.store.one('SELECT COUNT(*) AS n FROM worker_leaves')!.n,0);
  await leave(f); const latest=await f.detail(row);
  assert.equal(latest.status,1); assert.equal(latest.workerId,''); assert.equal(latest.slot,SLOT); assert.equal(latest.agreedTime,row.agreedTime);
  assert.equal(latest.staffingMessage,'原师傅临时有事，正在为您安排新师傅，上门时间不变');
  assert(!JSON.stringify(latest).includes('此时段正在休假')); assert(!Object.hasOwn(latest,'previousWorkers'));
  assert.equal((await f.raw('worker','GET',`/worker/repairs/${row.id}`)).status,404);
  assert.equal(f.stored(row).previousWorkers[0].workerId,f.ids.worker);
});

test('return: preview includes returned orders with no eligible replacement, for leave and skill revocation', async t => {
  const f=await fixture(t); const row=await f.processing();
  await skills(f,'worker2',['doors']);
  const before=f.stored(row);
  const preview=await leave(f,true);
  assert.deepEqual(ids(preview.returned),[row.id]); assert.deepEqual(ids(preview.property),[row.id]);
  assert.deepEqual(f.stored(row),before);
  await leave(f);
  assert.equal(f.stored(row).status,1); assert.match(f.stored(row).staffingIssue,/暂无/);
  const untimed=await f.create('');
  const assigned=await f.change('admin',untimed,'assign',{workerId:f.ids.worker});
  const profile=await f.call('worker','GET','/worker/skills');
  const path=`/management/workers/${f.ids.worker}/skills`;
  const body={workforceRevision:profile.workforceRevision,skills:['doors']};
  const revokePreview=await f.call('admin','PUT',path,{...body,preview:true});
  assert.deepEqual(ids(revokePreview.returned),[assigned.id]); assert.deepEqual(ids(revokePreview.property),[assigned.id]);
  await f.call('admin','PUT',path,body);
  assert.equal(f.stored(assigned).status,1); assert.match(f.stored(assigned).staffingIssue,/暂无/);
});

test('return: started visits stay assigned; near visits enter pool and property todo immediately', async t => {
  const f=await fixture(t); const row=await f.processing();
  f.at(Date.parse('2026-10-18T09:00:00+08:00'));
  const preview=await leave(f,true); assert.deepEqual(ids(preview.returned),[row.id]); assert.deepEqual(ids(preview.property),[row.id]);
  await leave(f); assert.equal(f.stored(row).status,1); assert.match(f.stored(row).staffingIssue,/不足 2 小时/);
  assert.deepEqual(ids(await pool(f,'worker2')),[row.id]);
  const accepted=await f.change('worker2',await f.detail(row),'claim');
  assert.equal(accepted.staffingIssue,'');
  f.at(Date.parse('2026-10-18T10:00:00+08:00'));
  const profile=await f.call('worker2','GET','/worker/skills');
  const body={revision:profile.workforceRevision,date:'2026-10-18',hour:'10'};
  const path=`/management/workers/${f.ids.worker2}/leave`;
  const impact=await f.call('admin','POST',path,{...body,preview:true});
  assert.deepEqual(impact.returned,[]); assert.deepEqual(ids(impact.property),[row.id]);
  await f.call('admin','POST',path,body); assert.equal(f.stored(row).status,2); assert.match(f.stored(row).staffingIssue,/休假/);
});

test('return: worker first proposal and other reschedules are voided, releases capacity and shows unscheduled message', async t => {
  const f=await fixture(t); let row=await f.create(''); row=await f.change('worker',row,'claim',{slot:SLOT});
  await leave(f); let latest=await f.detail(row);
  assert.equal(latest.slot,''); assert.equal(latest.pendingSchedule,null); assert.equal(latest.staffingMessage,'正在为您安排师傅');
  assert(latest.pendings[0].resolvedAt);
  latest=await f.change('worker2',latest,'claim',{slot:NEXT}); latest=await f.change('resident',latest,'reschedule',{accept:true});
  latest=await f.change('worker2',latest,'reschedule',{slot:'2026-10-18#14',reason:'改约',notified:true},'POST');
  await skills(f,'worker2',['doors']); latest=await f.detail(row);
  assert.equal(latest.slot,NEXT); assert(latest.pendings.at(-1).resolvedAt);
});

test('return: injected second-save failure rolls back leave, revisions and every affected repair', async t => {
  const f=await fixture(t); const first=await f.processing(); const second=await f.processing(NEXT);
  const profile=await f.call('worker','GET','/worker/skills'); const before=[f.stored(first),f.stored(second)];
  const save=f.store.save.bind(f.store); let writes=0;
  f.store.save=((...args: Parameters<typeof save>)=>{ if(args[0]==='repairs' && ++writes===2)throw new Error('injected'); return save(...args); }) as typeof save;
  try {
    const result=await f.raw('admin','POST',`/management/workers/${f.ids.worker}/leave`,{revision:profile.workforceRevision,date:'2026-10-18',hour:''});
    assert.equal(result.status,500);
  } finally { f.store.save=save; }
  assert.deepEqual([f.stored(first),f.stored(second)],before);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM worker_leaves')!.n,0);
  assert.equal((await f.call('worker','GET','/worker/skills')).workforceRevision,profile.workforceRevision);
});

test('fallback: one remaining worker may claim either order; the other becomes a task and added skill closes it', async t => {
  const f=await fixture(t); const a=await f.create(); const b=await f.create();
  await skills(f,'worker2',['doors']);
  assert.equal(f.stored(a).staffingIssue ?? '',''); assert.equal(f.stored(b).staffingIssue ?? '','');
  await f.change('worker',await f.detail(a),'claim'); assert.match(f.stored(b).staffingIssue,/暂无/);
  await skills(f,'worker2',['plumbing']); assert.equal(f.stored(b).staffingIssue,'');
  assert.deepEqual(ids(await pool(f,'worker2')),[b.id]);
});

test('fallback: unrelated impossible order neither blocks nor flags a normal pool order', async t => {
  const f=await fixture(t); await skills(f,'worker',['plumbing']); await skills(f,'worker2',['plumbing']);
  const impossible=await f.create(''); f.store.save('repairs',f.ids.resident,{...f.stored(impossible),slot:SLOT,repairItemId:'1005'},true);
  const normal=await f.create(); assert.deepEqual(ids(await pool(f)),[normal.id]);
  assert.equal(f.stored(normal).staffingIssue ?? '',''); assert.match(f.stored(impossible).staffingIssue,/暂无/);
  await f.change('worker',normal,'claim');
});

test('skills: self additions, removal preview, revision conflicts, authorization and property revocation share impact', async t => {
  const f=await fixture(t); await skills(f,'worker',['doors']); const row=await f.create('');
  assert.deepEqual(await pool(f),[]); await skills(f,'worker',['plumbing','doors']); assert.deepEqual(ids(await pool(f)),[row.id]);
  let accepted=await f.change('worker',row,'claim',{slot:SLOT});
  const preview=await skills(f,'worker',['doors'],true); assert.equal(preview.returned.length,1); assert(!JSON.stringify(preview).includes('"id"')); assert.equal(f.stored(row).status,2);
  const profile=await f.call('worker','GET','/worker/skills');
  await skills(f,'worker',['doors']); assert.equal(f.stored(row).status,1);
  assert.equal((await f.raw('worker','PUT','/worker/skills',{workforceRevision:profile.workforceRevision,skills:['plumbing']})).status,409);
  assert.equal((await f.raw('resident','GET','/worker/skills')).status,403);
  assert.equal((await f.raw('worker','PUT','/worker/skills',{workforceRevision:profile.workforceRevision,skills:[],workerId:f.ids.worker2})).code,40000);
  await skills(f,'worker',['plumbing','doors']); accepted=await f.change('worker',await f.detail(row),'claim',{slot:SLOT});
  const current=await f.call('worker','GET','/worker/skills'); const path=`/management/workers/${f.ids.worker}/skills`;
  const body={workforceRevision:current.workforceRevision,skills:['doors']};
  assert.deepEqual(ids((await f.call('admin','PUT',path,{...body,preview:true})).returned),[row.id]);
  await f.call('admin','PUT',path,body); assert.equal(f.stored(row).status,1);
  const worker=(await f.call('admin','GET','/management/workers')).find((item:Row)=>item.id===f.ids.worker);
  assert.equal(worker.skillChange.actorId,f.ids.admin);
  assert.equal((await f.raw('admin','PUT',path,{workforceRevision:worker.revision,skills:['doors','electrical']})).code,40001);
  assert.equal(accepted.status,2);
});

test('writes: unknown historical work allows two new matching reservations, third fails without increasing shortage', async t => {
  const f=await fixture(t); const unknown=await f.create('',{repairItemId:'1001'});
  f.store.save('repairs',f.ids.resident,{...f.stored(unknown),slot:SLOT},true);
  await f.create(); await f.create();
  assert.equal((await f.raw('resident','POST','/repair',{...f.body,slot:SLOT})).status,409);
});

test('writes: replacement worker cannot be consumed by a new reservation or urgent dispatch', async t => {
  const f=await fixture(t); await f.processing(); await leave(f);
  assert.equal((await f.raw('resident','POST','/repair',{...f.body,slot:SLOT})).status,409);
  let urgent=await f.create('',{urgentRequest:true}); urgent=await f.change('admin',urgent,'priority',{priority:'urgent',reason:'急单'});
  assert.equal((await f.raw('admin','PUT',`/management/repairs/${urgent.id}/dispatch`,{revision:urgent.revision,workerId:f.ids.worker2,slot:SLOT})).status,409);
});

// 独立穷举：不调用 requiredSkill、eligibility、staffingPlan 或被测匹配函数。
function exhaustive(records: RecordData[], workers: WorkerAvailability[]) {
  const skill=(row:RecordData)=>row.repairItemId==='1004'?'plumbing':row.repairItemId==='1005'?'electrical':row.repairItemId==='1002'?'doors':'';
  const absent=(worker:WorkerAvailability)=>worker.leaves.some(leave=>leave.date==='2026-10-18'&&(!leave.hour||leave.hour==='10'));
  const fixed=new Map<string,string>();
  for(const row of records) {
    const worker=workers.find(worker=>worker.id===row.workerId);
    if(worker&&!absent(worker)&&records.filter(other=>other.workerId===worker.id).length===1
      &&(!worker.skillsKnown||(worker.skills.length>0&&(!skill(row)||worker.skills.includes(skill(row) as 'plumbing')))))
      fixed.set(row.id,worker.id);
  }
  const remaining=records.filter(row=>!fixed.has(row.id)); let maximum=0;
  function enumerate(index:number,used:Set<string>,count:number) {
    if(index===remaining.length){maximum=Math.max(maximum,count);return;}
    enumerate(index+1,used,count);
    for(const worker of workers) if(!used.has(worker.id)&&!absent(worker)&&skill(remaining[index]!)&&worker.skills.includes(skill(remaining[index]!) as 'plumbing')) {
      used.add(worker.id); enumerate(index+1,used,count+1); used.delete(worker.id);
    }
  }
  enumerate(0,new Set(fixed.values()),fixed.size); return maximum;
}
function random(seed:number) { return ()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;}; }

test('matching oracle: 600 seeded exhaustive instances agree on new reservations, assignments and reassignments', () => {
  const rng=random(20261020), pick=(n:number)=>Math.floor(rng()*n);
  for(let instance=0;instance<600;instance++) {
    const workers:WorkerAvailability[]=Array.from({length:2+pick(3)},(_,i)=>{
      const skills=(['plumbing','electrical','doors'] as const).filter(()=>pick(2));
      const hasAudit=Boolean(pick(2));
      return {id:`w${i}`,skills,skillsKnown:skills.length>0||hasAudit,leaves:pick(4)===0?[{date:'2026-10-18',hour:pick(2)?'10':''}]:[]};
    });
    const rows:RecordData[]=Array.from({length:pick(6)},(_,i)=>({id:`r${i}`,status:2,slot:SLOT,repairItemId:['1004','1005','1002','1001'][pick(4)],workerId:pick(2)?workers[pick(workers.length)]!.id:''}));
    const candidate={id:'new',status:1,slot:SLOT,repairItemId:['1004','1005','1002'][pick(3)]};
    const allowed=exhaustive([...rows,candidate],workers)===exhaustive(rows,workers)+1;
    assert.equal(staffingRejection(rows,SLOT,workers,candidate)==='',allowed,`seed=20261020 instance=${instance}`);
    // 独立写入检查：不调用任何被测资格、冲突、匹配函数。每组都覆盖派单和改派。
    const admitted=(before:RecordData[],after:RecordData)=>{
      const worker=workers.find(item=>item.id===after.workerId);
      const skill=after.repairItemId==='1004'?'plumbing':after.repairItemId==='1005'?'electrical':after.repairItemId==='1002'?'doors':'';
      if(!worker||!skill||!worker.skills.includes(skill))return false;
      if(worker.leaves.some(item=>item.date==='2026-10-18'&&(!item.hour||item.hour==='10')))return false;
      if(before.some(item=>item.id!==after.id&&item.workerId===worker.id))return false;
      const next=[...before.filter(item=>item.id!==after.id),after];
      const added=before.some(item=>item.id===after.id)?0:1;
      return exhaustive(next,workers)>=exhaustive(before,workers)+added;
    };
    const pending={...candidate,id:'pending',workerId:''};
    const assignRows=[...rows,pending];
    const assigned={...pending,status:5,workerId:workers[pick(workers.length)]!.id};
    assert.equal(staffingRejection(assignRows,SLOT,workers,assigned)==='',admitted(assignRows,assigned),`assign instance=${instance}`);
    const oldWorker=pick(workers.length);
    const previous={...candidate,id:'assigned',status:2,workerId:workers[oldWorker]!.id};
    const reassignRows=[...rows,previous];
    const reassigned={...previous,workerId:workers[(oldWorker+1+pick(workers.length-1))%workers.length]!.id};
    assert.equal(staffingRejection(reassignRows,SLOT,workers,reassigned)==='',admitted(reassignRows,reassigned),`reassign instance=${instance}`);
  }
});

test('settlement: cached and per-record results are identical, including owner filters and invalidated slots', () => {
  const cached=new Store(':memory:'), plain=new Store(':memory:'); const rng=random(8945);
  try {
    for(const store of [cached,plain]) {
      store.run("INSERT INTO users(id,mobile,nickName) VALUES ('owner','18800000000','owner'),('other','18800000001','other')");
      for(let w=0;w<4;w++) {store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')",`w${w}`,`1990000000${w}`,`w${w}`);store.run('INSERT INTO worker_skills VALUES (?,?)',`w${w}`,w%2?'electrical':'plumbing');}
    }
    for(let i=0;i<65;i++) {
      const row:RecordData={id:`r${i}`,status:1,slot:i%2?SLOT:NEXT,repairItemId:rng()<.5?'1004':'1005',workerId:rng()<.5?`w${i%4}`:'',revision:1};
      if(i%7===0){row.status=2;row.pendings=[{id:`p${i}`,kind:'revoke',by:'resident',at:new Date(START).toISOString(),reason:'取消',deadline:new Date(START+H).toISOString()}];}
      for(const store of [cached,plain])store.save('repairs',i%2?'owner':'other',row);
    }
    const now=()=>START+3*H;
    const a=new RepairRepository(cached,now,()=>{},''),b=new RepairRepository(plain,now,()=>{},'');
    for(const filter of [{owner:'owner'},{}]) {
      a.settleAll(filter);
      const rows=filter.owner?plain.db.prepare('SELECT id FROM repairs WHERE userId=?').all(filter.owner):plain.db.prepare('SELECT id FROM repairs').all();
      for(const row of rows)b.settleOne(String(row.id));
      // 先比较业务结算，避免后续 settleAll 掩盖缓存与逐单结算的差异。
      const business=(payload:unknown)=>{
        const record=JSON.parse(String(payload)) as RecordData;
        ensureRounds(record); delete record.poolShortage; delete record.poolShortageIncident;
        if(record.rescheduleOffer) (record.rescheduleOffer as Row).id='generated-offer-id';
        return record;
      };
      for(const row of cached.db.prepare('SELECT id,payload FROM repairs').all()) assert.deepEqual(business(row.payload),
        business(plain.one('SELECT payload FROM repairs WHERE id=?',String(row.id))!.payload),`business record ${row.id}`);
      // 单条结算不计算跨单提示；在同一范围完成结算后同步聚合提示，再比较完整 payload。
      b.settleAll(filter);
      const normalized=(payload:unknown)=>{const record=JSON.parse(String(payload));if(record.rescheduleOffer)record.rescheduleOffer.id='generated-offer-id';return record;};
      for(const row of cached.db.prepare('SELECT id,payload FROM repairs').all()) assert.deepEqual(normalized(row.payload),
        normalized(plain.one('SELECT payload FROM repairs WHERE id=?',String(row.id))!.payload),`record ${row.id}`);
    }
  } finally {cached.close();plain.close();}
});

test('request budgets: slots, dispatch options, assignment options and pool each read workforce once', async t => {
  const f=await fixture(t); const row=await f.create(); let urgent=await f.create('',{urgentRequest:true});
  urgent=await f.change('admin',urgent,'priority',{priority:'urgent',reason:'急单'});
  const service=new RepairService(f.store,f.time,'4000000000');
  const repository=(service as unknown as {repository:RepairRepository}).repository;
  const read=repository.workerAvailability.bind(repository); let reads=0;
  repository.workerAvailability=()=>{reads++;return read();};
  const operations=[()=>service.slots(f.ids.resident,{date:'2026-10-18',excludeId:row.id}),
    ()=>service.dispatchOptions(f.ids.admin,urgent.id,{limit:77}),()=>service.assignmentOptions(f.ids.admin,row.id),()=>service.repairPool(f.ids.worker)];
  for(const operation of operations){reads=0;operation();assert.equal(reads,1);}
});

test('settlement owner filter includes another owners competing order and leaves it unsettled', async t => {
  const f=await fixture(t); const row=await f.create(); await skills(f,'worker2',['doors']);
  f.store.save('repairs',f.ids.other,{id:'foreign',status:2,slot:SLOT,workerId:f.ids.worker,repairItemId:'1004',revision:3});
  const before=f.store.get('repairs',f.ids.other,'foreign');
  await f.detail(row); assert.match(f.stored(row).staffingIssue,/暂无/);
  const repository=new RepairRepository(f.store,f.time,()=>{},''); repository.settleAll({owner:f.ids.resident});
  assert.match(f.stored(row).staffingIssue,/暂无/);
  assert.deepEqual(f.store.get('repairs',f.ids.other,'foreign'),before);
});

test('skills: injected settlement write failure rolls back skills and audit with returned orders', async t => {
  const f=await fixture(t); const row=await f.processing(); await skills(f,'worker2',['doors']);
  const before=f.stored(row), profile=await f.call('worker','GET','/worker/skills');
  const save=f.store.save.bind(f.store);let count=0;
  f.store.save=((...args:Parameters<typeof save>)=>{if(args[0]==='repairs'&&++count===2)throw new Error('settlement failure');return save(...args);}) as typeof save;
  try {assert.equal((await f.raw('worker','PUT','/worker/skills',{workforceRevision:profile.workforceRevision,skills:['doors']})).status,500);}
  finally {f.store.save=save;}
  assert.deepEqual(f.stored(row),before); assert.deepEqual(await f.call('worker','GET','/worker/skills'),profile);
});
