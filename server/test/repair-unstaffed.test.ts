import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, SLOT, NEXT, START, H, type Row } from './repair-fixture.js';
import { RepairRepository } from '../src/repair/repository.js';
import { notificationKind } from '../src/repair/notification-tasks.js';

type F = Awaited<ReturnType<typeof fixture>>;
async function skills(f: F, who: 'worker' | 'worker2', values: string[], preview = false) {
  const profile = await f.call(who, 'GET', '/worker/skills');
  return f.call(who, 'PUT', '/worker/skills', { workforceRevision: profile.workforceRevision, skills: values, preview });
}
async function leave(f: F, who: 'worker' | 'worker2', hour = '10', preview = false) {
  const profile = await f.call(who, 'GET', '/worker/skills');
  return f.call('admin', 'POST', `/management/workers/${f.ids[who]}/leave`,
    { revision: profile.workforceRevision, date: '2026-10-18', hour, preview });
}
async function offered(f: F) {
  const row = await f.create();
  await leave(f, 'worker'); await leave(f, 'worker2');
  return f.detail(row);
}
const notes = (f: F, row: Row, key: string) => f.store.db.prepare('SELECT * FROM notifications WHERE repairId=? AND taskKey LIKE ? AND active=1').all(row.id, key + '%');
const choose = (f: F, row: Row, body: Row) => f.raw('resident', 'PUT', `/repair/${row.id}/unstaffed-choice`,
  { revision: row.revision, offerId: row.rescheduleOffer.id, ...body });
const options = (f: F, row: Row) => f.call('resident', 'GET', `/repair/${row.id}/unstaffed-options?date=2026-10-18`);

test('unstaffed trigger: shared pool shortage waits until one worker claims before offering remainder', async t => {
  const f = await fixture(t); const a = await f.create(); const b = await f.create();
  await leave(f, 'worker');
  assert.equal((await f.detail(a)).rescheduleOffer, undefined);
  assert.equal((await f.detail(b)).rescheduleOffer, undefined);
  await f.change('worker2', await f.detail(a), 'claim');
  const remainder = await f.detail(b);
  assert(remainder.rescheduleOffer.id);
  assert.equal(remainder.slot, SLOT);
  assert.equal(notes(f, b, 'unstaffed_offer:').length, 1);
  assert.equal(notes(f, b, 'staffing:').length, 0);
  assert.equal(notes(f, b, 'assignment').length, 0);
  assert.equal((await f.detail(b)).rescheduleOffer.id, remainder.rescheduleOffer.id);
});

test('unstaffed trigger: unscheduled urgent unclassified and pending changes never receive offers', async t => {
  const f = await fixture(t); const base = await offered(f);
  for (const patch of [{ slot: '', agreedTime: '' }, { priority: 'urgent' }, { priority: '', urgentRequest: true },
    { repairItemId: '1003' }, { pendings: [{ id: 'p', kind: 'reschedule' }] }, { pendings: [{ id: 'p', kind: 'revoke' }] }]) {
    const row: Row & { id: string } = { ...f.stored(base), ...patch }; delete row.rescheduleOffer;
    f.store.save('repairs', f.ids.resident, row, true);
    assert.equal((await f.detail(row)).rescheduleOffer, undefined);
    f.store.save('repairs', f.ids.resident, { ...base, staffingIssue: '', rescheduleOffer: undefined }, true);
  }
});

test('unstaffed deadline: shared response constants cap deadline and short response goes directly to property', async t => {
  const f = await fixture(t); const row = await f.create();
  f.at(Date.parse('2026-10-18T07:15:00+08:00'));
  await leave(f, 'worker'); await leave(f, 'worker2');
  let current = await f.detail(row);
  assert.equal(Date.parse(current.rescheduleOffer.deadline), Date.parse('2026-10-18T08:00:00+08:00'));
  const stored = f.stored(row); delete stored.rescheduleOffer; f.store.save('repairs', f.ids.resident, stored, true);
  f.at(Date.parse('2026-10-18T07:31:00+08:00')); current = await f.detail(row);
  assert.equal(current.rescheduleOffer, undefined);
  f.notifications.sync(f.ids.resident, f.stored(row));
  assert.match(String(notes(f, row, 'staffing:')[0]?.body), /住户未改时间，请电话联系/);
});

