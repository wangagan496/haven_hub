import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, START, type Row } from './repair-fixture.js';
import { RepairService } from '../src/repair/service.js';
import { RepairViews } from '../src/repair/views.js';
import { Status, newRound } from '../src/repair/model.js';

function seed(f: Awaited<ReturnType<typeof fixture>>, count: number, owner = f.ids.resident) {
  f.store.transaction(() => {
    for (let index = 0; index < count; index++) {
      f.store.save('repairs', owner, { id: `${owner}-repair-${index}`, status: Status.cancelled, revision: index,
        repairItemId: '1004', description: `row ${index}`, createdAt: new Date(START - index * 1000).toISOString(),
        mobile: '13800138000', workerMobile: '13800138002', previousWorkers: ['private-worker'],
        poolShortage: { internal: true }, timeline: [], rounds: [newRound(1, '首次维修', '')], pendings: [] });
    }
  });
}

test('resident pages preserve full-list order, totals, masking and action fields', async t => {
  const f = await fixture(t);
  seed(f, 47);
  seed(f, 8, f.ids.other);
  const expected = new RepairService(f.store, f.time, f.config.propertyPhone).residentList(f.ids.resident);
  const collected: Row[] = [];
  for (let current = 1; current <= 7; current++) {
    const page = await f.call('resident', 'GET', `/repair?current=${current}&pageSize=7`);
    assert.equal(page.total, 47);
    assert.equal(page.pageTotal, 7);
    assert.equal(page.current, current);
    assert.deepEqual(page.rows, expected.slice((current - 1) * 7, current * 7));
    collected.push(...page.rows);
  }
  assert.deepEqual(collected, expected);
  assert.equal(collected[0]?.id, `${f.ids.resident}-repair-46`, 'sequence order, not createdAt');
  for (const row of collected) {
    assert.equal(row.mobile, '138****8000');
    assert.equal(row.workerMobile, '138****8002');
    assert.equal(row.previousWorkers, undefined);
    assert.equal(row.poolShortage, undefined);
    assert(Array.isArray(row.availableActions));
    assert.equal(row.availableActions[0]?.enabled, false);
  }
});

test('corrupt records before, inside and after a page do not consume offsets or inflate totals', async t => {
  const f = await fixture(t);
  seed(f, 9);
  f.store.run('UPDATE repairs SET payload=? WHERE id=?', 'null', `${f.ids.resident}-repair-8`);
  f.store.run('UPDATE repairs SET payload=? WHERE id=?', '[]', `${f.ids.resident}-repair-5`);
  f.store.run('UPDATE repairs SET payload=? WHERE id=?', JSON.stringify({ id: 'broken-rounds', status: 0, rounds: [null] }), `${f.ids.resident}-repair-2`);
  f.store.db.exec('PRAGMA ignore_check_constraints=ON');
  try { f.store.run('UPDATE repairs SET payload=? WHERE id=?', '{bad-json', `${f.ids.resident}-repair-0`); }
  finally { f.store.db.exec('PRAGMA ignore_check_constraints=OFF'); }
  const expected = new RepairService(f.store, f.time, f.config.propertyPhone).residentList(f.ids.resident);
  assert.equal(expected.length, 5);
  for (let current = 1; current <= 4; current++) {
    const page = await f.call('resident', 'GET', `/repair?current=${current}&pageSize=2`);
    assert.equal(page.total, 5);
    assert.equal(page.pageTotal, 3);
    assert.deepEqual(page.rows, expected.slice((current - 1) * 2, current * 2));
  }
});

test('first page settles expired records outside its window and still invokes notification hooks', async t => {
  const f = await fixture(t);
  const round = newRound(1, '首次维修', new Date(START - 3600000).toISOString());
  round.confirmDeadline = new Date(START).toISOString();
  round.completedAt = new Date(START - 3600000).toISOString();
  round.cost = 10;
  round.note = '已完成';
  f.store.save('repairs', f.ids.resident, { id: 'off-page-expired', status: Status.confirming, revision: 4,
    repairItemId: '1004', workerId: f.ids.worker, rounds: [round], timeline: [], pendings: [] });
  seed(f, 3);
  const saved: string[] = [];
  const original = f.store.onRepairSaved;
  f.store.onRepairSaved = (owner, record) => { saved.push(record.id); original?.(owner, record); };
  const page = await f.call('resident', 'GET', '/repair?pageSize=1');
  assert.equal(page.rows.length, 1);
  assert.notEqual(page.rows[0].id, 'off-page-expired');
  assert.equal(page.total, 4);
  const settled = f.store.get('repairs', f.ids.resident, 'off-page-expired')!;
  assert.equal(settled.status, Status.completed);
  assert.equal(settled.revision, 5);
  assert(saved.includes('off-page-expired'));
  const last = await f.call('resident', 'GET', '/repair?current=4&pageSize=1');
  assert.equal(last.rows[0].status, Status.completed);
  assert.equal(last.rows[0].revision, 5);
});

