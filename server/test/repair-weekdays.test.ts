import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/database.js';
import { RepairRepository } from '../src/repair/repository.js';
import { slotAvailability } from '../src/repair/schedule.js';
import { fixture, START, type Row } from './repair-fixture.js';

const path = '/management/repair-capacities';

test('weekdays: empty seven-day templates and per-hour date > weekday > default precedence', async t => {
  const f = await fixture(t);
  assert.deepEqual(await f.call('admin', 'GET', `${path}/weekdays`), { 1: {}, 2: {}, 3: {}, 4: {}, 5: {}, 6: {}, 7: {} });
  await f.call('admin', 'PUT', path, { capacities: { '08': 12, '09': 13, '10': 14 } });
  await f.call('admin', 'PUT', `${path}/weekdays/6`, { capacities: { '08': 20, '09': 21 } });
  await f.call('admin', 'PUT', `${path}/2026-10-17`, { capacities: { '08': 30 } });
  const values = await f.call('admin', 'GET', `${path}?date=2026-10-17`);
  assert.equal(values.weekday, 6);
  assert.deepEqual(['08', '09', '10'].map(hour => [values.effective[hour], values.sources[hour]]),
    [[30, 'date'], [21, 'weekday'], [14, 'default']]);
  assert.equal(values.effectiveTotal, Object.values<number>(values.effective).reduce((a, b) => a + b, 0));
  assert.equal(values.defaultTotal, Object.values<number>(values.defaults).reduce((a, b) => a + b, 0));
  assert.equal(values.warnings.find((row: Row) => row.hour === '08').capacity, 30);
  const defaults = await f.call('admin', 'GET', path);
  assert.equal(defaults.weekday, null);
  assert.equal(defaults.effective['08'], 12);
  assert.ok(Object.values(defaults.sources).every(source => source === 'default'));
});

test('weekdays: public today uses Beijing Sunday while UTC remains Saturday', async t => {
  const f = await fixture(t);
  await f.call('admin', 'PUT', `${path}/weekdays/6`, { capacities: { '10': 6 } });
  await f.call('admin', 'PUT', `${path}/weekdays/7`, { capacities: { '10': 7 } });
  f.at(Date.parse('2026-10-17T17:00:00Z'));
  const result = await f.call('resident', 'GET', '/repair/slots');
  assert.equal(result.today, '2026-10-18');
  assert.equal(result.date, '2026-10-18');
  assert.equal(result.slots.find((row: Row) => row.slot.endsWith('#10')).capacity, 7);
});

test('weekdays: Saturday zero disables querying and booking; Sunday unaffected; date override restores slot', async t => {
  const f = await fixture(t);
  await f.call('admin', 'PUT', `${path}/weekdays/6`, { capacities: { '10': 0 } });
  const saturday = (await f.slots('2026-10-17')).slots.find((row: Row) => row.slot.endsWith('#10'));
  assert.equal(saturday.selectable, false);
  assert.equal(saturday.remaining, 0);
  assert.equal((await f.raw('resident', 'POST', '/repair', { ...f.body, slot: '2026-10-17#10' })).status, 409);
  assert.equal((await f.slots('2026-10-18')).slots.find((row: Row) => row.slot.endsWith('#10')).selectable, true);
  await f.create('2026-10-18#10');
  await f.call('admin', 'PUT', `${path}/2026-10-17`, { capacities: { '10': 5 } });
  assert.equal((await f.slots('2026-10-17')).slots.find((row: Row) => row.slot.endsWith('#10')).selectable, true);
  await f.create('2026-10-17#10');
});

test('weekdays: partial updates preserve other hours; deleting restores fallback without deleting date overrides', async t => {
  const f = await fixture(t);
  await f.call('admin', 'PUT', `${path}/weekdays/6`, { capacities: { '10': 0 } });
  await f.call('admin', 'PUT', `${path}/weekdays/6`, { capacities: { '11': 3 } });
  assert.deepEqual((await f.call('admin', 'GET', `${path}/weekdays`))['6'], { '10': 0, '11': 3 });
  await f.call('admin', 'PUT', `${path}/2026-10-17`, { capacities: { '10': 5 } });
  await f.call('admin', 'DELETE', `${path}/weekdays/6`);
  let values = await f.call('admin', 'GET', `${path}?date=2026-10-17`);
  assert.equal(values.effective['10'], 5);
  assert.equal(values.sources['10'], 'date');
  assert.equal(values.effective['11'], values.defaults['11']);
  await f.call('admin', 'PUT', `${path}/weekdays/6`, { capacities: { '10': 0 } });
  await f.call('admin', 'DELETE', `${path}/2026-10-17`);
  values = await f.call('admin', 'GET', `${path}?date=2026-10-17`);
  assert.equal(values.sources['10'], 'weekday');
  assert.equal(values.effective['10'], 0);
  await f.call('admin', 'DELETE', `${path}/weekdays/6`);
  values = await f.call('admin', 'GET', `${path}?date=2026-10-17`);
  assert.equal(values.effective['10'], values.defaults['10']);
});

