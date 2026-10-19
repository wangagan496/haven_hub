import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { fixture, H, START, SLOT, NEXT, type Row } from './repair-fixture.js';
import { Status } from '../src/repair/model.js';
import { shiftSuggestions } from '../src/repair/policy.js';
import { dispatchSlots, parseSlot } from '../src/repair/schedule.js';
import { RepairService } from '../src/repair/service.js';

type F = Awaited<ReturnType<typeof fixture>>;
const grade = (f: F, row: Row, priority = 'urgent') => f.change('admin', row, 'priority', { priority, reason: '物业核实等级' });
async function urgent(f: F) { return grade(f, await f.create('', { urgentRequest: true, asap: true })); }
const notes = (f: F, row: Row, title: string) => f.store.db.prepare('SELECT userId, taskKey, active FROM notifications WHERE repairId=? AND title=?').all(row.id, title);

for (const role of ['resident', 'worker'] as const) {
  test(`phase2: ${role} cannot access grading, shift, dispatch or management queries`, async t => {
    const f = await fixture(t);
    const row = await urgent(f);
    for (const [method, path, body] of [
      ['PUT', `/management/repairs/${row.id}/priority`, { revision: row.revision, priority: 'light', reason: '越权' }],
      ['PUT', `/management/repairs/${row.id}/shift`, { revision: row.revision, slot: NEXT, reason: '越权' }],
      ['PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot: SLOT, workerId: f.ids.worker }],
      ['GET', '/management/repair-queue', undefined],
      ['GET', '/management/repair-shift-suggestions', undefined],
      ['GET', `/management/repairs/${row.id}/dispatch-options`, undefined],
    ] as const) assert.equal((await f.raw(role, method, path, body)).status, 403);
    const service = new RepairService(f.store, f.time, '');
    assert.throws(() => service.grade(f.ids[role], row.id, { revision: 0, priority: 'light', reason: '越权' }), /仅物业/);
    assert.equal(f.stored(row).revision, row.revision);
  });
}

test('phase2: grading requires reason and valid priority, preserves preferences and enforces revision', async t => {
  const f = await fixture(t);
  let row = await f.create('', { urgentRequest: true });
  for (const body of [{ priority: 'urgent' }, { priority: 'urgent', reason: ' ' }, { priority: 'wrong', reason: '原因' }]) {
    assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/priority`, { revision: row.revision, ...body })).code, 10000);
  }
  row = await grade(f, row);
  assert.equal(row.priority, 'urgent');
  assert.equal(row.urgentRequest, true);
  assert.equal(row.priorityPending, false);
  assert.equal(row.todo[0], '急单待调度');
  assert.match(row.timeline.at(-1).detail, /物业核实等级/);
  const before = f.stored(row);
  assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/priority`, { revision: row.revision - 1, priority: 'light', reason: '旧版本' })).status, 409);
  assert.deepEqual(f.stored(row), before);
  row = await grade(f, row, 'medium');
  assert.equal(notes(f, row, '急单待调度')[0]?.active, 0);
});

test('phase2: waiting queue prioritizes urgent then unrated requests before medium and light', async t => {
  const f = await fixture(t);
  const light = await grade(f, await f.create(''), 'light');
  f.at(START + 1000);
  const ungraded = await f.create('', { urgentRequest: true, asap: true });
  f.at(START + 2000);
  const medium = await grade(f, await f.create(''), 'medium');
  f.at(START + 3000);
  const high = await urgent(f);
  const cancelled = await f.create('');
  await f.change('resident', cancelled, 'revoke');
  const queue = await f.call('admin', 'GET', '/management/repair-queue');
  assert.deepEqual(queue.map((row: Row) => row.id), [high.id, ungraded.id, medium.id, light.id]);
  assert.equal(queue[1].priorityPending, true);
  assert(queue[1].todo.includes('紧急诉求待定级'));
  assert.equal(queue[1].priority, '');
});

