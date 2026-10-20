import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';
import { CommunityService } from '../src/community/service.js';
import { registerPhaseOneTests } from './repair-phase-one-cases.js';

export type ApiFixtureFactory = typeof fixture;
registerPhaseOneTests(fixture);

type Envelope = { code: number; data: any; message: string };

test('version one database migration preserves resident data and defaults role safely', async t => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-migration-'));
  const path = join(folder, 'database.sqlite');
  const original = await fixture(t, path);
  const session = await original.login();
  const house = await original.room(session.token);
  original.store.db.exec('DROP TABLE repair_capacity_weekdays; ALTER TABLE users DROP COLUMN role; PRAGMA user_version = 1;');
  await original.close();
  const migrated = await fixture(t, path);
  assert.equal(migrated.store.one('PRAGMA user_version')?.user_version, 7);
  assert.equal((await migrated.request('GET', '/userInfo', session.token)).data.role, 'resident');
  assert.equal((await migrated.request('GET', `/room/${house.record.id}`, session.token)).data.name, house.record.name);
  await migrated.close();
  rmSync(path);
  rmdirSync(folder);
});

test('property review: reject, edit and resubmit the same room, approve; stale and unauthorized reviews rejected', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const admin = await f.login('13800138090');
  f.store.run("UPDATE users SET role = 'admin' WHERE mobile = ?", '13800138090');
  const house = await f.room(resident.token);
  const path = `/management/rooms/${house.record.id}/review`;
  assert.equal((await f.request('GET','/management/rooms',resident.token)).status,403);
  assert.equal((await f.request('PUT',path,resident.token,{revision:1,decision:'approve'})).status,403);
  assert.notEqual((await f.request('PUT',path,admin.token,{revision:1,decision:'reject',reason:''})).code,10000);
  const rejected = await f.request('PUT',path,admin.token,{revision:1,decision:'reject',reason:'证件照片不清楚'});
  assert.equal(rejected.data.status,3);
  assert.equal((await f.request('GET',`/room/${house.record.id}`,resident.token)).data.reviewReason,'证件照片不清楚');
  const edited = await f.request('POST','/room',resident.token,{...house.body,id:house.record.id});
  assert.equal(edited.data.rows[0].status,1);
  assert.equal(edited.data.rows[0].reviewReason,'');
  assert.equal(edited.data.rows[0].id,house.record.id);
  assert.equal((await f.request('PUT',path,admin.token,{revision:1,decision:'approve'})).status,409);
  const approved = await f.request('PUT',path,admin.token,{revision:3,decision:'approve'});
  assert.equal(approved.data.status,2);
  assert.equal((await f.request('PUT',path,admin.token,{revision:4,decision:'reject',reason:'重复审核'})).code,40001);
});

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
  const created = await f.request('POST','/repair',resident.token,{houseId:house.record.id,repairItemId:'1004',mobile:'13800138000',slot:'2026-10-20#10',attachment:[house.body.idcardFrontUrl]});
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
  const body = {houseId:house.record.id,repairItemId:'1004',mobile:'13800138000',slot:'2026-10-20#10'};
  assert.equal((await f.request('POST','/repair',resident.token,{...body,attachment:Array(8).fill(house.body.idcardFrontUrl)})).code,10000);
  assert.notEqual((await f.request('POST','/repair',resident.token,{...body,attachment:Array(9).fill(house.body.idcardFrontUrl)})).code,10000);
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
async function fixture(t: TestContext, path = ':memory:', now: () => number = () => Date.parse('2026-10-17T00:00:00Z')) {
  const config = { ...readConfig({}), databasePath: path };
  const logs: object[] = [];
  const { app, store } = createApp(config, { now, log: event => logs.push(event) });
  // 此 API 契约套件包含同一时段 23 条分页数据；提供足够的真实可匹配人手。
  // 专门的排单套件使用两个师傅，独立验证人手不足与并发。
  for (let i = 0; i < 24; i++) {
    const id = `pagination-worker-${i}`;
    store.run("INSERT OR IGNORE INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')", id, `199000001${String(i).padStart(2, '0')}`, `预备师傅${i}`);
    store.run("INSERT OR IGNORE INTO worker_skills(workerId,skill) VALUES (?,'plumbing')", id);
  }
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const base = `http://127.0.0.1:${address.port}`;
  let closed = false;
  async function close() {
    if (closed) return;
    closed = true;
    await new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
      server.closeIdleConnections();
    });
    store.close();
  }
  t.after(close);
  async function request(method: string, path: string, token?: string, body?: unknown) {
    const response = await fetch(base + path, { method, headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, ...(await response.json() as Envelope) };
  }
  async function login(mobile = '13800138000') {
    const code = await request('GET', `/code?mobile=${mobile}`);
    assert.equal(code.code, 10000);
    assert.equal(code.data.development, true);
    const login = await request('POST', '/login', undefined, { mobile, code: code.data.code });
    assert.equal(login.code, 10000);
    if (['13800138091','13800138092'].includes(mobile)) {
      const id = String(store.one('SELECT id FROM users WHERE mobile=?', mobile)!.id);
      store.run("INSERT OR IGNORE INTO worker_skills(workerId,skill) VALUES (?,'plumbing')", id);
    }
    return login.data as { token: string; refreshToken: string };
  }
  async function upload(token: string) {
    const image = await sharp({ create: { width: 8, height: 8, channels: 3, background: '#7654a1' } }).png().toBuffer();
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(image)]), 'example.png');
    const response = await fetch(base + '/upload', { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: form });
    const body = await response.json() as Envelope;
    assert.equal(body.code, 10000);
    return String(body.data.url);
  }
  const roomBody = (url: string) => ({ point: '学习小区', building: '1栋', room: '101', name: '张三', gender: 1,
    mobile: '13800138000', idcardFrontUrl: url, idcardBackUrl: url });
  async function room(token: string) {
    const url = await upload(token);
    const body = roomBody(url);
    const response = await request('POST', '/room', token, body);
    assert.equal(response.code, 10000);
    assert.equal(response.data.complete, true);
    return { record: response.data.rows[0], body };
  }
  return { base, config, store, request, login, upload, room, roomBody, logs, close };
}

