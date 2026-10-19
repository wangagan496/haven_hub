import test from 'node:test';
import assert from 'node:assert/strict';
import type { RecordData } from '../src/database.js';
import { ApiError } from '../src/errors.js';
import { Status, currentRound, events, newRound, openPending, pendings, rounds } from '../src/repair/model.js';
import { closed, inWarranty, reworkUsed, rules, settle, todoTags, warrantyEnd } from '../src/repair/policy.js';
import * as actions from '../src/repair/actions.js';
import { RepairViews } from '../src/repair/views.js';
import { parseSlot, slotFromTime } from '../src/repair/schedule.js';

// 仅操作普通对象，不创建 Store，不导入 SQLite 运行时代码。
const H = 3_600_000;
const now = Date.parse('2026-10-17T00:00:00Z');
const iso = (time: number) => new Date(time).toISOString();
const workerId = 'worker-a';
function record(status: number = Status.processing): RecordData {
  return { id: 'repair-a', status, revision: 7, createdAt: iso(now - H),
    workerId, workerName: '张师傅', workerMobile: '13800138091', mobile: '13800138000',
    slot: '2026-10-18#08', expectedSlot: '2026-10-18#08',
    expectedTime: '2026-10-18T08:00:00+08:00', agreedTime: '2026-10-18T08:00:00+08:00',
    rounds: [{ ...newRound(1, 'first', iso(now - H)), workerId, workerName: '张师傅' }],
    timeline: [], pendings: [] };
}
function completed(number = 1) {
  const row = record(Status.completed);
  row.rounds = Array.from({ length: number }, (_, index) => ({ ...newRound(index + 1, 'first', iso(now)),
    workerId, workerName: '张师傅', completedAt: iso(now), confirmedAt: iso(now), confirmedBy: 'resident' }));
  return row;
}
function businessFailure(operation: () => unknown, message: RegExp) {
  assert.throws(operation, (error: unknown) => error instanceof ApiError && error.status === 200
    && error.code === 40001 && message.test(error.message));
}

test('policy: automatic confirmation happens exactly at deadline and is idempotent', () => {
  const row = record(Status.confirming);
  const deadline = now + rules.autoConfirmMs;
  currentRound(row).confirmDeadline = iso(deadline);
  assert.equal(settle(row, deadline - 1), false);
  assert.equal(row.status, Status.confirming);
  assert.equal(settle(row, deadline), true);
  assert.equal(row.status, Status.completed);
  assert.equal(currentRound(row).confirmedAt, iso(deadline));
  assert.equal(currentRound(row).confirmedBy, 'system');
  assert.equal(events(row)[0]?.at, iso(deadline));
  assert.equal(settle(row, deadline + H), false);
  assert.equal(events(row).length, 1);
  assert.equal(row.revision, 7, 'revision is owned by the repository');
});

for (const number of [1, 2]) {
  test(`policy: round ${number} warranty ends at its exact boundary`, () => {
    const row = completed(number);
    const end = now + rules.warrantyMs[number - 1]!;
    assert.equal(warrantyEnd(row), iso(end));
    assert.equal(inWarranty(row, end - 1), true);
    assert.equal(closed(row, end - 1), false);
    assert.equal(inWarranty(row, end), false);
    assert.equal(closed(row, end), true);
    assert.equal(reworkUsed(row), number === 2);
  });
}

test('policy: a timely pending aftersale keeps an expired repair open', () => {
  const row = completed();
  actions.applyAftersale(row, { reason: '再次漏水', pendingId: 'after-a' }, now + H);
  const expired = now + rules.warrantyMs[0];
  assert.equal(inWarranty(row, expired), false);
  assert.equal(closed(row, expired), false);
  assert.deepEqual(todoTags(row, expired), ['售后返修待审核']);
  actions.reviewAftersale(row, { approve: false, reason: '已沟通' }, expired);
  assert.equal(closed(row, expired), true);
  assert.equal(reworkUsed(row), false);
});