test('phase2: shift suggestions follow light, not-started, never-shifted, furthest-start ordering', () => {
  const make = (id: string, priority: string, slot: string, shiftCount = 0) => ({ id, priority, slot, shiftCount, agreedTime: parseSlot(slot)!.start, status: Status.processing });
  const rows = [make('urgent', 'urgent', '2026-10-20#10'), make('light-started', 'light', '2026-10-17#08'),
    make('light-shifted', 'light', '2026-10-22#10', 1), make('light-near', 'light', SLOT), make('light-far', 'light', '2026-10-19#10')];
  const before = structuredClone(rows);
  const hints = shiftSuggestions(rows, START);
  assert.deepEqual(hints.map(row => row.id), ['light-far', 'light-near', 'light-shifted', 'light-started', 'urgent']);
  assert.equal(hints[3]?.canShift, false);
  assert.equal(hints[3]?.shiftReason, '已开始的时段不能顺延');
  assert.deepEqual(rows, before);
});

test('phase2: shift suggestions endpoint filters date without applying changes', async t => {
  const f = await fixture(t);
  const a = await f.create();
  const b = await f.create('2026-10-19#10');
  const result = await f.call('admin', 'GET', '/management/repair-shift-suggestions?date=2026-10-18');
  assert.deepEqual(result.map((row: Row) => row.id), [a.id]);
  assert.equal(result[0].canShift, true);
  assert.equal(f.stored(a).revision, a.revision);
  assert.equal(f.stored(b).revision, b.revision);
});

test('phase2: shift immediately transfers capacity, voids proposal, increments count and notifies both', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  await f.capacities(1, '11');
  let row = await f.processing();
  row = await f.change('worker', row, 'reschedule', { slot: '2026-10-18#14', reason: '协商', notified: true }, 'POST');
  row = await f.change('admin', row, 'shift', { slot: NEXT, reason: '留出急单安排' });
  assert.equal(row.slot, NEXT);
  assert.equal(row.agreedTime, parseSlot(NEXT)!.start);
  assert.equal(row.expectedSlot, SLOT);
  assert.equal(row.status, Status.processing);
  assert.equal(row.shiftCount, 1);
  assert.equal(row.pendings[0].resolution, 'shifted');
  assert.match(row.timeline.at(-1).detail, /留出急单安排/);
  assert.deepEqual(notes(f, row, '时间已调整').filter(note => note.active).map(note => note.userId).sort(), [f.ids.resident, f.ids.worker].sort());
  const slots = (await f.slots()).slots;
  assert.equal(slots.find((slot: Row) => slot.slot === SLOT).occupied, 0);
  assert.equal(slots.find((slot: Row) => slot.slot === NEXT).occupied, 1);
  row = await f.change('admin', row, 'shift', { slot: '2026-10-18#14', reason: '再次协调' });
  assert.equal(row.shiftCount, 2);
  assert.equal(notes(f, row, '时间已调整').filter(note => note.active).length, 2);
  assert.equal(notes(f, row, '时间已调整').filter(note => !note.active).length, 2);
});

for (const offset of [0, 1]) {
  test(`phase2: shift rejects source slot already started by ${offset}ms`, async t => {
    const f = await fixture(t);
    const row = await f.processing();
    f.at(parseSlot(SLOT)!.startsAt + offset);
    const before = f.stored(row);
    const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/shift`, { revision: row.revision, slot: '2026-10-19#10', reason: '延期' });
    assert.match(result.message, /已开始/);
    assert.deepEqual(f.stored(row), before);
  });
}

test('phase2: shift requires reason and later valid slot with normal lead, and rejects waiting orders', async t => {
  const f = await fixture(t);
  const row = await f.processing('2026-10-17#10');
  for (const body of [{ slot: NEXT }, { slot: NEXT, reason: ' ' }, { slot: '2026-10-17#09', reason: '更早' },
    { slot: row.slot, reason: '相同' }, { slot: '2026-10-24#10', reason: '超范围' }]) {
    assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/shift`, { revision: row.revision, ...body })).code, 10000);
  }
  f.at(START + 1.5 * H);
  assert.match((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/shift`, { revision: row.revision, slot: '2026-10-17#11', reason: '过近' })).message, /2 小时/);
  const waiting = await f.create('');
  assert.match((await f.raw('admin', 'PUT', `/management/repairs/${waiting.id}/shift`, { revision: waiting.revision, slot: SLOT, reason: '无原时段' })).message, /首次上门时间尚未确认/);
  assert.equal(f.stored(row).shiftCount, 0);
});

for (const conflict of ['capacity', 'worker'] as const) {
  test(`phase2: shift ${conflict} conflict rolls back the proposal, revision and reservation`, async t => {
    const f = await fixture(t);
    let row = await f.processing();
    row = await f.change('worker', row, 'reschedule', { slot: '2026-10-18#14', reason: '待回应', notified: true }, 'POST');
    if (conflict === 'capacity') { await f.capacities(1, '11'); await f.create(NEXT); }
    else await f.processing(NEXT);
    const before = f.stored(row);
    const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/shift`, { revision: row.revision, slot: NEXT, reason: '安排' });
    assert.equal(result.status, 409);
    assert.match(result.message, conflict === 'worker' ? /该师傅此时段已有安排/ : /已约满/);
    assert.deepEqual(f.stored(row), before);
  });
}

