import test from 'node:test';
import assert from 'node:assert/strict';
import { OperationsMetrics, pushOperationsSnapshot } from '../src/operations.js';
import { MAX_ATTEMPTS } from '../src/notifications.js';
import { fixture } from './repair-fixture.js';

test('operations: latency uses fixed histogram bounds and counts HTTP 200 auth rejection', () => {
  let now = 0;
  const metrics = new OperationsMetrics(() => now);
  const finish = metrics.begin(true);
  assert.equal(metrics.snapshot().activeRequests, 1);
  now = 120;
  finish({ status: 200, businessError: true });
  finish(); // response close after finish must never double count
  const snapshot = metrics.snapshot();
  assert.equal(snapshot.completed, 1);
  assert.equal(snapshot.rejected, 1);
  assert.equal(snapshot.authRejected, 1);
  assert.equal(snapshot.serverErrorRate, 0);
  assert.equal(snapshot.activeRequests, 0);
  assert.equal(snapshot.aborted, 0);
  assert.equal(snapshot.latency.p95UpperBoundMs, 250);
  assert.equal(snapshot.latency.buckets.reduce((sum, bucket) => sum + bucket.count, 0), 1);
});

test('operations: window evicts old traffic and faults while retaining current buckets', () => {
  let now = 0;
  const metrics = new OperationsMetrics(() => now);
  metrics.begin(true)({ status: 429, businessError: false });
  metrics.recordEvent({ event: 'sms_send_failed', reason: 'not-retained' });
  now = 599999;
  assert.equal(metrics.snapshot().rateLimited, 1);
  metrics.begin(false)({ status: 500, businessError: true });
  now = 600000;
  const snapshot = metrics.snapshot();
  assert.equal(snapshot.completed, 1);
  assert.equal(snapshot.serverErrors, 1);
  assert.equal(snapshot.serverErrorRate, 1);
  assert.equal(snapshot.rateLimited, 0);
  assert.equal(snapshot.smsSendFailures, 0);
  now = 1800000;
  assert.equal(metrics.snapshot().completed, 0);
  assert.equal(metrics.snapshot().serverErrorRate, null);
  assert.equal(metrics.snapshot().latency.p95UpperBoundMs, null);
});

test('operations: 100000 events keep bounded output with no raw identifiers or unexpected labels', () => {
  let now = 0;
  const metrics = new OperationsMetrics(() => now);
  for (let i = 0; i < 100000; i++) {
    now = i * 7;
    metrics.begin(false)({ status: 200, businessError: false });
    metrics.recordEvent({ event: `untrusted-${i}`, token: 'secret' });
  }
  metrics.recordEvent({ event: '__proto__', mobile: '13800138000' });
  metrics.recordEvent({ event: 'push_dispatch_failed', repairId: 'private-id', message: 'secret' });
  const snapshot = metrics.snapshot();
  assert.equal(snapshot.latency.buckets.length, 9);
  assert.equal(snapshot.pushDispatchFailures, 1);
  assert.equal(snapshot.completed, 85714);
  assert(JSON.stringify(snapshot).length < 1500);
  assert.doesNotMatch(JSON.stringify(snapshot), /untrusted|private-id|13800138000|secret|__proto__/);
});

test('operations: aborted responses, infinite latency bin and percentile use distinct denominators', () => {
  let now = 0;
  const metrics = new OperationsMetrics(() => now);
  const abandoned = metrics.begin(false);
  abandoned(); abandoned();
  for (let index = 0; index < 19; index++) metrics.begin(false)({ status: 200, businessError: false });
  const slow = metrics.begin(false);
  now += 10001;
  slow({ status: 503, businessError: true });
  assert.equal(metrics.snapshot().latency.p95UpperBoundMs, 50);
  const secondSlow = metrics.begin(false);
  now += 10001;
  secondSlow({ status: 200, businessError: false });
  const snapshot = metrics.snapshot();
  assert.equal(snapshot.latency.p95UpperBoundMs, null); // above final finite bound
  assert.equal(snapshot.latency.buckets.at(-1)!.count, 2);
  assert.equal(snapshot.completed, 21);
  assert.equal(snapshot.aborted, 1);
  assert.equal(snapshot.serverErrorRate, 1 / 21);
});

test('operations endpoint requires an enabled property administrator and has no public metrics', async t => {
  const f = await fixture(t);
  for (const role of [undefined, 'resident', 'worker'] as const) {
    const result = await f.raw(role, 'GET', '/management/operations');
    assert.equal(result.status, role ? 403 : 401);
    assert.equal(result.data, null);
  }
  assert.equal((await f.call('admin', 'GET', '/management/operations')).schemaVersion, 1);
  const response = await fetch(f.base + '/management/operations', { headers: { Authorization: `Bearer ${f.tokens.admin}` } });
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal((await f.raw(undefined, 'GET', '/health')).data.requests, undefined);
  f.store.run('UPDATE users SET disabledAt=? WHERE id=?', f.time(), f.ids.admin);
  assert.equal((await f.raw('admin', 'GET', '/management/operations')).status, 401);
});

