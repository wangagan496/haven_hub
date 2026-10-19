import test from 'node:test';
import assert from 'node:assert/strict';
import { constants, generateKeyPairSync, verify } from 'node:crypto';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/database.js';
import { MAX_ATTEMPTS, Notifications, validatePushEndpoint } from '../src/notifications.js';
import { createPushTransport, huaweiJwt, huaweiResult, type PushTransport, type PushMessage, type PushResult } from '../src/push-transport.js';
import { createApp, pushRootCandidates } from '../src/app.js';
import { readConfig } from '../src/config.js';
import { RepairService } from '../src/repair-service.js';

function fixture() {
  let now = Date.parse('2026-10-17T00:00:00Z');
  const store = new Store(':memory:');
  for (const [id,mobile,role] of [['resident','13800000001','resident'],['worker','13800000002','worker'],['admin','13800000003','admin'],['other','13800000004','resident']]) {
    store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)',id!,mobile!,id!,role!);
  }
  const sent: PushMessage[] = [];
  let result: PushResult = { status: 'accepted', reason: '服务接受' };
  const transport: PushTransport = { publicConfig: () => ({webPublicKey:'test',harmonyConfigured:false}),
    send: async (_device,message) => {sent.push(message);return result;} };
  const notes = new Notifications(store,transport,()=>now);
  store.onRepairSaved = (owner,record)=>notes.sync(owner,record);
  const record = {id:'repair-1',status:6,workerId:'worker',rounds:[{number:1}],pendings:[]};
  return { store,notes,sent,record,transport,advance:(ms=60001)=>{now+=ms;},fail:()=>{result={status:'failed',reason:'失败'};},succeed:()=>{result={status:'accepted',reason:'服务接受'};} };
}

test('repair write atomically persists one task; viewing never confirms it; completion resolves it',async()=>{
  const f=fixture();
  try {
    f.store.save('repairs','resident',f.record);
    f.store.save('repairs','resident',f.record,true);
    const list=f.notes.list('resident');
    assert.equal(list.length,1); assert.equal(list[0]!.active,1);
    f.notes.read('resident',String(list[0]!.id));
    assert.equal(f.notes.list('resident')[0]!.active,1);
    assert.throws(()=>f.notes.read('other',String(list[0]!.id)),/不属于/);
    f.store.save('repairs','resident',{...f.record,status:3},true);
    assert.equal(f.notes.list('resident')[0]!.active,0);
    assert.throws(()=>f.store.transaction(()=>{f.store.save('repairs','resident',{...f.record,id:'rollback'});throw Error('rollback');}));
    assert.equal(f.store.one('SELECT id FROM notifications WHERE repairId=?','rollback'),undefined);
  } finally {await f.notes.stop();f.store.close();}
});

test('retry queue persists failed attempts and accepts without claiming delivery',async()=>{
  const f=fixture();
  try {
    f.notes.register('resident',{platform:'harmony',token:'device-token',installationId:'a'.repeat(64)});
    f.store.save('repairs','resident',f.record);
    f.fail();await f.notes.dispatch();
    assert.equal(f.notes.list('resident')[0]!.deliveries[0]!.status,'failed');
    await f.notes.dispatch();assert.equal(f.sent.length,1);
    f.advance();f.succeed();await f.notes.dispatch();
    assert.equal(f.notes.list('resident')[0]!.deliveries[0]!.status,'accepted');
    assert.equal(f.sent.length,2);
    f.notes.remind('worker','repair-1');
    assert.equal(f.notes.list('resident').length,1);
    assert.throws(()=>f.notes.remind('worker','repair-1'),/一分钟/);
    assert.throws(()=>f.notes.remind('other','repair-1'),/无权/);
  } finally {await f.notes.stop();f.store.close();}
});

test('account switch removes stale queue and revoked installation cannot receive new sends',async()=>{
  const f=fixture();
  try {
    const registration={platform:'harmony',token:'same-device',installationId:'b'.repeat(64)};
    f.notes.register('resident',registration);
    f.store.save('repairs','resident',f.record);
    f.notes.register('other',registration);
    await f.notes.dispatch();assert.equal(f.sent.length,0);
    f.notes.register('resident',registration);
    f.notes.unregister({installationId:registration.installationId});
    await f.notes.dispatch();assert.equal(f.sent.length,0);
  } finally {await f.notes.stop();f.store.close();}
});

