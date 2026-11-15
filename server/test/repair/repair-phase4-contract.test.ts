import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, type Row } from './repair-fixture.js';

test('phase4: admin slot view supplies shift eligibility without leaking it to resident or worker', async t => {
  const f = await fixture(t);
  const row = await f.processing();
  const path = `/repair/slots?date=2026-10-18&excludeId=${row.id}`;
  const slots = (await f.call('admin', 'GET', path)).slots as Row[];
  assert.equal(slots.find(slot => slot.slot.endsWith('#09'))!.shiftSelectable, false);
  assert.equal(slots.find(slot => slot.slot.endsWith('#10'))!.shiftSelectable, false);
  assert.equal(slots.find(slot => slot.slot.endsWith('#11'))!.shiftSelectable, true);
  for (const role of ['resident', 'worker'] as const) {
    assert.ok((await f.call(role, 'GET', path)).slots.every((slot: Row) => !Object.hasOwn(slot, 'shiftSelectable')));
  }
  assert.ok((await f.call('admin', 'GET', '/repair/slots')).slots.every((slot: Row) => !Object.hasOwn(slot, 'shiftSelectable')));
});

test('phase4: pending first schedule and capacity/worker conflicts exclude shift options', async t => {
  const f = await fixture(t);
  let row = await f.create('');
  row = await f.change('admin', row, 'reschedule', { slot: '2026-10-18#10', reason: '首次安排', notified: true }, 'POST');
  const path = `/repair/slots?date=2026-10-18&excludeId=${row.id}`;
  assert.ok((await f.call('admin', 'GET', path)).slots.every((slot: Row) => slot.shiftSelectable === false));
  const agreed = await f.processing('2026-10-18#14');
  await f.processing('2026-10-18#15');
  await f.capacities(0, '16');
  const slots = (await f.call('admin', 'GET', `/repair/slots?date=2026-10-18&excludeId=${agreed.id}`)).slots as Row[];
  assert.equal(slots.find(slot => slot.slot.endsWith('#15'))!.shiftSelectable, false);
  assert.equal(slots.find(slot => slot.slot.endsWith('#16'))!.shiftSelectable, false);
  assert.equal(slots.find(slot => slot.slot.endsWith('#17'))!.shiftSelectable, true);
});