test('optional floors round trip through HTTP and invalid floors explain the error', async t => {
  const f = await fixture(t);
  const session = await f.login();
  const url = await f.upload(session.token);
  const body = f.roomBody(url);
  const created = await f.request('POST', '/room', session.token, { ...body, floor: '63' });
  assert.equal(created.code, 10000);
  const id = created.data.rows[0].id;
  assert.equal((await f.request('GET', `/room/${id}`, session.token)).data.floor, '63');
  const repair = await f.request('POST', '/repair', session.token, {
    houseId: id, repairItemId: '1004', mobile: '13800138000', slot: '2026-10-20#10',
  });
  assert.equal(repair.code, 10000);
  assert.equal(repair.data.rows[0].houseInfo, '学习小区 1栋 63层 101');
  const visitor = await f.request('POST', '/visitor', session.token, {
    houseId: id, name: '访客', gender: 1, mobile: '13800138000', visitDate: '2026-10-20',
  });
  assert.equal(visitor.code, 10000);
  assert.equal(visitor.data.rows[0].houseInfo, '学习小区 1栋 63层 101');
  for (const floor of ['100', 'B1', '']) {
    const edited = await f.request('POST', '/room', session.token, { ...body, id, floor });
    assert.equal(edited.code, 10000);
    assert.equal(edited.data.rows[0].floor, floor);
    assert.equal((await f.request('GET', '/room', session.token)).data[0].floor, floor);
  }
  for (const floor of ['0', 'abc', 'B0', '-1', '10000']) {
    const invalid = await f.request('POST', '/room', session.token, { ...body, id, floor });
    assert.equal(invalid.code, 40000);
    assert.equal(invalid.message, '请输入有效楼层，例如33、100或B1');
    assert.equal((await f.request('GET', `/room/${id}`, session.token)).data.floor, '');
  }
  const legacy = await f.request('POST', '/room', session.token, body);
  assert.equal(legacy.code, 10000, 'older clients may omit floor');
});

test('room accepts English owner names through the HTTP API', async t => {
  const f = await fixture(t);
  const session = await f.login();
  const url = await f.upload(session.token);
  for (const name of ['John Smith', "O'Neil", 'Anne-Marie']) {
    const response = await f.request('POST', '/room', session.token, {
      ...f.roomBody(url), name,
    });
    assert.equal(response.code, 10000);
    assert(response.data.rows.some((row: { name: string }) => row.name === name));
  }
});