test('unstaffed stale: added skills or property assignment closes offer and resident task', async t => {
  for (const action of ['skills', 'assign']) {
    const f = await fixture(t);
    await skills(f, 'worker2', ['doors']); const row = await f.create(); await leave(f, 'worker');
    const open = await f.detail(row); assert(open.rescheduleOffer.id);
    if (action === 'skills') await skills(f, 'worker2', ['plumbing']);
    else {
      f.store.run("INSERT INTO worker_skills(workerId,skill) VALUES (?,'plumbing')", f.ids.worker2);
      const refreshed = await f.detail(row);
      await f.change('admin', refreshed, 'assign', { workerId: f.ids.worker2 });
    }
    const updated = await f.detail(row);
    assert.equal(updated.rescheduleOffer.resolution, 'stale');
    f.notifications.sync(f.ids.resident, f.stored(row)); assert.equal(notes(f, row, 'unstaffed_offer:').length, 0);
  }
});

test('unstaffed choices: shared filtering requires lead capacity eligibility and nonincreasing shortage; earlier slots allowed', async t => {
  const f = await fixture(t); const row = await offered(f);
  await f.capacities(0, '11'); await leave(f, 'worker', '14'); await leave(f, 'worker2', '14');
  const result = await options(f, row);
  assert(result.slots.length > 0);
  assert(!result.slots.some((s: Row) => [SLOT, NEXT, '2026-10-18#14'].includes(s.slot)));
  assert(result.slots.some((s: Row) => s.slot === '2026-10-18#08'));
  for (const s of result.slots) { assert.equal(s.selectable, true); assert(Date.parse(s.start) - f.time() >= 2 * H); }
  const admin = await f.call('admin', 'GET', `/management/repairs/${row.id}/unstaffed-options`);
  assert.equal(admin.slots.length, 3);
  for (const s of admin.slots) { assert(s.remaining > 0); assert(s.eligibleWorkerCount > 0); }
  const all: Row[] = [];
  for (const day of result.dates) all.push(...(await f.call('resident', 'GET', `/repair/${row.id}/unstaffed-options?date=${day}`)).slots);
  assert.deepEqual(admin.slots.map(({ capacity, remaining, eligibleWorkerCount, occupied, ...slot }: Row) => slot), all.slice(0, 3));
});

test('unstaffed resident options omit quota numbers while management retains all six fields', async t => {
  const f = await fixture(t); const row = await offered(f);
  const resident = await options(f, row);
  const admin = await f.call('admin', 'GET', `/management/repairs/${row.id}/unstaffed-options`);
  assert(resident.slots.length > 0); assert(admin.slots.length > 0);
  for (const key of ['remainingTotal', 'selectableRemainingTotal']) {
    assert.equal(Object.hasOwn(resident, key), false); assert.equal(typeof admin[key], 'number');
  }
  for (const key of ['capacity', 'remaining', 'eligibleWorkerCount', 'occupied']) {
    for (const slot of resident.slots) assert.equal(Object.hasOwn(slot, key), false);
    for (const slot of admin.slots) assert.equal(typeof slot[key], 'number');
  }
  const ordinary = await f.slots();
  assert.equal(typeof ordinary.remainingTotal, 'number');
  assert.equal(typeof ordinary.slots[0].capacity, 'number');
});

test('unstaffed resident: selecting applies immediately preserves pool and shift count and informs property', async t => {
  const f = await fixture(t); const row = await offered(f);
  const result = await choose(f, row, { slot: NEXT }); assert.equal(result.status, 200);
  const saved = f.stored(row);
  assert.equal(saved.slot, NEXT); assert.equal(saved.agreedTime, '2026-10-18T11:00:00+08:00');
  assert.equal(saved.status, 1); assert.equal(saved.shiftCount, row.shiftCount); assert.equal(saved.staffingIssue, '');
  assert.equal(saved.rescheduleOffer.resolution, 'resident_rescheduled');
  assert.equal(saved.timeline.at(-1).label, '住户因排不开师傅改选上门时间');
  assert.match(saved.timeline.at(-1).detail, / → /);
  const notice = notes(f, row, 'resident_rescheduled:')[0]!; assert.equal(notificationKind(String(notice.taskKey)), 'info'); assert.equal(notice.title, '住户已改时间');
  assert((await f.call('worker', 'GET', '/worker/repair-pool')).some((r: Row) => r.id === row.id));
  assert.equal(notes(f, row, 'unstaffed_offer:').length, 0);
});