test('policy: todo tags preserve timeout thresholds and resolved feedback disappears', () => {
  const row = record(Status.pending);
  row.createdAt = iso(now);
  assert.deepEqual(todoTags(row, now + rules.unassignedAlertMs - 1), []);
  assert.deepEqual(todoTags(row, now + rules.unassignedAlertMs), ['超时未派单']);
  row.status = Status.assigned;
  row.assignedAt = iso(now);
  assert.deepEqual(todoTags(row, now + rules.unacceptedAlertMs - 1), []);
  assert.deepEqual(todoTags(row, now + rules.unacceptedAlertMs), ['超时未接单']);
  actions.residentFeedback(row, { content: '请联系我', pendingId: 'feedback-a' }, now);
  assert(todoTags(row, now).includes('问题反馈待回复'));
  actions.note(row, { content: '已联系', target: 'feedback' }, now);
  assert(!todoTags(row, now).includes('问题反馈待回复'));
  assert.equal(row.status, Status.assigned);
});

test('policy: overdue reschedule never auto-accepts and the old agreement remains', () => {
  const row = record();
  const original = row.agreedTime;
  actions.propose(row, { slot: slotFromTime(iso(now + 48 * H)), reason: '换时间', role: 'resident', pendingId: 'move-a' }, now);
  assert.equal(settle(row, now + 100 * H), false);
  assert.equal(row.agreedTime, original);
  assert(openPending(row, 'reschedule'));
  assert(todoTags(row, now + 100 * H).includes('改约待回应'));
});

for (const hours of [1, 8, -1]) {
  test(`actions/policy: revoke with agreed time ${hours}h settles at the correct deadline`, () => {
    const row = record();
    row.agreedTime = iso(now + hours * H);
    actions.propose(row, { slot: slotFromTime(iso(now + 24 * H)), reason: '等待材料', role: 'worker', pendingId: 'move-a' }, now);
    actions.revoke(row, { revision: 7, reason: '取消', notified: true, pendingId: 'revoke-a' }, now);
    const deadline = now + (hours === 1 ? H : rules.revokeAutoMs);
    assert.equal(openPending(row, 'revoke')?.deadline, iso(deadline));
    assert.equal(settle(row, deadline - 1), false);
    assert.equal(settle(row, deadline), true);
    assert.equal(row.status, Status.cancelled);
    assert.equal(row.cancelledAt, iso(deadline));
    assert.equal(row.objectionDeadline, iso(deadline + rules.objectionMs));
    assert.equal(openPending(row, 'reschedule'), undefined);
    assert.equal(pendings(row)[0]?.resolution, 'revoked');
    assert.equal(settle(row, deadline + H), false);
  });
}

test('actions: legacy revoke needs no revision before acceptance but cannot cancel processing directly', () => {
  const row = record(Status.assigned);
  actions.revoke(row, { reason: '取消', notified: false, pendingId: 'unused' }, now);
  assert.equal(row.status, Status.cancelled);
  assert.equal(pendings(row).length, 0);
  const processing = record();
  const before = structuredClone(processing);
  businessFailure(() => actions.revoke(processing, { reason: '取消', notified: true, pendingId: 'no' }, now), /刷新/);
  assert.deepEqual(processing, before);
});

test('actions: assignment and acceptance preserve an existing round and valid resident time', () => {
  const row = record(Status.pending);
  actions.assign(row, { workerId, worker: { nickName: '张师傅', mobile: '13800138091' } }, now);
  assert.equal(row.status, Status.assigned);
  actions.accept(row, { workerId, slot: String(row.slot), reason: '', pendingId: 'unused' }, now);
  assert.equal(row.status, Status.processing);
  assert.equal(row.agreedTime, row.expectedTime);
  assert.equal(rounds(row).length, 1);
  assert.equal(pendings(row).length, 0);
  assert.deepEqual(events(row).map(item => item.action), ['assigned', 'accept']);
});