test('English owner names are unique across accounts; Chinese names may repeat', async t => {
  const f = await fixture(t);
  const a = await f.login();
  const b = await f.login('13800138001');
  const aUrl = await f.upload(a.token);
  const bUrl = await f.upload(b.token);
  const aBody = { ...f.roomBody(aUrl), name: 'John  Smith' };
  const bBody = { ...f.roomBody(bUrl), name: ' john smith ' };

  const first = await f.request('POST', '/room', a.token, aBody);
  assert.equal(first.code, 10000);
  const firstId = first.data.rows[0].id;
  const duplicate = await f.request('POST', '/room', b.token, bBody);
  assert.equal(duplicate.code, 40002);
  assert.equal(duplicate.message, '该英文姓名已被登记，请更换姓名');
  assert.deepEqual((await f.request('GET', '/room', b.token)).data, []);

  const edited = await f.request('POST', '/room', a.token, { ...aBody, id: firstId, room: '102' });
  assert.equal(edited.code, 10000, 'editing a record must not conflict with itself');

  const chineseA = await f.request('POST', '/room', a.token, { ...aBody, name: '张三' });
  const chineseB = await f.request('POST', '/room', b.token, { ...bBody, name: '张三' });
  assert.equal(chineseA.code, 10000);
  assert.equal(chineseB.code, 10000);

  const mixedA = await f.request('POST', '/room', a.token, { ...aBody, name: '李John' });
  const mixedB = await f.request('POST', '/room', b.token, { ...bBody, name: '李john' });
  assert.equal(mixedA.code, 10000);
  assert.equal(mixedB.code, 40002, 'names containing Latin letters use the English rule');

  await f.request('DELETE', `/room/${firstId}`, a.token);
  const reused = await f.request('POST', '/room', b.token, bBody);
  assert.equal(reused.code, 10000, 'deleting a record releases its English name');
});

test('validation errors identify the invalid house field', async t => {
  const f = await fixture(t);
  const session = await f.login();
  const missingCommunity = await f.request('POST', '/room', session.token, {
    point: '', building: '1栋', room: '101', name: '张三', gender: 1,
    mobile: '13800138000', idcardFrontUrl: 'bad', idcardBackUrl: 'bad',
  });
  assert.equal(missingCommunity.message, '小区不能为空');

  const invalidPhoto = await f.request('POST', '/room', session.token, {
    point: '学习小区', building: '1栋', room: '101', name: '张三', gender: 1,
    mobile: '13800138000', idcardFrontUrl: 'bad', idcardBackUrl: 'bad',
  });
  assert.equal(invalidPhoto.message, '身份证正面照片无效，请重新上传');
});

test('login codes are single use, expire, enforce cooldown and attempt limit; sessions rotate', async t => {
  let now = Date.now();
  const f = await fixture(t, ':memory:', () => now);
  const first = await f.request('GET', '/code?mobile=13800138000');
  assert.equal((await f.request('GET', '/code?mobile=13800138000')).status, 429);
  const credentials = { mobile: '13800138000', code: first.data.code };
  const session = (await f.request('POST', '/login', undefined, credentials)).data;
  assert.notEqual((await f.request('POST', '/login', undefined, credentials)).code, 10000);
  assert.equal((await f.request('GET', '/userInfo', session.token)).code, 10000);
  now += 31 * 60_000;
  assert.equal((await f.request('GET', '/userInfo', session.token)).status, 401);
  const rotated = await f.request('POST', '/refreshToken', session.refreshToken);
  assert.equal(rotated.code, 10000);
  assert.equal((await f.request('GET', '/userInfo', rotated.data.token)).code, 10000);
  assert.equal((await f.request('POST', '/refreshToken', session.refreshToken)).status, 401);
  const expired = await f.request('GET', '/code?mobile=13800138001');
  now += 301_000;
  assert.notEqual((await f.request('POST', '/login', undefined, { mobile: '13800138001', code: expired.data.code })).code, 10000);
  const attempts = await f.request('GET', '/code?mobile=13800138002');
  for (let i = 0; i < 5; i++) await f.request('POST', '/login', undefined,
    { mobile: '13800138002', code: attempts.data.code === '000000' ? '111111' : '000000' });
  assert.notEqual((await f.request('POST', '/login', undefined, { mobile: '13800138002', code: attempts.data.code })).code, 10000);
  assert(!JSON.stringify(f.logs).includes(session.token));
  assert(!JSON.stringify(f.logs).includes('13800138000'));
});