test('phase2: shift cannot void an unconfirmed first reservation or establish agreement', async t => {
  const f = await fixture(t);
  let row = await f.create('');
  row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '首次安排', notified: true }, 'POST');
  assert.equal(row.agreedTime, '');
  const before = f.stored(row);
  const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/shift`, { revision: row.revision, slot: NEXT, reason: '物业协调' });
  assert.equal(result.code, 40001);
  assert.equal(result.message, '首次上门时间尚未确认，请等待住户回应或重新提议');
  assert.deepEqual(f.stored(row), before);
  assert.equal(notes(f, row, '等待确认时间')[0]?.active, 1);
  assert.equal(notes(f, row, '时间已调整').length, 0);
});

test('phase2: dispatch slots include current, skip elapsed and lunch gaps, stay within seven days', () => {
  const current = dispatchSlots(START + H / 2, 3);
  assert.deepEqual(current.map(slot => slot.code), ['2026-10-17#08', '2026-10-17#09', '2026-10-17#10']);
  assert.equal(dispatchSlots(START + H, 1)[0]?.code, '2026-10-17#09');
  assert.equal(dispatchSlots(Date.parse('2026-10-17T12:30:00+08:00'), 1)[0]?.code, '2026-10-17#14');
  assert.equal(dispatchSlots(START, 77).at(-1)?.code, '2026-10-23#21');
});

test('phase2: urgent dispatch may use current slot over zero capacity and closes urgent task', async t => {
  const f = await fixture(t);
  let row = await urgent(f);
  await f.capacities(0, '08');
  f.at(START + H / 2);
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=2`);
  assert.equal(options.slots[0].current, true);
  assert.equal(options.slots[0].slot, '2026-10-17#08');
  assert.equal(options.slots[0].workers.length, 2);
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker, slot: '2026-10-17#08' });
  assert.equal(row.status, Status.processing);
  assert.equal(row.workerId, f.ids.worker);
  assert.equal(row.rounds[0].workerId, f.ids.worker);
  assert.equal(row.agreedTime, '2026-10-17T08:00:00+08:00');
  assert(row.acceptedAt && row.assignedAt);
  assert.equal(row.expectedSlot, '');
  assert.equal(notes(f, row, '急单待调度')[0]?.active, 0);
  assert.deepEqual(notes(f, row, '时间已调整').filter(note => note.active).map(note => note.userId).sort(), [f.ids.resident, f.ids.worker].sort());
  const publicSlot = (await f.slots('2026-10-17')).slots.find((slot: Row) => slot.slot === row.slot);
  assert.equal(publicSlot.occupied, 1);
  assert.equal(publicSlot.remaining, 0);
  assert.equal(publicSlot.selectable, false);
});

test('phase2: dispatch options exclude occupied workers, preserve free workers and do not reserve', async t => {
  const f = await fixture(t);
  const first = await f.processing();
  const row = await urgent(f);
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=22`);
  assert.deepEqual(options.slots.find((slot: Row) => slot.slot === SLOT).workers.map((worker: Row) => worker.id), [f.ids.worker2]);
  assert.equal(f.stored(row).slot, '');
  assert.equal(f.stored(first).slot, SLOT);
  const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot: SLOT, workerId: f.ids.worker });
  assert.equal(result.status, 409);
  assert.equal(result.message, '该师傅此时段已有安排');
  assert.equal(f.stored(row).slot, '');
});

test('phase2: urgent overbooking preserves existing order and public capacity stays at zero', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  const first = await f.processing();
  const before = f.stored(first);
  let row = await urgent(f);
  row = await f.change('admin', row, 'dispatch', { slot: SLOT, workerId: f.ids.worker2 });
  assert.deepEqual(f.stored(first), before);
  const slot = (await f.slots()).slots.find((slot: Row) => slot.slot === SLOT);
  assert.equal(slot.occupied, 2);
  assert.equal(slot.remaining, 0);
  assert.equal(slot.selectable, false);
  assert.equal((await f.raw('resident', 'POST', '/repair', { ...f.body, slot: SLOT })).status, 409);
});

test('phase2: already accepted urgent repair can be dispatched sooner, excluding its own reservation', async t => {
  const f = await fixture(t);
  let row = await grade(f, await f.processing());
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=22`);
  assert(options.slots.find((slot: Row) => slot.slot === SLOT).workers.some((worker: Row) => worker.id === f.ids.worker));
  row = await f.change('admin', row, 'dispatch', { slot: '2026-10-17#08', workerId: f.ids.worker, reason: '升级后立即处理' });
  assert.equal(row.slot, '2026-10-17#08');
  assert.equal(row.agreedTime, '2026-10-17T08:00:00+08:00');
  assert.equal(row.expectedSlot, SLOT);
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).occupied, 0);
});

