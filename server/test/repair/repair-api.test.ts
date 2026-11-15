import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from '../helpers/api-fixture.js';

test('one repair flows through assignment, worker acceptance and completion with revision and ownership checks', async t => {
  const f = await fixture(t, ':memory:', () => Date.parse('2026-10-17T00:00:00Z'));
  const resident = await f.login();
  const admin = await f.login('13800138090');
  f.store.run("UPDATE users SET role = 'admin' WHERE mobile = ?", '13800138090');
  const createdWorkers = await f.request('POST','/management/workers',admin.token,{mobile:'13800138091',nickName:'张师傅'});
  assert.equal(createdWorkers.code,10000);
  const workerId = createdWorkers.data.find((worker: any) => worker.mobile === '13800138091').id;
  const worker = await f.login('13800138091');
  assert.equal((await f.request('PUT','/worker/skills',worker.token,{workforceRevision:0,skills:['plumbing']})).code,10000);
  assert.equal((await f.request('GET','/userInfo',worker.token)).data.role,'worker');
  const other = await f.login('13800138092');
  f.store.run("UPDATE users SET role = 'worker' WHERE mobile = ?", '13800138092');
  const house = await f.room(resident.token);
  const repairPhoto = await f.upload(resident.token);
  const created = await f.request('POST','/repair',resident.token,{houseId:house.record.id,repairItemId:'1004',mobile:'13800138000',slot:'2026-10-20#10',attachment:[repairPhoto]});
  const id = created.data.rows[0].id;
  const assign = `/management/repairs/${id}/assign`;
  assert.equal((await f.request('PUT',assign,worker.token,{revision:1,workerId})).status,403);
  assert.equal((await f.request('GET','/worker/repairs',resident.token)).status,403);
  const assigned = await f.request('PUT',assign,admin.token,{revision:1,workerId});
  assert.equal(assigned.data.status,5);
  assert.equal(assigned.data.id,id);
  assert.equal((await f.request('PUT',assign,admin.token,{revision:1,workerId})).status,409);
  assert.equal((await f.request('GET','/worker/repairs',other.token)).data.length,0);
  assert.equal((await f.request('GET',`/worker/repairs/${id}`,other.token)).status,404);
  assert.equal((await f.request('PUT',`/worker/repairs/${id}/accept`,other.token,{revision:2})).status,404);
  assert.notEqual((await f.request('PUT',`/worker/repairs/${id}/complete`,worker.token,{revision:2})).code,10000);
  const accepted = await f.request('PUT',`/worker/repairs/${id}/accept`,worker.token,{revision:2,time:'2026-10-20T10:00:00+08:00',reason:'旧单补充具体时间'});
  assert.equal(accepted.data.status,2);
  assert.equal((await f.request('PUT',assign,admin.token,{revision:3,workerId})).code,40001);
  for (const body of [{ revision: 3 }, { revision: 3, result: '' }, { revision: 3, result: '   \n  ' }]) {
    const rejected = await f.request('PUT', `/worker/repairs/${id}/complete`, worker.token, body);
    assert.equal(rejected.code, 40001);
    assert.equal(rejected.message, '请填写处理结果后再完成维修');
    const unchanged = await f.request('GET', `/worker/repairs/${id}`, worker.token);
    assert.equal(unchanged.data.status, 2);
    assert.equal(unchanged.data.revision, 3);
    assert.deepEqual(unchanged.data.timeline.map((event:any) => event.action), ['submitted', 'assigned', 'accept']);
  }
  const completed = await f.request('PUT',`/worker/repairs/${id}/complete`,worker.token,{revision:3,result:'已修复漏水'});
  assert.equal(completed.data.status,6);
  const detail = await f.request('GET',`/repair/${id}`,resident.token);
  assert.equal(detail.data.completionNote,'已修复漏水');
  assert.equal(detail.data.workerName,'张师傅');
  assert.deepEqual(detail.data.timeline.map((event:any)=>event.action),['submitted','assigned','accept','complete']);
  assert.equal(detail.data.attachment.length,1);
  const staleCompletion = await f.request('PUT',`/worker/repairs/${id}/complete`,worker.token,{revision:3,result:'重复提交完工'});
  assert.equal(staleCompletion.status,409,`stale completion code=${staleCompletion.code} message=${staleCompletion.message}`);
});

