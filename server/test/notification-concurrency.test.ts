import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { Store } from '../src/database.js';
import { DELIVERY_LEASE_MS, MAX_ATTEMPTS, Notifications } from '../src/notifications.js';
import type { PushResult, PushTransport } from '../src/push-transport.js';

const accepted: PushResult = { status: 'accepted', reason: '服务已接收' };
const registration = { platform: 'harmony', token: 'fixture-device', installationId: 'a'.repeat(64) };

function fixture(t: TestContext) {
  const folder = mkdtempSync(join(tmpdir(), 'haven-push-lease-'));
  const path = join(folder, 'test.sqlite');
  const store = new Store(path);
  let now = Date.parse('2026-10-28T00:00:00Z');
  const sent: string[] = [];
  const pending: ((result: PushResult) => void)[] = [];
  let pause = false;
  const transport: PushTransport = {
    publicConfig: () => ({ webPublicKey: '', harmonyConfigured: true }),
    send: async (_device, message) => {
      sent.push(message.notificationId);
      return pause ? new Promise<PushResult>(resolve => pending.push(resolve)) : accepted;
    },
  };
  store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('owner','13800000001','owner','resident')");
  const connections = [store];
  const services: Notifications[] = [];
  const createService = (connection = store) => {
    const service = new Notifications(connection, transport, () => now);
    services.push(service);
    return service;
  };
  const notes = createService();
  notes.register('owner', registration);
  notes.sync('owner', { id: 'repair', status: 6, rounds: [{ number: 1 }], pendings: [] });
  const noteId = notes.list('owner')[0]!.id;
  const delivery = () => store.one('SELECT * FROM push_deliveries WHERE notificationId=?', noteId)!;
  t.after(async () => {
    pause = false;
    for (const resolve of pending.splice(0)) resolve(accepted);
    await Promise.all(services.map(service => service.stop()));
    for (const connection of connections.reverse()) connection.close();
    rmSync(folder, { recursive: true, force: true });
  });
  return { store, notes, sent, noteId, delivery, path,
    get now() { return now; },
    advance: (ms: number) => { now += ms; },
    pause: () => { pause = true; },
    release: (result: PushResult = accepted) => {
      const resolve = pending.shift();
      assert.ok(resolve, 'expected one in-flight transport request');
      resolve(result);
    },
    open: () => {
      const connection = new Store(path);
      connections.push(connection);
      return createService(connection);
    },
  };
}

test('push lease: another service does not restart a live send', async t => {
  const f = fixture(t);
  f.pause();
  const running = f.notes.dispatch();
  const original = f.delivery();
  const other = f.open();
  assert.equal(f.delivery().status, 'sending');
  assert.equal(f.delivery().lease, original.lease);
  assert.ok(Number(original.nextAt) > f.now, 'live send must have a recovery deadline');
  await other.dispatch();
  assert.equal(f.sent.length, 1);
  f.release();
  await running;
  assert.equal(f.delivery().status, 'accepted');
});

test('push lease: two connections claim each queued delivery only once', async t => {
  const f = fixture(t);
  const other = f.open();
  f.pause();
  const one = f.notes.dispatch();
  await other.dispatch();
  assert.equal(f.sent.length, 1);
  assert.equal(f.delivery().attempts, 1);
  f.release();
  await one;
  assert.equal(f.delivery().status, 'accepted');
});

test('push lease: periodic recovery retries an abandoned send only after its deadline', async t => {
  const f = fixture(t);
  f.store.run("UPDATE push_deliveries SET status='sending',attempts=1,lease='abandoned',nextAt=?", f.now + 1000);
  await f.notes.dispatch();
  assert.equal(f.sent.length, 0);
  f.advance(999);
  await f.notes.dispatch();
  assert.equal(f.sent.length, 0);
  f.advance(1);
  await f.notes.dispatch();
  assert.equal(f.sent.length, 1);
  assert.equal(f.delivery().status, 'accepted');
  assert.equal(f.delivery().attempts, 2);
});