test('task recipients follow assignment reschedule and aftersale ownership',async()=>{
  const f=fixture();
  try {
    f.store.save('repairs','resident',{...f.record,status:5});
    assert.equal(f.notes.list('worker').filter(n=>n.active).length,1);
    f.store.save('repairs','resident',{...f.record,status:2,pendings:[{id:'change',kind:'reschedule',by:'worker',at:'today',reason:'new time'}]},true);
    assert.equal(f.notes.list('worker').filter(n=>n.active).length,0);
    assert.equal(f.notes.list('resident').filter(n=>n.active).length,1);
    f.store.save('repairs','resident',{...f.record,status:3,pendings:[{id:'after',kind:'aftersale',by:'resident',at:'today',reason:'leak'}]},true);
    assert.equal(f.notes.list('admin').filter(n=>n.active).length,1);
    assert.equal(f.notes.list('resident').filter(n=>n.active).length,0);
  } finally {await f.notes.stop();f.store.close();}
});

test('Web Push endpoint rejects SSRF and deceptive provider suffixes',()=>{
  for(const endpoint of ['http://localhost/push','https://127.0.0.1/push','https://evilnotify.windows.com/push','https://fcm.googleapis.com.evil.test/push','https://user:pass@fcm.googleapis.com/push'])assert.throws(()=>validatePushEndpoint(endpoint));
  validatePushEndpoint('https://wns2-par02p.notify.windows.com/w/?token=opaque');
});

test('token rotation while another device sends skips its stale snapshot',async()=>{
  const f=fixture();
  let release!: (result: PushResult) => void;
  const first = new Promise<PushResult>(resolve => { release=resolve; });
  const tokens: string[]=[];
  f.transport.send=async device=>{tokens.push(device.platform==='harmony'?device.token:'web');return tokens.length===1?first:{status:'accepted',reason:'accepted'};};
  try {
    f.notes.register('resident',{platform:'harmony',token:'one',installationId:'d'.repeat(64)});
    f.notes.register('resident',{platform:'harmony',token:'old',installationId:'e'.repeat(64)});
    f.store.save('repairs','resident',f.record);
    const dispatch=f.notes.dispatch();
    f.notes.register('resident',{platform:'harmony',token:'new',installationId:'e'.repeat(64)});
    release({status:'accepted',reason:'accepted'});await dispatch;
    assert.deepEqual(tokens,['one']);
    await f.notes.dispatch();assert.deepEqual(tokens,['one','new']);
  } finally {await f.notes.stop();f.store.close();}
});

test('late expired result cannot remove a newly registered device or overwrite its queue',async()=>{
  const f=fixture();
  let release!: (result: PushResult) => void;
  f.transport.send=()=>new Promise(resolve=>{release=resolve;});
  try {
    const device={platform:'harmony',token:'same',installationId:'f'.repeat(64)};
    f.notes.register('resident',device);f.store.save('repairs','resident',f.record);
    const dispatch=f.notes.dispatch();
    f.notes.unregister({installationId:device.installationId});
    f.notes.register('resident',device);
    release({status:'expired',reason:'old expired'});await dispatch;
    assert.equal(f.notes.list('resident')[0]!.deliveries[0]!.status,'queued');
    assert.equal(f.store.one('SELECT count(*) AS n FROM push_devices')?.n,1);
  } finally {await f.notes.stop();f.store.close();}
});

test('rework creates one worker task and agreeing a new time resolves it',async()=>{
  const f=fixture();
  try {
    const record={...f.record,status:2,rounds:[{number:1},{number:2,reason:'rejected'}],agreedTime:''};
    f.store.save('repairs','resident',record);f.store.save('repairs','resident',record,true);
    assert.equal(f.notes.list('worker').filter(n=>n.active).length,1);
    f.store.save('repairs','resident',{...record,agreedTime:'2026-10-18 10:00'},true);
    assert.equal(f.notes.list('worker').filter(n=>n.active).length,0);
  } finally {await f.notes.stop();f.store.close();}
});

