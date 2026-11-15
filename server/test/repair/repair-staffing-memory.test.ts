import test from 'node:test';
import assert from 'node:assert/strict';
import { Store, type RecordData } from '../../src/database.js';
import { RepairRepository } from '../../src/repair/repository.js';
import { RepairViews } from '../../src/repair/views.js';
import { StaffingContext, readWorkforce, staffingPlan, staffingRejection } from '../../src/repair/workforce.js';
import { slotAvailability, type WorkerAvailability } from '../../src/repair/schedule.js';
import { compareQueue } from '../../src/repair/policy.js';
import { fixture, START, SLOT, NEXT } from './repair-fixture.js';

const workers: WorkerAvailability[] = [
  { id: 'w1', skills: ['plumbing', 'electrical'], skillsKnown: true, leaves: [] },
  { id: 'w2', skills: ['plumbing'], skillsKnown: true, leaves: [{ date: '2026-10-19', hour: '' }] },
];
const capacities = () => ({ '10': 30, '11': 30 });
const views = new RepairViews(() => START, '', () => {});
const repoFor = (store: Store) => new RepairRepository(store, () => START, () => {}, '');

// Independent pre-change storage: keep complete records and the original insertion order.
function fullContext(records: RecordData[], workforce = workers) {
  const context = new StaffingContext(workforce, []);
  for (const record of records) {
    const slot = String(record.slot ?? '');
    const rows = context.slots.get(slot) ?? [];
    rows.push(record); context.slots.set(slot, rows);
  }
  return context;
}

function heavyRecord(id: string): RecordData {
  return { id, status: 1, workerId: '', repairItemId: '1004', slot: SLOT, revision: 3,
    repairItemName: '水管', priority: 'medium', urgentRequest: true, createdAt: '2026-10-01',
    agreedTime: '2026-10-18T10:00:00+08:00', houseId: 'house', community: '小区', building: '1栋', description: '漏水',
    attachment: ['private-image'], mobile: '13800138000',
    timeline: Array.from({ length: 30 }, (_, index) => ({ index, detail: '历史记录'.repeat(100) })),
    rounds: [{ number: 1, note: '维修结果'.repeat(200) }], pendings: [] };
}

function outcome(context: StaffingContext, records: RecordData[]) {
  const slots = [SLOT, NEXT, '', '2026-10-19#10'];
  return {
    plans: slots.map(slot => context.plan(slot)),
    eligible: records.map(row => [row.id, context.eligible(row)]),
    reasons: slots.map(slot => context.reason(slot, { id: 'candidate', status: 1, repairItemId: '1004', slot })),
    alternatives: ['plumbing', 'electrical', 'doors', ''].map(skill =>
      context.alternatives(skill as 'plumbing' | 'electrical' | 'doors' | '', START, capacities)),
    shortages: context.shortages(),
    pool: [...context.slots.values()].flat().filter(row => context.eligible(row).includes('w1'))
      .sort(compareQueue).map(row => views.pool(row)),
  };
}

test('staffing snapshots retain all orders without retaining their history and private payloads', () => {
  const records = Array.from({ length: 80 }, (_, i) => heavyRecord(`r${i}`));
  const before = JSON.stringify(records);
  const context = new StaffingContext(workers, records);
  const retained = [...context.slots.values()].flat();
  assert.equal(retained.length, records.length);
  assert(JSON.stringify(retained).length < before.length / 10, 'staffing snapshot retains full history payloads');
  assert.equal(JSON.stringify(records), before, 'source records must stay intact');
  assert.deepEqual(outcome(context, records), outcome(fullContext(records), records));
});

test('compact snapshots preserve legacy status, skill, ordering, occupancy and pool presentation', () => {
  const records: RecordData[] = [1, 2, 3, 4, 0, 5, '1', '4', null].map((status, i) => ({
    ...heavyRecord(`r${i}`), status, workerId: i % 2 ? 'w1' : '',
    slot: i % 3 ? SLOT : NEXT, requiredSkill: i % 2 ? 'electrical' : 'unknown',
    priority: i % 4 ? 'light' : 'urgent', urgentRequest: i % 2 === 0,
  }));
  records.push({ id: 'unscheduled', status: 1, repairItemId: '1004' },
    { ...heavyRecord('override'), repairItemId: '1003', requiredSkill: 'doors' },
    { ...heavyRecord('tied-b'), createdAt: '2026-10-02' },
    { ...heavyRecord('tied-a'), createdAt: '2026-10-02' });
  const context = new StaffingContext(workers, records);
  assert.deepEqual(outcome(context, records), outcome(fullContext(records), records));
  for (const slot of [SLOT, NEXT]) {
    assert.deepEqual(context.plan(slot), staffingPlan(records, slot, workers));
    const candidate = { id: 'candidate', status: 1, repairItemId: '1004', workerId: 'w1' };
    assert.equal(context.reason(slot, candidate), staffingRejection(records, slot, workers, candidate));
  }
  assert.deepEqual(slotAvailability('2026-10-18', capacities(), [...context.slots.values()].flat(), START),
    slotAvailability('2026-10-18', capacities(), records, START));
});