for (const priority of ['', 'medium', 'light']) {
  test(`phase2: resident urgency request cannot authorize dispatch with priority '${priority}'`, async t => {
    const f = await fixture(t);
    let row = await f.create('', { urgentRequest: true, asap: true });
    if (priority) row = await grade(f, row, priority);
    assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot: SLOT, workerId: f.ids.worker })).code, 10000);
    assert.notEqual((await f.raw('admin', 'GET', `/management/repairs/${row.id}/dispatch-options`)).code, 10000);
    assert.equal(f.stored(row).slot, '');
  });
}

test('phase2: dispatch rejects invalid workers, ended slots, invalid hours and outside horizon', async t => {
  const f = await fixture(t);
  const row = await urgent(f);
  f.at(START + H);
  for (const [slot, workerId] of [['2026-10-17#08', f.ids.worker], ['2026-10-17#18', f.ids.worker],
    ['2026-10-24#08', f.ids.worker], [SLOT, f.ids.resident], [SLOT, randomUUID()]]) {
    assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot, workerId })).code, 10000);
  }
  assert.equal(f.stored(row).revision, row.revision);
  for (const limit of ['0', '78', 'abc']) assert.notEqual((await f.raw('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=${limit}`)).code, 10000);
});

test('phase2: simultaneous urgent requests for one worker slot allow exactly one and leave the loser unchanged', async t => {
  const f = await fixture(t);
  const rows = [await urgent(f), await urgent(f)];
  const before = rows.map(row => f.stored(row));
  const results = await Promise.all(rows.map(row => f.raw('admin', 'PUT', `/management/repairs/${row.id}/dispatch`, { revision: row.revision, slot: SLOT, workerId: f.ids.worker })));
  assert.deepEqual(results.map(result => result.status).sort(), [200, 409]);
  const loser = results.findIndex(result => result.status === 409);
  assert.deepEqual(f.stored(rows[loser]!), before[loser]);
});

test('phase2: property can shift a light order then dispatch urgent without evicting anyone automatically', async t => {
  const f = await fixture(t);
  let first = await grade(f, await f.processing(), 'light');
  const second = await f.processing(SLOT, 'worker2');
  const row = await urgent(f);
  const before = f.stored(second);
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=22`);
  assert.equal(options.slots.find((slot: Row) => slot.slot === SLOT).workers.length, 0);
  first = await f.change('admin', first, 'shift', { slot: NEXT, reason: '协调轻单' });
  const done = await f.change('admin', row, 'dispatch', { slot: SLOT, workerId: f.ids.worker });
  assert.equal(done.slot, SLOT);
  assert.equal(f.stored(first).slot, NEXT);
  assert.deepEqual(f.stored(second), before);
});

test('phase2: dispatch closes first scheduling proposal and does not later auto-accept it', async t => {
  const f = await fixture(t);
  let row = await urgent(f);
  row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '先协商', notified: true }, 'POST');
  row = await f.change('admin', row, 'dispatch', { slot: NEXT, workerId: f.ids.worker });
  assert.equal(row.pendings[0].resolution, 'dispatched');
  assert.equal(row.agreedTime, parseSlot(NEXT)!.start);
  assert.equal(row.pendingSchedule, null);
  f.at(START + 3 * H);
  row = await f.detail(row);
  assert.equal(row.slot, NEXT);
  assert.equal(row.autoAccepted, false);
});

test('phase2: needsAdmin enters todo, normal progress stays compatible, property closes and later request renotifies', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  row = await f.change('worker', row, 'progress', { content: '缺少材料', needsAdmin: true }, 'POST');
  assert.equal(row.needsAdmin, true);
  const initial = notes(f, row, '师傅请求物业协助')[0]!;
  assert.equal(initial.userId, f.ids.admin);
  assert.equal(initial.active, 1);
  assert((await f.call('admin', 'GET', '/management/repairs')).find((value: Row) => value.id === row.id).todo.includes('师傅请求物业协助'));
  row = await f.change('worker', row, 'progress', { content: '继续处理' }, 'POST');
  row = await f.change('worker', row, 'progress', { content: '再次更新', needsAdmin: false }, 'POST');
  assert.equal(row.needsAdmin, true);
  assert.equal(notes(f, row, '师傅请求物业协助').length, 1);
  row = await f.change('admin', row, 'notes', { target: 'follow', content: '材料已送到', resolveNeedsAdmin: true }, 'POST');
  assert.equal(row.needsAdmin, false);
  assert.equal(notes(f, row, '师傅请求物业协助')[0]?.active, 0);
  row = await f.change('worker', row, 'progress', { content: '需要进一步协调', needsAdmin: true }, 'POST');
  const active = notes(f, row, '师傅请求物业协助').filter(note => note.active);
  assert.equal(active.length, 1);
  assert.notEqual(active[0]!.taskKey, initial.taskKey);
  row = await f.change('worker', row, 'complete', { result: '完成' });
  assert.equal(row.needsAdmin, false);
  assert.equal(notes(f, row, '师傅请求物业协助').filter(note => note.active).length, 0);
});

test('phase2: progress boolean validation and worker ownership reject without modifying assistance', async t => {
  const f = await fixture(t);
  const row = await f.processing();
  const path = `/worker/repairs/${row.id}/progress`;
  assert.equal((await f.raw('worker2', 'POST', path, { revision: row.revision, content: '越权', needsAdmin: true })).status, 404);
  assert.equal((await f.raw('resident', 'POST', path, { revision: row.revision, content: '越权', needsAdmin: true })).status, 403);
  assert.notEqual((await f.raw('worker', 'POST', path, { revision: row.revision, content: '错误类型', needsAdmin: 'true' })).code, 10000);
  assert.equal(f.stored(row).needsAdmin, false);
});

test('phase2: first proposal notifies waiting, timeout notifies both, listing deduplicates, completion closes', async t => {
  const f = await fixture(t);
  let row = await f.processing('');
  row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '首次安排', notified: true }, 'POST');
  assert.equal(row.agreedTime, '');
  assert.equal(row.pendingSchedule.proposedSlot, SLOT);
  assert.equal(notes(f, row, '等待确认时间')[0]?.active, 1);
  f.at(Date.parse(row.pendings[0].deadline));
  row = await f.detail(row);
  assert.equal(row.agreedTime, parseSlot(SLOT)!.start);
  assert.equal(notes(f, row, '等待确认时间')[0]?.active, 0);
  assert.deepEqual(notes(f, row, '超时已生效').filter(note => note.active).map(note => note.userId).sort(), [f.ids.resident, f.ids.worker].sort());
  await f.call('resident', 'GET', '/notifications');
  await f.call('resident', 'GET', '/notifications');
  assert.equal(notes(f, row, '超时已生效').length, 2);
  row = await f.change('worker', row, 'complete', { result: '已修复' });
  assert.equal(notes(f, row, '超时已生效').filter(note => note.active).length, 0);
});

test('phase2: urgent notification is pinned before the 100 row limit and its response shape remains compatible', async t => {
  const f = await fixture(t);
  const row = await urgent(f);
  const template = f.stored(await f.create(''));
  for (let i = 0; i < 105; i++) {
    f.at(START + i + 1);
    f.store.save('repairs', f.ids.resident, { ...template, id: randomUUID() });
  }
  const list = await f.call('admin', 'GET', '/notifications');
  assert.equal(list.length, 100);
  assert.equal(list[0].repairId, row.id);
  assert.equal(list[0].title, '急单待调度');
  assert.deepEqual(Object.keys(list[0]).sort(), ['id', 'repairId', 'role', 'title', 'body', 'active', 'createdAt', 'readAt', 'deliveries', 'kind'].sort());
  assert.equal((await f.call('resident', 'GET', '/notifications')).some((note: Row) => note.title === '急单待调度'), false);
});

for (const action of ['shift', 'dispatch'] as const) {
  test(`phase2: ${action} save failure rolls back all repair mutations`, async t => {
    const f = await fixture(t);
    const row = action === 'shift' ? await f.processing() : await urgent(f);
    const before = f.stored(row);
    f.store.onRepairSaved = () => { throw Error('injected save failure'); };
    const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/${action}`, { revision: row.revision, slot: NEXT,
      ...(action === 'shift' ? { reason: '协调' } : { workerId: f.ids.worker }) });
    assert.equal(result.status, 500);
    assert.deepEqual(f.stored(row), before);
  });
}