test('transport keeps VAPID keys and recovers interrupted deliveries without new tasks',async()=>{
  const f=fixture();
  try {
    const config=readConfig({DATABASE_PATH:':memory:'});
    const one=createPushTransport(config,f.store).publicConfig();
    const two=createPushTransport(config,f.store).publicConfig();
    assert.equal(one.webPublicKey,two.webPublicKey);
    f.notes.register('resident',{platform:'harmony',token:'token',installationId:'9'.repeat(64)});
    f.store.save('repairs','resident',f.record);
    f.store.run("UPDATE push_deliveries SET status='sending'");
    await f.notes.stop();
    const reopened=new Notifications(f.store,f.transport);
    assert.equal(reopened.list('resident').length,1);
    assert.equal(reopened.list('resident')[0]!.deliveries[0]!.status,'queued');
    await reopened.dispatch();await reopened.stop();
    assert.equal(f.sent.length,1);
  } finally {f.store.close();}
});

test('Huawei JWT uses PS256 and required official claims',()=>{
  const {privateKey,publicKey}=generateKeyPairSync('rsa',{modulusLength:2048});
  const now=Date.parse('2026-10-17T00:00:00Z');
  const jwt=huaweiJwt({key_id:'kid',sub_account:'account',private_key:privateKey.export({format:'pem',type:'pkcs8'}).toString()},now);
  const [header,payload,signature]=jwt.split('.');
  assert.equal(JSON.parse(Buffer.from(header!,'base64url').toString()).alg,'PS256');
  const claims=JSON.parse(Buffer.from(payload!,'base64url').toString());
  assert.equal(claims.aud,'https://oauth-login.cloud.huawei.com/oauth2/v3/token');
  assert.equal(claims.exp-claims.iat,3600);
  assert.equal(verify('sha256',Buffer.from(header+'.'+payload),{key:publicKey,padding:constants.RSA_PKCS1_PSS_PADDING,saltLength:32},Buffer.from(signature!,'base64url')),true);
});

test('notification HTTP endpoints require authentication while revocation accepts only a random capability',async()=>{
  const f=fixture();
  const config=readConfig({DATABASE_PATH:':memory:'});
  const app=createApp(config,{pushTransport:f.transport,pushTimer:false,log:()=>{}});
  const server=app.app.listen(0,'127.0.0.1');
  await new Promise<void>(resolve=>server.once('listening',resolve));
  const address=server.address();assert.ok(address && typeof address==='object');
  const url='http://127.0.0.1:'+address.port;
  try {
    assert.equal((await fetch(url+'/notifications')).status,401);
    const invalid=await fetch(url+'/notifications/unregister',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({installationId:'guess'})});
    assert.equal((await invalid.json() as {code:number}).code,40000);
    const valid=await fetch(url+'/notifications/unregister',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({installationId:'c'.repeat(64)})});
    assert.equal((await valid.json() as {code:number}).code,10000);
  } finally {server.closeAllConnections();await new Promise<void>(resolve=>server.close(()=>resolve()));app.store.close();await f.notes.stop();f.store.close();}
});

test('FIX S-M1 push assets resolve from both tsx source and compiled dist layouts', () => {
  const source = new URL('../src/app.ts', import.meta.url).href;
  const compiled = new URL('../dist/src/app.js', import.meta.url).href;
  for (const moduleUrl of [source, compiled]) {
    const root = pushRootCandidates(moduleUrl).find(candidate => existsSync(join(candidate, 'push.js')));
    assert.ok(root, `no web/push.js candidate for ${moduleUrl}`);
    assert.ok(existsSync(join(root, 'push', 'sw.js')));
  }
});

test('FIX S-M2 notification sync failure never rolls back the repair save', async () => {
  const f = fixture();
  const events: object[] = [];
  const notes = new Notifications(f.store, f.transport, Date.now, event => events.push(event));
  f.store.onRepairSaved = (owner, record) => { notes.sync(owner, record); };
  try {
    // workerId 指向不存在的用户：待办外键失败。
    f.store.save('repairs', 'resident', { ...f.record, id: 'bad-worker', status: 5, workerId: 'missing-user' });
    assert.equal(f.store.one('SELECT count(*) AS n FROM repairs WHERE id = ?', 'bad-worker')?.n, 1);
    assert.equal(f.store.one('SELECT count(*) AS n FROM notifications WHERE repairId = ?', 'bad-worker')?.n, 0);
    assert.deepEqual(events.map(event => (event as { event: string }).event), ['notification_sync_failed']);
    // 后续正常工单不受影响。
    f.store.save('repairs', 'resident', f.record);
    assert.equal(notes.list('resident').length, 1);
  } finally { await notes.stop(); await f.notes.stop(); f.store.close(); }
});

