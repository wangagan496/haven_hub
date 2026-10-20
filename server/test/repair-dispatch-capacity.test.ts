import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, SLOT, NEXT, type Row } from './repair-fixture.js';
import type { PushMessage, PushTransport } from '../src/push-transport.js';

async function urgent(f: Awaited<ReturnType<typeof fixture>>) {
  return f.change('admin', await f.create('', { urgentRequest: true, asap: true }), 'priority', { priority: 'urgent', reason: '核实漏水' });
}

test('dispatch staffing: unassigned reservations block urgent overbooking and retain the admin task', async t => {
  const f = await fixture(t);
  const reservations = [await f.create(), await f.create()];
  const before = reservations.map(row => f.stored(row));
  const row = await urgent(f);
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=22`);
  const slot = options.slots.find((item: Row) => item.slot === SLOT);
  assert.equal(slot.occupied, 2);
  assert.equal(slot.unassigned, 2);
  assert.equal(slot.workerCount, 2);
  assert.equal(slot.dispatchable, false);
  assert.match(slot.reason, /人手/);
  for (let attempt = 0; attempt < 2; attempt++) {
    const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot: SLOT, workerId: f.ids.worker });
    assert.equal(result.status, 409);
    assert.match(result.message, /人手/);
  }
  assert.equal(f.stored(row).slot, '');
  assert.equal(f.stored(row).revision, row.revision);
  assert.deepEqual(reservations.map(item => f.stored(item)), before);
  const notes = f.store.db.prepare("SELECT active FROM notifications WHERE repairId=? AND taskKey='urgent_dispatch'").all(row.id);
  assert.deepEqual(notes.map(note => note.active), [1]);
});

test('dispatch staffing: stale options recheck reservations and exclude the order itself', async t => {
  const f = await fixture(t);
  let row = await urgent(f);
  await f.call('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=22`);
  await f.create();
  const other = await f.create();
  const blocked = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot: SLOT, workerId: f.ids.worker });
  assert.equal(blocked.status, 409);
  // The urgent order can still use another slot; retrying must not count itself twice.
  row = await f.change('admin', row, 'dispatch', { slot: NEXT, workerId: f.ids.worker });
  row = await f.change('admin', row, 'dispatch', { slot: NEXT, workerId: f.ids.worker2 });
  assert.equal(row.workerId, f.ids.worker2);
  assert.equal(f.stored(other).slot, SLOT);
});

test('dispatch staffing: two different workers cannot consume the last staffing place twice', async t => {
  const f = await fixture(t);
  await f.create();
  const rows = [await urgent(f), await urgent(f)];
  const results = await Promise.all(rows.map((row, index) => f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, {
    revision: row.revision, slot: SLOT, workerId: index ? f.ids.worker2 : f.ids.worker,
  })));
  assert.deepEqual(results.map(result => result.status).sort(), [200, 409]);
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).occupied, 2);
});

test('dispatch staffing: property push queues without reading admin pages, retries and stays deduplicated after rejection', async t => {
  const sent: PushMessage[] = [];
  let fail = true;
  const pushTransport: PushTransport = {
    publicConfig: () => ({ webPublicKey: '', harmonyConfigured: true }),
    send: async (_device, message) => { sent.push(message); return { status: fail ? 'failed' : 'accepted', reason: 'test transport' }; },
  };
  const f = await fixture(t, { pushTransport });
  f.notifications.register(f.ids.admin, { platform: 'harmony', token: 'test-admin-device', installationId: 'a'.repeat(64) });
  const requested = await f.create('', { urgentRequest: true, asap: true });
  const note = () => f.store.one("SELECT id,active FROM notifications WHERE repairId=? AND taskKey='urgent_request'", requested.id)!;
  assert.equal(note().active, 1);
  await f.notifications.dispatch();
  assert(sent.some(message => message.title === '紧急诉求待定级'));
  assert.equal(f.store.one('SELECT status FROM push_deliveries WHERE notificationId=?', String(note().id))?.status, 'failed');
  const count = sent.length;
  await f.notifications.dispatch();
  assert.equal(sent.length, count);
  fail = false; f.at(f.time() + 60001);
  await f.notifications.dispatch();
  assert.equal(f.store.one('SELECT status FROM push_deliveries WHERE notificationId=?', String(note().id))?.status, 'accepted');
  const row = await f.change('admin', requested, 'priority', { priority: 'urgent', reason: '确认急单' });
  await f.create(); await f.create();
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot: SLOT, workerId: f.ids.worker })).status, 409);
  }
  await f.notifications.dispatch();
  assert.equal(sent.filter(message => message.title === '急单待调度').length, 1);
  const task = f.store.one("SELECT id,active FROM notifications WHERE repairId=? AND taskKey='urgent_dispatch'", row.id)!;
  assert.equal(task.active, 1);
  f.notifications.read(f.ids.admin, String(task.id));
  assert.equal(f.store.one('SELECT active FROM notifications WHERE id=?', String(task.id))?.active, 1);
  await f.change('admin', row, 'dispatch', { slot: NEXT, workerId: f.ids.worker });
  assert.equal(f.store.one('SELECT active FROM notifications WHERE id=?', String(task.id))?.active, 0);
});

test('dispatch staffing: server timer sends urgent request with no property page open', { timeout: 15000 }, async t => {
  let notify!: () => void;
  const deliveredToTransport = new Promise<void>(resolve => { notify = resolve; });
  const pushTransport: PushTransport = {
    publicConfig: () => ({ webPublicKey: '', harmonyConfigured: true }),
    send: async (_device, message) => { if (message.title === '紧急诉求待定级') notify(); return { status: 'accepted', reason: 'test transport' }; },
  };
  const f = await fixture(t, { pushTransport, pushTimer: true });
  f.notifications.register(f.ids.admin, { platform: 'harmony', token: 'test-admin-device', installationId: 'b'.repeat(64) });
  await f.create('', { urgentRequest: true, asap: true });
  await deliveredToTransport;
});