test('operations endpoint observes business auth failure, server errors and rate limits without secrets', async t => {
  const f = await fixture(t);
  const before = await f.call('admin', 'GET', '/management/operations');
  const login = await f.raw(undefined, 'POST', '/LOGIN/', { mobile: '13912345678', code: '987654' });
  assert.equal(login.status, 200);
  assert.notEqual(login.code, 10000);
  const original = f.store.one;
  f.store.one = function (sql, ...values) {
    if (sql.startsWith('SELECT id, nickName, avatar, role FROM users')) throw new Error('secret=private-error');
    return original.call(this, sql, ...values);
  };
  const result = await f.raw('resident', 'GET', '/userInfo?secret=private-query');
  f.store.one = original;
  assert.equal(result.status, 500);
  for (let index = 0; index < 22; index++) await f.raw(undefined, 'POST', '/login', {});
  const snapshot = await f.call('admin', 'GET', '/management/operations');
  assert.equal(snapshot.requests.serverErrors - before.requests.serverErrors, 1);
  assert.equal(snapshot.requests.authRejected - before.requests.authRejected, 23);
  assert(snapshot.requests.rateLimited >= 1);
  assert.doesNotMatch(JSON.stringify(snapshot), /13912345678|987654|private-query|private-error/);
  for (const value of [...Object.values(f.ids), ...Object.values(f.tokens)]) assert(!JSON.stringify(snapshot).includes(value));
});

test('healthy probes and snapshots do not inflate business traffic; snapshot polling is limited', async t => {
  const f = await fixture(t);
  const before = await f.call('admin', 'GET', '/management/operations');
  for (const path of ['/health', '/READY/', '/admin/', '/admin/missing.js']) await fetch(f.base + path);
  const after = await f.call('admin', 'GET', '/management/operations');
  assert.equal(after.requests.completed, before.requests.completed);
  for (let index = 0; index < 10; index++) assert.equal((await f.raw('admin', 'GET', '/management/operations')).status, 200);
  assert.equal((await f.raw('admin', 'GET', '/management/operations')).status, 429);
});

test('push inventory distinguishes backoff, exhausted retries, expired leases and inactive history without mutation', async t => {
  const f = await fixture(t);
  f.store.run(`INSERT INTO notifications(id,userId,repairId,taskKey,role,title,body,active,createdAt)
    VALUES ('ops-note',?,'private-repair','task','resident','private-title','private-body',1,?)`, f.ids.resident, f.time());
  const cases = [
    ['due', 'queued', 0, f.time() - 70000], ['backoff', 'failed', 1, f.time() + 60000],
    ['stopped', 'failed', MAX_ATTEMPTS, f.time() - 90000], ['sending', 'sending', 1, f.time() + 10000],
    ['expired-lease', 'sending', 1, f.time() - 1], ['accepted', 'accepted', 1, 0],
    ['unconfigured', 'unconfigured', 1, 0], ['expired', 'expired', 1, 0], ['unknown', 'unknown', 0, 0],
    ['orphan', 'queued', 0, 0],
  ] as const;
  for (const [id, status, attempts, nextAt] of cases) {
    if (id !== 'orphan') f.store.run('INSERT INTO push_devices VALUES (?,?,?,?,?,?)',
      id, f.ids.resident, 'harmony', id, '{"token":"private-token"}', f.time());
    f.store.run('INSERT INTO push_deliveries(notificationId,deviceId,status,attempts,nextAt,reason) VALUES (?,?,?,?,?,?)',
      'ops-note', id, status, attempts, nextAt, 'private-reason');
  }
  const before = f.store.db.prepare('SELECT * FROM push_deliveries').all();
  const snapshot = pushOperationsSnapshot(f.store, f.time());
  assert.deepEqual(snapshot, { activeDeliveries: 10, queued: 2, failed: 2, sending: 2, accepted: 1,
    unconfigured: 1, expired: 1, unknownStatus: 1, stopped: 1, expiredLeases: 1, orphaned: 1, due: 1, oldestDueDelayMs: 70000 });
  assert.deepEqual(f.store.db.prepare('SELECT * FROM push_deliveries').all(), before);
  assert.doesNotMatch(JSON.stringify(snapshot), /private-/);
  f.store.run("UPDATE notifications SET active=0 WHERE id='ops-note'");
  assert.equal(pushOperationsSnapshot(f.store, f.time()).activeDeliveries, 0);
});

test('actual failed push and task sync appear in operations counters with fixed labels only', async t => {
  const f = await fixture(t, { pushTransport: { publicConfig: () => ({ webPublicKey: '', harmonyConfigured: true }),
    send: async () => { throw new Error('private-device-token'); } } });
  f.notifications.register(f.ids.resident, { platform: 'harmony', token: 'private-device-token', installationId: 'c'.repeat(64) });
  f.store.save('repairs', f.ids.resident, { id: 'ops-push', status: 6, workerId: f.ids.worker, rounds: [{ number: 1 }], pendings: [] });
  await f.notifications.dispatch();
  f.store.db.exec("CREATE TRIGGER ops_sync_failure BEFORE INSERT ON notifications BEGIN SELECT RAISE(ABORT,'private-sync-error'); END");
  f.store.save('repairs', f.ids.resident, { id: 'ops-sync', status: 6, workerId: f.ids.worker, rounds: [{ number: 1 }], pendings: [] });
  f.store.db.exec('DROP TRIGGER ops_sync_failure');
  const snapshot = await f.call('admin', 'GET', '/management/operations');
  assert.equal(snapshot.requests.pushTransportFailures, 1);
  assert.equal(snapshot.requests.notificationSyncFailures, 1);
  assert.equal(snapshot.push.failed, 1);
  assert.equal(snapshot.push.due, 0); // retry is backing off, not overdue
  assert.doesNotMatch(JSON.stringify(snapshot), /private-|ops-push|ops-sync/);
});