test('actions: acceptance retains slot; a later proposal requires the other party response', () => {
  const row = record(Status.assigned);
  const proposed = '2026-10-19#08';
  actions.accept(row, { workerId, reason: '', pendingId: 'unused' }, now);
  actions.propose(row, { slot: proposed, reason: '材料未到', role: 'worker', pendingId: 'move-a' }, now);
  assert.equal(row.agreedTime, row.expectedTime);
  assert.equal(openPending(row, 'reschedule')?.proposedSlot, proposed);
  const before = structuredClone(row);
  businessFailure(() => actions.respond(row, { accept: true, reason: '', role: 'worker' }, now), /自己发起/);
  assert.deepEqual(row, before);
  actions.respond(row, { accept: true, reason: '', role: 'resident' }, now);
  assert.equal(row.agreedTime, parseSlot(proposed)!.start);
  assert.equal(openPending(row, 'reschedule'), undefined);
});

test('actions: invalid acceptance and completion are rejected without mutations', () => {
  const row = record(Status.assigned);
  row.slot = '';
  row.agreedTime = '';
  const before = structuredClone(row);
  businessFailure(() => actions.accept(row, { workerId, slot: '2026-10-17#09', reason: '补时间', pendingId: 'no' }, now), /不足 30 分钟/);
  businessFailure(() => actions.accept(row, { workerId, slot: '2026-10-18#08', reason: '', pendingId: 'no' }, now), /填写上门安排原因/);
  businessFailure(() => actions.complete(row, { workerId, result: '修好', cost: 0 }, now), /已接单/);
  assert.deepEqual(row, before);
});

test('actions: completion closes proposals and resident confirmation starts the warranty', () => {
  const row = record();
  actions.propose(row, { slot: slotFromTime(iso(now + 48 * H)), reason: '改约', role: 'worker', pendingId: 'move-a' }, now);
  actions.complete(row, { workerId, result: '更换水管', cost: 12.5 }, now);
  assert.equal(row.status, Status.confirming);
  assert.equal(currentRound(row).cost, 12.5);
  assert.equal(currentRound(row).confirmDeadline, iso(now + rules.autoConfirmMs));
  assert.equal(pendings(row)[0]?.resolution, 'completed');
  actions.confirm(row, {}, now + H);
  assert.equal(currentRound(row).confirmedAt, iso(now + H));
  assert.equal(currentRound(row).confirmedBy, 'resident');
  assert.equal(warrantyEnd(row), iso(now + H + rules.warrantyMs[0]));
});

test('actions: rejection starts one rework with original worker and supplied contact', () => {
  const row = record(Status.confirming);
  currentRound(row).confirmDeadline = iso(now + H);
  actions.reject(row, { reason: '仍然漏水', worker: { mobile: '13800138092' } }, now);
  assert.equal(row.status, Status.processing);
  assert.equal(row.agreedTime, '');
  assert.equal(rounds(row)[0]?.confirmDeadline, '');
  assert.equal(currentRound(row).number, 2);
  assert.equal(currentRound(row).workerId, workerId);
  assert.equal(row.workerMobile, '13800138092');
  assert(todoTags(row, now).includes('住户未修好'));
  actions.complete(row, { workerId, result: '再次更换', cost: 0 }, now);
  const before = structuredClone(row);
  businessFailure(() => actions.reject(row, { reason: '还未好' }, now), /返修过一次/);
  assert.deepEqual(row, before);
});

test('actions: pending aftersale may be approved after warranty expires', () => {
  const row = completed();
  actions.applyAftersale(row, { reason: '再次漏水', pendingId: 'after-a' }, now);
  actions.reviewAftersale(row, { approve: true, reason: '核实通过' }, now + rules.warrantyMs[0]);
  assert.equal(currentRound(row).number, 2);
  assert.equal(currentRound(row).reason, 'aftersale');
  assert.equal(row.status, Status.processing);
  assert.equal(pendings(row)[0]?.resolution, 'approved');
  assert.equal(row.agreedTime, '');
});