test('FIX S-M2 a corrupt stored repair does not stop the server from starting', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-push-start-'));
  const path = join(folder, 'database.sqlite');
  try {
    const seed = new Store(path);
    seed.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('resident','13800000001','resident','resident')");
    seed.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'orphan', 'resident',
      JSON.stringify({ id: 'orphan', status: 5, workerId: 'missing-user', rounds: [{ number: 1 }], pendings: [] }));
    seed.close();
    const events: object[] = [];
    const app = createApp(readConfig({ DATABASE_PATH: path }), { pushTimer: false, log: event => events.push(event) });
    try {
      assert.ok(events.some(event => (event as { event: string }).event === 'notification_sync_failed'));
      assert.equal(app.store.one('SELECT count(*) AS n FROM repairs')?.n, 1);
    } finally { await app.notifications.stop(); app.store.close(); }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});
for (const [label, payload] of [
  ['null payload', null],
  ['null pending', { id: 'corrupt', status: 5, rounds: [{ number: 1 }], pendings: [null] }],
] as const) {
  test(`FIX startup isolates ${label} and still settles healthy repairs`, async () => {
    const folder = mkdtempSync(join(tmpdir(), 'haven-corrupt-start-'));
    const path = join(folder, 'database.sqlite');
    const now = Date.parse('2026-10-18T00:00:00Z');
    let started = false;
    try {
      const seed = new Store(path);
      seed.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('resident','13800000001','resident','resident')");
      seed.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'corrupt', 'resident', JSON.stringify(payload));
      seed.save('repairs', 'resident', { id: 'healthy', status: 6, rounds: [{ number: 1, confirmDeadline: '2026-10-17T00:00:00Z' }], pendings: [] });
      seed.save('repairs', 'resident', { id: 'waiting', status: 6, rounds: [{ number: 1 }], pendings: [] });
      seed.close();
      const events: { event?: string; repairId?: string }[] = [];
      const app = createApp(readConfig({ DATABASE_PATH: path }), { pushTimer: false, now: () => now, log: event => events.push(event) });
      started = true;
      try {
        assert.equal(app.store.get('repairs', 'resident', 'healthy')?.status, 3);
        assert.equal(app.store.one('SELECT payload FROM repairs WHERE id = ?', 'corrupt')?.payload, JSON.stringify(payload));
        assert.ok(events.some(event => event.event === 'repair_settlement_failed' && event.repairId === 'corrupt'));
        assert.ok(app.notifications.list('resident').some(note => note.repairId === 'waiting'));
        new RepairService(app.store, () => now, '020-88888888').settleAll();
        await app.notifications.dispatch();
        assert.equal(app.store.one('SELECT count(*) AS n FROM repairs')?.n, 3);
      } finally { await app.notifications.stop(); app.store.close(); }
    } finally {
      try { rmSync(folder, { recursive: true, force: true }); }
      catch (error) { if (started) throw error; } // 启动失败可能留有数据库句柄，不覆盖原始回归错误。
    }
  });
}

