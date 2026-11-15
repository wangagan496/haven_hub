import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, NEXT, type Row } from './repair-fixture.js';

for (const round of [1, 2]) {
  test(`reassignment: processing round ${round} clears saved result and requires the replacement to accept`, async t => {
    const f = await fixture(t);
    let row = await f.processing();
    if (round === 2) {
      row = await f.change('worker', row, 'complete', { result: '第一轮结果', cost: 15 });
      row = await f.change('resident', row, 'reject', { reason: '仍然漏水' });
    }
    row = await f.change('worker', row, 'result', { result: '前任处理结果', cost: 81, ready: true, cause: '前任判断' });
    assert.equal(row.resultReady, true);
    const fees = structuredClone(f.stored(row).fees);
    const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/assignment-options`);
    assert.equal(options.find((item: Row) => item.id === f.ids.worker2).selectable, true);
    const previous = row;
    row = await f.change('admin', row, 'assign', { workerId: f.ids.worker2 });
    assert.equal(row.status, 5);
    assert.equal(row.workerId, f.ids.worker2);
    assert.equal(row.round, round);
    assert.equal(row.acceptedAt, '');
    assert.deepEqual(f.stored(row).fees, fees);
    const current = f.stored(row).rounds[0];
    assert.equal(current.note, '');
    assert.equal(current.cost, null);
    assert.equal(current.cause, '待排查');
    assert.equal(current.resultSavedAt, '');
    assert.equal((await f.detail(row)).resultReady, false);
    const onsite = f.store.one("SELECT count(*) AS n FROM notifications WHERE repairId=? AND taskKey LIKE 'onsite-confirm:%' AND active=1", row.id);
    assert.equal(onsite?.n, 0);
    assert.equal((await f.raw('worker', 'GET', `/worker/repairs/${row.id}`)).status, 404);
    assert.equal((await f.raw('resident', 'PUT', `/repair/${row.id}/confirm`, { revision: row.revision })).code, 40001);
    assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/assign`, { revision: previous.revision, workerId: f.ids.worker })).status, 409);
    assert.equal((await f.raw('worker2', 'PUT', `/worker/repairs/${row.id}/result`, { revision: row.revision, ready: true, result: '尚未接单', cost: 0 })).code, 40001);
    row = await f.change('worker2', row, 'accept');
    row = await f.change('worker2', row, 'result', { ready: true, result: '乙师傅重新维修', cost: 22 });
    row = await f.change('resident', row, 'confirm');
    assert.equal(row.status, 3);
    assert.equal(f.stored(row).rounds[0].workerId, f.ids.worker2);
    assert.equal(f.stored(row).fees.at(-1).cost, 22);
  });
}

test('reassignment: processing keeps role, current-worker, skills and schedule guards', async t => {
  const f = await fixture(t);
  const row = await f.processing();
  const path = `/management/repairs/${row.id}/assign`;
  const body = { revision: row.revision, workerId: f.ids.worker2 };
  for (const role of ['resident', 'worker', 'worker2'] as const) assert.equal((await f.raw(role, 'PUT', path, body)).status, 403);
  assert.equal((await f.raw('admin', 'PUT', path, { ...body, workerId: f.ids.worker })).code, 40001);
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/assignment-options`);
  assert.equal(options.find((item: Row) => item.id === f.ids.worker).selectable, false);
  f.store.run('DELETE FROM worker_skills WHERE workerId=?', f.ids.worker2);
  assert.equal((await f.raw('admin', 'PUT', path, body)).status, 409);
  f.store.run("INSERT INTO worker_skills(workerId,skill) VALUES (?, 'plumbing')", f.ids.worker2);
  const other = await f.processing(NEXT, 'worker2');
  // Existing assigned work at the same slot must still prevent reassignment.
  f.store.save('repairs', f.ids.resident, { ...f.stored(other), slot: row.slot, agreedTime: row.agreedTime }, true);
  assert.equal((await f.raw('admin', 'PUT', path, body)).status, 409);
  assert.equal(f.stored(row).workerId, f.ids.worker);
});

test('reassignment: pending revoke blocks assignment without mutation and acknowledgement still cancels', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  row = await f.change('resident', row, 'revoke', { reason: '已电话告知原师傅取消维修', notified: true });
  const before = structuredClone(f.stored(row));
  const path = `/management/repairs/${row.id}/assign`;
  const denied = await f.raw('admin', 'PUT', path, { revision: row.revision, workerId: f.ids.worker2 });
  assert.equal(denied.status, 200);
  assert.equal(denied.code, 40001);
  assert.match(denied.message, /撤销/);
  assert.deepEqual(f.stored(row), before);
  const options = await f.call('admin', 'GET', `/management/repairs/${row.id}/assignment-options`);
  assert(options.length > 0);
  for (const option of options) {
    assert.equal(option.selectable, false);
    assert.equal(option.reason, '住户已申请撤销，请先处理撤销申请');
  }
  assert.equal(options.find((item: Row) => item.id === f.ids.worker2).selectable, false);
  assert.deepEqual(f.stored(row), before);
  assert.equal((await f.raw('worker2', 'GET', `/worker/repairs/${row.id}`)).status, 404);

  row = await f.change('worker', row, 'revoke');
  assert.equal(row.status, 0);
  const cancelled = structuredClone(f.stored(row));
  assert(cancelled.pendings.every((item: Row) => item.kind !== 'revoke' || item.resolvedAt));
  const closed = await f.raw('admin', 'PUT', path, { revision: row.revision, workerId: f.ids.worker2 });
  assert.equal(closed.code, 40001);
  assert.match(closed.message, /只能对未接单工单派单/);
  assert.deepEqual(f.stored(row), cancelled);
});

for (const state of ['confirming', 'completed', 'cancelled'] as const) {
  test(`reassignment: ${state} remains closed to assignment`, async t => {
    const f = await fixture(t);
    let row = await f.processing();
    if (state === 'cancelled') {
      row = await f.change('resident', row, 'revoke', { reason: '取消', notified: true });
      row = await f.change('worker', row, 'revoke');
    } else {
      row = await f.change('worker', row, 'complete', { result: '已修复', cost: 20 });
      if (state === 'completed') row = await f.change('resident', row, 'confirm');
    }
    const before = f.stored(row);
    assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${row.id}/assign`, { revision: row.revision, workerId: f.ids.worker2 })).code, 40001);
    assert.deepEqual(f.stored(row), before);
  });
}