test('room writes return full authoritative lists, enforce ownership and preserve restart data', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-server-test-'));
  // 单个已知临时目录；清理安排在服务关闭之后。
  const f = await fixture(t, join(directory, 'test.sqlite'));
  const a = await f.login();
  const b = await f.login('13800138001');
  const { record, body } = await f.room(a.token);
  const edited = await f.request('POST', '/room', a.token, { ...body, id: record.id, room: '102' });
  assert.equal(edited.data.rows[0].room, '102');
  assert.equal(edited.data.total, 1);
  assert.equal((await f.request('GET', `/room/${record.id}`, b.token)).status, 404);
  assert.equal((await f.request('POST', '/room', b.token, { ...body, id: record.id })).status, 404);
  assert.equal((await f.request('DELETE', `/room/${record.id}`, b.token)).status, 404);
  assert.notEqual((await f.request('POST', '/room', b.token, body)).code, 10000, 'another account cannot bind the uploaded image');
  assert.deepEqual((await f.request('GET', '/room', b.token)).data, []);
  await f.close();
  const reopened = await fixture(t, join(directory, 'test.sqlite'));
  const persisted = await reopened.request('GET', '/room', a.token);
  assert.equal(persisted.data[0].room, '102');
  const deleted = await reopened.request('DELETE', `/room/${record.id}`, a.token);
  assert.deepEqual(deleted.data, { complete: true, rows: [], total: 0 });
  await reopened.close();
  rmSync(directory, { recursive: true });
});

test('repair creation returns all rows beyond a page, cancellation updates status and isolates accounts', async t => {
  const f = await fixture(t);
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
  const cancelled = await f.request('PUT', `/cancel/repair/${record.id}`, a.token);
  assert.equal(cancelled.data.rows[0].status, 0);
  assert.equal(cancelled.data.rows.length, 23);
  assert.notEqual((await f.request('PUT', `/cancel/repair/${record.id}`, a.token)).code, 10000);
  assert.notEqual((await f.request('POST', '/repair', a.token, { ...body, appointment: '2026-02-30' })).code, 10000);
});

test('visitor, profile, announcement and upload contracts are usable by the app', async t => {
  const f = await fixture(t);
  const a = await f.login();
  const b = await f.login('13800138001');
  const { record: house, body } = await f.room(a.token);
  const visitor = await f.request('POST', '/visitor', a.token, { houseId: house.id, name: '李四', gender: 0,
    mobile: '13800138001', visitDate: '2026-10-20' });
  assert.equal(visitor.code, 10000);
  assert.equal(visitor.data.total, 1);
  assert.equal(visitor.data.rows[0].status, 1);
  assert.equal((await f.request('GET', `/visitor/${visitor.data.rows[0].id}`, b.token)).status, 404);
  const png = await fetch(f.base + new URL(visitor.data.rows[0].url).pathname);
  assert.equal(png.headers.get('content-type'), 'image/png');
  assert.deepEqual([...new Uint8Array(await png.arrayBuffer()).slice(0, 4)], [137, 80, 78, 71]);
  const profile = await f.request('PUT', '/userInfo', a.token, { nickName: '测试用户', avatar: body.idcardFrontUrl });
  assert.equal(profile.data.nickName, '测试用户');
  assert(profile.data.id);
  assert.equal((await f.request('GET', '/announcement')).data.length, 1);
  assert.equal((await f.request('GET', '/announcement/local-welcome')).code, 10000);
  assert.equal((await f.request('GET', '/repairItem', a.token)).data.length, 4);
});

test('mutation rolls back if constructing the returned full list fails', async t => {
  const f = await fixture(t);
  const a = await f.login();
  const profile = await f.request('GET', '/userInfo', a.token);
  const { body } = await f.room(a.token);
  const service = new CommunityService(f.store, f.config.publicBaseUrl);
  const list = f.store.list.bind(f.store);
  f.store.list = () => { throw new Error('injected read failure'); };
  assert.throws(() => service.saveRoom(profile.data.id, body), /injected read failure/);
  f.store.list = list;
  assert.equal((await f.request('GET', '/room', a.token)).data.length, 1);
});

test('rejects unauthenticated writes, malformed uploads, invalid JSON and disallowed browser origins', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('POST', '/room', undefined, {})).status, 401);
  assert.equal((await f.request('GET', '/code?mobile=invalid')).code, 40000);
  const a = await f.login();
  const form = new FormData();
  form.append('file', new Blob(['not an image']), 'fake.png');
  const upload = await fetch(f.base + '/upload', { method: 'POST', headers: { Authorization: `Bearer ${a.token}` }, body: form });
  assert.notEqual((await upload.json() as Envelope).code, 10000);
  const json = await fetch(f.base + '/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{' });
  assert.equal(json.status, 400);
  const forbidden = await fetch(f.base + '/health', { headers: { Origin: 'https://untrusted.example' } });
  assert.equal(forbidden.status, 403);
  const allowed = await fetch(f.base + '/health', { headers: { Origin: 'http://localhost:8080' } });
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'http://localhost:8080');
  const preflight = await fetch(f.base + '/repair', { method: 'OPTIONS', headers: { Origin: 'http://localhost:8080', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'authorization,content-type' } });
  assert.equal(preflight.status, 204);
  assert.throws(() => readConfig({ NODE_ENV: 'production' }), /生产/);
});