for (const role of ['admin', 'resident', 'worker'] as const) {
  test(`FIX repair list isolates corrupt rows for ${role}`, () => {
    const store = new Store(':memory:');
    const events: { event?: string; repairId?: string; role?: string; type?: string }[] = [];
    const repairs = new RepairService(store, () => Date.parse('2026-10-18T00:00:00Z'), '020-88888888', event => events.push(event));
    try {
      for (const [id, mobile, userRole] of [
        ['resident', '13800000001', 'resident'], ['other', '13800000002', 'resident'], ['worker', '13800000003', 'worker'],
      ]) store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', id!, mobile!, id!, userRole!);
      const healthy = { status: 5, rounds: [{ number: 1 }], pendings: [] };
      // 售后期已结束的工单会在各角色 view 的 closed 判断中读取 pendings。
      const corrupt = { status: 3, rounds: [{ number: 1, confirmedAt: '2000-01-01T00:00:00Z' }], pendings: [null] };
      const rows = [
        { id: 'resident-healthy', owner: 'resident', payload: { ...healthy, id: 'resident-healthy' } },
        { id: 'resident-null', owner: 'resident', payload: null },
        { id: 'resident-pending', owner: 'resident', payload: { ...corrupt, id: 'resident-pending' } },
        { id: 'worker-healthy', owner: 'other', payload: { ...healthy, id: 'worker-healthy', workerId: 'worker' } },
        { id: 'worker-pending', owner: 'other', payload: { ...corrupt, id: 'worker-pending', workerId: 'worker' } },
      ];
      for (const row of rows) store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', row.id, row.owner, JSON.stringify(row.payload));
      const before = store.db.prepare('SELECT id, payload FROM repairs ORDER BY seq DESC').all();
      assert.doesNotThrow(() => {
        const list = role === 'admin' ? repairs.adminList() : role === 'resident' ? repairs.residentList('resident') : repairs.workerList('worker');
        assert.deepEqual(list.map(record => record.id), role === 'admin' ? ['worker-healthy', 'resident-healthy'] : [`${role}-healthy`]);
      });
      const skipped = events.filter(event => event.event === 'repair_list_record_skipped');
      const expectedIds = role === 'admin' ? ['worker-pending', 'resident-pending', 'resident-null']
        : role === 'resident' ? ['resident-pending', 'resident-null'] : ['worker-pending'];
      assert.deepEqual(skipped, expectedIds.map(repairId => ({ event: 'repair_list_record_skipped', repairId, role, type: 'TypeError' })));
      for (const event of skipped) {
        assert.equal(Object.hasOwn(event, 'payload'), false);
        assert.equal(Object.hasOwn(event, 'message'), false);
      }
      assert.deepEqual(store.db.prepare('SELECT id, payload FROM repairs ORDER BY seq DESC').all(), before);
    } finally { store.close(); }
  });
}

test('corrupt row is logged once across repeated settlement and listing', () => {
  const store = new Store(':memory:');
  const events: { event?: string; repairId?: string; role?: string; type?: string }[] = [];
  const repairs = new RepairService(store, () => Date.parse('2026-10-18T00:00:00Z'), '020-88888888', event => events.push(event));
  try {
    store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('resident','13800000001','resident','resident')");
    store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'null-row', 'resident', 'null');
    store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'pending-row', 'resident', JSON.stringify({
      id: 'pending-row', status: 3, rounds: [{ number: 1, confirmedAt: '2000-01-01T00:00:00Z' }], pendings: [null],
    }));
    const before = store.db.prepare('SELECT id, payload FROM repairs ORDER BY seq').all();
    for (let i = 0; i < 3; i++) repairs.settleAll();
    for (let i = 0; i < 3; i++) assert.deepEqual(repairs.adminList(), []);
    for (const repairId of ['null-row', 'pending-row']) {
      assert.deepEqual(events.filter(event => event.repairId === repairId), [
        { event: 'repair_settlement_failed', repairId, type: 'TypeError' },
        { event: 'repair_list_record_skipped', repairId, role: 'admin', type: 'TypeError' },
      ]);
    }
    assert.deepEqual(store.db.prepare('SELECT id, payload FROM repairs ORDER BY seq').all(), before);
  } finally { store.close(); }
});

test('fixed row logs again if it breaks later', () => {
  const store = new Store(':memory:');
  const events: { event?: string; repairId?: string }[] = [];
  const repairs = new RepairService(store, () => Date.parse('2026-10-18T00:00:00Z'), '020-88888888', event => events.push(event));
  try {
    store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('resident','13800000001','resident','resident')");
    store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'repair', 'resident', 'null');
    assert.deepEqual(repairs.adminList(), []);
    store.run('UPDATE repairs SET payload = ? WHERE id = ?', JSON.stringify({ id: 'repair', status: 1, rounds: [{ number: 1 }], pendings: [] }), 'repair');
    assert.deepEqual(repairs.adminList().map(record => record.id), ['repair']);
    store.run('UPDATE repairs SET payload = ? WHERE id = ?', 'null', 'repair');
    assert.deepEqual(repairs.adminList(), []);
    // 再次失败只补一条，两种事件各自清除和重新去重。
    assert.deepEqual(repairs.adminList(), []);
    for (const eventName of ['repair_list_record_skipped', 'repair_settlement_failed']) {
      assert.equal(events.filter(event => event.event === eventName && event.repairId === 'repair').length, 2);
    }
  } finally { store.close(); }
});