test('unstaffed concurrency: two residents racing last capacity get one success and unchanged losing order', async t => {
  const f = await fixture(t); const a = await f.create(); const b = await f.create();
  f.store.run('UPDATE repairs SET userId=? WHERE id=?', f.ids.other, b.id);
  await leave(f, 'worker'); await leave(f, 'worker2'); await f.capacities(1, '11');
  const rows = [await f.detail(a), await f.call('other', 'GET', `/repair/${b.id}`)];
  const results = await Promise.all(rows.map((row, i) => f.raw(i ? 'other' : 'resident', 'PUT', `/repair/${row.id}/unstaffed-choice`,
    { revision: row.revision, offerId: row.rescheduleOffer.id, slot: NEXT })));
  assert.equal(results.filter(r => r.status === 200).length, 1);
  assert.equal(results.filter(r => r.status === 409).length, 1);
  const loser = results.findIndex(r => r.status === 409);
  assert.equal(results[loser]!.message, '该时段刚被约满，请重新选择');
  const saved = f.store.get('repairs', loser ? f.ids.other : f.ids.resident, rows[loser]!.id)!;
  assert.equal(saved.slot, SLOT); assert.equal(saved.revision, rows[loser]!.revision);
});

test('unstaffed fallback: keep and expiry close resident task create property phone task and never reoffer', async t => {
  for (const mode of ['keep', 'expired']) {
    const f = await fixture(t); const row = await offered(f);
    if (mode === 'keep') assert.equal((await choose(f, row, { keep: true })).status, 200);
    else {
      f.at(Date.parse(row.rescheduleOffer.deadline));
      const result = await choose(f, row, { slot: NEXT });
      assert.equal(result.status, 409); assert.equal(result.message, '已过可选时间，物业会联系您');
    }
    const saved = await f.detail(row); assert.equal(saved.slot, SLOT);
    assert.equal(saved.rescheduleOffer.resolution, mode === 'keep' ? 'resident_kept' : 'expired');
    f.notifications.sync(f.ids.resident, f.stored(row));
    assert.equal(notes(f, row, 'unstaffed_offer:').length, 0);
    assert.match(String(notes(f, row, 'staffing:')[0]?.body), /住户未改时间，请电话联系/);
    assert.equal((await f.call('admin', 'GET', `/management/repairs/${row.id}/unstaffed-options`)).slots.length, 3);
  }
});

test('unstaffed authorization and revision: foreign resident hidden worker forbidden and ordinary conflicts unchanged', async t => {
  const f = await fixture(t); const row = await offered(f); const body = { revision: row.revision, offerId: row.rescheduleOffer.id, slot: NEXT };
  assert.equal((await f.raw('other', 'PUT', `/repair/${row.id}/unstaffed-choice`, body)).status, 404);
  assert.equal((await f.raw('worker', 'PUT', `/repair/${row.id}/unstaffed-choice`, body)).status, 403);
  assert.equal((await choose(f, row, { revision: row.revision - 1, slot: NEXT })).message, '记录已更新，请刷新后再操作');
  assert.equal((await choose(f, row, { offerId: 'wrong', slot: NEXT })).message, '已过可选时间，物业会联系您');
});

test('unstaffed property: requires phone confirmation checks target atomically and rejects ordinary orders', async t => {
  const f = await fixture(t); const row = await offered(f); const path = `/management/repairs/${row.id}/unstaffed-reschedule`;
  assert.equal((await f.raw('admin', 'PUT', path, { revision: row.revision, slot: NEXT })).code, 40001);
  await f.capacities(0, '11');
  const refused = await f.raw('admin', 'PUT', path, { revision: row.revision, slot: NEXT, notified: true });
  assert.equal(refused.status, 409); assert.equal(refused.message, '该时段已不可选'); assert.equal(f.stored(row).slot, SLOT);
  await f.capacities(1, '11');
  const changed = await f.call('admin', 'PUT', path, { revision: row.revision, slot: NEXT, notified: true });
  assert.equal(changed.slot, NEXT); assert.equal(changed.rescheduleOffer.resolution, 'stale');
  assert.equal(changed.timeline.at(-1).label, '物业电话确认后改时间'); assert.equal(changed.shiftCount, row.shiftCount);
  assert.equal((await f.raw('admin', 'PUT', path, { revision: changed.revision, slot: '2026-10-18#14', notified: true })).code, 40001);
  assert.equal((await choose(f, changed, { slot: '2026-10-18#14' })).status, 409);
});