test('repair photos enforce eight and ownership; public profile cannot escalate roles', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const other = await f.login('13800138001');
  const house = await f.room(resident.token);
  const foreign = await f.upload(other.token);
  const body = {houseId:house.record.id,repairItemId:'1004',mobile:'13800138000'};
  const repairPhoto = await f.upload(resident.token);
  assert.equal((await f.request('POST','/repair',resident.token,{...body,attachment:Array(8).fill(repairPhoto)})).code,10000);
  assert.notEqual((await f.request('POST','/repair',resident.token,{...body,attachment:Array(9).fill(repairPhoto)})).code,10000);
  assert.notEqual((await f.request('POST','/repair',resident.token,{...body,attachment:[foreign]})).code,10000);
  assert.notEqual((await f.request('PUT','/userInfo',resident.token,{nickName:'伪造管理员',avatar:'',role:'admin'})).code,10000);
  assert.equal((await f.request('GET','/userInfo',resident.token)).data.role,'resident');
  const page=await fetch(f.base+'/admin/');
  assert.equal(page.status,200);
  assert.match(await page.text(),/物业登录/);
});

test('reassignment revokes previous worker access and old version acceptance', async t => {
  const f=await fixture(t);
  const resident=await f.login();
  const admin=await f.login('13800138090');
  f.store.run("UPDATE users SET role='admin' WHERE mobile='13800138090'");
  const a=await f.request('POST','/management/workers',admin.token,{mobile:'13800138091',nickName:'张师傅'});
  const workerA=a.data[0].id;
  const b=await f.request('POST','/management/workers',admin.token,{mobile:'13800138092',nickName:'李师傅'});
  const workerB=b.data.find((r:any)=>r.mobile==='13800138092').id;
  const tokenA=await f.login('13800138091');
  const tokenB=await f.login('13800138092');
  for(const session of [tokenA,tokenB]) assert.equal((await f.request('PUT','/worker/skills',session.token,{workforceRevision:0,skills:['plumbing']})).code,10000);
  const house=await f.room(resident.token);
  const created=await f.request('POST','/repair',resident.token,{houseId:house.record.id,repairItemId:'1004',mobile:'13800138000',slot:'2026-10-20#10'});
  const id=created.data.rows[0].id;
  await f.request('PUT',`/management/repairs/${id}/assign`,admin.token,{revision:1,workerId:workerA});
  const reassigned=await f.request('PUT',`/management/repairs/${id}/assign`,admin.token,{revision:2,workerId:workerB});
  assert.equal(reassigned.data.workerId,workerB);
  assert.equal((await f.request('PUT',`/worker/repairs/${id}/accept`,tokenA.token,{revision:2})).status,404);
  assert.equal((await f.request('GET','/worker/repairs',tokenA.token)).data.length,0);
});

test('repair creation returns all rows beyond a page, cancellation updates status and isolates accounts', async t => {
  const f = await fixture(t);
  // 仅此用例同一时段创建 23 条记录，按需准备人手，避免排班约束干扰分页断言。
  for (let i = 0; i < 23; i++) {
    const id = `pagination-worker-${i}`;
    f.store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')", id, `199000001${String(i).padStart(2, '0')}`, `预备师傅${i}`);
    f.store.run("INSERT INTO worker_skills(workerId,skill) VALUES (?,'plumbing')", id);
  }
  const a = await f.login();
  const b = await f.login('13800138001');
  const { record: house } = await f.room(a.token);
  const body = { houseId: house.id, repairItemId: '1004', mobile: '13800138000', slot: '2026-10-20#10', attachment: [] };
  let response: any;
  for (let i = 0; i < 23; i++) {
    response = await f.request('POST', '/repair', a.token, { ...body, description: `记录${i}` });
    assert.equal(response.code, 10000);
    assert.equal(response.data.total, i + 1);
    assert.equal(response.data.rows.length, i + 1);
  }
  assert.equal(response.data.rows[0].description, '记录22');
  const record = response.data.rows[0];
  assert.equal((await f.request('GET', '/repair?current=2&pageSize=20', a.token)).data.rows.length, 3);
  assert.equal((await f.request('POST', '/repair', b.token, body)).status, 404);
  assert.equal((await f.request('GET', `/repair/${record.id}`, b.token)).status, 404);
  assert.equal((await f.request('PUT', `/cancel/repair/${record.id}`, b.token)).status, 404);
  const current = (await f.request('GET', `/repair/${record.id}`, a.token)).data;
  const cancelled = await f.request('PUT', `/cancel/repair/${record.id}`, a.token, { revision: current.revision });
  assert.equal(cancelled.data.rows[0].status, 0);
  assert.equal(cancelled.data.rows.length, 23);
  assert.notEqual((await f.request('PUT', `/cancel/repair/${record.id}`, a.token)).code, 10000);
  assert.notEqual((await f.request('POST', '/repair', a.token, { ...body, appointment: '2026-02-30' })).code, 10000);
});