test("worker settlement ignores other owners' unparseable rows", () => {
  const store = new Store(':memory:');
  const events: { repairId?: string }[] = [];
  const repairs = new RepairService(store, () => Date.parse('2026-10-18T00:00:00Z'), '020-88888888', event => events.push(event));
  try {
    for (const [id, mobile, role] of [
      ['resident', '13800000001', 'resident'], ['other', '13800000002', 'resident'], ['worker', '13800000003', 'worker'],
    ]) store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', id!, mobile!, id!, role!);
    store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'other-null', 'other', 'null');
    // 模拟已有的损坏数据；正常写入会被 json_valid CHECK 拦截。
    store.db.exec('PRAGMA ignore_check_constraints = ON');
    store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'other-invalid', 'other', '{bad');
    store.db.exec('PRAGMA ignore_check_constraints = OFF');
    store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'healthy', 'resident', JSON.stringify({
      id: 'healthy', status: 5, workerId: 'worker', rounds: [{ number: 1 }], pendings: [],
    }));
    assert.doesNotThrow(() => repairs.settleAll({ workerId: 'worker' }));
    assert.doesNotThrow(() => assert.deepEqual(repairs.workerList('worker').map(record => record.id), ['healthy']));
    assert.deepEqual(events, []);
  } finally { store.close(); }
});

test('FIX settlement failure rolls back only that row and continues with later repairs', async () => {
  const app = createApp(readConfig({ DATABASE_PATH: ':memory:' }), { pushTimer: false, log: () => {} });
  try {
    app.store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('resident','13800000001','resident','resident')");
    for (const id of ['blocked', 'healthy']) app.store.save('repairs', 'resident', { id, status: 6, rounds: [{ number: 1, confirmDeadline: '2000-01-01T00:00:00Z' }], pendings: [] });
    app.store.db.exec(`CREATE TABLE settlement_audit (id TEXT);
      CREATE TRIGGER block_one_settlement BEFORE UPDATE OF payload ON repairs WHEN OLD.id = 'blocked' BEGIN
        INSERT INTO settlement_audit(id) VALUES (OLD.id);
        SELECT RAISE(FAIL, 'fixture settlement failure');
      END;`);
    new RepairService(app.store, Date.now, '020-88888888').settleAll();
    assert.equal(app.store.get('repairs', 'resident', 'blocked')?.status, 6);
    assert.equal(app.store.get('repairs', 'resident', 'healthy')?.status, 3);
    assert.equal(app.store.one('SELECT count(*) AS n FROM settlement_audit')?.n, 0);
  } finally { await app.notifications.stop(); app.store.close(); }
});

test('FIX migration upgrades a version-two database that already has early push tables', () => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-push-migrate-'));
  const path = join(folder, 'database.sqlite');
  try {
    const old = new Store(path);
    old.db.exec(`DROP TABLE push_deliveries;
      CREATE TABLE push_deliveries (notificationId TEXT NOT NULL REFERENCES notifications(id), deviceId TEXT NOT NULL, status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0, nextAt INTEGER NOT NULL, reason TEXT NOT NULL DEFAULT '', PRIMARY KEY(notificationId,deviceId));
      PRAGMA user_version = 2;`);
    old.close();
    const upgraded = new Store(path);
    try {
      assert.equal(upgraded.one('PRAGMA user_version')?.user_version, 3);
      assert.ok(upgraded.db.prepare('PRAGMA table_info(push_deliveries)').all().some(column => column.name === 'lease'));
    } finally { upgraded.close(); }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});