test('push lease: restart preserves a live claim and recovers old unleased rows', async t => {
  const f = fixture(t);
  f.store.run("UPDATE push_deliveries SET status='sending',attempts=1,lease='live',nextAt=?", f.now + 1000);
  const other = f.open();
  assert.equal(f.delivery().status, 'sending');
  await other.dispatch();
  assert.equal(f.sent.length, 0);
  f.advance(1000);
  await other.dispatch();
  assert.equal(f.delivery().status, 'accepted');
  f.store.run("UPDATE push_deliveries SET status='sending',attempts=1,lease='',nextAt=0");
  const legacy = f.open();
  await legacy.dispatch();
  assert.equal(f.sent.length, 2);
  assert.equal(f.delivery().status, 'accepted');
});

test('push lease: an expired last attempt stops automatic retry but remains manually retryable', async t => {
  const f = fixture(t);
  f.store.run("UPDATE push_deliveries SET status='sending',attempts=?,lease='abandoned',nextAt=?", MAX_ATTEMPTS, f.now + 1000);
  f.advance(60_001);
  await f.notes.dispatch();
  const delivery = f.notes.list('owner')[0]!.deliveries[0]!;
  assert.equal(delivery.status, 'failed');
  assert.equal(delivery.stopped, true);
  assert.equal(f.sent.length, 0);
  f.notes.retry('owner', f.noteId);
  await f.notes.dispatch();
  assert.equal(f.sent.length, 1);
  assert.equal(f.delivery().attempts, 1);
  assert.equal(f.delivery().status, 'accepted');
});

for (const staleStatus of ['accepted', 'expired'] as const) {
  test(`push lease: stale ${staleStatus} result cannot finish a replacement claim`, async t => {
    const f = fixture(t);
    const other = f.open();
    f.pause();
    const oldRun = f.notes.dispatch();
    const firstLease = f.delivery().lease;
    f.advance(60_001);
    f.notes.retry('owner', f.noteId);
    const newRun = other.dispatch();
    const newLease = f.delivery().lease;
    assert.notEqual(newLease, firstLease);
    f.release({ status: staleStatus, reason: '旧投递结果' });
    await oldRun;
    assert.equal(f.delivery().status, 'sending');
    assert.equal(f.delivery().lease, newLease);
    assert.equal(f.store.one('SELECT count(*) AS count FROM push_devices')?.count, 1);
    f.release();
    await newRun;
    assert.equal(f.delivery().status, 'accepted');
  });
}

test('push lease: queued retries respect their backoff across connections', async t => {
  const f = fixture(t);
  const other = f.open();
  f.store.run("UPDATE push_deliveries SET status='failed',attempts=1,nextAt=?", f.now + 60_000);
  await Promise.all([f.notes.dispatch(), other.dispatch()]);
  assert.equal(f.sent.length, 0);
  f.advance(60_000);
  await Promise.all([f.notes.dispatch(), other.dispatch()]);
  assert.equal(f.sent.length, 1);
  assert.equal(f.delivery().attempts, 2);
});

for (const attempts of [1, MAX_ATTEMPTS]) {
  test(`push lease: stale batch rechecks backoff and attempt limit after await attempts=${attempts}`, async t => {
    const f = fixture(t);
    f.notes.register('owner', { ...registration, token: 'second-device', installationId: 'b'.repeat(64) });
    f.pause();
    const running = f.notes.dispatch();
    assert.equal(f.sent.length, 1);
    f.store.run("UPDATE push_deliveries SET status='failed',attempts=?,nextAt=? WHERE status='queued'", attempts, f.now + 60_000);
    f.release();
    // 旧批次不能仅因状态仍是failed就越过另一个发送者刚写入的退避或上限。
    await Promise.race([running, new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error('stale batch sent the second device')), 1000);
      timer.unref();
    })]);
    assert.equal(f.sent.length, 1);
    const waiting = f.store.one("SELECT attempts,nextAt FROM push_deliveries WHERE status='failed'")!;
    assert.equal(waiting.attempts, attempts);
    assert.equal(waiting.nextAt, f.now + 60_000);
  });
}

