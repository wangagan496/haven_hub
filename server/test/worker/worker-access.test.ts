import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { fixture, H } from '../repair/repair-fixture.js';
import { AuthService } from '../../src/auth.js';

test('disabling a worker invalidates sessions, media and push; restoring requires a fresh login and appends audit history', async t => {
  const f = await fixture(t);
  const path = `/management/workers/${f.ids.worker}/access`;
  const old = f.store.one('SELECT * FROM sessions WHERE userId=?', f.ids.worker)!;
  const refreshToken = randomBytes(32).toString('hex');
  old.refreshHash = createHash('sha256').update(refreshToken).digest('hex');
  f.store.run('UPDATE sessions SET refreshHash=? WHERE userId=?', String(old.refreshHash), f.ids.worker);
  f.store.run('INSERT INTO push_devices VALUES (?,?,?,?,?,?)', 'device', f.ids.worker, 'web', 'endpoint-hash', '{}', f.time());
  f.store.run('INSERT INTO notifications(id,userId,repairId,taskKey,role,title,body,active,createdAt) VALUES (?,?,?,?,?,?,?,?,?)',
    'notice', f.ids.worker, 'completed-repair', 'old-task', 'worker', '测试通知', '测试内容', 1, f.time());
  f.store.run('INSERT INTO push_deliveries(notificationId,deviceId,status,nextAt,lease) VALUES (?,?,?,?,?)',
    'notice', 'device', 'queued', f.time(), 'old-lease');
  f.store.run('INSERT INTO push_deliveries(notificationId,deviceId,status,nextAt,reason) VALUES (?,?,?,?,?)',
    'notice', 'past-device', 'accepted', f.time(), '推送服务已接收');
  const id = randomBytes(32).toString('hex');
  f.store.run('INSERT INTO uploads VALUES (?,?,?,?)', id, f.ids.worker, 'image/png', Buffer.from('private'));
  assert.equal((await f.raw('resident', 'PUT', path, { revision: 0, enabled: false, reason: '离职' })).status, 403);
  await f.call('admin', 'PUT', path, { revision: 0, enabled: false, reason: '离职交接完成' });
  assert.equal((await f.raw('worker', 'GET', '/userInfo')).status, 401);
  assert.equal((await fetch(`${f.base}/media/${id}`, { headers: { Authorization: `Bearer ${f.tokens.worker}` } })).status, 401);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM sessions WHERE userId=?', f.ids.worker)!.n, 0);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM push_devices WHERE userId=?', f.ids.worker)!.n, 0);
  assert.equal(f.store.one("SELECT active FROM notifications WHERE id='notice'")!.active, 0);
  assert.deepEqual({ ...f.store.one("SELECT status,lease FROM push_deliveries WHERE notificationId='notice' AND deviceId='device'") },
    { status: 'cancelled', lease: '' });
  assert.deepEqual({ ...f.store.one("SELECT status,reason FROM push_deliveries WHERE notificationId='notice' AND deviceId='past-device'") },
    { status: 'accepted', reason: '推送服务已接收' });
  const auth = new AuthService(f.store, f.time);
  assert.throws(() => auth.refresh(`Bearer ${refreshToken}`), /失效/);
  assert.equal((await f.raw(undefined, 'GET', '/code?mobile=13800138002')).status, 403);
  // A retained token cannot bypass the enabled-state check, even if an old session row survives.
  f.store.run('INSERT INTO sessions(accessHash,refreshHash,userId,accessExpires,refreshExpires) VALUES (?,?,?,?,?)',
    String(old.accessHash), String(old.refreshHash), f.ids.worker, f.time()+H, f.time()+H);
  assert.equal((await f.raw('worker', 'GET', '/userInfo')).status, 401);
  assert.throws(() => auth.refresh(`Bearer ${refreshToken}`), /停用/);
  f.store.run('INSERT OR REPLACE INTO codes(mobile,hash,expires,sentAt,attempts) VALUES (?,?,?,?,?)', '13800138002',
    createHash('sha256').update('13800138002:123456').digest('hex'), f.time()+H, f.time(), 0);
  assert.throws(() => auth.login({ mobile: '13800138002', code: '123456' }), /停用/);
  assert.equal((await f.raw('admin', 'PUT', path, { revision: 0, enabled: true, reason: '恢复' })).status, 409);
  await f.call('admin', 'PUT', path, { revision: 1, enabled: true, reason: '重新入职' });
  assert.throws(() => auth.refresh(`Bearer ${refreshToken}`), /失效/);
  assert.equal((await f.raw('worker', 'GET', '/userInfo')).status, 401);
  const events = await f.call('admin', 'GET', `/management/workers/${f.ids.worker}/account-events`);
  assert.deepEqual(events.map((event: any) => [event.enabled, event.reason, event.actorId]),
    [[1, '重新入职', f.ids.admin], [0, '离职交接完成', f.ids.admin]]);
  const code = await f.raw(undefined, 'GET', '/code?mobile=13800138002');
  const session = await f.raw(undefined, 'POST', '/login', { mobile: '13800138002', code: code.data.code });
  assert.equal(session.code, 10000);
  assert.notEqual(session.data.token, f.tokens.worker);
});

test('worker must hand over active repairs before disable; disabled workers never count toward capacity or assignments', async t => {
  const f = await fixture(t);
  let repair = await f.create();
  repair = await f.change('admin', repair, 'assign', { workerId: f.ids.worker });
  const path = `/management/workers/${f.ids.worker}/access`;
  const rejected = await f.raw('admin', 'PUT', path, { revision: 0, enabled: false, reason: '离职' });
  assert.notEqual(rejected.code, 10000);
  assert.match(rejected.message, /先改派/);
  assert.equal((await f.raw('worker', 'GET', '/userInfo')).code, 10000);
  repair = await f.change('admin', repair, 'assign', { workerId: f.ids.worker2 });
  await f.call('admin', 'PUT', path, { revision: 0, enabled: false, reason: '工单已交接' });
  assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${repair.id}/assign`,
    { revision: repair.revision, workerId: f.ids.worker })).code, 10000);
  assert.notEqual((await f.raw('admin', 'POST', `/management/workers/${f.ids.worker}/leave`,
    { revision: 1, date: '2026-10-20', reason: '休假' })).code, 10000);
  assert.equal((await f.raw('resident', 'GET', `/management/workers/${f.ids.worker}/account-events`)).status, 403);
});
