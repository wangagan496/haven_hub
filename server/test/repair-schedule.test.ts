import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/database.js';
import { RepairService } from '../src/repair/service.js';
import { RepairRepository } from '../src/repair/repository.js';
import { repairNotificationTasks } from '../src/repair/notification-tasks.js';
import * as actions from '../src/repair/actions.js';
import { Status } from '../src/repair/model.js';
import { availableDates, bookingRejection, businessDate, firstProposalDeadline, initialCapacities, occupancy,
  parseSlot, requireFreeWorker, scheduleRules, slotAvailability, slotFromTime } from '../src/repair/schedule.js';

import { fixture, H, START, SLOT, NEXT, type Row } from './repair-fixture.js';

test('schedule pure: exact slot encoding, periods, duration and historical parsing', () => {
  assert.deepEqual(scheduleRules.hours, [8, 9, 10, 11, 14, 15, 16, 17, 19, 20, 21]);
  assert.equal(parseSlot('2026-10-18#08')?.period, 'morning');
  assert.equal(parseSlot('2026-10-18#14')?.period, 'afternoon');
  const last = parseSlot('2026-10-18#21')!;
  assert.equal(last.period, 'evening');
  assert.equal(last.end, '2026-10-18T22:00:00+08:00');
  assert.equal(last.endsAt - last.startsAt, H);
  for (const bad of ['2026-02-30#08', '2026-10-18#8', '2026-10-18#12', '2026-10-18#22', '2026-10-18']) assert.equal(parseSlot(bad), undefined);
  assert.equal(slotFromTime('2026-10-18T02:00:00Z'), SLOT);
  assert.equal(slotFromTime('2026-10-18T10:00:00+08:00'), SLOT);
  for (const bad of ['2026-10-18', '2026-10-18T10:30:00+08:00', '2026-10-18T10:00:01+08:00', '2026-02-30T10:00:00+08:00']) assert.equal(slotFromTime(bad), '');
});

test('schedule pure: two-hour lead and inclusive seven-day range have exact boundaries', () => {
  assert.equal(bookingRejection('2026-10-17#10', START), '');
  assert.match(bookingRejection('2026-10-17#10', START + 1), /2 小时/);
  assert.equal(bookingRejection('2026-10-23#21', START), '');
  assert.match(bookingRejection('2026-10-24#08', START), /7 天/);
  assert.match(bookingRejection('2026-10-16#21', START), /7 天/);
});

test('schedule pure: business day rolls at Beijing midnight independent of host timezone', () => {
  const midnight = Date.parse('2026-10-18T00:00:00+08:00');
  assert.equal(businessDate(midnight - 1), '2026-10-17');
  assert.equal(businessDate(midnight), '2026-10-18');
  assert.equal(availableDates(midnight - 1).at(-1), '2026-10-23');
  assert.equal(availableDates(midnight).at(-1), '2026-10-24');
});

test('schedule pure: early completion releases future slots, cancelled orders do not occupy; exclude self and conflicts', () => {
  const completed = { id: 'one', slot: SLOT, status: Status.processing as number, workerId: 'w', agreedTime: parseSlot(SLOT)!.start };
  actions.complete(completed, { workerId: 'w', result: '提前修好', cost: 0 }, START);
  assert.equal(completed.slot, '');
  assert.equal(completed.agreedTime, parseSlot(SLOT)!.start);
  const records = [
    completed,
    { id: 'two', slot: SLOT, status: Status.pending, workerId: 'w' },
    { id: 'three', slot: SLOT, status: Status.cancelled, workerId: 'w2' },
    { id: 'legacy-cancel', slot: SLOT, status: 4 },
  ];
  assert.equal(occupancy(records, SLOT), 1);
  assert.equal(occupancy(records, SLOT, 'one'), 1);
  assert.equal(occupancy(records, SLOT, 'two'), 0);
  assert.throws(() => requireFreeWorker(records, SLOT, 'w'), /该师傅此时段已有安排/);
  assert.doesNotThrow(() => requireFreeWorker(records, SLOT, 'w', 'two'));
  assert.doesNotThrow(() => requireFreeWorker(records, SLOT, 'w2'));
  const slots = slotAvailability('2026-10-18', { ...initialCapacities, '10': 1 }, records, START);
  assert.equal(slots.find(slot => slot.slot === SLOT)?.remaining, 0);
  assert.equal(slots.find(slot => slot.slot === SLOT)?.selectable, false);
});

test('schedule pure: first proposal uses min(two hours, start minus two hours) and a thirty-minute minimum', () => {
  assert.equal(firstProposalDeadline(SLOT, START), new Date(START + 2 * H).toISOString());
  assert.equal(firstProposalDeadline('2026-10-17#11', START), new Date(START + H).toISOString());
  assert.doesNotThrow(() => firstProposalDeadline('2026-10-17#11', START + H / 2));
  assert.throws(() => firstProposalDeadline('2026-10-17#11', START + H / 2 + 1), /不足 30 分钟/);
});

