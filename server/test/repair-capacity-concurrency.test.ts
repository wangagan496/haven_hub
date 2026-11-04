import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fixture, START } from './repair-fixture.js';
import { Store } from '../src/database.js';
import { RepairRepository } from '../src/repair/repository.js';

const path = '/management/repair-capacities';

test('capacity writes without a reviewed revision are rejected without changing configuration', async t => {
  const f = await fixture(t);
  const before = await f.call('admin', 'GET', path);
  for (const target of [path, `${path}/weekdays/7`, `${path}/2026-10-18`]) {
    const result = await f.raw('admin', 'PUT', target, { capacities: { '10': 0 } });
    assert.equal(result.code, 40000, target);
  }
  for (const target of [`${path}/weekdays/7`, `${path}/2026-10-18`]) {
    assert.equal((await f.raw('admin', 'DELETE', target)).code, 40000, target);
  }
  assert.deepEqual(await f.call('admin', 'GET', path), before);
});

test('one atomic capacity snapshot covers defaults, weekdays and dates; stale competing writes do not overwrite', async t => {
  const f = await fixture(t);
  const first = await f.call('admin', 'GET', `${path}?date=2026-10-18`);
  assert.match(first.revision, /^[a-f0-9]{64}$/);
  assert.deepEqual(first.templates, await f.call('admin', 'GET', `${path}/weekdays`));
  assert.equal((await f.call('admin', 'GET', path)).revision, first.revision);
  // Two independently read pages both try to change the same hour.
  const results = await Promise.all([4, 9].map(value => f.raw('admin', 'PUT', path,
    { revision: first.revision, capacities: { '10': value } })));
  assert.deepEqual(results.map(result => result.status).sort(), [200, 409]);
  const winner = results.find(result => result.status === 200)!;
  const current = await f.call('admin', 'GET', path);
  assert.equal(current.defaults['10'], winner.data.defaults['10']);
  assert.equal(current.revision, winner.data.revision);
  assert.notEqual(current.revision, first.revision);
  // A default change also invalidates a page that was editing inherited weekday/date values.
  for (const target of [`${path}/weekdays/7`, `${path}/2026-10-18`]) {
    assert.equal((await f.raw('admin', 'PUT', target,
      { revision: first.revision, capacities: { '10': 0 } })).status, 409);
  }
  assert.deepEqual(await f.call('admin', 'GET', path), current);
});

test('stale clear cannot erase newer weekday or date values; review and retry preserves fallback rules', async t => {
  const f = await fixture(t);
  for (const target of [`${path}/weekdays/7`, `${path}/2026-10-18`]) {
    const before = await f.call('admin', 'GET', path);
    await f.call('admin', 'PUT', target, { revision: before.revision, capacities: { '10': 0 } });
    const changed = await f.call('admin', 'GET', `${path}?date=2026-10-18`);
    assert.equal(changed.effective['10'], 0);
    const stale = await f.raw('admin', 'DELETE', target, { revision: before.revision });
    assert.equal(stale.status, 409);
    assert.deepEqual(await f.call('admin', 'GET', `${path}?date=2026-10-18`), changed);
    await f.call('admin', 'DELETE', target, { revision: changed.revision });
    const cleared = await f.call('admin', 'GET', `${path}?date=2026-10-18`);
    assert.equal(cleared.effective['10'], cleared.defaults['10']);
  }
});

test('capacity revision is not authorization and malformed preconditions never write', async t => {
  const f = await fixture(t);
  const before = await f.call('admin', 'GET', path);
  for (const role of ['resident', 'worker'] as const) {
    for (const target of [path, `${path}/weekdays/7`, `${path}/2026-10-18`]) {
      assert.equal((await f.raw(role, 'PUT', target,
        { revision: before.revision, capacities: { '10': 0 } })).status, 403);
    }
  }
  for (const revision of [null, 0, {}, '', 'bad', 'a'.repeat(63)]) {
    assert.equal((await f.raw('admin', 'PUT', path, { revision, capacities: { '10': 0 } })).code, 40000);
  }
  assert.equal((await f.raw('admin', 'PUT', path,
    { revision: 'a'.repeat(64), capacities: { '10': 0 } })).status, 409);
  assert.deepEqual(await f.call('admin', 'GET', path), before);
});

test('capacity versions survive reopening and detect changes made by another database connection', () => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-capacity-concurrency-'));
  const file = join(directory, 'fixture.sqlite');
  let first = new Store(file);
  const second = new Store(file);
  try {
    first.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('audit-admin','13900001111','测试管理员','admin')");
    const a = new RepairRepository(first, () => START, () => {}, '');
    const b = new RepairRepository(second, () => START, () => {}, '');
    const snapshot = a.capacitySnapshot('2026-10-18');
    assert.equal(b.capacitySnapshot().revision, snapshot.revision);
    b.saveCapacities({ '10': 3 }, snapshot.revision, 'audit-admin', '2026-10-18');
    assert.throws(() => a.saveWeekdayCapacities(7, { '10': 0 }, snapshot.revision, 'audit-admin'), { status: 409 });
    assert.equal(a.capacitySnapshot('2026-10-18').effective['10'], 3);
    const committed = b.capacitySnapshot('2026-10-18');
    first.close();
    first = new Store(file);
    const reopened = new RepairRepository(first, () => START, () => {}, '');
    assert.deepEqual(reopened.capacitySnapshot('2026-10-18'), committed);
    assert.equal(first.one('PRAGMA user_version')?.user_version, 13);
  } finally { first.close(); second.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('capacity partial-write failure rolls back all hours and leaves the reviewed content version unchanged', () => {
  const store = new Store(':memory:');
  try {
    store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('audit-admin','13900001111','测试管理员','admin')");
    const repository = new RepairRepository(store, () => START, () => {}, '');
    const before = repository.capacitySnapshot();
    store.db.exec(`CREATE TRIGGER capacity_failure BEFORE UPDATE ON repair_capacity_defaults
      WHEN NEW.hour='09' BEGIN SELECT RAISE(ABORT, 'injected capacity failure'); END;`);
    assert.throws(() => repository.saveCapacities({ '08': 1, '09': 2 }, before.revision, 'audit-admin'), /injected capacity failure/);
    assert.deepEqual(repository.capacitySnapshot(), before);
    store.db.exec('DROP TRIGGER capacity_failure');
    // Content versions intentionally remain stable when values do not change.
    assert.equal(repository.saveCapacities(before.defaults, before.revision, 'audit-admin').revision, before.revision);
    repository.saveWeekdayCapacities(7, { '10': 0 }, before.revision, 'audit-admin');
    const changed = repository.capacitySnapshot();
    assert.notEqual(changed.revision, before.revision);
    assert.throws(() => repository.clearWeekdayCapacities(7, before.revision, 'audit-admin'), { status: 409 });
  } finally { store.close(); }
});
