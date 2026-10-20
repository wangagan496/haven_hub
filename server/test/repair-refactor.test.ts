import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { Store, type RecordData } from '../src/database.js';
import { ApiError } from '../src/errors.js';
import { CommunityService } from '../src/community/service.js';
import { RepairService } from '../src/repair/service.js';
import { RepairRepository } from '../src/repair/repository.js';
import { Status, newRound } from '../src/repair/model.js';

const now = Date.parse('2026-10-17T00:00:00Z');
const iso = (time: number) => new Date(time).toISOString();
const owner = '10000000-0000-4000-8000-000000000001';
const workerId = '10000000-0000-4000-8000-000000000002';
const houseId = '10000000-0000-4000-8000-000000000003';
const baseUrl = 'http://localhost:3000';

function fixture(t: TestContext) {
  const store = new Store(':memory:');
  t.after(() => store.close());
  store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', owner, '13800138000', '住户', 'resident');
  store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', workerId, '13800138091', '师傅', 'worker');
  store.run("INSERT INTO worker_skills(workerId,skill) VALUES (?,'plumbing')", workerId);
  store.save('rooms', owner, { id: houseId, point: '小区', building: '1栋', floor: 'B1', room: '101' });
  const repairs = new RepairService(store, () => now, '020-88888888', () => {}, baseUrl);
  const repository = new RepairRepository(store, () => now, () => {}, baseUrl);
  function seed(status: number = Status.pending) {
    const record: RecordData = { id: 'repair-a', repairItemId: '1004', status, revision: 7, workerId, mobile: '13800138000',
      workerMobile: '13800138091', agreedTime: iso(now + 3_600_000),
      rounds: [newRound(1, 'first', iso(now - 3_600_000))], pendings: [], timeline: [] };
    store.save('repairs', owner, record);
    return record;
  }
  const input = { houseId, repairItemId: '1004', mobile: '13800138000', expectedTime: '2026-10-18T10:00:00+08:00' };
  return { store, repairs, repository, seed, input };
}

test('refactor: independent settlement survives a stale mutation and invokes Store.save hook', t => {
  const f = fixture(t);
  const record = f.seed(Status.confirming);
  (record.rounds as ReturnType<typeof newRound>[])[0]!.confirmDeadline = iso(now);
  f.store.save('repairs', owner, record, true);
  const saved: RecordData[] = [];
  f.store.onRepairSaved = (_owner, row) => saved.push(structuredClone(row));
  assert.throws(() => f.repairs.confirm(owner, record.id, { revision: 7 }), { status: 409, code: 40900 });
  const stored = f.store.get('repairs', owner, record.id)!;
  assert.equal(stored.status, Status.completed);
  assert.equal(stored.revision, 8);
  assert.equal(saved.length, 1);
  assert.equal(saved[0]?.revision, 8);
});

test('refactor: owner and worker authorization still precede stale revision conflicts', t => {
  const f = fixture(t);
  const row = f.seed(Status.completed);
  assert.throws(() => f.repairs.confirm('other-resident', row.id, { revision: 1 }), { status: 404, code: 40400 });
  assert.throws(() => f.repairs.progress('other-worker', row.id, { revision: 1, content: '说明' }), { status: 404, code: 40400 });
  assert.throws(() => f.repairs.confirm(owner, row.id, { revision: 1 }), { status: 409, code: 40900 });
  assert.throws(() => f.repairs.confirm(owner, row.id, { revision: 7 }), { status: 200, code: 40001 });
  assert.throws(() => f.repository.mutate(row.id, 1, () => { throw new ApiError(403, 40300, '无权操作'); }, () => {}), { status: 403 });
  assert.equal(f.store.get('repairs', owner, row.id)?.revision, 7);
});