test('empty, out-of-range, default and maximum-size pages retain response contract', async t => {
  const f = await fixture(t);
  assert.deepEqual(await f.call('resident', 'GET', '/repair'), { rows: [], total: 0, pageTotal: 0, current: 1 });
  seed(f, 205);
  const defaults = await f.call('resident', 'GET', '/repair');
  assert.equal(defaults.rows.length, 20);
  assert.equal(defaults.pageTotal, 11);
  const max = await f.call('resident', 'GET', '/repair?pageSize=200');
  assert.equal(max.rows.length, 200);
  assert.equal(max.pageTotal, 2);
  for (const current of [3, 1000000, Number.MAX_SAFE_INTEGER]) {
    assert.deepEqual(await f.call('resident', 'GET', `/repair?current=${current}&pageSize=200`),
      { rows: [], total: 205, pageTotal: 2, current });
  }
});

test('invalid page inputs are rejected before settlement and account scope stays server-selected', async t => {
  const f = await fixture(t);
  seed(f, 4);
  seed(f, 2, f.ids.other);
  const before = f.store.one('SELECT total_changes() AS count')?.count;
  for (const query of ['current=0','current=-1','current=1.5','current=NaN','pageSize=0','pageSize=201','pageSize=2.5','current=1&current=2']) {
    const response = await f.raw('resident', 'GET', '/repair?' + query);
    assert.equal(response.code, 40000, query);
  }
  assert.equal(f.store.one('SELECT total_changes() AS count')?.count, before);
  const own = await f.call('resident', 'GET', `/repair?pageSize=1&userId=${f.ids.other}`);
  assert.equal(own.total, 4);
  assert.equal(own.rows[0].id, `${f.ids.resident}-repair-3`);
  const other = await f.call('other', 'GET', '/repair');
  assert.equal(other.total, 2);
  assert.equal((await f.raw(undefined, 'GET', '/repair')).status, 401);
});

test('resident HTTP pagination reads through a cursor instead of materializing every SQL row', async t => {
  const f = await fixture(t);
  seed(f, 65);
  const prepare = f.store.db.prepare.bind(f.store.db);
  let orderedOwnerQueries = 0;
  t.mock.method(f.store.db, 'prepare', (sql: string) => {
    const statement = prepare(sql);
    if (/SELECT id, payload FROM repairs WHERE userId = \? ORDER BY seq DESC/.test(sql)) {
      orderedOwnerQueries++;
      statement.all = () => { throw new Error('unbounded resident row materialization'); };
    }
    return statement;
  });
  const response = await f.raw('resident', 'GET', '/repair?pageSize=3&current=2');
  assert.equal(response.code, 10000, response.message);
  assert.equal(response.data.total, 65);
  assert.equal(response.data.rows.length, 3);
  assert(orderedOwnerQueries > 0);
});

test('existing owner-order index supports resident page scan without temporary sort', async t => {
  const f = await fixture(t);
  const plan = f.store.db.prepare('EXPLAIN QUERY PLAN SELECT id, payload FROM repairs WHERE userId = ? ORDER BY seq DESC').all(f.ids.resident);
  const text = plan.map(row => row.detail).join(' ');
  assert.match(text, /SEARCH repairs USING INDEX repairs_owner/);
  assert.doesNotMatch(text, /TEMP B-TREE/);
});

test('streamed pages preserve corrupt-record log deduplication and reset it after recovery', () => {
  const logs: object[] = [];
  const views = new RepairViews(() => START, '020-88888888', event => logs.push(event));
  const broken = [{ id: 'broken', payload: 'null' }];
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.deepEqual(views.pageViews(broken, 'resident', 1, 1), { rows: [], total: 0, pageTotal: 0, current: 1 });
  }
  assert.equal(logs.length, 1);
  assert.deepEqual(logs[0], { event: 'repair_list_record_skipped', repairId: 'broken', role: 'resident', type: 'TypeError' });
  assert.equal(views.pageViews([{ id: 'broken', payload: JSON.stringify({ id: 'broken', status: 0 }) }], 'resident', 1, 1).total, 1);
  views.pageViews(broken, 'resident', 1, 1);
  assert.equal(logs.length, 2);
});