test('actions: release preserves slot, appointment, history and round', () => {
  const row = record();
  actions.propose(row, { slot: slotFromTime(iso(now + 48 * H)), reason: '换时间', role: 'worker', pendingId: 'move-a' }, now);
  actions.revoke(row, { revision: 7, reason: '取消', notified: true, pendingId: 'revoke-a' }, now);
  actions.release(row, { workerId, reason: '无法继续' }, now);
  assert.equal(row.status, Status.pending);
  assert.equal(row.workerId, '');
  assert.equal(row.slot, '2026-10-18#08');
  assert.equal(row.agreedTime, '2026-10-18T08:00:00+08:00');
  assert.equal(currentRound(row).number, 1);
  assert.deepEqual(pendings(row).map(item => item.resolution), ['released', 'released']);
  assert.deepEqual(row.previousWorkers, [{ workerId, workerName: '张师傅', releasedAt: iso(now), reason: '无法继续' }]);
  assert(todoTags(row, now).includes('师傅退出待重派'));
});

test('actions: acknowledgement cancels immediately and objection never reopens the repair', () => {
  const row = record();
  actions.revoke(row, { revision: 7, reason: '取消', notified: true, pendingId: 'revoke-a' }, now);
  actions.acknowledgeRevoke(row, {}, now);
  const expired = structuredClone(row);
  businessFailure(() => actions.objectRevoke(expired, { reason: '已产生费用' }, now + rules.objectionMs), /异议期/);
  actions.objectRevoke(row, { reason: '已产生费用' }, now + rules.objectionMs - 1);
  assert.equal(row.status, Status.cancelled);
  assert(todoTags(row, now).includes('撤销有异议'));
  actions.note(row, { content: '已协调', target: 'objection' }, now + rules.objectionMs);
  assert(!todoTags(row, now).includes('撤销有异议'));
});

test('actions: verification targets the completed round and never overwrites reported cost', () => {
  const row = record();
  actions.complete(row, { workerId, result: '更换水管', cost: 12.5 }, now);
  actions.reject(row, { reason: '仍漏水' }, now);
  actions.note(row, { content: '核实材料', target: 'verify', cost: 10 }, now);
  assert.equal(rounds(row)[0]?.cost, 12.5);
  assert.equal(rounds(row)[0]?.verifiedNote, '核实材料（核实费用 10 元）');
  assert.equal(currentRound(row).verifiedNote, '');
  assert.equal(events(row).at(-1)?.round, 1);
  businessFailure(() => actions.note(row, { content: '不允许', target: 'verify', round: 2 }, now), /尚未提交完工/);
});

test('actions: identical record, input and clock produce identical progress and feedback', () => {
  const first = record();
  const second = structuredClone(first);
  for (const row of [first, second]) {
    actions.progress(row, { content: '正在等材料' }, now);
    actions.residentFeedback(row, { content: '请告知进度', pendingId: 'feedback-a' }, now);
  }
  assert.deepEqual(first, second);
  assert.equal(first.status, Status.processing);
  assert.equal(first.revision, 7);
});

test('views: only non-admin closed views mask phones; worker history is omitted', () => {
  const row = completed();
  row.previousWorkers = [{ workerId: 'old' }];
  const before = structuredClone(row);
  let clock = now;
  const views = new RepairViews(() => clock, '020-88888888', () => {});
  assert.equal(views.view(row, 'resident').mobile, '13800138000');
  clock += rules.warrantyMs[0];
  assert.equal(views.view(row, 'resident').mobile, '138****8000');
  assert.equal(views.view(row, 'worker').workerMobile, '138****8091');
  assert.equal(views.view(row, 'worker').previousWorkers, undefined);
  assert.equal(views.view(row, 'admin').mobile, '13800138000');
  assert.equal(views.view(row, 'admin').propertyPhone, '020-88888888');
  assert.deepEqual(row, before);
});