test('saved moves and cancellation refresh compact snapshots and invalidate cached decisions', () => {
  let records = [heavyRecord('moving'), { ...heavyRecord('held'), status: 2, workerId: 'w1', slot: NEXT }];
  const context = new StaffingContext(workers, records);
  outcome(context, records);
  for (const changes of [{ slot: NEXT }, { status: 0 }, { slot: '', status: 1, requiredSkill: 'electrical' }]) {
    const previous = records[0]!;
    const changed = { ...previous, ...changes };
    context.saved(String(previous.slot), changed);
    records = [changed, records[1]!];
    assert.deepEqual(outcome(context, records), outcome(fullContext(records), records));
    assert(JSON.stringify([...context.slots.values()].flat()).length < JSON.stringify(records).length / 10);
  }
  const record = records[0]!;
  context.saved(String(record.slot), record);
  record.description = 'later mutation';
  assert.notEqual(context.slots.get('')!.find(row => row.id === record.id)!.description, record.description);
});

test('resident HTTP reads build global staffing without materializing all SQL payloads', async t => {
  const f = await fixture(t);
  for (let i = 0; i < 15; i++) f.store.save('repairs', f.ids.resident, { ...heavyRecord(`r${i}`), status: 0 });
  const prepare = f.store.db.prepare.bind(f.store.db);
  let scans = 0;
  t.mock.method(f.store.db, 'prepare', (sql: string) => {
    const statement = prepare(sql);
    if (sql === 'SELECT id, payload FROM repairs ORDER BY seq DESC') {
      scans++;
      statement.all = () => { throw new Error('unbounded staffing SQL materialization'); };
    }
    return statement;
  });
  const result = await f.raw('resident', 'GET', '/repair?pageSize=1');
  assert.equal(result.code, 10000, result.message);
  assert.equal(result.data.total, 15);
  assert(scans > 0);
});

test('staffing cursor skips malformed payloads but propagates cursor failure and closes it', t => {
  const store = new Store(':memory:');
  try {
    store.run("INSERT INTO users(id,mobile,nickName) VALUES ('owner','13800138000','owner')");
    for (const [index, payload] of ['null', '[]', '1', JSON.stringify(heavyRecord('valid'))].entries()) {
      store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', `r${index}`, 'owner', payload);
    }
    const repository = repoFor(store);
    assert.equal([...repository.staffingContext().slots.values()].flat().length, 1);
    const prepare = store.db.prepare.bind(store.db);
    let closed = false;
    t.mock.method(store.db, 'prepare', (sql: string) => {
      const statement = prepare(sql);
      if (sql === 'SELECT id, payload FROM repairs ORDER BY seq DESC') {
        statement.iterate = function* () {
          try { yield { id: 'valid', payload: JSON.stringify(heavyRecord('valid')) }; throw new Error('cursor failed'); }
          finally { closed = true; }
        };
      }
      return statement;
    });
    assert.throws(() => repository.staffingContext(), /cursor failed/);
    assert(closed);
  } finally { store.close(); }
});

test('filtered settlement preserves complete stored records, cross-owner shortage cleanup and save hooks', () => {
  const stores = [new Store(':memory:'), new Store(':memory:')];
  try {
    const hooks: RecordData[][] = [[], []];
    const repositories = stores.map((store, index) => {
      for (const id of ['owner', 'other']) store.run('INSERT INTO users(id,mobile,nickName) VALUES (?,?,?)', id, id, id);
      for (const worker of workers) {
        store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')", worker.id, worker.id, worker.id);
        for (const skill of worker.skills) store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)', worker.id, skill);
      }
      const records = [heavyRecord('a'), heavyRecord('b'), heavyRecord('c'),
        { ...heavyRecord('old-shortage'), status: 0, poolShortage: { stale: true } }];
      records.forEach((row, i) => store.save('repairs', i % 2 ? 'other' : 'owner', row));
      store.onRepairSaved = (_owner, record) => hooks[index]!.push(structuredClone(record));
      const repository = repoFor(store);
      if (index === 1) repository.staffingContext = () => fullContext(
        repository.allRows().map(row => JSON.parse(String(row.payload)) as RecordData), readWorkforce(store));
      return repository;
    });
    for (const filter of [{ owner: 'owner' }, { workerId: 'w1' }, { slotDate: '2026-10-18' }, {}]) {
      repositories.forEach(repo => repo.settleAll(filter, repo.staffingContext(), true));
      assert.deepEqual(repositories[0]!.allRows(), repositories[1]!.allRows());
      assert.deepEqual(hooks[0], hooks[1]);
    }
    const saved = repositories[0]!.load('a').record;
    assert(saved.poolShortage);
    assert.deepEqual(saved.timeline, heavyRecord('a').timeline);
    assert.equal(repositories[0]!.load('old-shortage').record.poolShortage, null);
    assert(hooks[0]!.length > 0);
  } finally { stores.forEach(store => store.close()); }
});
