import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { fixture, START, SLOT, NEXT, type Row } from './repair-fixture.js';
import { Status } from '../src/repair/model.js';
import { shiftRejection, todoTags } from '../src/repair/policy.js';
import { parseSlot } from '../src/repair/schedule.js';

type F = Awaited<ReturnType<typeof fixture>>;
const grade = (f: F, row: Row, priority = 'urgent') => f.change('admin', row, 'priority', { priority, reason: '物业核实' });
const REASSIGNED = '工单已由物业改派，无需上门';
const UNCONFIRMED = '首次上门时间尚未确认，请等待住户回应或重新提议';
const notes = (f: F, row: Row, title: string) => f.store.db.prepare('SELECT userId,taskKey,active FROM notifications WHERE repairId=? AND title=?').all(row.id, title);

for (const accepted of [false, true]) {
  test(`phase2 review: first proposal blocks shift before resident confirmation, worker accepted=${accepted}`, async t => {
    const f = await fixture(t);
    let row = await f.create('');
    row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '首次安排', notified: true }, 'POST');
    if (accepted) {
      row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
      row = await f.change('worker', row, 'accept');
    }
    const before = f.stored(row);
    const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/shift`, { revision: row.revision, slot: NEXT, reason: '物业顺延' });
    assert.equal(result.status, 200);
    assert.equal(result.code, 40001);
    assert.equal(result.message, UNCONFIRMED);
    assert.deepEqual(f.stored(row), before);
    const hints = await f.call('admin', 'GET', '/management/repair-shift-suggestions');
    assert.equal(hints.find((item: Row) => item.id === row.id).canShift, false);
    assert.equal(hints.find((item: Row) => item.id === row.id).shiftReason, UNCONFIRMED);
    assert.equal(notes(f, row, '等待确认时间')[0]?.active, 1);
    assert.equal(notes(f, row, '时间已调整').length, 0);
    assert.equal((await f.slots()).slots.find((item: Row) => item.slot === SLOT).occupied, 1);
    assert.equal((await f.slots()).slots.find((item: Row) => item.slot === NEXT).occupied, 0);
  });
}

test('phase2 review: shift guard rejects either missing agreement or an unresolved first proposal', () => {
  const base = { id: 'guard', status: Status.processing, slot: SLOT, agreedTime: parseSlot(SLOT)!.start };
  assert.equal(shiftRejection({ ...base, agreedTime: '' }, START), UNCONFIRMED);
  assert.equal(shiftRejection({ ...base, pendings: [{ id: 'first', kind: 'reschedule', firstSchedule: true }] }, START), UNCONFIRMED);
  assert.equal(shiftRejection(base, START), '');
});

for (const confirmation of ['resident', 'timeout'] as const) {
  test(`phase2 review: shift is allowed after first agreement becomes effective by ${confirmation}`, async t => {
    const f = await fixture(t);
    let row = await f.create('');
    row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '首次安排', notified: true }, 'POST');
    if (confirmation === 'resident') row = await f.change('resident', row, 'reschedule', { accept: true });
    else { f.at(Date.parse(row.pendingSchedule.deadline)); row = await f.detail(row); }
    row = await f.change('admin', row, 'shift', { slot: NEXT, reason: '确认后顺延' });
    assert.equal(row.agreedTime, parseSlot(NEXT)!.start);
    assert.equal(row.shiftCount, 1);
  });
}

test('phase2 review: urgency request immediately notifies property and precedes older normal orders', async t => {
  const f = await fixture(t);
  const ordinary = await f.create('');
  f.at(START + 1000);
  const requested = await f.create('', { urgentRequest: true, asap: true });
  const immediate = notes(f, requested, '紧急诉求待定级');
  assert.deepEqual(immediate.map(note => [note.userId, note.taskKey, note.active]), [[f.ids.admin, 'urgent_request', 1]]);
  f.at(START + 2000);
  await f.create('');
  const list = await f.call('admin', 'GET', '/notifications');
  assert.equal(list[0].repairId, requested.id);
  assert.equal(list[0].title, '紧急诉求待定级');
  const queue = await f.call('admin', 'GET', '/management/repair-queue');
  assert(queue.findIndex((row: Row) => row.id === requested.id) < queue.findIndex((row: Row) => row.id === ordinary.id));
  const view = queue.find((row: Row) => row.id === requested.id);
  assert.deepEqual(view.todo, ['紧急诉求待定级']);
  assert.equal(view.priorityPending, true);
  assert.deepEqual(view.preferenceTags, ['尽快上门']);
  await f.call('admin', 'GET', '/notifications');
  assert.equal(notes(f, requested, '紧急诉求待定级').length, 1);
});

test('phase2 review: queue ranks urgent, requested-unrated, medium including ordinary-unrated, light then creation time', async t => {
  const f = await fixture(t);
  const olderMedium = await grade(f, await f.create(''), 'medium');
  f.at(START + 1000);
  const ordinary = await f.create('');
  f.at(START + 2000);
  const request = await f.create('', { urgentRequest: true });
  f.at(START + 3000);
  const request2 = await f.create('', { urgentRequest: true });
  f.at(START + 4000);
  const high = await grade(f, await f.create(''));
  const light = await grade(f, await f.create('', { urgentRequest: true }), 'light');
  const queue = await f.call('admin', 'GET', '/management/repair-queue');
  assert.deepEqual(queue.map((row: Row) => row.id), [high.id, request.id, request2.id, olderMedium.id, ordinary.id, light.id]);
});

for (const priority of ['urgent', 'medium', 'light']) {
  test(`phase2 review: grading request as ${priority} closes its notification and removes its todo`, async t => {
    const f = await fixture(t);
    let row = await f.create('', { urgentRequest: true });
    assert.equal(notes(f, row, '紧急诉求待定级')[0]?.active, 1);
    row = await grade(f, row, priority);
    assert.equal(notes(f, row, '紧急诉求待定级')[0]?.active, 0);
    assert.equal(row.priorityPending, false);
    assert(!row.todo.includes('紧急诉求待定级'));
    assert.equal(notes(f, row, '急单待调度').filter(note => note.active).length, priority === 'urgent' ? 1 : 0);
  });
}

test('phase2 review: urgent request and urgent dispatch are both pinned before the notification limit', async t => {
  const f = await fixture(t);
  const requested = await f.create('', { urgentRequest: true });
  f.at(START + 1);
  const high = await grade(f, await f.create(''));
  const template = f.stored(await f.create(''));
  for (let i = 0; i < 105; i++) {
    f.at(START + i + 2);
    f.store.save('repairs', f.ids.resident, { ...template, id: randomUUID() });
  }
  const list = await f.call('admin', 'GET', '/notifications');
  assert.equal(list.length, 100);
  assert.deepEqual(list.slice(0, 2).map((note: Row) => [note.repairId, note.title]), [[high.id, '急单待调度'], [requested.id, '紧急诉求待定级']]);
  const cancelled = await f.change('resident', requested, 'revoke');
  assert.equal(notes(f, cancelled, '紧急诉求待定级')[0]?.active, 0);
});

test('phase2 review: ordinary unrated orders have a view flag but no grading todo or ASAP tag', async t => {
  const f = await fixture(t);
  const row = await f.create('');
  const view = (await f.call('admin', 'GET', '/management/repairs')).find((item: Row) => item.id === row.id);
  assert.equal(view.priorityPending, true);
  assert.deepEqual(view.todo, []);
  assert.deepEqual(view.preferenceTags, []);
  assert.equal(notes(f, row, '紧急诉求待定级').length, 0);
  assert.equal((await grade(f, row, 'medium')).priorityPending, false);
});

for (const status of [Status.confirming, Status.completed, Status.cancelled]) {
  test(`phase2 review: urgency request creates no grading todo or notification in status ${status}`, async t => {
    const f = await fixture(t);
    const row = await f.create('', { urgentRequest: true });
    f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, status }, true);
    assert(!todoTags(f.stored(row), START).includes('紧急诉求待定级'));
    assert.equal(notes(f, row, '紧急诉求待定级')[0]?.active, 0);
  });
}

async function reassigned(f: F) {
  f.store.run('UPDATE users SET nickName=? WHERE id=?', '师傅 A', f.ids.worker);
  f.store.run('UPDATE users SET nickName=? WHERE id=?', '师傅 B', f.ids.worker2);
  let row = await grade(f, await f.processing());
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker2, slot: NEXT });
  return row;
}

test('phase2 review: redispatch preserves original worker, explicit timeline and one notice without restoring access', async t => {
  const f = await fixture(t);
  const row = await reassigned(f);
  assert.deepEqual(row.previousWorkers, [{ workerId: f.ids.worker, workerName: '师傅 A', releasedAt: new Date(START).toISOString(), reason: '物业急单改派' }]);
  assert.match(row.timeline.at(-1).detail, /由 师傅 A 改派给 师傅 B/);
  assert.equal(notes(f, row, REASSIGNED)[0]?.userId, f.ids.worker);
  assert.equal(notes(f, row, REASSIGNED)[0]?.active, 1);
  const list = await f.call('worker', 'GET', '/notifications');
  assert(list.some((note: Row) => note.repairId === row.id && note.title === REASSIGNED && note.active));
  await f.call('worker', 'GET', '/notifications');
  assert.equal(notes(f, row, REASSIGNED).length, 1);
  assert.equal((await f.raw('worker', 'GET', `/worker/repairs/${row.id}`)).status, 404);
});

for (const nextAction of ['progress', 'grade', 'shift', 'redispatch', 'complete', 'cancel'] as const) {
  test(`phase2 review: original worker notice closes after ${nextAction}`, async t => {
    const f = await fixture(t);
    let row = await reassigned(f);
    assert.equal(notes(f, row, REASSIGNED)[0]?.active, 1);
    if (nextAction === 'progress') row = await f.change('worker2', row, 'progress', { content: '已出发' }, 'POST');
    if (nextAction === 'grade') row = await grade(f, row, 'medium');
    if (nextAction === 'shift') row = await f.change('admin', row, 'shift', { slot: '2026-10-18#14', reason: '再次协调' });
    if (nextAction === 'redispatch') row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker, slot: SLOT });
    if (nextAction === 'complete') row = await f.change('worker2', row, 'complete', { result: '修好' });
    if (nextAction === 'cancel') {
      row = await f.change('resident', row, 'revoke', { notified: true });
      row = await f.change('worker2', row, 'revoke');
    }
    assert.equal(notes(f, row, REASSIGNED).find(note => note.userId === f.ids.worker)?.active, 0);
    if (nextAction === 'redispatch') {
      assert.equal(row.previousWorkers.length, 2);
      assert.equal(row.previousWorkers[1].workerId, f.ids.worker2);
      assert.equal(notes(f, row, REASSIGNED).find(note => note.userId === f.ids.worker2)?.active, 1);
    }
  });
}

test('phase2 review: initial dispatch and same-worker redispatch do not create previous workers or reassignment notices', async t => {
  const f = await fixture(t);
  let row = await grade(f, await f.create(''));
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker, slot: SLOT });
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker, slot: NEXT });
  assert.deepEqual(row.previousWorkers ?? [], []);
  assert.equal(notes(f, row, REASSIGNED).length, 0);
});

test('phase2 review: redispatch of an unaccepted assignment records the original worker and closes acceptance notice', async t => {
  const f = await fixture(t);
  let row = await grade(f, await f.create(''));
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  assert.equal(row.status, Status.assigned);
  f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, previousWorkers: null }, true);
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker2, slot: SLOT });
  assert.equal(row.previousWorkers.length, 1);
  assert.equal(row.previousWorkers[0].workerId, f.ids.worker);
  assert.equal(row.previousWorkers[0].reason, '物业急单改派');
  assert.equal(notes(f, row, REASSIGNED)[0]?.active, 1);
  const acceptance = f.store.db.prepare('SELECT active FROM notifications WHERE repairId=? AND taskKey=?').get(row.id, 'accept:' + f.ids.worker);
  assert.equal(acceptance?.active, 0);
});

test('phase2 review: redispatch appends to existing release history without replacing it', async t => {
  const f = await fixture(t);
  let row = await grade(f, await f.processing());
  await f.change('worker', row, 'release', { reason: '原师傅退出' });
  row = await f.detail(row);
  assert.equal(row.previousWorkers, undefined);
  const history = structuredClone(f.stored(row).previousWorkers);
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker2, slot: NEXT });
  assert.deepEqual(row.previousWorkers, history);
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker, slot: SLOT });
  assert.deepEqual(row.previousWorkers.slice(0, -1), history);
  assert.equal(row.previousWorkers.at(-1).workerId, f.ids.worker2);
  assert.equal(row.previousWorkers.at(-1).reason, '物业急单改派');
});

test('phase2 review: redispatch save failure rolls back history, timeline, assignment and notifications together', async t => {
  const f = await fixture(t);
  const row = await grade(f, await f.processing());
  const before = f.stored(row);
  const beforeNotes = f.store.db.prepare('SELECT * FROM notifications WHERE repairId=? ORDER BY id').all(row.id);
  const sync = f.store.onRepairSaved;
  f.store.onRepairSaved = (owner, record) => { sync?.(owner, record); throw Error('injected after notification synchronization'); };
  const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, workerId: f.ids.worker2, slot: NEXT });
  assert.equal(result.status, 500);
  assert.deepEqual(f.stored(row), before);
  assert.deepEqual(f.store.db.prepare('SELECT * FROM notifications WHERE repairId=? ORDER BY id').all(row.id), beforeNotes);
});