test('weekdays: lowering below occupancy keeps records unchanged and clamps remaining at zero', async t => {
  const f = await fixture(t);
  const row = await f.create();
  const before = f.stored(row);
  await f.call('admin', 'PUT', `${path}/weekdays/7`, { capacities: { '10': 0 } });
  assert.deepEqual(f.stored(row), before);
  const slot = (await f.slots()).slots.find((row: Row) => row.slot.endsWith('#10'));
  assert.equal(slot.occupied, 1);
  assert.equal(slot.remaining, 0);
  assert.equal(slot.selectable, false);
  const saved = await f.call('admin', 'PUT', `${path}/weekdays/7`, { capacities: { '10': 1_000_000 } });
  assert.equal(saved['7']['10'], 1_000_000);
  assert.ok((await f.call('admin', 'GET', `${path}?date=2026-10-18`)).warnings.length);
});

for (const day of ['0', '8', '1.5', 'abc']) test(`weekdays: rejects weekday ${day}`, async t => {
  const f = await fixture(t);
  for (const method of ['PUT', 'DELETE']) {
    const result = await f.raw('admin', method, `${path}/weekdays/${day}`, method === 'PUT' ? { capacities: { '10': 1 } } : undefined);
    assert.equal(result.code, 40000);
  }
});

test('weekdays: shared validation rejects invalid hours, negative, fraction, string and excess capacities', async t => {
  const f = await fixture(t);
  for (const capacities of [{ '12': 3 }, { '8': 1 }, { '10': -1 }, { '10': 0.5 }, { '10': '3' }, { '10': 1_000_001 }, {}]) {
    assert.equal((await f.raw('admin', 'PUT', `${path}/weekdays/1`, { capacities })).code, 40000);
  }
  assert.deepEqual((await f.call('admin', 'GET', `${path}/weekdays`))['1'], {});
});

test('weekdays: resident and worker cannot read or change templates', async t => {
  const f = await fixture(t);
  for (const role of ['resident', 'worker'] as const) {
    assert.equal((await f.raw(role, 'GET', `${path}/weekdays`)).status, 403);
    assert.equal((await f.raw(role, 'PUT', `${path}/weekdays/1`, { capacities: { '10': 1 } })).status, 403);
    assert.equal((await f.raw(role, 'DELETE', `${path}/weekdays/1`)).status, 403);
  }
});

test('weekdays migration: v4 to v5 preserves raw defaults, overrides, repair payloads and exact availability; reopen is stable', () => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-weekdays-v4-'));
  const file = join(directory, 'fixture.sqlite');
  let store = new Store(file);
  try {
    store.run("INSERT INTO users(id,mobile,nickName) VALUES ('r','13800138000','迁移虚构住户')");
    store.save('repairs', 'r', { id: 'legacy', status: 2, revision: 9, slot: '2026-10-18#10', agreedTime: '2026-10-18T10:00:00+08:00', timeline: [] });
    store.run("UPDATE repair_capacity_defaults SET capacity=83 WHERE hour='10'");
    store.run("INSERT INTO repair_capacity_overrides VALUES ('2026-10-18','10',7)");
    store.db.exec('DROP TABLE repair_capacity_weekdays; PRAGMA user_version=4');
    const snapshot = () => ({ defaults: store.db.prepare('SELECT * FROM repair_capacity_defaults ORDER BY hour').all(),
      overrides: store.db.prepare('SELECT * FROM repair_capacity_overrides ORDER BY date,hour').all(),
      repairs: store.db.prepare('SELECT * FROM repairs ORDER BY seq').all() });
    const before = snapshot();
    const effective = { ...Object.fromEntries(before.defaults.map(row => [String(row.hour), Number(row.capacity)])), '10': 7 };
    const rows = before.repairs.map(row => JSON.parse(String(row.payload)));
    const availability = slotAvailability('2026-10-18', effective, rows, START);
    store.close();
    store = new Store(file);
    assert.equal(store.one('PRAGMA user_version')?.user_version, 7);
    assert.deepEqual(snapshot(), before);
    assert.equal(store.one('SELECT COUNT(*) AS count FROM repair_capacity_weekdays')?.count, 0);
    const repository = new RepairRepository(store, () => START, () => {}, '');
    assert.deepEqual(slotAvailability('2026-10-18', repository.capacities('2026-10-18').effective, repository.scheduledRowsForDate('2026-10-18'), START), availability);
    assert.equal(availability.find(row => row.slot.endsWith('#10'))?.remaining, 6);
    repository.saveWeekdayCapacities(7, { '10': 0 });
    store.close();
    store = new Store(file);
    assert.equal(store.one('PRAGMA user_version')?.user_version, 7);
    assert.deepEqual(snapshot(), before);
    assert.equal(store.one("SELECT capacity FROM repair_capacity_weekdays WHERE weekday=7 AND hour='10'")?.capacity, 0);
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});