test('schedule API: last capacity under simultaneous requests succeeds exactly once', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  const results = await Promise.all([1, 2].map(() => f.raw('resident', 'POST', '/repair', { ...f.body, slot: SLOT })));
  assert.deepEqual(results.map(row => row.status).sort(), [200, 409]);
  assert.equal(results.filter(row => row.code === 10000).length, 1);
  assert.equal(f.store.list('repairs', f.ids.resident).length, 1);
  assert.equal((await f.slots()).slots.find((row: Row) => row.slot === SLOT).remaining, 0);
});

test('schedule API: self exclusion is authorized for resident, assigned worker and admin only', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  let row = await f.create();
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  const path = `/repair/slots?date=2026-10-18&excludeId=${row.id}`;
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).selectable, false);
  for (const role of ['resident', 'worker', 'admin'] as const) {
    const data = await f.call(role, 'GET', path);
    assert.equal(data.slots.find((slot: Row) => slot.slot === SLOT).remaining, 1);
  }
  assert.equal((await f.raw('other', 'GET', path)).status, 404);
  assert.equal((await f.raw('worker2', 'GET', path)).status, 404);
  assert.equal((await f.raw(undefined, 'GET', '/repair/slots')).status, 401);
});

test('schedule API: all new creation requests enforce lead/range/exact hours and cannot set priority', async t => {
  const f = await fixture(t);
  for (const input of [{ slot: '2026-10-17#09' }, { slot: '2026-10-24#08' }, { slot: '2026-10-18#12' },
    { expectedTime: '2026-10-18T10:30:00+08:00' }, { appointment: '2026-10-18' }, { slot: SLOT, priority: 'urgent' },
    { slot: '', asap: true }, { slot: SLOT, asap: true, urgentRequest: true }]) {
    assert.notEqual((await f.raw('resident', 'POST', '/repair', { ...f.body, ...input })).code, 10000);
  }
  const waiting = await f.create('');
  assert.equal(waiting.slot, '');
  const asap = await f.create('', { asap: true, urgentRequest: true });
  assert.equal(asap.priority, '');
  assert.equal(asap.asap, true);
  assert.equal(asap.urgentRequest, true);
  assert.equal(asap.autoAccepted, false);
  assert.equal(asap.shiftCount, 0);
  assert.equal((await f.create('2026-10-17#10')).slot, '2026-10-17#10');
  assert.equal((await f.create('2026-10-23#21')).slot, '2026-10-23#21');
});

test('schedule API: old time field aliases map exactly to slots and cannot bypass full capacity', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  const first = await f.call('resident', 'POST', '/repair', { ...f.body, expectedTime: '2026-10-18T02:00:00+00:00' });
  assert.equal(first.rows[0].slot, SLOT);
  assert.equal(first.rows[0].expectedSlot, SLOT);
  const second = await f.raw('resident', 'POST', '/repair', { ...f.body, expectedTime: '2026-10-18T10:00:00+08:00' });
  assert.equal(second.status, 409);
});

test('schedule API: capacity defaults, date override, warning and reset without a daily cap', async t => {
  const f = await fixture(t);
  const initial = await f.call('admin', 'GET', '/management/repair-capacities');
  assert.equal(initial.defaultTotal, 500);
  assert.equal(Object.keys(initial.defaults).length, 11);
  const changed = await f.capacities(501);
  assert(changed.defaultTotal > 500);
  assert(changed.warnings.some((row: Row) => row.hour === '10' && row.message.includes('维修人员总数')));
  const override = await f.call('admin', 'PUT', '/management/repair-capacities/2026-10-18', { capacities: { '10': 0 } });
  assert.equal(override.effective['10'], 0);
  assert.equal(override.defaults['10'], 501);
  assert.equal((await f.slots()).slots.find((row: Row) => row.slot === SLOT).selectable, false);
  assert.equal((await f.slots('2026-10-19')).slots.find((row: Row) => row.slot.endsWith('#10')).capacity, 501);
  const reset = await f.call('admin', 'DELETE', '/management/repair-capacities/2026-10-18');
  assert.deepEqual(reset.overrides, {});
  assert.equal(reset.effective['10'], 501);
  for (const role of ['resident', 'worker'] as const) {
    assert.equal((await f.raw(role, 'GET', '/management/repair-capacities')).status, 403);
    assert.equal((await f.raw(role, 'PUT', '/management/repair-capacities', { capacities: { '10': 2 } })).status, 403);
    assert.equal((await f.raw(role, 'DELETE', '/management/repair-capacities/2026-10-18')).status, 403);
  }
  for (const capacities of [{ '12': 1 }, { '10': -1 }, { '10': 1.5 }, {}]) {
    assert.notEqual((await f.raw('admin', 'PUT', '/management/repair-capacities', { capacities })).code, 10000);
  }
});