test('refactor: action failure rolls back only its transaction, not the completed settlement', t => {
  const f = fixture(t);
  const row = f.seed(Status.confirming);
  (row.rounds as ReturnType<typeof newRound>[])[0]!.confirmDeadline = iso(now);
  f.store.save('repairs', owner, row, true);
  assert.throws(() => f.repository.mutate(row.id, 8, () => {}, record => {
    record.status = Status.cancelled;
    throw new ApiError(200, 40001, '注入动作失败');
  }), /注入动作失败/);
  assert.equal(f.store.get('repairs', owner, row.id)?.status, Status.completed);
  assert.equal(f.store.get('repairs', owner, row.id)?.revision, 8);
});

test('refactor: new creation and legacy CommunityService creation preserve their response contracts', t => {
  const f = fixture(t);
  f.store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('second-worker','13800138092','第二师傅','worker')");
  f.store.run("INSERT INTO worker_skills(workerId,skill) VALUES ('second-worker','plumbing')");
  const saved: string[] = [];
  f.store.onRepairSaved = (_owner, record) => saved.push(record.id);
  const created = f.repairs.createRepair(owner, f.input);
  assert.equal(created.complete, true);
  assert.equal(created.total, 1);
  assert.equal(created.rows[0]?.id, created.createdId);
  assert.equal(created.rows[0]?.propertyPhone, '020-88888888');
  assert.equal(created.rows[0]?.houseInfo, '小区 1栋 地下1层 101');
  const legacy = new CommunityService(f.store, baseUrl, () => now).createRepair(owner, f.input);
  assert.equal(legacy.complete, true);
  assert.equal(legacy.total, 2);
  assert.equal(legacy.rows[0]?.id, legacy.createdId);
  assert.equal(legacy.rows[0]?.propertyPhone, undefined, 'standalone legacy list remains raw');
  assert.deepEqual(saved, [created.createdId, legacy.createdId]);
});

test('refactor: creation/list failure rolls back both repair and transactional save hook', t => {
  const f = fixture(t);
  f.store.onRepairSaved = (_owner, row) => f.store.run('INSERT INTO push_settings(name,value) VALUES (?,?)', row.id, 'sync');
  assert.throws(() => f.repairs.createRepair(owner, f.input, () => { throw Error('injected list failure'); }), /injected list failure/);
  assert.equal(f.store.list('repairs', owner).length, 0);
  assert.equal(f.store.one('SELECT COUNT(*) AS count FROM push_settings')?.count, 0);
});

test('refactor: legacy revoke accepts no revision and returns masked complete list', t => {
  const f = fixture(t);
  const row = f.seed();
  const result = f.repairs.legacyRevoke(owner, row.id, {});
  assert.deepEqual(Object.keys(result).sort(), ['complete', 'rows', 'total']);
  assert.equal(result.complete, true);
  assert.equal(result.total, 1);
  assert.equal(result.rows[0]?.status, Status.cancelled);
  assert.equal(result.rows[0]?.revision, 8);
  assert.equal(result.rows[0]?.mobile, '138****8000');
});

test('refactor: legacy revoke list failure rolls back the requested cancellation', t => {
  const f = fixture(t);
  const row = f.seed();
  f.repairs.residentList = () => { throw Error('injected list failure'); };
  assert.throws(() => f.repairs.legacyRevoke(owner, row.id, {}), /injected list failure/);
  assert.equal(f.store.get('repairs', owner, row.id)?.status, Status.pending);
  assert.equal(f.store.get('repairs', owner, row.id)?.revision, 7);
});

test('refactor: legacy revoke cannot roll back an already-due automatic cancellation', t => {
  const f = fixture(t);
  const row = f.seed(Status.processing);
  row.pendings = [{ id: 'revoke-a', kind: 'revoke', by: 'resident', at: iso(now - 3_600_000), reason: '取消', deadline: iso(now) }];
  f.store.save('repairs', owner, row, true);
  assert.throws(() => f.repairs.legacyRevoke(owner, row.id, { revision: 7 }), { status: 409, code: 40900 });
  const stored = f.store.get('repairs', owner, row.id)!;
  assert.equal(stored.status, Status.cancelled);
  assert.equal(stored.revision, 8);
  assert.equal(stored.cancelledAt, iso(now));
});