test('cursor failure after the requested page propagates instead of returning a partial total', () => {
  let closed = false;
  function* failedRows() {
    try {
      yield { id: 'first', payload: JSON.stringify({ id: 'first', status: 0 }) };
      throw new Error('injected cursor failure');
    } finally { closed = true; }
  }
  const views = new RepairViews(() => START, '020-88888888', () => {});
  assert.throws(() => views.pageViews(failedRows(), 'resident', 1, 1), /injected cursor failure/);
  assert.equal(closed, true);
});

test('resident filters apply before page offsets and count only matching visible records', async t => {
  const f = await fixture(t);
  seed(f, 27);
  seed(f, 9, f.ids.other);
  const statuses = [Status.cancelled, Status.pending, Status.assigned, Status.processing, Status.confirming, Status.completed, 99];
  for (let index = 0; index < 27; index++) {
    const record = f.store.get('repairs', f.ids.resident, `${f.ids.resident}-repair-${index}`)!;
    record.status = statuses[index % statuses.length];
    f.store.save('repairs', f.ids.resident, record, true);
  }
  // Corrupt matching row must not inflate a filtered total.
  f.store.save('repairs', f.ids.resident, { id: 'broken-filter-row', status: Status.pending, rounds: [null] });
  const all = new RepairService(f.store, f.time, f.config.propertyPhone).residentList(f.ids.resident);
  const filters: Record<string, number[]> = { pending: [1], waiting: [5], processing: [2, 6], completed: [3] };
  for (const [filter, accepted] of Object.entries(filters)) {
    const expected = all.filter(row => accepted.includes(Number(row.status)));
    assert(expected.length > 2);
    const result: Row[] = [];
    for (let current = 1; current <= Math.ceil(expected.length / 2) + 1; current++) {
      const page = await f.call('resident', 'GET', `/repair?filter=${filter}&current=${current}&pageSize=2&userId=${f.ids.other}`);
      assert.equal(page.total, expected.length, filter);
      assert.equal(page.filter, filter);
      assert.equal(page.pageTotal, Math.ceil(expected.length / 2), filter);
      assert.deepEqual(page.rows, expected.slice((current - 1) * 2, current * 2), filter);
      result.push(...page.rows);
    }
    assert.deepEqual(result, expected, filter);
  }
  assert.deepEqual((await f.call('resident', 'GET', '/repair?filter=all&pageSize=200')).rows, all);
});

test('invalid resident filters fail before settlement; absent filters preserve older clients', async t => {
  const f = await fixture(t);
  seed(f, 1);
  const before = f.store.one('SELECT total_changes() AS count')?.count;
  for (const query of ['filter=unknown', 'filter=', 'filter=1', 'filter=all&filter=pending']) {
    assert.equal((await f.raw('resident', 'GET', '/repair?' + query)).code, 40000, query);
  }
  assert.equal(f.store.one('SELECT total_changes() AS count')?.count, before);
  assert.deepEqual(await f.call('resident', 'GET', '/repair'), await f.call('resident', 'GET', '/repair?filter=all'));
});

test('filtered pages reflect settlement before filtering and preserve off-filter notifications', async t => {
  const f = await fixture(t);
  const round = newRound(1, '首次维修', new Date(START - 3600000).toISOString());
  round.confirmDeadline = new Date(START).toISOString();
  round.completedAt = new Date(START - 3600000).toISOString();
  f.store.save('repairs', f.ids.resident, { id: 'expired', status: Status.confirming, revision: 1,
    repairItemId: '1004', workerId: f.ids.worker, rounds: [round], timeline: [], pendings: [] });
  const saved: string[] = [];
  const original = f.store.onRepairSaved;
  f.store.onRepairSaved = (owner, record) => { saved.push(record.id); original?.(owner, record); };
  const processing = await f.call('resident', 'GET', '/repair?filter=processing');
  assert.equal(processing.total, 0);
  assert.deepEqual(processing.rows, []);
  assert(saved.includes('expired'));
  const completed = await f.call('resident', 'GET', '/repair?filter=completed');
  assert.equal(completed.total, 1);
  assert.equal(completed.rows[0].id, 'expired');
  assert.equal(completed.rows[0].revision, 2);
});
