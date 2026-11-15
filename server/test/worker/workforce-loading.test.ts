import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../../src/database.js';
import { readWorkforce, holdingEligibility, staffingPlan } from '../../src/repair/workforce.js';
import type { WorkerAvailability } from '../../src/repair/schedule.js';
import type { RepairSkill } from '../../src/repair/model.js';

// Independent pre-change reference: each worker filters the full child tables.
function reference(store: Store): WorkerAvailability[] {
  const skills = store.db.prepare('SELECT workerId,skill FROM worker_skills').all();
  const known = new Set([...skills, ...store.db.prepare('SELECT workerId FROM worker_skill_audit').all()].map(row => String(row.workerId)));
  const leaves = store.db.prepare('SELECT workerId,date,hour FROM worker_leaves').all();
  return store.db.prepare("SELECT id FROM users WHERE role='worker' AND disabledAt=0").all().map(row => ({
    id: String(row.id), skillsKnown: known.has(String(row.id)),
    skills: skills.filter(skill => skill.workerId === row.id).map(skill => String(skill.skill) as RepairSkill),
    leaves: leaves.filter(leave => leave.workerId === row.id).map(leave => ({ date: String(leave.date), hour: String(leave.hour) })),
  }));
}

function addWorker(store: Store, id: string, skills: string[], leaves: { date: string; hour: string }[] = [], disabled = false, audited = false) {
  store.run("INSERT INTO users(id,mobile,nickName,role,disabledAt) VALUES (?,?,?,'worker',?)", id, id, id, disabled ? 1 : 0);
  for (const skill of skills) store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)', id, skill);
  if (audited) store.run('INSERT INTO worker_skill_audit(workerId,actorId,actorName,changedAt) VALUES (?,?,?,?)', id, id, id, '2026-10-28');
  for (const leave of leaves) store.run('INSERT INTO worker_leaves(workerId,date,hour,reason) VALUES (?,?,?,?)', id, leave.date, leave.hour, 'synthetic');
}

test('workforce loading preserves ordering, legacy/cleared skill state, leaves and enabled-role filtering', () => {
  const store = new Store(':memory:');
  try {
    assert.deepEqual(readWorkforce(store), []);
    addWorker(store, 'legacy', []);
    addWorker(store, 'cleared', [], [], false, true);
    addWorker(store, 'disabled', ['plumbing'], [{ date: '2026-10-29', hour: '' }], true);
    addWorker(store, '__proto__', ['doors', 'plumbing'], [{ date: '2026-10-29', hour: '10' }]);
    addWorker(store, 'constructor', ['electrical'], [{ date: '2026-10-29', hour: '' }], false, true);
    addWorker(store, 'admin', ['plumbing']);
    store.run("UPDATE users SET role='admin' WHERE id='admin'");
    const result = readWorkforce(store);
    assert.deepEqual(result, reference(store));
    assert.deepEqual(result.map(worker => worker.id), ['legacy', 'cleared', '__proto__', 'constructor']);
    assert.equal(holdingEligibility(result.find(worker => worker.id === 'legacy'), { id: 'old', workerId: 'legacy' }), '');
    assert.match(holdingEligibility(result.find(worker => worker.id === 'cleared'), { id: 'old', workerId: 'cleared' }), /未登记/);
    assert.match(holdingEligibility(result.find(worker => worker.id === 'constructor'),
      { id: 'held', workerId: 'constructor', repairItemId: '1005' }, '2026-10-29#10'), /休假/);
  } finally { store.close(); }
});