test('FIX S-L1 a freshly created task cannot be reminded within the first minute', async () => {
  const f = fixture();
  try {
    f.store.save('repairs', 'resident', f.record);
    assert.throws(() => f.notes.remind('worker', 'repair-1'), /一分钟/);
    const id = String(f.notes.list('resident')[0]!.id);
    assert.throws(() => f.notes.retry('resident', id), /一分钟/);
    f.advance();
    assert.equal(f.notes.remind('worker', 'repair-1').queued, 1);
  } finally { await f.notes.stop(); f.store.close(); }
});

test('FIX S-L2 another installation cannot take over an endpoint bound to a different account', async () => {
  const f = fixture();
  try {
    f.notes.register('resident', { platform: 'harmony', token: 'shared-token', installationId: '1'.repeat(64) });
    assert.throws(() => f.notes.register('other', { platform: 'harmony', token: 'shared-token', installationId: '2'.repeat(64) }), /其他账号/);
    assert.deepEqual(f.store.db.prepare('SELECT userId FROM push_devices').all().map(row => row.userId), ['resident']);
    // 同一用户重装（新的 installationId）可以接管自己的旧绑定。
    f.notes.register('resident', { platform: 'harmony', token: 'shared-token', installationId: '3'.repeat(64) });
    assert.equal(f.store.one('SELECT count(*) AS n FROM push_devices')?.n, 1);
    // 同一安装换账号仍然允许。
    f.notes.register('other', { platform: 'harmony', token: 'shared-token', installationId: '3'.repeat(64) });
    assert.deepEqual(f.store.db.prepare('SELECT userId FROM push_devices').all().map(row => row.userId), ['other']);
  } finally { await f.notes.stop(); f.store.close(); }
});

test('FIX S-L4 an expired subscription removes the device and its other queued deliveries', async () => {
  const f = fixture();
  f.transport.send = async () => ({ status: 'expired', reason: '订阅失效' });
  try {
    f.notes.register('resident', { platform: 'harmony', token: 'gone', installationId: '4'.repeat(64) });
    f.store.save('repairs', 'resident', f.record);
    f.store.save('repairs', 'resident', { ...f.record, id: 'repair-2' });
    await f.notes.dispatch();
    assert.equal(f.store.one('SELECT count(*) AS n FROM push_devices')?.n, 0);
    assert.deepEqual(f.store.db.prepare('SELECT status FROM push_deliveries').all().map(row => row.status), ['expired']);
  } finally { await f.notes.stop(); f.store.close(); }
});
test('FIX S-L5 retries back off and the final failure is marked as stopped', async () => {
  const f = fixture();
  try {
    f.notes.register('resident', { platform: 'harmony', token: 'flaky', installationId: '5'.repeat(64) });
    f.store.save('repairs', 'resident', f.record);
    f.fail();
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      await f.notes.dispatch();
      // 退避期内不会再次发送。
      await f.notes.dispatch();
      assert.equal(f.sent.length, attempt);
      const delivery = f.notes.list('resident')[0]!.deliveries[0]!;
      assert.equal(delivery.attempts, attempt);
      assert.equal(delivery.stopped, attempt === MAX_ATTEMPTS);
      assert.equal(delivery.reason === '已停止自动重试，请手动重试', attempt === MAX_ATTEMPTS);
      f.advance(3_600_000);
    }
    await f.notes.dispatch();
    assert.equal(f.sent.length, MAX_ATTEMPTS);
    f.succeed();
    f.notes.retry('resident', String(f.notes.list('resident')[0]!.id));
    await f.notes.dispatch();
    assert.equal(f.notes.list('resident')[0]!.deliveries[0]!.status, 'accepted');
  } finally { await f.notes.stop(); f.store.close(); }
});

test('FIX Huawei response parsing follows the documented codes', () => {
  assert.equal(huaweiResult(true, { code: '80000000', msg: 'Success' }).status, 'accepted');
  const invalid = huaweiResult(false, { code: '80300007', msg: JSON.stringify({ failure: 1, illegalTokens: { tokenFormatError: ['t'] } }) });
  assert.equal(invalid.status, 'expired');
  const partial = huaweiResult(true, { code: '80100000', msg: JSON.stringify({ success: 0, failure: 1, illegalTokens: { tokenPlatformNotSupport: ['t'] } }) });
  assert.equal(partial.status, 'expired');
  // 权益或项目配置问题：不当作设备失效。
  assert.equal(huaweiResult(false, { code: '80300007', msg: JSON.stringify({ illegalTokens: { noRight: ['t'] } }) }).status, 'failed');
  assert.equal(huaweiResult(false, { code: '80200005', msg: 'Jwt token expired.' }).resetJwt, true);
  assert.equal(huaweiResult(false, '<html>bad gateway</html>').status, 'failed');
});