test('push lease: late expired response cannot clear a recovered attempt or device', async t => {
  const f = fixture(t);
  const other = f.open();
  f.pause();
  const first = f.notes.dispatch();
  const firstLease = f.delivery().lease;
  f.advance(DELIVERY_LEASE_MS);
  const recovered = other.dispatch();
  assert.equal(f.sent.length, 2);
  assert.equal(f.delivery().attempts, 2);
  assert.notEqual(f.delivery().lease, firstLease);
  f.release({ status: 'expired', reason: '迟到的失效结果' });
  await first;
  assert.equal(f.delivery().status, 'sending');
  assert.equal(f.store.one('SELECT count(*) AS count FROM push_devices')?.count, 1);
  f.release();
  await recovered;
  assert.equal(f.delivery().status, 'accepted');
  assert.equal(f.delivery().lease, '');
});

test('push lease: closing the task during delivery prevents stale completion or recovery', async t => {
  const f = fixture(t);
  f.pause();
  const running = f.notes.dispatch();
  f.notes.sync('owner', { id: 'repair', status: 3, rounds: [{ number: 1 }], pendings: [] });
  assert.equal(f.delivery().status, 'cancelled');
  f.release();
  await running;
  f.advance(DELIVERY_LEASE_MS);
  const other = f.open();
  await other.dispatch();
  assert.equal(f.sent.length, 1);
  assert.equal(f.delivery().status, 'cancelled');
});

test('push lease: independent Node processes compete for one delivery without duplicate sends',
  { timeout: 15_000 }, async t => {
  const f = fixture(t);
  const source = `
    import { Store } from ${JSON.stringify(new URL('../src/database.ts', import.meta.url).href)};
    import { Notifications } from ${JSON.stringify(new URL('../src/notifications.ts', import.meta.url).href)};
    const store = new Store(process.env.PUSH_TEST_DATABASE);
    let finish;
    const notes = new Notifications(store, {
      publicConfig: () => ({ webPublicKey: '', harmonyConfigured: true }),
      send: () => new Promise(resolve => { finish = resolve; process.send('sent'); }),
    }, () => Number(process.env.PUSH_TEST_NOW));
    process.on('message', async message => {
      if (message === 'dispatch') { await notes.dispatch(); process.send('done'); }
      if (message === 'release') finish({ status: 'accepted', reason: 'accepted' });
      if (message === 'stop') { await notes.stop(); store.close(); process.disconnect(); }
    });
    process.send('ready');
  `;
  const children = [0, 1].map(() => spawn(process.execPath,
    ['--import', 'tsx', '--input-type=module', '-e', source], {
      env: { ...process.env, PUSH_TEST_DATABASE: f.path, PUSH_TEST_NOW: String(f.now) },
      stdio: ['ignore', 'ignore', 'pipe', 'ipc'], windowsHide: true,
    }));
  const exited = children.map(child => once(child, 'exit'));
  t.after(async () => {
    for (const child of children) if (child.exitCode === null) child.kill();
    await Promise.all(exited);
  });
  const next = (index: number) => once(children[index]!, 'message').then(([message]) => message);
  await Promise.all(children.map((_, i) => next(i).then(message => assert.equal(message, 'ready'))));
  const outcomes = children.map((_, i) => next(i));
  for (const child of children) child.send('dispatch');
  const results = await Promise.all(outcomes);
  assert.deepEqual(results.toSorted(), ['done', 'sent']);
  assert.equal(f.delivery().attempts, 1);
  assert.equal(f.delivery().status, 'sending');
  const winner = results.indexOf('sent');
  const completed = next(winner);
  children[winner]!.send('release');
  assert.equal(await completed, 'done');
  assert.equal(f.delivery().status, 'accepted');
  for (const child of children) child.send('stop');
  await Promise.all(exited);
});