test('workforce loading equals the full-scan reference across mixed rosters and staffing decisions', () => {
  const store = new Store(':memory:');
  try {
    store.transaction(() => {
      for (let index = 0; index < 91; index++) {
        const skills = ['plumbing', 'electrical', 'doors'].filter((_, i) => (index + i) % 4 !== 0);
        addWorker(store, `w${index}`, index % 9 ? skills : [],
          Array.from({ length: index % 7 }, (_, day) => ({ date: `2026-10-${28 + day % 3}`, hour: String(8 + day) })),
          index % 11 === 0, index % 5 === 0);
      }
    });
    const actual = readWorkforce(store);
    const expected = reference(store);
    assert.deepEqual(actual, expected);
    const records = Array.from({ length: 100 }, (_, index) => ({ id: `r${index}`, status: index % 4 ? 1 : 2,
      workerId: index % 4 ? '' : `w${index % 91}`, repairItemId: ['1004', '1005', '1002'][index % 3],
      slot: `2026-10-${28 + index % 3}#10` }));
    for (const slot of ['2026-10-28#10', '2026-10-29#10', '2026-10-30#10']) {
      assert.deepEqual(staffingPlan(records, slot, actual), staffingPlan(records, slot, expected));
    }
  } finally { store.close(); }
});

test('workforce loading reflects edits, rollback and disable immediately without shared mutable result state', () => {
  const store = new Store(':memory:');
  try {
    addWorker(store, 'one', ['plumbing'], [{ date: '2026-10-29', hour: '10' }]);
    addWorker(store, 'two', []);
    const before = reference(store);
    const first = readWorkforce(store);
    (first[0]!.skills as RepairSkill[]).push('doors');
    (first[0]!.leaves as { date: string; hour: string }[]).push({ date: '2026-10-30', hour: '' });
    assert.deepEqual(readWorkforce(store), before);
    assert.throws(() => store.transaction(() => {
      store.run("DELETE FROM worker_skills WHERE workerId='one'");
      store.run("DELETE FROM worker_leaves WHERE workerId='one'");
      store.run("INSERT INTO worker_skill_audit(workerId,actorId,actorName,changedAt) VALUES ('one','one','one','2026-10-28')");
      const changed = readWorkforce(store);
      assert.deepEqual(changed, reference(store));
      assert.deepEqual(changed[0]!.skills, []);
      assert.equal(changed[0]!.skillsKnown, true);
      throw new Error('rollback');
    }), /rollback/);
    assert.deepEqual(readWorkforce(store), before);
    store.run("UPDATE users SET disabledAt=1 WHERE id='one'");
    assert.deepEqual(readWorkforce(store).map(worker => worker.id), ['two']);
    store.run("UPDATE users SET disabledAt=0 WHERE id='one'");
    assert.deepEqual(readWorkforce(store), before);
  } finally { store.close(); }
});

test('one workforce load visits child-table ownership fields only a bounded number of times', t => {
  const store = new Store(':memory:');
  try {
    for (let index = 0; index < 40; index++) addWorker(store, `w${index}`, ['plumbing', 'electrical'],
      Array.from({ length: 15 }, (_, day) => ({ date: `2026-10-${String(day + 1).padStart(2, '0')}`, hour: '' })), false, true);
    const expected = reference(store);
    const prepare = store.db.prepare.bind(store.db);
    let childRows = 0;
    let ownerReads = 0;
    t.mock.method(store.db, 'prepare', (sql: string) => {
      const statement = prepare(sql);
      if (/^SELECT workerId(?:,skill|,date,hour)? FROM worker_(?:skills|skill_audit|leaves)$/.test(sql)) {
        const all = statement.all.bind(statement);
        statement.all = () => all().map(row => {
          childRows++;
          return new Proxy(row, { get(target, property) {
            if (property === 'workerId') ownerReads++;
            return Reflect.get(target, property);
          } });
        });
      }
      return statement;
    });
    assert.deepEqual(readWorkforce(store), expected);
    assert.equal(childRows, 720);
    t.diagnostic(`child rows=${childRows}, ownership field reads=${ownerReads}`);
    assert(ownerReads <= childRows * 4, `repeated child-table scan: ${ownerReads} owner reads for ${childRows} rows`);
  } finally { store.close(); }
});