test('FIX web push 404/410 become expired, other errors stay retriable', async () => {
  const store = new Store(':memory:');
  try {
    let status = 410;
    const transport = createPushTransport(readConfig({ DATABASE_PATH: ':memory:' }), store, {
      webPush: async () => { throw Object.assign(new Error('push service'), { statusCode: status }); },
    });
    const device = { platform: 'web' as const, profileId: 'p', subscription: { endpoint: 'https://fcm.googleapis.com/x', keys: { p256dh: 'k', auth: 'a' } } };
    const message = { notificationId: '12345678-1234-1234-1234-123456789abc', title: 't', body: 'b' };
    for (const [code, expected] of [[410, 'expired'], [404, 'expired'], [500, 'failed'], [429, 'failed']] as const) {
      status = code;
      assert.equal((await transport.send(device, message)).status, expected, `HTTP ${code}`);
    }
  } finally { store.close(); }
});
test('FIX Huawei transport sends the documented v3 body and maps invalid tokens to expired', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-huawei-'));
  const store = new Store(':memory:');
  try {
    const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const keyFile = join(folder, 'key.json');
    writeFileSync(keyFile, JSON.stringify({ key_id: 'kid', sub_account: 'account', private_key: privateKey.export({ format: 'pem', type: 'pkcs8' }).toString() }));
    const config = readConfig({ DATABASE_PATH: ':memory:', HUAWEI_PUSH_PROJECT_ID: '123', HUAWEI_PUSH_KEY_FILE: keyFile });
    const requests: { url: string; body: any; headers: Record<string, string> }[] = [];
    let reply: object = { code: '80000000', msg: 'Success' };
    const fakeFetch = (async (url: string, init: RequestInit) => {
      requests.push({ url, body: JSON.parse(String(init.body)), headers: init.headers as Record<string, string> });
      return new Response(JSON.stringify(reply), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }) as typeof fetch;
    const transport = createPushTransport(config, store, { fetch: fakeFetch });
    assert.equal(transport.publicConfig().harmonyConfigured, true);
    const device = { platform: 'harmony' as const, token: 'device-token', profileId: 'p'.repeat(64) };
    const message = { notificationId: '12345678-1234-1234-1234-123456789abc', title: '报修待处理', body: '有新的报修派给你' };
    assert.equal((await transport.send(device, message)).status, 'accepted');
    const sent = requests[0]!;
    assert.equal(sent.url, 'https://push-api.cloud.huawei.com/v3/123/messages:send');
    assert.equal(sent.headers['push-type'], '0');
    assert.match(sent.headers.Authorization!, /^Bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    assert.deepEqual(sent.body.target, { token: ['device-token'] });
    assert.equal(sent.body.payload.notification.profileId, device.profileId);
    assert.deepEqual(sent.body.payload.notification.clickAction, { actionType: 0, data: { notificationId: message.notificationId } });
    assert.equal(sent.body.pushOptions.ttl, 3600);
    reply = { code: '80300007', msg: JSON.stringify({ failure: 1, illegalTokens: { tokenFormatError: ['device-token'] } }) };
    assert.equal((await transport.send(device, message)).status, 'expired');
  } finally { store.close(); rmSync(folder, { recursive: true, force: true }); }
});

test('FIX S-L3 revocation retries use their own limit and never exhaust login attempts', async () => {
  const app = createApp(readConfig({ DATABASE_PATH: ':memory:' }), { pushTimer: false, log: () => {} });
  const server = app.app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address(); assert.ok(address && typeof address === 'object');
  const url = 'http://127.0.0.1:' + address.port;
  try {
    for (let i = 0; i < 30; i++) {
      await fetch(url + '/notifications/unregister', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ installationId: 'c'.repeat(64) }) });
    }
    assert.notEqual((await fetch(url + '/code?mobile=13800138000')).status, 429);
  } finally { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); await app.notifications.stop(); app.store.close(); }
});