test('phase2: terminal states reject grade, shift and dispatch; pending revoke cannot be moved', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  row = await grade(f, row);
  row = await f.change('resident', row, 'revoke', { notified: true });
  assert.match((await f.raw('admin', 'GET', `/management/repairs/${row.id}/dispatch-options`)).message, /已申请撤销/);
  for (const action of ['shift', 'dispatch']) {
    assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/${action}`, { revision: row.revision, slot: NEXT,
      ...(action === 'shift' ? { reason: '协调' } : { workerId: f.ids.worker2 }) })).code, 10000);
  }
  for (const status of [0, 4, 3, 6]) {
    f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, status, pendings: [] }, true);
    const before = f.stored(row);
    for (const [action, body] of [['priority', { priority: 'light', reason: '原因' }], ['shift', { slot: NEXT, reason: '原因' }],
      ['dispatch', { slot: NEXT, workerId: f.ids.worker2 }]] as const) {
      assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/${action}`, { revision: row.revision, ...body })).code, 10000);
      assert.deepEqual(f.stored(row), before);
    }
  }
});

test('phase2: urgent redispatch closes old worker notice and revokes old worker access', async t => {
  const f = await fixture(t);
  let row = await urgent(f);
  row = await f.change('admin', row, 'dispatch', { slot: SLOT, workerId: f.ids.worker });
  row = await f.change('admin', row, 'dispatch', { slot: NEXT, workerId: f.ids.worker2 });
  assert.equal((await f.raw('worker', 'GET', `/worker/repairs/${row.id}`)).status, 404);
  const active = notes(f, row, '时间已调整').filter(note => note.active);
  assert.deepEqual(active.map(note => note.userId).sort(), [f.ids.resident, f.ids.worker2].sort());
  assert.equal(row.rounds[0].workerId, f.ids.worker2);
  assert.equal(row.shiftCount, 0);
});