test('schedule API: query alone advances the Beijing booking date without a timer', async t => {
  const f = await fixture(t);
  const midnight = Date.parse('2026-10-18T00:00:00+08:00');
  f.at(midnight - 1);
  const before = await f.call('resident', 'GET', '/repair/slots');
  f.at(midnight);
  const after = await f.call('worker', 'GET', '/repair/slots');
  assert.equal(before.date, '2026-10-17');
  assert.equal(after.date, '2026-10-18');
  assert.equal(after.dates.at(-1), '2026-10-24');
  assert.equal(after.slots.length, 11);
  assert.equal(after.remainingTotal, after.slots.reduce((sum: number, row: Row) => sum + row.remaining, 0));
  assert.equal(after.defaultTotal, undefined);
});

test('schedule API: waiting order accepts without slot; first proposal reserves immediately and rejection releases', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  let row = await f.processing('');
  row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '已电话沟通', notified: true }, 'POST');
  assert.equal(row.slot, SLOT);
  assert.equal(row.pendings[0].firstSchedule, true);
  assert.equal(row.agreedTime, '');
  assert.deepEqual(row.slotWindow, { start: parseSlot(SLOT)!.start, end: parseSlot(SLOT)!.end });
  assert.equal(row.pendings[0].deadline, new Date(START + 2 * H).toISOString());
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).remaining, 0);
  row = await f.change('resident', row, 'reschedule', { accept: false, reason: '当天不在家' });
  assert.equal(row.slot, '');
  assert.equal(row.agreedTime, '');
  assert.equal(row.autoAccepted, false);
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).remaining, 1);
});

for (const mode of ['resident-confirm', 'timeout'] as const) {
  test(`schedule API: first proposal ${mode} keeps its reservation, with timeout feedback`, async t => {
    const f = await fixture(t);
    await f.capacities(1);
    let row = await f.processing('');
    row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '已沟通', notified: true }, 'POST');
    assert.equal(row.agreedTime, '');
    if (mode === 'resident-confirm') {
      row = await f.change('resident', row, 'reschedule', { accept: true });
      assert.equal(row.autoAccepted, false);
    } else {
      const deadline = Date.parse(row.pendings[0].deadline);
      f.at(deadline - 1);
      assert.equal((await f.detail(row)).autoAccepted, false);
      f.at(deadline);
      await f.slots();
      row = f.stored(row);
      assert.equal(row.autoAccepted, true);
      assert.equal(row.pendings[0].resolution, 'auto_accepted');
      assert.equal(row.pendings[0].resolvedAt, new Date(deadline).toISOString());
      const revision = row.revision;
      await f.slots();
      assert.equal(f.stored(row).revision, revision, 'settlement must be idempotent');
      row = await f.change('resident', row, 'feedback', { content: '这个时间不方便' }, 'POST');
      const admin = (await f.call('admin', 'GET', '/management/repairs')).find((item: Row) => item.id === row.id);
      assert(admin.todo.includes('问题反馈待回复'));
    }
    assert.equal(row.slot, SLOT);
    assert.equal(row.agreedTime, parseSlot(SLOT)!.start);
    assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).occupied, 1);
  });
}

