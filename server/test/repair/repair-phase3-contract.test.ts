import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, SLOT, NEXT, type Row } from './repair-fixture.js';

for (const arrangement of ['none', 'agreed', 'pending'] as const) {
  test(`phase3 review: urgent dispatch records firstSchedule with previous arrangement ${arrangement}`, async t => {
    const f = await fixture(t);
    let row = await f.create(arrangement === 'agreed' ? SLOT : '');
    if (arrangement === 'pending') {
      row = await f.change('admin', row, 'reschedule', {slot: SLOT, reason: '首次提议', notified: true}, 'POST');
      assert.equal(row.agreedTime, '');
      assert.equal(row.slot, SLOT);
    }
    row = await f.change('admin', row, 'priority', {priority: 'urgent', reason: '核实急单'});
    row = await f.change('admin', row, 'dispatch', {workerId: f.ids.worker, slot: NEXT});
    assert.equal(row.timeline.at(-1).firstSchedule, arrangement === 'none');
    assert.equal((await f.detail(row)).timeline.at(-1).firstSchedule, arrangement === 'none');
    assert.equal((await f.call('worker', 'GET', `/worker/repairs/${row.id}`)).timeline.at(-1).firstSchedule, arrangement === 'none');
    row = await f.change('admin', row, 'dispatch', {workerId: f.ids.worker, slot: SLOT});
    assert.equal(row.timeline.at(-1).firstSchedule, false);
  });
}

test('phase3: non-admin timeline hides previous worker identifier without changing storage or notifications', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  row = await f.change('admin', row, 'priority', { priority: 'urgent', reason: '核实急单' });
  row = await f.change('admin', row, 'dispatch', { workerId: f.ids.worker2, slot: NEXT });
  assert.equal(row.timeline.at(-1).previousWorkerId, f.ids.worker);
  const before = f.stored(row);
  for (const role of ['resident', 'worker2'] as const) {
    const path = role === 'resident' ? `/repair/${row.id}` : `/worker/repairs/${row.id}`;
    const visible = await f.call(role, 'GET', path);
    assert(visible.timeline.every((event: Row) => !Object.hasOwn(event, 'previousWorkerId')));
    assert.match(visible.timeline.at(-1).detail, /由 .* 改派给/);
  }
  const admin = (await f.call('admin', 'GET', '/management/repairs')).find((item: Row) => item.id === row.id);
  assert.equal(admin.timeline.at(-1).previousWorkerId, f.ids.worker);
  assert.deepEqual(f.stored(row), before);
  const notices = () => f.call('worker', 'GET', '/notifications');
  const original = (await notices()).find((item: Row) => item.title === '工单已由物业改派，无需上门');
  assert.equal(original.active, 1);
  assert.equal(original.kind, 'info');
  await f.change('worker2', row, 'progress', { content: '出发' }, 'POST');
  assert.equal((await notices()).find((item: Row) => item.id === original.id).active, 0);
});

test('phase3: notification contract classifies time adjustment, timeout and reassignment as info, others as task', async t => {
  const f = await fixture(t);
  let row = await f.processing('');
  row = await f.change('worker', row, 'reschedule', { slot: SLOT, reason: '首次安排', notified: true }, 'POST');
  const waiting = (await f.call('resident', 'GET', '/notifications')).find((item: Row) => item.title === '等待确认时间');
  assert.equal(waiting.kind, 'task');
  f.at(Date.parse(row.pendings[0].deadline));
  row = await f.detail(row);
  const timeout = (await f.call('resident', 'GET', '/notifications')).find((item: Row) => item.title === '超时已生效');
  assert.equal(timeout.kind, 'info');
  row = await f.change('admin', row, 'shift', { slot: NEXT, reason: '物业协调' });
  const adjusted = (await f.call('worker', 'GET', '/notifications')).find((item: Row) => item.title === '时间已调整' && item.active);
  assert.equal(adjusted.kind, 'info');
  const high = await f.create('', { urgentRequest: true });
  const task = (await f.call('admin', 'GET', '/notifications')).find((item: Row) => item.repairId === high.id && item.title === '紧急诉求待定级');
  assert.equal(task.kind, 'task');
});