test('phase2: urgent candidates treat cancelled occupancy as free but retain completed slot history', async t => {
  const f = await fixture(t);
  const occupied = await f.processing();
  f.store.save('repairs', f.ids.resident, { ...f.stored(occupied), id: occupied.id, status: Status.completed }, true);
  const cancelled = await f.processing(SLOT, 'worker2');
  f.store.save('repairs', f.ids.resident, { ...f.stored(cancelled), id: cancelled.id, status: Status.cancelled }, true);
  const row = await urgent(f);
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/dispatch-options?limit=22`);
  assert.deepEqual(options.slots.find((slot: Row) => slot.slot === SLOT).workers.map((worker: Row) => worker.id), [f.ids.worker2]);
});

test('phase2: stale shift and dispatch revisions return conflicts without changing records', async t => {
  const f = await fixture(t);
  const row = await grade(f, await f.processing());
  const before = f.stored(row);
  for (const action of ['shift', 'dispatch']) {
    const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/${action}`, { revision: row.revision - 1, slot: NEXT,
      ...(action === 'shift' ? { reason: '协调' } : { workerId: f.ids.worker }) });
    assert.equal(result.status, 409);
    assert.deepEqual(f.stored(row), before);
  }
});

test('phase2: needsAdmin survives worker release and closes on direct cancellation', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  row = await f.change('worker', row, 'progress', { content: '请物业协调', needsAdmin: true }, 'POST');
  await f.change('worker', row, 'release', { reason: '无法继续' });
  row = await f.detail(row);
  assert.equal(row.needsAdmin, true);
  assert.equal(notes(f, row, '师傅请求物业协助')[0]?.active, 1);
  row = await f.change('resident', row, 'revoke');
  assert.equal(row.needsAdmin, false);
  assert.equal(notes(f, row, '师傅请求物业协助')[0]?.active, 0);
});