test('unstaffed preview: unchanged shortages excluded new shortages included and worker ids recursively removed', async t => {
  const f = await fixture(t); await f.create(); await f.create(); await leave(f, 'worker');
  let preview = await leave(f, 'worker', '11', true); assert.deepEqual(preview.shortages, []);
  const a = await f.create(NEXT); const b = await f.create(NEXT);
  preview = await leave(f, 'worker', '11', true);
  assert.deepEqual(preview.shortages.map((s: Row) => s.slot), [NEXT]);
  assert.deepEqual(preview.shortages[0].orders.map((r: Row) => r.id).sort(), [a.id, b.id].sort());
  const self = await skills(f, 'worker', ['doors'], true);
  assert.equal(self.shortages.length, 1); assert(!JSON.stringify(self).includes('"id"'));
});

test('unstaffed settlement: owner filtering updates aggregate warning on another owners order', async t => {
  const f = await fixture(t); const a = await f.create(); f.at(START + 1); const b = await f.create();
  f.store.run('UPDATE repairs SET userId=? WHERE id=?', f.ids.other, a.id);
  f.store.run("INSERT INTO worker_leaves(workerId,date,hour,reason) VALUES (?,'2026-10-18','10','test')", f.ids.worker);
  const repository = new RepairRepository(f.store, f.time, () => {}, '');
  repository.settleAll({ owner: f.ids.resident });
  assert.equal((f.store.get('repairs', f.ids.other, a.id)!.poolShortage as Row).shortage, 1);
  f.store.run('DELETE FROM worker_leaves WHERE workerId=?', f.ids.worker);
  repository.settleAll({ owner: f.ids.resident });
  assert.equal(f.store.get('repairs', f.ids.other, a.id)!.poolShortage, null);
  assert.equal(f.stored(b).slot, SLOT);
});

test('unstaffed lifecycle: no options closes stale and restored capacity creates a new offer', async t => {
  const f = await fixture(t); const row = await offered(f);
  f.store.run('UPDATE repair_capacity_defaults SET capacity=0');
  const stale = await f.detail(row);
  assert.equal(stale.rescheduleOffer.resolution, 'stale');
  assert.equal((await choose(f, row, { slot: NEXT })).message, '已过可选时间，物业会联系您');
  f.store.run('UPDATE repair_capacity_defaults SET capacity=2');
  const renewed = await f.detail(row);
  assert(renewed.rescheduleOffer.id !== row.rescheduleOffer.id);
  assert.equal(renewed.rescheduleOffer.resolvedAt, undefined);
});

test('unstaffed preview: increasing an existing matching deficit is included', async t => {
  const f = await fixture(t); const a = await f.create(); await f.create();
  f.store.save('repairs', f.ids.resident, { ...f.stored(a), id: 'third-reservation', createdAt: new Date(START + 1).toISOString() });
  const preview = await leave(f, 'worker', '10', true);
  assert.equal(preview.shortages.length, 1); assert.equal(preview.shortages[0].shortage, 2);
});

test('unstaffed choices: free public quota cannot admit additional matching deficit', async t => {
  const f = await fixture(t); const row = await offered(f);
  await f.create(NEXT); await f.create(NEXT);
  const response = await options(f, row);
  assert(!response.slots.some((s: Row) => s.slot === NEXT));
  const before = f.stored(row);
  const result = await choose(f, await f.detail(row), { slot: NEXT });
  assert.equal(result.status, 409); assert.equal(result.message, '该时段刚被约满，请重新选择');
  assert.deepEqual(f.stored(row), before);
});

test('unstaffed trigger: no future alternatives creates no offer and property shift voids an open offer', async t => {
  const f = await fixture(t); const row = await f.create();
  f.store.run('UPDATE repair_capacity_defaults SET capacity=0');
  await leave(f, 'worker'); await leave(f, 'worker2');
  const unavailable = await f.detail(row);
  assert.equal(unavailable.rescheduleOffer, undefined); assert.equal(notes(f, row, 'unstaffed_offer:').length, 0);
  f.store.run('UPDATE repair_capacity_defaults SET capacity=2');
  const open = await f.detail(row); assert(open.rescheduleOffer.id);
  const shifted = await f.change('admin', open, 'shift', { slot: NEXT, reason: '物业顺延' });
  assert.equal(shifted.rescheduleOffer.resolution, 'stale');
  assert.equal(notes(f, row, 'unstaffed_offer:').length, 0);
});