test('schedule API: property proposes first time before assignment; only resident may confirm', async t => {
  const f = await fixture(t);
  let row = await f.create('');
  row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '物业安排', notified: true }, 'POST');
  assert.equal(row.status, Status.pending);
  assert.notEqual((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/reschedule`, { revision: row.revision, accept: true })).code, 10000);
  assert.equal((await f.raw('resident', 'POST', `/management/repairs/${row.id}/reschedule`, { revision: row.revision, slot: NEXT, reason: '越权', notified: true })).status, 403);
  row = await f.change('resident', row, 'reschedule', { accept: true });
  assert.equal(row.slot, SLOT);
  assert.equal(row.autoAccepted, false);
});

test('schedule API: first proposal deadline rejects less than thirty minutes without reserving', async t => {
  const f = await fixture(t);
  const row = await f.processing('');
  f.at(START + H / 2 + 1);
  const result = await f.raw('worker', 'POST', `/worker/repairs/${row.id}/reschedule`,
    { revision: row.revision, slot: '2026-10-17#11', reason: '安排', notified: true });
  assert.match(result.message, /不足 30 分钟/);
  assert.equal(f.stored(row).slot, '');
  assert.equal(f.stored(row).revision, row.revision);
});

test('schedule API: reschedule proposal holds no new capacity; full-at-confirm invalidation commits with 409', async t => {
  const f = await fixture(t);
  await f.capacities(1, '11');
  let row = await f.processing();
  row = await f.change('worker', row, 'reschedule', { slot: NEXT, reason: '改约', notified: true }, 'POST');
  assert.equal(row.slot, SLOT);
  assert.equal(row.pendings[0].deadline, undefined);
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === NEXT).occupied, 0);
  await f.create(NEXT);
  const result = await f.raw('resident', 'PUT', `/repair/${row.id}/reschedule`, { revision: row.revision, accept: true });
  assert.equal(result.status, 409);
  const persisted = f.stored(row);
  assert.equal(persisted.slot, SLOT);
  assert.equal(persisted.pendings[0].resolution, 'conflict');
  assert.equal(persisted.revision, row.revision + 1);
  assert.equal(persisted.timeline.at(-1).action, 'reschedule_voided');
});

test('schedule API: reschedule acceptance atomically transfers capacity and preserves resident preference', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  await f.capacities(1, '11');
  let row = await f.processing();
  row = await f.change('resident', row, 'reschedule', { slot: NEXT, reason: '出门', notified: true }, 'POST');
  row = await f.change('worker', row, 'reschedule', { accept: true });
  assert.equal(row.slot, NEXT);
  assert.equal(row.expectedSlot, SLOT);
  const result = await f.slots();
  assert.equal(result.slots.find((slot: Row) => slot.slot === SLOT).remaining, 1);
  assert.equal(result.slots.find((slot: Row) => slot.slot === NEXT).remaining, 0);
});

test('schedule API: assignment, acceptance and first scheduling all enforce worker conflicts', async t => {
  const f = await fixture(t);
  const first = await f.processing();
  const second = await f.create();
  let result = await f.raw('admin', 'PUT', `/management/repairs/${second.id}/assign`, { revision: second.revision, workerId: f.ids.worker });
  assert.equal(result.status, 409);
  assert.equal(result.message, '该师傅此时段已有安排');
  let waiting = await f.create('');
  waiting = await f.change('admin', waiting, 'assign', { workerId: f.ids.worker });
  result = await f.raw('worker', 'PUT', `/worker/repairs/${waiting.id}/accept`, { revision: waiting.revision, slot: SLOT, reason: '安排' });
  assert.equal(result.status, 409);
  assert.equal(f.stored(waiting).status, Status.assigned);
  waiting = await f.change('worker', waiting, 'accept');
  result = await f.raw('worker', 'POST', `/worker/repairs/${waiting.id}/reschedule`,
    { revision: waiting.revision, slot: SLOT, reason: '安排', notified: true });
  assert.equal(result.status, 409);
  assert.equal(f.stored(waiting).slot, '');
  assert.equal(f.stored(first).slot, SLOT);
});

test('schedule API: pending first reservation also prevents a second assignment to that worker', async t => {
  const f = await fixture(t);
  let row = await f.processing('');
  row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '安排', notified: true }, 'POST');
  const second = await f.create();
  const result = await f.raw('admin', 'PUT', `/management/repairs/${second.id}/assign`, { revision: second.revision, workerId: f.ids.worker });
  assert.equal(result.status, 409);
});

test('schedule API: worker conflict on reschedule confirmation voids proposal and retains old slot', async t => {
  const f = await fixture(t);
  let first = await f.processing();
  first = await f.change('resident', first, 'reschedule', { slot: NEXT, reason: '改约', notified: true }, 'POST');
  await f.processing(NEXT);
  const result = await f.raw('worker', 'PUT', `/worker/repairs/${first.id}/reschedule`, { revision: first.revision, accept: true });
  assert.equal(result.status, 409);
  assert.equal(result.message, '该师傅此时段已有安排');
  assert.equal(f.stored(first).slot, SLOT);
  assert.equal(f.stored(first).pendings[0].resolution, 'conflict');
});

test('schedule API: releasing keeps capacity and frees the worker; cancellation frees capacity', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  let row = await f.processing();
  await f.change('worker', row, 'release', { reason: '无法继续' });
  row = await f.detail(row);
  assert.equal(row.slot, SLOT);
  assert.equal(row.agreedTime, parseSlot(SLOT)!.start);
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).remaining, 0);
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker2 });
  await f.capacities(2);
  const second = await f.create();
  await f.change('admin', second, 'assign', { workerId: f.ids.worker });
  row = await f.change('resident', row, 'revoke');
  assert.equal(row.slot, '');
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).remaining, 1);
});

test('schedule API: automatic cancellation releases future capacity before the next creation', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  let row = await f.processing();
  row = await f.change('resident', row, 'revoke', { reason: '取消', notified: true });
  f.at(Date.parse(row.pendings[0].deadline));
  const next = await f.create();
  assert.equal(next.slot, SLOT);
  assert.equal(f.stored(row).status, Status.cancelled);
  assert.equal(f.stored(row).slot, '');
});

for (const mode of ['reject', 'aftersale'] as const) {
  test(`schedule API: ${mode} starts rework with no slot and makes the prior capacity available`, async t => {
    const f = await fixture(t);
    await f.capacities(1);
    let row = await f.processing();
    row = await f.change('worker', row, 'complete', { result: '已完成', cost: 0 });
    if (mode === 'reject') row = await f.change('resident', row, 'reject', { reason: '未修好' });
    else {
      row = await f.change('resident', row, 'confirm');
      row = await f.change('resident', row, 'aftersale', { reason: '复发' }, 'POST');
      row = await f.change('admin', row, 'aftersale', { approve: true });
    }
    assert.equal(row.slot, '');
    assert.equal(row.agreedTime, '');
    assert.equal(row.round, 2);
    assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).remaining, 1);
    row = await f.change('worker', row, 'reschedule', { slot: NEXT, reason: '返修安排', notified: true }, 'POST');
    assert.equal(row.pendings.at(-1).firstSchedule, true);
  });
}

test('schedule API: reduced capacity does not stop acceptance of an already-reserved slot', async t => {
  const f = await fixture(t);
  let row = await f.create();
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  await f.capacities(0);
  row = await f.change('worker', row, 'accept');
  assert.equal(row.status, Status.processing);
  assert.equal(row.slot, SLOT);
  const slot = (await f.slots()).slots.find((value: Row) => value.slot === SLOT);
  assert.equal(slot.occupied, 1);
  assert.equal(slot.remaining, 0);
  assert.equal(slot.selectable, false);
});

test('schedule API: order-aware choices exclude worker conflicts and insufficient first-response time', async t => {
  const f = await fixture(t);
  await f.processing();
  const waiting = await f.processing('');
  const choices = await f.slots('2026-10-18', waiting.id);
  const occupied = choices.slots.find((slot: Row) => slot.slot === SLOT);
  assert(occupied.remaining > 0);
  assert.equal(occupied.selectable, false);
  assert.equal(occupied.reason, '该师傅此时段已有安排');
  f.at(START + H / 2 + 1);
  const today = await f.slots('2026-10-17', waiting.id);
  const tight = today.slots.find((slot: Row) => slot.slot === '2026-10-17#11');
  assert.equal(tight.selectable, false);
  assert.match(tight.reason, /不足 30 分钟/);
});

test('schedule API: first scheduling settlement persists when stale resident confirmation fails', async t => {
  const f = await fixture(t);
  let row = await f.processing('');
  row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '已沟通', notified: true }, 'POST');
  f.at(Date.parse(row.pendings[0].deadline));
  const result = await f.raw('resident', 'PUT', `/repair/${row.id}/reschedule`, { revision: row.revision, accept: true });
  assert.equal(result.status, 409);
  assert.equal(f.stored(row).autoAccepted, true);
  assert.equal(f.stored(row).revision, row.revision + 1);
  assert.equal(f.stored(row).slot, SLOT);
});

test('schedule API: release of a first proposal retains resident choice and its reserved slot', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  let row = await f.processing('');
  row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '已沟通', notified: true }, 'POST');
  await f.change('worker', row, 'release', { reason: '换人处理' });
  row = await f.detail(row);
  assert.equal(row.slot, SLOT);
  assert.equal(row.pendings[0].resolvedAt, undefined);
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).remaining, 0);
  row = await f.change('resident', row, 'reschedule', { accept: false, reason: '不方便' });
  assert.equal(row.slot, '');
  assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).remaining, 1);
});

test('schedule API: existing assignment from legacy data cannot be accepted over a worker conflict', async t => {
  const f = await fixture(t);
  await f.processing();
  const row = await f.create();
  // 模拟迁移前已存在的重复派单；不能通过新派单接口制造这个状态。
  f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, workerId: f.ids.worker, status: Status.assigned }, true);
  const fresh = await f.detail(row); // 人手冲突结算会更新 revision；先刷新，再检查业务冲突。
  const result = await f.raw('worker', 'PUT', `/worker/repairs/${row.id}/accept`, { revision: fresh.revision });
  assert.equal(result.status, 409);
  assert.equal(result.message, '该师傅此时段已有安排');
  assert.equal(f.stored(row).revision, fresh.revision);
});

test('schedule API: first slot checks and Store.save are rolled back if notification hook write fails', async t => {
  const f = await fixture(t);
  let row = await f.processing('');
  f.store.onRepairSaved = () => { throw Error('injected save failure'); };
  const result = await f.raw('worker', 'POST', `/worker/repairs/${row.id}/reschedule`,
    { revision: row.revision, slot: SLOT, reason: '安排', notified: true });
  assert.equal(result.status, 500);
  row = f.stored(row);
  assert.equal(row.slot, '');
  assert.equal(row.pendings.length, 0);
  assert.equal(occupancy(f.store.list('repairs', f.ids.resident), SLOT), 0);
});

for (const status of [Status.pending, Status.assigned]) {
  test(`review fix: admin first scheduling at status ${status} notifies resident and cancellation closes the task`, async t => {
    const f = await fixture(t);
    let row = await f.create('');
    if (status === Status.assigned) row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
    row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '物业安排', notified: true }, 'POST');
    const key = 'reschedule:' + row.pendings[0].id;
    const tasks = repairNotificationTasks(f.stored(row), f.ids.resident, [f.ids.admin]).filter(task => task.key === key);
    assert.deepEqual(tasks.map(task => [task.userId, task.role]), [[f.ids.resident, 'resident']]);
    const notes = f.store.db.prepare('SELECT userId, active FROM notifications WHERE repairId=? AND taskKey=?').all(row.id, key);
    assert.deepEqual(notes.map(note => [note.userId, note.active]), [[f.ids.resident, 1]]);
    row = await f.change('resident', row, 'revoke');
    assert.equal(f.store.one('SELECT active FROM notifications WHERE repairId=? AND taskKey=?', row.id, key)?.active, 0);
  });

  test(`review fix: direct cancellation at status ${status} voids first proposal and cannot restore slot`, async t => {
    const f = await fixture(t);
    await f.capacities(1);
    let row = await f.create('');
    if (status === Status.assigned) row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
    row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '安排', notified: true }, 'POST');
    row = await f.change('resident', row, 'revoke');
    assert.equal(row.status, Status.cancelled);
    assert.equal(row.slot, '');
    assert.equal(row.pendings[0].resolution, 'revoked');
    assert.equal(row.agreedTime, '');
    assert(row.pendings[0].resolvedAt);
    const before = f.stored(row);
    for (const accept of [true, false]) {
      const result = await f.raw('resident', 'PUT', `/repair/${row.id}/reschedule`, { revision: row.revision, accept, reason: '回应' });
      assert.notEqual(result.code, 10000);
      assert.deepEqual(f.stored(row), before);
    }
    f.at(START + 3 * H);
    assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).occupied, 0);
    assert.deepEqual(f.stored(row), before);
  });
}

for (const by of ['resident', 'worker', 'admin'] as const) {
  test(`review fix: ordinary proposal by ${by} notifies only the other participants`, async t => {
    const f = await fixture(t);
    let row = await f.processing();
    row = await f.change(by, row, 'reschedule', { slot: NEXT, reason: '改约', notified: true }, 'POST');
    const key = 'reschedule:' + row.pendings[0].id;
    const expected = by === 'admin' ? [f.ids.resident, f.ids.worker] : [by === 'worker' ? f.ids.resident : f.ids.worker];
    const notes = f.store.db.prepare('SELECT userId FROM notifications WHERE repairId=? AND taskKey=? AND active=1').all(row.id, key);
    assert.deepEqual(notes.map(note => String(note.userId)).sort(), expected.sort());
  });
}

for (const status of [Status.cancelled, 4, Status.confirming, Status.completed]) {
  test(`review fix: stale proposal at terminal status ${status} cannot be answered or invalidated`, async t => {
    const f = await fixture(t);
    let row = await f.processing();
    row = await f.change('worker', row, 'reschedule', { slot: NEXT, reason: '改约', notified: true }, 'POST');
    f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, status }, true);
    const before = f.stored(row);
    await f.capacities(0, '11');
    for (const accept of [true, false]) {
      const result = await f.raw('resident', 'PUT', `/repair/${row.id}/reschedule`, { revision: row.revision, accept, reason: '回应' });
      assert.match(result.message, /当前阶段不能回应改约/);
      assert.deepEqual(f.stored(row), before);
      const pure = structuredClone(before);
      assert.throws(() => actions.respond(pure, { accept, reason: '回应', role: 'resident' }, START), /当前阶段不能回应改约/);
      assert.deepEqual(pure, before);
    }
  });
}

for (const full of [false, true]) {
  test(`review fix: historical 18:00 agreement uses ordinary rescheduling, confirmation full=${full}`, async t => {
    const f = await fixture(t);
    await f.capacities(1);
    let row = await f.processing('');
    const agreedTime = '2026-10-20T18:00:00+08:00';
    f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, agreedTime }, true);
    if (full) await f.create(); // 普通改约允许先协商已满时段，同意时再检查。
    row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '历史改约', notified: true }, 'POST');
    assert.equal(row.pendings[0].firstSchedule, false);
    assert.equal(row.pendings[0].deadline, undefined);
    assert.equal(row.slot, '');
    assert.equal(row.agreedTime, agreedTime);
    f.at(START + 3 * H);
    row = await f.detail(row);
    assert.equal(row.pendings[0].resolvedAt, undefined);
    assert.equal(row.autoAccepted, false);
    assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).occupied, full ? 1 : 0);
    const result = await f.raw('resident', 'PUT', `/repair/${row.id}/reschedule`, { revision: row.revision, accept: true });
    const saved = f.stored(row);
    if (full) {
      assert.equal(result.status, 409);
      assert.equal(saved.pendings[0].resolution, 'conflict');
      assert.equal(saved.slot, '');
      assert.equal(saved.agreedTime, agreedTime);
    } else {
      assert.equal(result.code, 10000);
      assert.equal(saved.slot, SLOT);
      assert.equal(saved.agreedTime, parseSlot(SLOT)!.start);
    }
  });
}

test('review fix: historical agreement choices and proposal do not require first-response buffer', async t => {
  const f = await fixture(t);
  let row = await f.processing('');
  f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, agreedTime: '2026-10-20T18:00:00+08:00' }, true);
  f.at(START + H / 2 + 1);
  const slot = '2026-10-17#11';
  assert.equal((await f.slots('2026-10-17', row.id)).slots.find((value: Row) => value.slot === slot).selectable, true);
  row = await f.change('worker', row, 'reschedule', { slot, reason: '改约', notified: true }, 'POST');
  assert.equal(row.pendings[0].firstSchedule, false);
});

for (const offset of [-1, 0, H]) {
  test(`review fix: completion at slot start ${offset}ms releases only future capacity`, async t => {
    const f = await fixture(t);
    await f.capacities(1);
    let row = await f.processing();
    f.at(parseSlot(SLOT)!.startsAt + offset);
    row = await f.change('worker', row, 'complete', { result: '提前修好' });
    assert.equal(row.slot, offset < 0 ? '' : SLOT);
    assert.equal(row.agreedTime, parseSlot(SLOT)!.start);
    assert.equal(row.expectedSlot, SLOT);
    assert.equal((await f.slots()).slots.find((slot: Row) => slot.slot === SLOT).occupied, offset < 0 ? 0 : 1);
  });
}

test('review fix: date query returns only that day and uses the slot index', async t => {
  const f = await fixture(t);
  const today = await f.create('2026-10-17#10');
  const selected = await f.create();
  await f.create('2026-10-19#10');
  await f.create('');
  const repository = new RepairRepository(f.store, f.time, () => {}, '');
  assert.deepEqual(repository.scheduledRowsForDate('2026-10-18').map(row => row.id), [selected.id]);
  assert.deepEqual(repository.scheduledRowsForDate('2026-10-17').map(row => row.id), [today.id]);
  assert.deepEqual(repository.scheduledRowsForDate('2026-10-20'), []);
  const plan = f.store.db.prepare("EXPLAIN QUERY PLAN SELECT payload FROM repairs WHERE json_valid(payload) AND json_extract(payload,'$.slot') >= ? AND json_extract(payload,'$.slot') < ?").all('2026-10-18#', '2026-10-18$');
  assert(plan.some(row => /SEARCH repairs USING INDEX repairs_slot/.test(String(row.detail))));
});

test('review fix: expired stale first proposal cannot restore terminal orders during settlement', async t => {
  const f = await fixture(t);
  for (const status of [Status.cancelled, 4, Status.confirming, Status.completed]) {
    let row = await f.create('');
    row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '安排', notified: true }, 'POST');
    const record = f.stored(row);
    Object.assign(record, { status, slot: '' });
    record.pendings[0].deadline = new Date(START - 1).toISOString();
    f.store.save('repairs', f.ids.resident, record, true);
    const before = f.stored(row);
    await f.detail(row);
    const result = await f.raw('resident', 'PUT', `/repair/${row.id}/reschedule`, { revision: row.revision, accept: true });
    assert.match(result.message, /当前阶段不能回应改约/);
    assert.deepEqual(f.stored(row), before);
  }
});

test('review fix: date-scoped slot query settles selected day and explicitly excluded order only', async t => {
  const f = await fixture(t);
  let selected = await f.create('');
  selected = await f.change('admin', selected, 'reschedule', { slot: SLOT, reason: '安排', notified: true }, 'POST');
  let other = await f.create('');
  other = await f.change('admin', other, 'reschedule', { slot: '2026-10-19#10', reason: '安排', notified: true }, 'POST');
  f.at(START + 3 * H);
  await f.slots();
  assert.equal(f.stored(selected).autoAccepted, true);
  assert.equal(f.stored(other).autoAccepted, false);
  await f.slots('2026-10-18', other.id);
  assert.equal(f.stored(other).autoAccepted, true);
});

test('review fix: accepting legacy agreement with a proposed slot follows ordinary rescheduling', async t => {
  const f = await fixture(t);
  let row = await f.create('');
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  const agreedTime = '2026-10-20T18:00:00+08:00';
  f.store.save('repairs', f.ids.resident, { ...f.stored(row), id: row.id, agreedTime }, true);
  await f.capacities(0, '11');
  f.at(START + H / 2 + 1);
  row = await f.change('worker', row, 'accept', { slot: '2026-10-17#11', reason: '改约' });
  assert.equal(row.status, Status.processing);
  assert.equal(row.slot, '');
  assert.equal(row.agreedTime, agreedTime);
  assert.equal(row.pendings[0].firstSchedule, false);
  assert.equal(row.pendings[0].deadline, undefined);
  const response = await f.raw('resident', 'PUT', `/repair/${row.id}/reschedule`, { revision: row.revision, accept: true });
  assert.equal(response.status, 409);
});

test('phase2 pre-fix: accepting an assignment with a first proposal does not agree for the resident', async t => {
  const f = await fixture(t);
  let row = await f.create('');
  row = await f.change('admin', row, 'reschedule', { slot: SLOT, reason: '首次安排', notified: true }, 'POST');
  assert.equal(row.agreedTime, '');
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  row = await f.change('worker', row, 'accept');
  assert.equal(row.agreedTime, '');
  assert.equal(row.slot, SLOT);
  assert.equal(row.pendings[0].resolvedAt, undefined);
  row = await f.change('resident', row, 'reschedule', { accept: true });
  assert.equal(row.agreedTime, parseSlot(SLOT)!.start);
});

test('schedule migration: v3 to v4 maps only exact legacy times, uses Store.save, preserves defaults on reopen', () => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-schedule-'));
  const path = join(folder, 'schedule.sqlite');
  try {
    const old = new Store(path);
    old.run("INSERT INTO users(id,mobile,nickName) VALUES ('r','13800000000','住户')");
    for (const [id, agreedTime] of [['exact', '2026-10-18T10:00:00+08:00'], ['partial', '2026-10-18T10:30:00+08:00'], ['date', '2026-10-18']]) {
      old.save('repairs', 'r', { id: id!, status: Status.processing, agreedTime, expectedTime: agreedTime, revision: 9 });
    }
    old.db.exec('DROP TABLE repair_capacity_weekdays; DROP TABLE repair_capacity_defaults; DROP TABLE repair_capacity_overrides; DROP INDEX repairs_slot; PRAGMA user_version=3');
    old.close();
    const originalSave = Store.prototype.save;
    let saves = 0;
    Store.prototype.save = function (...args) { if (args[0] === 'repairs') saves++; return originalSave.apply(this, args); };
    let migrated: Store;
    try { migrated = new Store(path); } finally { Store.prototype.save = originalSave; }
    try {
      assert.equal(saves, 3);
      assert.equal(migrated.one('PRAGMA user_version')?.user_version, 7);
      assert.equal(migrated.get('repairs', 'r', 'exact')?.slot, SLOT);
      assert.equal(migrated.get('repairs', 'r', 'exact')?.revision, 9);
      for (const [id, expected] of [['partial', '2026-10-18T10:30:00+08:00'], ['date', '2026-10-18']]) {
        const row = migrated.get('repairs', 'r', id!)!;
        assert.equal(row.slot, '');
        assert.equal(row.agreedTime, expected);
        assert.equal(row.priority, '');
        assert.equal(row.urgentRequest, false);
        assert.equal(row.asap, false);
        assert.equal(row.autoAccepted, false);
        assert.equal(row.shiftCount, 0);
      }
      assert.match(String(migrated.one("SELECT sql FROM sqlite_master WHERE name='repairs_slot'")?.sql), /json_extract\(payload,'\$\.slot'\)/);
      migrated.run("UPDATE repair_capacity_defaults SET capacity=3 WHERE hour='10'");
    } finally { migrated.close(); }
    const reopened = new Store(path);
    try {
      assert.equal(reopened.one("SELECT capacity FROM repair_capacity_defaults WHERE hour='10'")?.capacity, 3);
      const service = new RepairService(reopened, () => START, '', () => {}, 'http://localhost:3000');
      assert.equal(service.residentDetail('r', 'partial').agreedTime, '2026-10-18T10:30:00+08:00');
    } finally { reopened.close(); }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});
